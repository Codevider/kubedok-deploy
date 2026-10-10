#!/usr/bin/env bash
#
# Kubedok installer.
#
# Idempotent and executable — run it, do not source it. Re-running against an
# existing install is safe: it never regenerates secrets, never touches the
# database volume, and keeps the installed release (update.sh moves that) and
# the saved settings. A variable given to a re-run changes that setting and is
# saved, which is how the host and TLS mode change after install; config.sh
# changes the rest.
#
#   git clone https://github.com/Codevider/kubedok-deploy.git kubedok
#   cd kubedok
#   sudo KUBEDOK_HOST=kubedok.example.com KUBEDOK_TLS=auto ./setup.sh
#
# Clone rather than download: this script sources scripts/common.sh and
# installs the compose/ files, so it cannot run as a standalone file.
#
# Configuration (environment variables):
#   KUBEDOK_HOST                 DNS name this install is served on. Required for TLS.
#   KUBEDOK_TLS                  off | on | auto          (default: auto)
#   KUBEDOK_TLS_SKIP_DNS_CHECK   Proceed even if DNS points at a proxy/CDN.
#   KUBEDOK_LETSENCRYPT_EMAIL    Contact address for the ACME account. Optional.
#   KUBEDOK_ENABLE_AGENT         Install the agent on this host too. (default: false)
#   KUBEDOK_RELEASE              Channel name or exact version. (default: stable)
#   KUBEDOK_PUBLIC_POSTGRES      Publish 5432 for debugging. (default: false)
#   KUBEDOK_ROOT                 Install directory. (default: /opt/kubedok)
#   KUBEDOK_RESTORE_FROM         A backup archive (kbd backup's) to start a NEW
#                                install from, instead of an empty database.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap: common.sh ships beside this script in the repo, and under
# scripts/ once installed.
if [ -f "${SCRIPT_DIR}/scripts/common.sh" ]; then
  # shellcheck source=scripts/common.sh
  . "${SCRIPT_DIR}/scripts/common.sh"
elif [ -f "${SCRIPT_DIR}/common.sh" ]; then
  # shellcheck source=scripts/common.sh
  . "${SCRIPT_DIR}/common.sh"
else
  # setup.sh cannot bootstrap itself: it needs scripts/ and compose/ from this
  # repository. Downloading this one file is the most likely way to get here,
  # so say exactly what to do instead of naming a missing path.
  cat >&2 <<'HINT'
setup.sh cannot run on its own — it needs the scripts/ and compose/
directories that live beside it in the repository.

Clone the repository and run it from there:

  git clone https://github.com/Codevider/kubedok-deploy.git kubedok
  cd kubedok
  sudo ./setup.sh

HINT
  exit 1
fi

# ── 1. Root ──────────────────────────────────────────────────────────────────
require_root "$@"

# ── Settings ─────────────────────────────────────────────────────────────────
# Read before any default applies. A re-run starts from the saved settings, so
# one given no variables changes nothing: it once fell back to the defaults
# here, which turned TLS off and moved to the newest release. A variable given
# on the command line wins over the saved value and is saved in its place.
load_config_under_env
for key in ${GIVEN_SETTINGS}; do
  check_setting "${key}" "${!key}"
done

KUBEDOK_TLS="${KUBEDOK_TLS:-auto}"
KUBEDOK_RELEASE="${KUBEDOK_RELEASE:-stable}"
KUBEDOK_ENABLE_AGENT="${KUBEDOK_ENABLE_AGENT:-false}"
KUBEDOK_PUBLIC_POSTGRES="${KUBEDOK_PUBLIC_POSTGRES:-false}"
KUBEDOK_SKIP_DEPS="${KUBEDOK_SKIP_DEPS:-false}"
KUBEDOK_RESTORE_FROM="${KUBEDOK_RESTORE_FROM:-}"

# ── 2. Supported platform ────────────────────────────────────────────────────
check_platform() {
  log "Checking platform"

  [ -r /etc/os-release ] || die "Cannot read /etc/os-release. Only Debian and Ubuntu are supported today."
  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID:-}:${ID_LIKE:-}" in
    debian:*|ubuntu:*|*:*debian*)
      ok "Detected ${PRETTY_NAME:-${ID}}"
      ;;
    *)
      die "Unsupported distribution: ${PRETTY_NAME:-${ID:-unknown}}. Only Debian and Ubuntu are supported today. Install Docker yourself and re-run with KUBEDOK_SKIP_DEPS=true to continue anyway."
      ;;
  esac
}

# ── 3. Dependencies ──────────────────────────────────────────────────────────
install_dependencies() {
  if [ "${KUBEDOK_SKIP_DEPS}" = "true" ]; then
    warn "KUBEDOK_SKIP_DEPS=true — not installing packages"
    require_cmd curl openssl jq flock docker
    return 0
  fi

  log "Installing dependencies"

  local wanted=(ca-certificates curl openssl jq util-linux)
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends "${wanted[@]}" >/dev/null
  ok "Base packages present"

  if docker version >/dev/null 2>&1; then
    ok "Docker Engine already installed ($(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'version unknown'))"
  else
    log "Installing Docker Engine from the official repository"
    install -m 0755 -d /etc/apt/keyrings
    local codename
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    local distro_id
    distro_id="$(. /etc/os-release && echo "${ID}")"

    curl -fsSL "https://download.docker.com/linux/${distro_id}/gpg" \
      -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
      "$(dpkg --print-architecture)" "${distro_id}" "${codename}" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
    systemctl enable --now docker >/dev/null 2>&1 || true
    ok "Docker Engine installed"
  fi

  if ! docker compose version >/dev/null 2>&1; then
    log "Installing the Docker Compose plugin"
    apt-get install -y -qq --no-install-recommends docker-compose-plugin >/dev/null \
      || die "Could not install the Docker Compose plugin. Install it manually and re-run."
  fi
  ok "Docker Compose available ($(docker compose version --short 2>/dev/null || echo 'version unknown'))"

  require_cmd curl openssl jq flock docker
}

# ── 4. Architecture and Docker capability ────────────────────────────────────
check_capabilities() {
  log "Checking architecture and Docker"

  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64|aarch64|arm64) ok "Architecture ${arch} is supported" ;;
    *) die "Unsupported CPU architecture: ${arch}. Kubedok images are published for amd64 and arm64." ;;
  esac

  docker info >/dev/null 2>&1 \
    || die "Cannot talk to the Docker daemon. Is it running? Try: systemctl status docker"

  # A control plane that cannot pull images is not going to get far.
  docker run --rm hello-world >/dev/null 2>&1 \
    || warn "Could not run a test container. Image pulls may fail — check outbound network and registry access."

  ok "Docker is usable"
}

# ── TLS decision ─────────────────────────────────────────────────────────────
# Resolved before anything is started, because it changes how nginx is
# configured and whether the ACME client runs at all.
resolve_tls() {
  log "Resolving TLS mode (KUBEDOK_TLS=${KUBEDOK_TLS})"

  case "${KUBEDOK_TLS}" in
    off)
      KUBEDOK_TLS_ENABLED=false
      warn "TLS is disabled. Kubedok will be served over plain HTTP."
      ;;
    on)
      [ -n "${KUBEDOK_HOST:-}" ] \
        || die "KUBEDOK_TLS=on requires KUBEDOK_HOST to be a DNS name you control."
      check_tls_host
      KUBEDOK_TLS_ENABLED=true
      ok "TLS enabled for ${KUBEDOK_HOST}"
      ;;
    auto)
      if [ -z "${KUBEDOK_HOST:-}" ]; then
        KUBEDOK_TLS_ENABLED=false
        warn "No KUBEDOK_HOST set — serving HTTP only. No self-signed certificate is created."
      else
        # A hostname was supplied, so silently downgrading would hide a DNS
        # mistake behind an insecure install.
        check_tls_host
        KUBEDOK_TLS_ENABLED=true
        ok "TLS enabled for ${KUBEDOK_HOST}"
      fi
      ;;
    *)
      die "KUBEDOK_TLS must be one of: off, on, auto (got: ${KUBEDOK_TLS})"
      ;;
  esac

  export KUBEDOK_TLS_ENABLED
}

# Returns when KUBEDOK_HOST can be served over TLS from here; explains why not
# and exits otherwise. A host that already has a certificate needs no DNS
# check: the check guards issuance, and a re-run must not stop because the
# record has been proxied since.
check_tls_host() {
  if [ -f "$(certificate_path "${KUBEDOK_HOST}")" ]; then
    ok "${KUBEDOK_HOST} already has a certificate"
    return 0
  fi
  dns_points_here "${KUBEDOK_HOST}" && return 0
  if [ "${KUBEDOK_TLS_SKIP_DNS_CHECK:-false}" = "true" ]; then
    warn "DNS does not point here, but KUBEDOK_TLS_SKIP_DNS_CHECK=true — continuing."
    if [ -n "${DNS_CDN}" ]; then
      warn "Traffic appears to route through ${DNS_CDN}; the ACME challenge must reach this host through it."
    fi
    return 0
  fi
  explain_dns_failure "${KUBEDOK_HOST}"
  exit 1
}

# True when the hostname resolves to an address this machine holds.
#
# Sets DNS_RESOLVED, DNS_LOCAL and DNS_CDN so the caller can explain the
# failure instead of just asserting it. "It does not resolve here" is useless
# advice to someone looking at a DNS record they just created correctly.
DNS_RESOLVED=""
DNS_LOCAL=""
DNS_CDN=""

dns_points_here() {
  local host="$1"
  local addr

  DNS_CDN=""
  DNS_RESOLVED="$(getent ahosts "${host}" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  if [ -z "${DNS_RESOLVED}" ]; then
    debug "${host} does not resolve at all"
    return 1
  fi

  DNS_LOCAL="$(ip -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u || true)"
  # Behind NAT the public address is not on any local interface, so also ask
  # what the outside world sees. Two providers, in case one is blocked.
  local public_addr
  public_addr="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null || true)"
  [ -n "${public_addr}" ] && DNS_LOCAL="${DNS_LOCAL}"$'\n'"${public_addr}"

  for addr in ${DNS_RESOLVED}; do
    if printf '%s\n' "${DNS_LOCAL}" | grep -qx "${addr}"; then
      debug "${host} resolves to ${addr}, which is local"
      return 0
    fi
  done

  # A proxied DNS record resolves to the CDN, never to the origin. That is the
  # single most common reason this check fails on a record that is set right.
  DNS_CDN="$(identify_cdn "${DNS_RESOLVED}")"

  debug "${host} resolves to [${DNS_RESOLVED//$'\n'/ }] but none are local [${DNS_LOCAL//$'\n'/ }]"
  return 1
}

# Name the CDN behind a set of addresses, or print nothing.
identify_cdn() {
  local addrs="$1" a
  for a in ${addrs}; do
    case "${a}" in
      104.1[6-9].*|104.2[0-7].*|172.6[4-7].*|172.7[01].*|162.158.*|162.159.*|\
      173.245.4[89].*|103.21.24[4-7].*|103.22.20[0-3].*|103.31.[4-7].*|\
      141.101.6[4-9].*|141.101.[7-9]*.*|108.162.*|190.93.24[0-3].*|\
      188.114.9[6-9].*|197.234.24[0-3].*|198.41.12[89].*|131.0.7[2-5].*|\
      2606:4700:*|2803:f800:*|2405:b500:*|2405:8100:*|2a06:98c0:*|2c0f:f248:*)
        printf 'Cloudflare'; return 0 ;;
      2600:9000:*|13.3[2-5].*|99.8[4-6].*|205.251.*)
        printf 'CloudFront'; return 0 ;;
      151.101.*|199.232.*)
        printf 'Fastly'; return 0 ;;
    esac
  done
  return 0
}

# Explain a failed DNS check with the actual data, not an assertion.
explain_dns_failure() {
  local host="$1"

  err "KUBEDOK_HOST=${host} does not resolve to this server."
  printf '\n'
  printf '    %s resolves to:\n' "${host}"
  printf '%s\n' "${DNS_RESOLVED}" | sed 's/^/      /'
  printf '\n    this server'"'"'s addresses:\n'
  if [ -n "${DNS_LOCAL}" ]; then
    printf '%s\n' "${DNS_LOCAL}" | grep -v '^$' | sed 's/^/      /'
  else
    printf '      (could not determine — no `ip` command and no outbound access?)\n'
  fi
  printf '\n'

  if [ -n "${DNS_CDN}" ]; then
    printf '    Those are %s addresses: the DNS record is PROXIED.\n' "${DNS_CDN}"
    printf '    The record is correct, it just points at %s rather than here.\n\n' "${DNS_CDN}"
    printf '    Recommended: turn the proxy off for this record (grey cloud /\n'
    printf '    "DNS only"), run setup.sh to obtain a real certificate, then turn\n'
    printf '    the proxy back on with SSL mode "Full (strict)". The origin keeps\n'
    printf '    a valid certificate and the edge can verify it.\n\n'
    printf '    To proceed with the proxy left on, so the ACME challenge is\n'
    printf '    forwarded through it:\n'
    printf '      KUBEDOK_TLS_SKIP_DNS_CHECK=true ./setup.sh\n'
    printf '    That usually works, but fails if the proxy blocks or rewrites\n'
    printf '    /.well-known/acme-challenge/.\n\n'
    printf '    Or serve HTTP only and let the edge terminate TLS:\n'
    printf '      KUBEDOK_TLS=off ./setup.sh\n'
    printf '    Only do that with SSL mode "Full", never "Flexible" — Flexible\n'
    printf '    leaves the edge-to-origin leg unencrypted across the internet.\n\n'
  else
    printf '    Point the A/AAAA record at one of this server'"'"'s addresses and\n'
    printf '    re-run, or install without HTTPS on purpose:\n'
    printf '      KUBEDOK_TLS=off ./setup.sh\n\n'
    printf '    If you just changed the record, DNS may still be cached; check\n'
    printf '    with: dig +short %s\n\n' "${host}"
  fi
}

# ── Starting from a backup ───────────────────────────────────────────────────
# KUBEDOK_RESTORE_FROM starts a new install from a backup archive instead of an
# empty database. The database is loaded after PostgreSQL starts and before the
# server does, so the server never runs against an empty or half-loaded
# schema, and the backup's registry-encryption-key is in place before then.
# Only for a new install: an existing one is restored with `kbd restore`, which
# takes a safety backup first.
RESTORE_STAGE=""

check_restore_archive() {
  [ -n "${KUBEDOK_RESTORE_FROM}" ] || return 0
  log "Checking the backup to start from"

  [ -f "${KUBEDOK_RESTORE_FROM}" ] || die "KUBEDOK_RESTORE_FROM: no such file: ${KUBEDOK_RESTORE_FROM}"
  if current_release >/dev/null 2>&1; then
    die "Kubedok is already installed at ${KUBEDOK_ROOT}, and KUBEDOK_RESTORE_FROM only starts a new install. Restore into this one with: $(command_hint restore) ${KUBEDOK_RESTORE_FROM}"
  fi
  if docker volume inspect kubedok_postgres_data >/dev/null 2>&1; then
    die "The database volume kubedok_postgres_data already exists, so this is not a new install. Restore into it with kbd restore, or remove the volume first if its data is not needed."
  fi

  RESTORE_STAGE="$(mktemp -d)"
  trap 'rm -rf "${RESTORE_STAGE}"' EXIT
  tar -xzf "${KUBEDOK_RESTORE_FROM}" -C "${RESTORE_STAGE}" \
    || die "Could not read ${KUBEDOK_RESTORE_FROM} as a .tar.gz archive."
  [ -f "${RESTORE_STAGE}/database.sql" ] \
    || die "${KUBEDOK_RESTORE_FROM} has no database.sql. Is it a Kubedok backup?"
  # Without the key the data was encrypted with, every stored registry
  # credential and certificate is unreadable, so a backup without it is refused
  # rather than started with a new key.
  [ -s "${RESTORE_STAGE}/secrets/registry-encryption-key" ] \
    || die "${KUBEDOK_RESTORE_FROM} has no secrets/registry-encryption-key, so its stored registry credentials and certificates could not be read."

  ok "Backup from release $(jq -r '.release // "unknown"' "${RESTORE_STAGE}/backup.json" 2>/dev/null || echo unknown), taken $(jq -r '.createdAt // "unknown"' "${RESTORE_STAGE}/backup.json" 2>/dev/null || echo unknown)"
}

# The backup's data has to be one this release can bring forward: from the
# release's upgrade floor up to the release itself. Checked before anything
# is written, so a refusal leaves no install behind.
check_restore_release() {
  [ -n "${KUBEDOK_RESTORE_FROM}" ] || return 0
  local manifest="$1" target from min
  target="$(manifest_field release "${manifest}")"
  from="$(jq -r '.release // empty' "${RESTORE_STAGE}/backup.json" 2>/dev/null || true)"
  if ! is_semver "${from}"; then
    warn "The backup does not say which release made it. Loading it into ${target} anyway."
    return 0
  fi
  semver_ge "${target}" "${from}" \
    || die "The backup comes from ${from}, which is newer than ${target}. Install ${from} or later: KUBEDOK_RELEASE=${from}"
  min="$(manifest_field minimumUpgradeFrom "${manifest}")"
  semver_ge "${from}" "${min}" \
    || die "The backup comes from ${from}, and ${target} only takes data from ${min} on."
}

seed_restored_secrets() {
  [ -n "${KUBEDOK_RESTORE_FROM}" ] || return 0
  log "Taking the secrets from the backup"
  ensure_secrets_dir
  # postgres-password stays this install's: the database is created with it,
  # and a dump carries no roles.
  local name src taken=()
  for name in registry-encryption-key jwt-secret; do
    src="${RESTORE_STAGE}/secrets/${name}"
    if [ -f "${src}" ] && [ ! -L "${src}" ] && [ -s "${src}" ]; then
      ( umask 077; cp -- "${src}" "${KUBEDOK_SECRETS_DIR}/${name}" )
      chmod 600 "${KUBEDOK_SECRETS_DIR}/${name}"
      taken+=("${name}")
    fi
  done
  ok "From the backup: ${taken[*]}"
}

load_restored_database() {
  [ -n "${KUBEDOK_RESTORE_FROM}" ] || return 0
  log "Loading the database from the backup"
  if ! docker exec -i kubedok-postgres psql -X -q -v ON_ERROR_STOP=1 \
       -U "${KUBEDOK_POSTGRES_USER:-kubedok}" -d "${KUBEDOK_POSTGRES_DB:-kubedok}" \
       < "${RESTORE_STAGE}/database.sql" > "${RESTORE_STAGE}/load.log" 2>&1; then
    err "Loading the database failed:"
    tail -30 "${RESTORE_STAGE}/load.log" | sed 's/^/      /' >&2
    die "The server was not started. Remove the partly loaded database before trying again: docker rm -f kubedok-postgres && docker volume rm kubedok_postgres_data"
  fi
  ok "Database loaded ($(du -h "${RESTORE_STAGE}/database.sql" | cut -f1))"
}

# ── 5. Install directory ─────────────────────────────────────────────────────
create_layout() {
  log "Creating ${KUBEDOK_ROOT}"

  mkdir -p \
    "${KUBEDOK_RELEASES_DIR}" \
    "${KUBEDOK_CONFIG_DIR}" \
    "${KUBEDOK_SECRETS_DIR}" \
    "${KUBEDOK_BACKUPS_DIR}" \
    "${KUBEDOK_TLS_DIR}/letsencrypt" \
    "${KUBEDOK_TLS_DIR}/webroot"

  chmod 755 "${KUBEDOK_ROOT}"
  chmod 700 "${KUBEDOK_SECRETS_DIR}" "${KUBEDOK_BACKUPS_DIR}"
  chmod 755 "${KUBEDOK_TLS_DIR}" "${KUBEDOK_TLS_DIR}/webroot"
  ok "Install layout ready"
}

# ── 6. Release manifest ──────────────────────────────────────────────────────
install_release() {
  local installed
  installed="$(current_release 2>/dev/null || true)"

  if [ -n "${installed}" ] && [ -f "${KUBEDOK_RELEASES_DIR}/${installed}/release.json" ]; then
    # A re-run keeps the installed release and the digests its manifest
    # pinned, even when that version has been published again since. Moving
    # to another release takes a backup first, which is update.sh's job.
    if setting_given KUBEDOK_RELEASE && [ "${KUBEDOK_RELEASE}" != "${installed}" ]; then
      die "Kubedok ${installed} is installed here, and setup.sh does not change releases. Run: $(command_hint update) ${KUBEDOK_RELEASE}"
    fi
    RELEASE_VERSION="${installed}"
    RELEASE_DIR="${KUBEDOK_RELEASES_DIR}/${RELEASE_VERSION}"
    ok "Release ${RELEASE_VERSION}, already installed"
  else
    log "Resolving release '${KUBEDOK_RELEASE}'"

    local tmp_manifest
    tmp_manifest="$(mktemp)"
    resolve_manifest "${KUBEDOK_RELEASE}" "${tmp_manifest}" >/dev/null

    RELEASE_VERSION="$(manifest_field release "${tmp_manifest}")"
    check_restore_release "${tmp_manifest}"
    ok "Release ${RELEASE_VERSION}"

    RELEASE_DIR="${KUBEDOK_RELEASES_DIR}/${RELEASE_VERSION}"
    mkdir -p "${RELEASE_DIR}"
    mv "${tmp_manifest}" "${RELEASE_DIR}/release.json"
    chmod 644 "${RELEASE_DIR}/release.json"
  fi
  mkdir -p "${RELEASE_DIR}/compose" "${RELEASE_DIR}/scripts"

  # Ship the compose files and scripts that belong to this release, so a
  # rollback restores the tooling as well as the images.
  local file
  for file in postgres.yml postgres.public.yml server.yml nginx.yml agent.yml; do
    if [ -f "${SCRIPT_DIR}/compose/${file}" ]; then
      install -m 644 "${SCRIPT_DIR}/compose/${file}" "${RELEASE_DIR}/compose/${file}"
    else
      fetch_url "${KUBEDOK_RELEASE_BASE_URL}/compose/${file}" "${RELEASE_DIR}/compose/${file}"
    fi
  done

  for file in common.sh doctor.sh backup.sh restore.sh status.sh logs.sh \
              restart.sh config.sh rollback.sh agent-install.sh agent-update.sh \
              cert-renew.sh uninstall.sh clean.sh kbd; do
    if [ -f "${SCRIPT_DIR}/scripts/${file}" ]; then
      install -m 755 "${SCRIPT_DIR}/scripts/${file}" "${RELEASE_DIR}/scripts/${file}"
    else
      fetch_url "${KUBEDOK_RELEASE_BASE_URL}/scripts/${file}" "${RELEASE_DIR}/scripts/${file}" || true
      [ -f "${RELEASE_DIR}/scripts/${file}" ] && chmod 755 "${RELEASE_DIR}/scripts/${file}"
    fi
  done

  # update.sh lives at the repository root, but in a release tree it goes
  # beside common.sh: operators run current/scripts/update.sh, and every
  # release keeps the updater that came with it.
  if [ -f "${SCRIPT_DIR}/update.sh" ]; then
    install -m 755 "${SCRIPT_DIR}/update.sh" "${RELEASE_DIR}/scripts/update.sh"
  else
    fetch_url "${KUBEDOK_RELEASE_BASE_URL}/update.sh" "${RELEASE_DIR}/scripts/update.sh"
    chmod 755 "${RELEASE_DIR}/scripts/update.sh"
  fi

  set_current_release "${RELEASE_VERSION}"
  ok "Installed release tree at ${RELEASE_DIR}"
}

# ── 7. Secrets ───────────────────────────────────────────────────────────────
# Never regenerated: a new registry-encryption-key would make every stored
# registry credential and certificate in the database undecryptable.
generate_secrets() {
  log "Ensuring secrets"
  ensure_all_secrets
}

write_configuration() {
  log "Writing configuration"

  # Every setting this run was given is saved. update.sh and the other scripts
  # read kubedok.env alone, so one that was only in the environment, such as
  # KUBEDOK_HTTP_BIND, was lost at the next update.
  local key
  for key in ${GIVEN_SETTINGS}; do
    set_config "${key}" "${!key}"
  done

  # Listed even when empty, so the file shows what there is to set.
  for key in KUBEDOK_HOST KUBEDOK_LETSENCRYPT_EMAIL KUBEDOK_RELEASE KUBEDOK_PUBLIC_POSTGRES \
             KUBEDOK_HTTP_PORT KUBEDOK_HTTPS_PORT; do
    config_has "${key}" || set_config "${key}" "${!key:-}"
  done

  # Decided by this run, from KUBEDOK_TLS and the host.
  set_config KUBEDOK_TLS "${KUBEDOK_TLS}"
  set_config KUBEDOK_TLS_ENABLED "${KUBEDOK_TLS_ENABLED}"

  chmod 600 "${KUBEDOK_CONFIG_FILE}"
  ok "Configuration at ${KUBEDOK_CONFIG_FILE}"
}

# ── 8. Networks ──────────────────────────────────────────────────────────────
create_networks() {
  log "Creating private networks"
  ensure_networks
}

pull_images() {
  log "Pulling release images"
  local manifest="${KUBEDOK_CURRENT_LINK}/release.json"
  local component ref
  for component in postgres server nginx; do
    ref="$(manifest_image "${component}" "${manifest}")"
    docker pull -q "${ref}" >/dev/null || die "Could not pull ${component} image: ${ref}"
    ok "Pulled ${component}"
  done
  if [ "${KUBEDOK_ENABLE_AGENT}" = "true" ]; then
    ref="$(manifest_image agent "${manifest}")"
    docker pull -q "${ref}" >/dev/null || die "Could not pull agent image: ${ref}"
    ok "Pulled agent"
  fi
}

# ── 9 + 10. PostgreSQL ───────────────────────────────────────────────────────
start_postgres() {
  log "Starting PostgreSQL"
  compose postgres up -d
  wait_for_container_health kubedok-postgres 180 \
    || die "PostgreSQL did not become healthy. Check: docker logs kubedok-postgres"
  ok "PostgreSQL is healthy"
}

# ── 11. Server ───────────────────────────────────────────────────────────────
start_server() {
  log "Starting the server (migrations run on startup)"
  compose server up -d
  wait_for_container_health kubedok-server 300 \
    || die "The server did not become healthy. Check: docker logs kubedok-server"
  ok "Server is healthy"
}

# ── 12. nginx ────────────────────────────────────────────────────────────────
start_nginx() {
  log "Starting nginx"
  compose nginx up -d
  wait_for_container_health kubedok-nginx 120 \
    || die "nginx did not become healthy. Check: docker logs kubedok-nginx"

  if wait_for_http "$(local_base_url)/api/health" 60; then
    ok "Serving on port ${KUBEDOK_HTTP_PORT:-80}"
  else
    die "nginx is up but $(local_base_url)/api/health is not responding."
  fi
}

# ── 14. TLS ──────────────────────────────────────────────────────────────────
issue_certificate() {
  [ "${KUBEDOK_TLS_ENABLED}" = "true" ] || return 0

  log "Obtaining a TLS certificate for ${KUBEDOK_HOST}"
  "${KUBEDOK_CURRENT_LINK}/scripts/cert-renew.sh" --issue \
    || die "Certificate issuance failed. Kubedok is still serving HTTP on port ${KUBEDOK_HTTP_PORT:-80}. Fix the cause and run: $(command_hint cert-renew) --issue"

  log "Restarting nginx with TLS"
  compose nginx up -d --force-recreate
  wait_for_container_health kubedok-nginx 120 || die "nginx did not come back up with TLS."
  ok "HTTPS enabled"
}

# ── 13. Restart on boot ──────────────────────────────────────────────────────
# Every compose project already uses `restart: unless-stopped`, so the Docker
# daemon brings containers back. All that is needed is for Docker itself to
# start at boot.
configure_boot() {
  log "Configuring restart-on-boot"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable docker >/dev/null 2>&1 \
      && ok "Docker starts at boot; containers use restart=unless-stopped" \
      || warn "Could not enable the docker service. Enable it manually: systemctl enable docker"
  else
    warn "systemd not found — make sure Docker starts at boot on this system."
  fi
}

install_agent() {
  [ "${KUBEDOK_ENABLE_AGENT}" = "true" ] || return 0
  log "Installing the local agent"
  warn "The agent needs a registration token from the Kubedok UI."
  warn "Run: $(command_hint agent-install) --token <token>"
}

# ── 15. Summary ──────────────────────────────────────────────────────────────
print_summary() {
  local scheme="http" port="${KUBEDOK_HTTP_PORT:-80}" hostname="${KUBEDOK_HOST:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
  local url

  if [ "${KUBEDOK_TLS_ENABLED}" = "true" ]; then
    scheme="https"; port="${KUBEDOK_HTTPS_PORT:-443}"
  fi

  if { [ "${scheme}" = "http" ] && [ "${port}" = "80" ]; } \
    || { [ "${scheme}" = "https" ] && [ "${port}" = "443" ]; }; then
    url="${scheme}://${hostname}"
  else
    url="${scheme}://${hostname}:${port}"
  fi

  # `sudo kbd status` and the like, or the scripts' paths without the command.
  local run="sudo kbd " sh=""
  if ! kbd_installed; then
    run="${KUBEDOK_CURRENT_LINK}/scripts/"
    sh=".sh"
  fi

  printf '\n'
  printf '%s────────────────────────────────────────────────────────%s\n' "${_c_green}" "${_c_reset}"
  printf '  Kubedok %s is running\n' "${RELEASE_VERSION}"
  printf '%s────────────────────────────────────────────────────────%s\n' "${_c_green}" "${_c_reset}"
  printf '\n'
  printf '  URL              %s\n' "${url}"
  printf '  Install          %s\n' "${KUBEDOK_ROOT}"
  printf '  Configuration    %s\n' "${KUBEDOK_CONFIG_FILE}"
  printf '  Secrets          %s\n' "${KUBEDOK_SECRETS_DIR}"
  if [ -n "${KUBEDOK_RESTORE_FROM}" ]; then
    printf '  Started from     %s\n' "${KUBEDOK_RESTORE_FROM}"
  fi
  printf '\n'
  printf '  Status           %sstatus%s\n' "${run}" "${sh}"
  printf '  Logs             %slogs%s [postgres|server|nginx|agent]\n' "${run}" "${sh}"
  printf '  Restart          %srestart%s [component|all]\n' "${run}" "${sh}"
  printf '  Settings         %sconfig%s\n' "${run}" "${sh}"
  printf '  Health check     %sdoctor%s\n' "${run}" "${sh}"
  printf '  Backup           %sbackup%s\n' "${run}" "${sh}"
  printf '  Update           %supdate%s\n' "${run}" "${sh}"
  if kbd_installed; then
    printf '  Every command    kbd help\n'
  fi
  printf '\n'

  if [ "${KUBEDOK_TLS_ENABLED}" != "true" ]; then
    printf '  %s!%s HTTPS is disabled. Traffic, including the login password, is\n' "${_c_yellow}" "${_c_reset}"
    printf '    sent in the clear. Set KUBEDOK_HOST to a DNS name pointing here\n'
    printf '    and re-run with KUBEDOK_TLS=on to enable it.\n\n'
  fi

  printf '  %sBack up %s — losing registry-encryption-key\n' "${_c_yellow}" "${KUBEDOK_SECRETS_DIR}${_c_reset}"
  printf '  makes stored registry credentials permanently unrecoverable.\n\n'
}

main() {
  printf '\n%sKubedok installer%s\n\n' "${_c_blue}" "${_c_reset}"

  check_platform
  install_dependencies
  check_capabilities

  mkdir -p "${KUBEDOK_ROOT}"
  acquire_lock 300

  check_restore_archive
  resolve_tls
  create_layout
  install_release
  install_kbd_link
  seed_restored_secrets
  generate_secrets
  write_configuration
  create_networks

  # Re-read config so compose.env is built from the merged result.
  load_config
  write_compose_env "${KUBEDOK_CURRENT_LINK}/release.json" >/dev/null

  pull_images
  start_postgres
  load_restored_database
  start_server
  start_nginx
  issue_certificate
  configure_boot
  install_agent

  print_summary
}

main "$@"
