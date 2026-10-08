#!/usr/bin/env bash
#
# Obtain and renew the TLS certificate, then reload nginx.
#
#   cert-renew.sh --issue          # first issuance
#   cert-renew.sh                  # renew if due (safe to run daily)
#   cert-renew.sh --force          # renew even if not due
#   cert-renew.sh --dry-run        # exercise the flow against the ACME staging path
#   cert-renew.sh --install-timer  # install the systemd renewal timer
#
# nginx serves TLS but never issues anything. Certbot runs as a one-shot
# container against the webroot nginx already exposes at
# /.well-known/acme-challenge/, so there is no host-level certbot install and
# no need to stop nginx to renew.
#
# HTTP-01 validation requires port 80 to be reachable from the public
# internet: https://letsencrypt.org/docs/allow-port-80/
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

CERTBOT_IMAGE="${KUBEDOK_CERTBOT_IMAGE:-certbot/certbot:latest}"

MODE="renew"
FORCE=false
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --issue) MODE="issue"; shift ;;
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --install-timer) MODE="install-timer"; shift ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_root
require_installed
require_cmd docker curl
load_config

LE_DIR="${KUBEDOK_TLS_DIR}/letsencrypt"
WEBROOT="${KUBEDOK_TLS_DIR}/webroot"

install_timer() {
  command -v systemctl >/dev/null 2>&1 \
    || die "systemd is not available. Schedule ${SCRIPT_DIR}/cert-renew.sh twice daily by another means."

  cat > /etc/systemd/system/kubedok-cert-renew.service <<UNIT
[Unit]
Description=Renew the Kubedok TLS certificate
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${KUBEDOK_ROOT}/current/scripts/cert-renew.sh
UNIT

  # Twice daily is the Let's Encrypt recommendation; the random delay keeps
  # every Kubedok install in the world from hitting the ACME API at once.
  cat > /etc/systemd/system/kubedok-cert-renew.timer <<UNIT
[Unit]
Description=Renew the Kubedok TLS certificate twice daily

[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload
  systemctl enable --now kubedok-cert-renew.timer >/dev/null
  ok "Renewal timer installed (next: $(systemctl show kubedok-cert-renew.timer -p NextElapseUSecRealtime --value 2>/dev/null || echo 'see systemctl list-timers'))"
}

if [ "${MODE}" = "install-timer" ]; then
  install_timer
  exit 0
fi

[ -n "${KUBEDOK_HOST:-}" ] \
  || die "KUBEDOK_HOST is not set in ${KUBEDOK_CONFIG_FILE}. TLS needs a DNS name."

mkdir -p "${LE_DIR}" "${WEBROOT}"
chmod 755 "${WEBROOT}"

certbot_run() {
  docker run --rm \
    -v "${LE_DIR}:/etc/letsencrypt" \
    -v "${WEBROOT}:/var/www/certbot" \
    "${CERTBOT_IMAGE}" "$@"
}

# Outcome of fetching the probe marker: "200" only when the marker itself came
# back; otherwise the HTTP status, a note that a 200 carried the wrong body, or
# curl's own error when nothing answered at all (DNS failure, refused
# connection, timeout). Never fails the caller.
#   $1  the client: local_curl for loopback, curl for the public route
#   $2  the URL; anything after it is passed to the client
probe_outcome() {
  local via="$1" url="$2"; shift 2
  local errfile out body code
  errfile="$(mktemp)"
  out="$("${via}" -sS --max-time 15 -w '\n%{http_code}' "$@" "${url}" 2>"${errfile}")" || true
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  if [ -z "${code}" ] || [ "${code}" = "000" ]; then
    code="$(head -n1 "${errfile}" | sed 's/^curl: ([0-9]*) //')"
    [ -n "${code}" ] || code="no response"
  elif [ "${code}" = "200" ] && [ "${body}" != "ok" ]; then
    code="200 but not the marker: something other than the challenge webroot answered"
  fi
  rm -f "${errfile}"
  printf '%s' "${code}"
}

reload_nginx() {
  if docker inspect kubedok-nginx >/dev/null 2>&1 \
    && [ "$(docker inspect -f '{{.State.Running}}' kubedok-nginx)" = "true" ]; then
    # A reload picks up the renewed files without dropping connections.
    if docker exec kubedok-nginx nginx -s reload >/dev/null 2>&1; then
      ok "nginx reloaded"
    else
      warn "Could not reload nginx. Restart it: $(command_hint restart) nginx"
    fi
  fi
}

case "${MODE}" in
  issue)
    log "Requesting a certificate for ${KUBEDOK_HOST}"

    if [ -f "${LE_DIR}/live/${KUBEDOK_HOST}/fullchain.pem" ] && [ "${FORCE}" != "true" ]; then
      ok "A certificate for ${KUBEDOK_HOST} already exists. Use --force to replace it."
      exit 0
    fi

    # The challenge path has to work before certbot is asked to use it,
    # otherwise the failure surfaces as an opaque ACME error.
    #
    # certbot --webroot writes each token to <webroot>/.well-known/acme-challenge/
    # and nginx maps the request URI onto that same tree (`root`, not `alias`),
    # so the probe has to sit at exactly that depth. A file at the top of the
    # webroot gets a 404 and makes a perfectly good install look firewalled.
    probe_dir="${WEBROOT}/.well-known/acme-challenge"
    probe="kubedok-acme-probe-$$"
    probe_path="/.well-known/acme-challenge/${probe}"
    mkdir -p "${probe_dir}"
    chmod 755 "${WEBROOT}/.well-known" "${probe_dir}"
    printf 'ok' > "${probe_dir}/${probe}"
    chmod 644 "${probe_dir}/${probe}"
    trap 'rm -f "${probe_dir:?}/${probe:?}"' EXIT

    # Two probes, so the failure names the right layer: nginx on this host
    # first, then the public route Let's Encrypt will actually take.
    local_url="$(local_base_url)${probe_path}"
    status="$(probe_outcome local_curl "${local_url}")"
    if [ "${status}" != "200" ]; then
      die "nginx on this host is not serving the ACME challenge webroot.
    Tried: ${local_url} (pinned to 127.0.0.1) -> ${status}
    Expected 200 for ${probe_dir}/${probe}.
    Check that nginx is running (docker logs kubedok-nginx) and that
    ${WEBROOT} is mounted at /var/www/certbot inside the container."
    fi
    ok "nginx serves the challenge webroot"

    # Let's Encrypt follows redirects, HTTPS included, and does not validate
    # the certificate it lands on — so neither does this probe.
    public_url="http://${KUBEDOK_HOST}${probe_path}"
    status="$(probe_outcome curl "${public_url}" --location --max-redirs 10 --insecure)"
    if [ "${status}" != "200" ]; then
      die "The ACME challenge path is not reachable from the internet.
    Tried: ${public_url} -> ${status}
    nginx serves it locally, so the problem is on the way in. Check that
    port 80 is open in the firewall and any cloud security group, that
    ${KUBEDOK_HOST} resolves to this server, and that no proxy or CDN in
    front rewrites /.well-known/acme-challenge/. A 200 without the marker
    means a redirect landed somewhere that does not serve the challenge
    webroot — usually an edge forcing HTTPS in front of an older nginx.
    Let's Encrypt requires port 80: https://letsencrypt.org/docs/allow-port-80/"
    fi
    rm -f "${probe_dir:?}/${probe}"
    trap - EXIT
    ok "Challenge path reachable from the internet"

    args=(certonly --webroot -w /var/www/certbot
          -d "${KUBEDOK_HOST}"
          --agree-tos --non-interactive
          --keep-until-expiring)
    # The contact address is optional: Let's Encrypt registers an account
    # without one, and it stopped sending expiry reminders in 2025. Only the
    # first issuance registers; later runs reuse the account.
    if [ -n "${KUBEDOK_LETSENCRYPT_EMAIL:-}" ]; then
      args+=(--email "${KUBEDOK_LETSENCRYPT_EMAIL}" --no-eff-email)
    else
      args+=(--register-unsafely-without-email)
    fi
    [ "${DRY_RUN}" = "true" ] && args+=(--dry-run)
    [ "${FORCE}" = "true" ] && args+=(--force-renewal)

    certbot_run "${args[@]}" || die "Certificate issuance failed. See the certbot output above."

    if [ "${DRY_RUN}" = "true" ]; then
      ok "Dry run succeeded — the real issuance should work."
      exit 0
    fi

    ok "Certificate issued for ${KUBEDOK_HOST}"
    install_timer
    ;;

  renew)
    log "Renewing certificates if due"
    # Only the host nginx serves. A certificate for a host the install used to
    # have stops validating once its DNS moves away, and its failure would
    # fail the run before nginx reloaded the one in use.
    args=(renew --cert-name "${KUBEDOK_HOST}" --webroot -w /var/www/certbot --non-interactive)
    [ "${DRY_RUN}" = "true" ] && args+=(--dry-run)
    [ "${FORCE}" = "true" ] && args+=(--force-renewal)

    if certbot_run "${args[@]}"; then
      [ "${DRY_RUN}" = "true" ] && { ok "Dry-run renewal succeeded."; exit 0; }
      ok "Renewal check complete"
      reload_nginx
    else
      die "Renewal failed. Certificates already on disk are untouched; investigate before they expire."
    fi
    ;;
esac
