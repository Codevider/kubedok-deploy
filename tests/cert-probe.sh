#!/usr/bin/env bash
#
# Regression test for the TLS paths the deployment scripts take through nginx.
#
#   tests/cert-probe.sh
#
# integration.sh installs with KUBEDOK_TLS=off, so nothing there exercises
# what happens once a hostname and a certificate are involved. That gap let
# release 1.4.0 ship two bugs at once. The ACME pre-flight in cert-renew.sh
# wrote its marker one directory too high, so nginx answered 404 and every
# correctly configured install was told port 80 was firewalled. And the nginx
# health check followed the HTTP→HTTPS redirect into a certificate check for
# 127.0.0.1 that can never pass, so a working TLS install was reported
# unhealthy and every script that waits on nginx failed.
#
# How it works
# ------------
# The real nginx image runs twice: first in the pre-issuance state setup.sh
# creates (TLS requested, no certificate yet), then with a self-signed
# certificate in place, the post-issuance state. A throwaway Linux runner
# shares nginx's network namespace, so 127.0.0.1 inside it IS nginx — exactly
# what the host sees in production. The scripts run from this working tree;
# a stub `docker` binary stands in for the certbot container, so Let's Encrypt
# is never contacted.
set -Eeuo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK="${KUBEDOK_TEST_WORK:-/private/tmp/kubedok-cert-probe}"
NGINX_IMAGE="${KUBEDOK_TEST_NGINX_IMAGE:-kubedok-nginx:dev}"
NET="kubedok-cert-probe"
NGINX="kubedok-cert-probe-nginx"
RUNNER="kubedok-cert-probe-runner"
HOST="acme.test"
INSTALL_ROOT="${WORK}/opt-kubedok"
CERT_DIR="${INSTALL_ROOT}/tls/letsencrypt/live/${HOST}"

PASS=0
FAIL=0

c_green=$'\033[32m'; c_red=$'\033[31m'; c_blue=$'\033[34m'; c_dim=$'\033[2m'; c_off=$'\033[0m'

step()  { printf '\n%s▸ %s%s\n' "${c_blue}" "$*" "${c_off}"; }
pass()  { printf '  %s✓%s %s\n' "${c_green}" "${c_off}" "$*"; PASS=$((PASS+1)); }
fails() { printf '  %s✗%s %s\n' "${c_red}" "${c_off}" "$*"; FAIL=$((FAIL+1)); }
info()  { printf '  %s%s%s\n' "${c_dim}" "$*" "${c_off}"; }
abort() { printf '\n%sABORT:%s %s\n\n' "${c_red}" "${c_off}" "$*"; exit 1; }

stop_stack() { docker rm -f "${NGINX}" "${RUNNER}" >/dev/null 2>&1 || true; }

cleanup() {
  stop_stack
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

# ── Preflight ────────────────────────────────────────────────────────────────
step 'Preflight'
command -v docker >/dev/null || abort 'docker is required'
command -v jq >/dev/null || abort 'jq is required'
docker info >/dev/null 2>&1 || abort 'the Docker daemon is not reachable'
docker compose version >/dev/null 2>&1 || abort 'the Docker Compose plugin is required'
docker image inspect "${NGINX_IMAGE}" >/dev/null 2>&1 \
  || abort "Missing image ${NGINX_IMAGE}.
    Build it from the application repository, github.com/glikaj/kubedok:
      docker build -f infra/docker/nginx.Dockerfile -t kubedok-nginx:dev .
    or point KUBEDOK_TEST_NGINX_IMAGE at a released image."
info "nginx image ${NGINX_IMAGE}"

cleanup
mkdir -p "${INSTALL_ROOT}/config" "${INSTALL_ROOT}/tls/letsencrypt" "${INSTALL_ROOT}/tls/webroot" \
         "${WORK}/scripts" "${WORK}/bin"
chmod 755 "${INSTALL_ROOT}/tls" "${INSTALL_ROOT}/tls/webroot"
cp "${DEPLOY_DIR}"/scripts/cert-renew.sh "${DEPLOY_DIR}"/scripts/common.sh "${WORK}/scripts/"
chmod +x "${WORK}"/scripts/*.sh

# Stands in for the docker CLI inside the runner: satisfies require_cmd and
# records the certbot invocation instead of running it.
cat > "${WORK}/bin/docker" <<'SH'
#!/bin/sh
echo "stub-docker: $*"
exit 0
SH
chmod +x "${WORK}/bin/docker"

# Just enough for `docker compose config` to render compose/nginx.yml.
printf 'KUBEDOK_TLS_DIR=%s\nKUBEDOK_IMAGE_NGINX=%s\n' "${INSTALL_ROOT}/tls" "${NGINX_IMAGE}" \
  > "${WORK}/compose.env"

# ── Stack helpers ────────────────────────────────────────────────────────────
start_stack() {
  docker network create "${NET}" >/dev/null 2>&1 || true
  docker run -d --name "${NGINX}" --network "${NET}" --network-alias "${HOST}" \
    -e KUBEDOK_TLS_ENABLED=true \
    -e "KUBEDOK_SERVER_NAME=${HOST}" \
    -e KUBEDOK_SERVER_HOST=127.0.0.1 \
    -v "${INSTALL_ROOT}/tls/letsencrypt:/etc/letsencrypt:ro" \
    -v "${INSTALL_ROOT}/tls/webroot:/var/www/certbot" \
    "${NGINX_IMAGE}" >/dev/null

  # The runner joins nginx's network namespace, so 127.0.0.1 is nginx and the
  # public name resolves to it too. The install root is mounted at the SAME
  # absolute path, so the paths the scripts print are the ones on disk. The
  # self-signed certificate doubles as the trust anchor, standing in for the
  # publicly trusted one a real install has.
  docker run -d --name "${RUNNER}" --network "container:${NGINX}" \
    -e "KUBEDOK_ROOT=${INSTALL_ROOT}" -e NO_COLOR=1 \
    -e "CURL_CA_BUNDLE=${CERT_DIR}/fullchain.pem" \
    -v "${INSTALL_ROOT}:${INSTALL_ROOT}" \
    -v "${WORK}/scripts:/deploy/scripts:ro" \
    -v "${WORK}/bin:/stub:ro" \
    alpine:3.20 sleep infinity >/dev/null
  docker exec "${RUNNER}" sh -c 'apk add --no-cache bash curl >/dev/null 2>&1 && cp /stub/docker /usr/local/bin/docker' \
    || abort 'could not prepare the runner'

  # 200 on plain HTTP, 301 on TLS; either means nginx is up.
  for _ in $(seq 1 30); do
    docker exec "${RUNNER}" curl -fsS -o /dev/null http://127.0.0.1/ 2>/dev/null && break
    sleep 1
  done
  docker exec "${RUNNER}" curl -fsS -o /dev/null http://127.0.0.1/ 2>/dev/null || abort 'nginx did not come up'
  info "nginx: $(docker logs "${NGINX}" 2>&1 | sed -n 's/.*kubedok-nginx: //p' | head -n1)"
}

# Rewrites the install's config. Extra KEY=VALUE arguments are appended.
# LE_EMAIL= (set, empty) writes the config setup.sh leaves without an address.
write_config() {
  local host="$1"; shift
  {
    printf 'KUBEDOK_HOST=%s\nKUBEDOK_LETSENCRYPT_EMAIL=%s\nKUBEDOK_TLS_ENABLED=true\n' \
      "${host}" "${LE_EMAIL-test@example.com}"
    local line
    for line in "$@"; do printf '%s\n' "${line}"; done
  } > "${INSTALL_ROOT}/config/kubedok.env"
}

OUT=""
RC=0
run_issue() {
  RC=0
  OUT="$(docker exec "${RUNNER}" /deploy/scripts/cert-renew.sh --issue --dry-run "$@" 2>&1)" || RC=$?
}

# Runs a snippet in the runner with common.sh sourced and the config loaded.
in_common() {
  docker exec "${RUNNER}" bash -c ". /deploy/scripts/common.sh && load_config && $*"
}

expect_line() {
  local what="$1" needle="$2"
  if grep -qF -- "${needle}" <<<"${OUT}"; then pass "${what}"; else fails "${what} — missing '${needle}'"; fi
}

reject_line() {
  local what="$1" needle="$2"
  if grep -qF -- "${needle}" <<<"${OUT}"; then fails "${what} — found '${needle}'"; else pass "${what}"; fi
}

probe_files() { find "${INSTALL_ROOT}/tls/webroot" -type f | wc -l | tr -d ' '; }

dump() { printf '%s\n' "${OUT}" | sed 's/^/      /'; }

# ═══════════════════════════════════════════════════════════════════════════
step 'PHASE A — before the first certificate: nginx serves plain HTTP'
start_stack

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 1 — a correctly wired install passes the probe and reaches certbot'

write_config "${HOST}"
run_issue
if [ "${RC}" -eq 0 ]; then pass 'cert-renew.sh --issue --dry-run exits 0'; else fails "exit ${RC}"; dump; fi
expect_line 'nginx serves the webroot locally'     'nginx serves the challenge webroot'
expect_line 'the public probe succeeds'            'Challenge path reachable from the internet'
expect_line 'certbot is invoked with the webroot'  "certonly --webroot -w /var/www/certbot -d ${HOST}"
expect_line 'the dry run is passed through'        '--dry-run'
expect_line 'the contact address is passed'        '--email test@example.com'
if [ "$(probe_files)" = "0" ]; then pass 'the probe file is cleaned up'; else fails "$(probe_files) probe file(s) left in the webroot"; fi

LE_EMAIL='' write_config "${HOST}"
run_issue
if [ "${RC}" -eq 0 ]; then pass 'without a contact address, issuance still goes ahead'; else fails "exit ${RC}"; dump; fi
expect_line 'the account is registered without one' '--register-unsafely-without-email'
reject_line 'no empty address is passed'           '--email'

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 2 — nginx fine, public route broken: the message blames the route'

write_config 'blackhole.invalid'
run_issue
if [ "${RC}" -ne 0 ]; then pass 'issuance is refused'; else fails 'issuance went ahead'; dump; fi
expect_line 'the local probe still passes'         'nginx serves the challenge webroot'
expect_line 'the failure names the internet route' 'not reachable from the internet'
expect_line 'the real curl error is shown'         'Could not resolve host'
reject_line 'certbot is not called'                'stub-docker: run'

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 3 — nginx not serving the webroot: the message blames this host'

write_config "${HOST}" 'KUBEDOK_HTTP_PORT=81'
run_issue
if [ "${RC}" -ne 0 ]; then pass 'issuance is refused'; else fails 'issuance went ahead'; dump; fi
expect_line 'the failure names nginx on this host' 'nginx on this host is not serving the ACME challenge webroot'
reject_line 'the internet is not blamed'           'not reachable from the internet'
reject_line 'certbot is not called'                'stub-docker: run'
if [ "$(probe_files)" = "0" ]; then pass 'the probe file is cleaned up on failure'; else fails "$(probe_files) probe file(s) left in the webroot"; fi

# ═══════════════════════════════════════════════════════════════════════════
step 'PHASE B — certificate issued: nginx restarts into TLS'

stop_stack
mkdir -p "${CERT_DIR}"
# ECDSA P-256 is certbot's default key type. Self-signed; the runner trusts
# it through CURL_CA_BUNDLE.
docker run --rm -v "${CERT_DIR}:/out" alpine:3.20 sh -c \
  "apk add --no-cache openssl >/dev/null 2>&1 \
   && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout /out/privkey.pem -out /out/fullchain.pem \
        -subj /CN=${HOST} -addext subjectAltName=DNS:${HOST} -days 2 >/dev/null 2>&1 \
   && chmod 644 /out/*.pem" \
  || abort 'could not create a test certificate'
write_config "${HOST}"
start_stack

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 4 — nginx is healthy in TLS mode'

code="$(docker exec "${RUNNER}" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ 2>/dev/null || true)"
if [ "${code}" = "301" ]; then pass 'port 80 redirects to HTTPS'; else fails "port 80 answered '${code}', expected 301"; fi
code="$(docker exec "${RUNNER}" curl -s -o /dev/null -w '%{http_code}' --resolve "${HOST}:443:127.0.0.1" "https://${HOST}/" 2>/dev/null || true)"
if [ "${code}" = "200" ]; then pass 'port 443 serves the UI with a certificate the runner trusts'; else fails "port 443 answered '${code}', expected 200"; fi

hc="$(docker compose --env-file "${WORK}/compose.env" -f "${DEPLOY_DIR}/compose/nginx.yml" config --format json 2>/dev/null \
  | jq -r '.services.nginx.healthcheck.test
           | if .[0] == "CMD" then (.[1:] | map(@sh) | join(" "))
             elif .[0] == "CMD-SHELL" then .[1] else empty end')"
if [ -z "${hc}" ]; then
  fails 'could not read the health check out of compose/nginx.yml'
elif docker exec "${NGINX}" sh -c "${hc}" >/dev/null 2>&1; then
  pass "the compose health check passes: ${hc}"
else
  fails "the compose health check fails in TLS mode: ${hc}"
fi

# The image's own HEALTHCHECK is what runs without the compose file; it has
# to agree. It reports 'starting' until the first probe, and 'unhealthy' only
# after three failures, so this can take a while on a broken image.
health=""
for _ in $(seq 1 60); do
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${NGINX}")"
  case "${health}" in healthy|unhealthy|none) break ;; esac
  sleep 2
done
case "${health}" in
  healthy) pass "the image's own health check reports healthy" ;;
  none)    fails 'the image declares no HEALTHCHECK' ;;
  *)       fails "the image's own health check reports '${health}' in TLS mode" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 5 — the scripts reach the install through the redirect, on loopback'

out="$(in_common 'local_curl -fsS -o /dev/null -w "%{http_code} %{url_effective}" "$(local_base_url)/"' 2>&1 || true)"
if [ "${out}" = "200 https://${HOST}/" ]; then
  pass "local_curl follows $(in_common 'local_base_url' 2>/dev/null)/ to ${out#200 } with a validated certificate"
else
  fails "local_curl got '${out}', expected '200 https://${HOST}/'"
fi
if in_common 'wait_for_http "$(local_base_url)/" 15' >/dev/null 2>&1; then
  pass 'wait_for_http succeeds against the redirecting port'
else
  fails 'wait_for_http gave up against the redirecting port'
fi

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 6 — re-issuing with a certificate in place'

run_issue
if [ "${RC}" -eq 0 ]; then pass 'a plain --issue exits 0 when a certificate exists'; else fails "exit ${RC}"; dump; fi
expect_line 'and says so'                          'already exists'
reject_line 'without calling certbot'              'stub-docker: run'

run_issue --force
if [ "${RC}" -eq 0 ]; then pass '--issue --force exits 0'; else fails "exit ${RC}"; dump; fi
expect_line 'the local probe passes in TLS mode'   'nginx serves the challenge webroot'
expect_line 'the public probe passes in TLS mode'  'Challenge path reachable from the internet'
expect_line 'certbot is asked to force renewal'    '--force-renewal'

# Renewal covers only the host nginx serves. A certificate left from a host
# the install used to have fails to renew once its DNS moves, and that
# failure stopped the run before nginx reloaded the certificate in use.
RC=0
OUT="$(docker exec "${RUNNER}" /deploy/scripts/cert-renew.sh --dry-run 2>&1)" || RC=$?
if [ "${RC}" -eq 0 ]; then pass 'a dry-run renewal exits 0'; else fails "exit ${RC}"; dump; fi
expect_line 'renewal names the served host'        "renew --cert-name ${HOST} "

# An edge that forces HTTPS redirects the challenge and Let's Encrypt follows,
# so the webroot has to be served on 443 as well.
mkdir -p "${INSTALL_ROOT}/tls/webroot/.well-known/acme-challenge"
printf 'ok' > "${INSTALL_ROOT}/tls/webroot/.well-known/acme-challenge/via-https"
body="$(docker exec "${RUNNER}" curl -fsS --resolve "${HOST}:443:127.0.0.1" \
  "https://${HOST}/.well-known/acme-challenge/via-https" 2>/dev/null || true)"
if [ "${body}" = "ok" ]; then
  pass 'the challenge webroot is served over HTTPS as well'
else
  fails "over HTTPS the challenge path returned '${body:0:40}', expected the marker"
fi

# ═══════════════════════════════════════════════════════════════════════════
printf '\n%s────────────────────────────────────────%s\n' "${c_blue}" "${c_off}"
printf '  %s%d passed%s' "${c_green}" "${PASS}" "${c_off}"
[ "${FAIL}" -gt 0 ] && printf ', %s%d failed%s' "${c_red}" "${FAIL}" "${c_off}"
printf '\n%s────────────────────────────────────────%s\n\n' "${c_blue}" "${c_off}"

[ "${FAIL}" -eq 0 ]
