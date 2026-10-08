#!/usr/bin/env bash
#
# End-to-end test for the Kubedok deployment scripts.
#
#   tests/integration.sh
#
# Exercises the real scripts against a real Docker daemon: install, backup,
# update, failed updates, rollback, restore, uninstall, plus the guards that
# are supposed to refuse unsafe operations.
#
# How it works
# ------------
# Two synthetic releases (1.0.0 and 1.0.1) are pushed to a throwaway local
# registry so the manifests can reference genuine digests, exactly like
# production. The manifests are served over file:// so the test needs no
# network at all.
#
# setup.sh requires root and Linux, so it runs inside a Debian container that
# drives the host Docker daemon. The install directory is bind-mounted at the
# SAME absolute path inside and out, because Compose secret paths are resolved
# by the daemon against the host filesystem.
set -Eeuo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK="${KUBEDOK_TEST_WORK:-/private/tmp/kubedok-integration}"
INSTALL_ROOT="${WORK}/opt-kubedok"
SERVE_DIR="${WORK}/serve"

REG_NAME="kubedok-test-registry"
REG_PORT="${KUBEDOK_TEST_REGISTRY_PORT:-5050}"
RUNNER="kubedok-test-runner"
# Built by TEST 6: the dev server image, reporting a release it is not.
WRONG_RELEASE_IMAGE="kubedok-test-wrong-release:latest"
# Built by TEST 5: the dev server image with a new digest, publishing 1.0.1 again.
REPUBLISHED_IMAGE="kubedok-test-republished:latest"
# Built by TEST 6b: an image no release names, pulled by digest alone.
STALE_IMAGE="kubedok-test-stale:latest"
STALE_REF=""
HTTP_PORT="${KUBEDOK_TEST_HTTP_PORT:-18080}"

PASS=0
FAIL=0

c_green=$'\033[32m'; c_red=$'\033[31m'; c_blue=$'\033[34m'; c_dim=$'\033[2m'; c_off=$'\033[0m'

step()  { printf '\n%s▸ %s%s\n' "${c_blue}" "$*" "${c_off}"; }
pass()  { printf '  %s✓%s %s\n' "${c_green}" "${c_off}" "$*"; PASS=$((PASS+1)); }
fails() { printf '  %s✗%s %s\n' "${c_red}" "${c_off}" "$*"; FAIL=$((FAIL+1)); }
info()  { printf '  %s%s%s\n' "${c_dim}" "$*" "${c_off}"; }
abort() { printf '\n%sABORT:%s %s\n\n' "${c_red}" "${c_off}" "$*"; exit 1; }

# Run a command inside the Linux runner container.
inrun() { docker exec -i "${RUNNER}" bash -lc "$*"; }

assert_eq() {
  local expected="$1" actual="$2" what="$3"
  if [ "${expected}" = "${actual}" ]; then
    pass "${what}"
  else
    fails "${what} — expected '${expected}', got '${actual}'"
  fi
}

assert_ok() {
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "${what}"; else fails "${what}"; fi
}

assert_fails() {
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then fails "${what} — the command unexpectedly succeeded"; else pass "${what}"; fi
}

# A setting as kubedok.env holds it, or as a container was given it.
saved_setting() { inrun "sed -n 's/^$1=//p' ${INSTALL_ROOT}/config/kubedok.env | tail -n1" | tr -d '\r'; }
container_env() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null | sed -n "s/^$2=//p"
}
started_at() { docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null; }

# Points the stable channel at a release.
set_stable() {
  jq -n --arg v "$1" '{schemaVersion:1, channel:"stable", release:$v,
        manifest:("releases/" + $v + ".json"), updatedAt:"2026-01-01T00:00:00Z"}' \
    > "${SERVE_DIR}/channels/stable.json"
}

# The install's release state, read inside the runner.
installed_release() { inrun "readlink -f ${INSTALL_ROOT}/current | xargs basename" | tr -d '\r'; }
previous_link()     { inrun "readlink ${INSTALL_ROOT}/previous | xargs -r basename" 2>/dev/null | tr -d '\r'; }
# Every entry in releases/, hidden ones included, on one line.
release_entries()   { inrun "ls -A1 ${INSTALL_ROOT}/releases | sort -V" | tr -d '\r' | xargs; }
# One checksum over a release tree's paths, modes and contents.
tree_sum() {
  inrun "cd ${INSTALL_ROOT}/releases/$1 && { find . -printf '%y %m %p\n' | sort; \
    find . -type f -print0 | sort -z | xargs -0 sha256sum; } | sha256sum" | tr -d '\r'
}

# What a failed update must leave: no staging area, and releases/, current
# and previous exactly as they were before it.
assert_update_left_nothing() {
  local what="$1" releases="$2" current="$3" previous="$4"
  assert_fails "${what}: no staging area is left" \
    docker exec "${RUNNER}" test -e "${INSTALL_ROOT}/.staging"
  assert_eq "${releases}" "$(release_entries)" "${what}: releases/ holds ${releases} and nothing else"
  assert_eq "${current}" "$(installed_release)" "${what}: current still points at ${current}"
  assert_eq "${previous}" "$(previous_link)" "${what}: previous still points at ${previous}"
}

# ── Teardown ─────────────────────────────────────────────────────────────────
cleanup() {
  step 'Cleaning up'
  docker rm -f kubedok-nginx kubedok-server kubedok-postgres kubedok-agent >/dev/null 2>&1 || true
  docker rm -f "${RUNNER}" "${REG_NAME}" >/dev/null 2>&1 || true
  docker image rm "${WRONG_RELEASE_IMAGE}" "${REPUBLISHED_IMAGE}" "${STALE_IMAGE}" >/dev/null 2>&1 || true
  if [ -n "${STALE_REF}" ]; then docker image rm "${STALE_REF}" >/dev/null 2>&1 || true; fi
  # The tags the releases were pushed under. The images stay, as kubedok-*:dev.
  docker images --format '{{.Repository}}:{{.Tag}}' | grep "^localhost:${REG_PORT}/kubedok-" \
    | while read -r tag; do docker image rm "${tag}" >/dev/null 2>&1 || true; done
  docker volume rm kubedok_postgres_data >/dev/null 2>&1 || true
  docker network rm kubedok-proxy kubedok-postgres >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
  info 'done'
}
trap cleanup EXIT

# ── Preflight ────────────────────────────────────────────────────────────────
step 'Preflight'
command -v docker >/dev/null || abort 'docker is required'
docker info >/dev/null 2>&1 || abort 'the Docker daemon is not reachable'

for img in kubedok-server:dev kubedok-nginx:dev kubedok-postgres:dev; do
  docker image inspect "${img}" >/dev/null 2>&1 \
    || abort "Missing image ${img}.
    These are built from the application repository, github.com/glikaj/kubedok.
    From a checkout of it:
      docker build -f infra/docker/server.Dockerfile   -t kubedok-server:dev   .
      docker build -f infra/docker/nginx.Dockerfile    -t kubedok-nginx:dev    .
      docker build -f infra/docker/postgres.Dockerfile -t kubedok-postgres:dev ."
done
info 'images present'

cleanup >/dev/null 2>&1 || true
mkdir -p "${INSTALL_ROOT}" "${SERVE_DIR}/releases" "${SERVE_DIR}/channels" \
         "${SERVE_DIR}/compose" "${SERVE_DIR}/scripts"
cp "${DEPLOY_DIR}"/compose/*.yml "${SERVE_DIR}/compose/"
cp "${DEPLOY_DIR}"/scripts/*.sh "${DEPLOY_DIR}/scripts/kbd" "${SERVE_DIR}/scripts/"
cp "${DEPLOY_DIR}"/setup.sh "${DEPLOY_DIR}"/update.sh "${SERVE_DIR}/"
cp "${DEPLOY_DIR}/releases/release.schema.json" "${SERVE_DIR}/releases/"
chmod +x "${SERVE_DIR}"/*.sh "${SERVE_DIR}"/scripts/*.sh "${SERVE_DIR}/scripts/kbd"
# A bare mirror of this repository, so TEST 0 can exercise a real `git clone`
# rather than a file copy.
REPO_MIRROR="${WORK}/repo-mirror.git"
git init -q --bare "${REPO_MIRROR}"
git -C "${DEPLOY_DIR}" push -q "file://${REPO_MIRROR}" HEAD:refs/heads/main 2>/dev/null \
  || abort "could not mirror the repository for the clone test"

info "workspace ${WORK}"

# ── Registry with two synthetic releases ─────────────────────────────────────
step 'Publishing two synthetic releases to a throwaway registry'

docker run -d --name "${REG_NAME}" -p "127.0.0.1:${REG_PORT}:5000" registry:2 >/dev/null
for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:${REG_PORT}/v2/" -o /dev/null 2>/dev/null && break
  sleep 1
done
curl -fsS "http://127.0.0.1:${REG_PORT}/v2/" -o /dev/null || abort 'the test registry did not come up'
info "registry on 127.0.0.1:${REG_PORT}"

# Both releases use identical image content. The point of the test is the
# deployment machinery, not a behavioural difference between builds — the
# release version is injected at run time from the manifest.
# Digests go in files rather than an associative array: this orchestrator
# runs on the developer's machine, and macOS still ships bash 3.2.
DIGEST_DIR="${WORK}/digests"
mkdir -p "${DIGEST_DIR}"

push_component() {
  local component="$1" src="$2" version="$3"
  local ref="localhost:${REG_PORT}/kubedok-${component}:${version}"
  docker tag "${src}" "${ref}"
  docker push -q "${ref}" >/dev/null 2>&1 || abort "could not push ${ref}"
  local digest
  digest="$(docker image inspect "${ref}" --format '{{range .RepoDigests}}{{println .}}{{end}}' \
    | grep "^localhost:${REG_PORT}/kubedok-${component}@" | head -1 | tr -d '\n')"
  [ -n "${digest}" ] || abort "could not read the digest for ${ref}"
  printf '%s' "${digest}" > "${DIGEST_DIR}/${component}-${version}"
}

digest_of() { cat "${DIGEST_DIR}/$1-$2"; }

write_manifest() {
  local version="$1" min_from="$2" pg_major="${3:-16}"
  jq -n \
    --arg release "${version}" \
    --arg published "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg server   "$(digest_of server "${version}")" \
    --arg nginx    "$(digest_of nginx "${version}")" \
    --arg postgres "$(digest_of postgres "${version}")" \
    --arg agent    "$(digest_of postgres "${version}")" \
    --argjson pg   "${pg_major}" \
    --arg minFrom  "${min_from}" \
    --arg rev      "0000000000000000000000000000000000000000" \
    '{schemaVersion:1, release:$release, publishedAt:$published,
      images:{server:$server, nginx:$nginx, postgres:$postgres, agent:$agent},
      builtFrom:{server:$rev, nginx:$rev, postgres:$rev, agent:$rev}, agentVersion:"1.0.0",
      postgresMajor:$pg, minimumAgentVersion:"1.0.0", minimumUpgradeFrom:$minFrom}' \
    > "${SERVE_DIR}/releases/${version}.json"
}

for v in 1.0.0 1.0.1; do
  push_component server   kubedok-server:dev   "${v}"
  push_component nginx    kubedok-nginx:dev    "${v}"
  push_component postgres kubedok-postgres:dev "${v}"
done
write_manifest 1.0.0 1.0.0
write_manifest 1.0.1 1.0.0

# A third manifest that bumps the PostgreSQL major, to prove update.sh refuses it.
write_manifest 1.0.1 1.0.0 17
mv "${SERVE_DIR}/releases/1.0.1.json" "${SERVE_DIR}/releases/2.0.0.json"
jq '.release = "2.0.0"' "${SERVE_DIR}/releases/2.0.0.json" > "${SERVE_DIR}/releases/2.0.0.tmp"
mv "${SERVE_DIR}/releases/2.0.0.tmp" "${SERVE_DIR}/releases/2.0.0.json"
write_manifest 1.0.1 1.0.0

set_stable 1.0.0

info 'releases 1.0.0, 1.0.1 and 2.0.0 (pg 17) published'

# ── Linux runner ─────────────────────────────────────────────────────────────
step 'Starting the Linux runner'

docker run -d --name "${RUNNER}" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${WORK}:${WORK}" \
  -e "KUBEDOK_ROOT=${INSTALL_ROOT}" \
  -e "KUBEDOK_RELEASE_BASE_URL=file://${SERVE_DIR}" \
  -e "KUBEDOK_LOCAL_BASE_URL=http://kubedok-nginx" \
  -e "KUBEDOK_HTTP_PORT=${HTTP_PORT}" \
  -e 'KUBEDOK_HTTP_BIND=127.0.0.1' \
  -e 'KUBEDOK_SKIP_DEPS=true' \
  -e 'KUBEDOK_TLS=off' \
  -e 'NO_COLOR=1' \
  debian:bookworm-slim sleep infinity >/dev/null

# Debian rather than Alpine on purpose: the scripts use `find -printf`, which
# busybox does not implement. bookworm has no docker-compose-v2 package, so the
# compose plugin binary is fetched directly.
inrun "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  --no-install-recommends ca-certificates curl openssl jq util-linux iproute2 \
  netcat-openbsd git docker.io > /tmp/apt.log 2>&1" \
  || { docker exec "${RUNNER}" tail -20 /tmp/apt.log 2>/dev/null | sed 's/^/      /'; abort 'could not install tools in the runner'; }

inrun 'set -e
  arch="$(uname -m)"
  for d in /usr/libexec/docker/cli-plugins /usr/local/lib/docker/cli-plugins; do mkdir -p "$d"; done
  curl -fsSL "https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-linux-${arch}" \
    -o /usr/libexec/docker/cli-plugins/docker-compose
  chmod +x /usr/libexec/docker/cli-plugins/docker-compose
  cp /usr/libexec/docker/cli-plugins/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose' \
  || abort 'could not install the Docker Compose plugin in the runner'

inrun 'docker version --format "{{.Server.Version}}"' >/dev/null \
  || abort 'the runner cannot reach the Docker daemon'
info "runner ready ($(inrun 'docker compose version --short' 2>/dev/null | tr -d '\r'))"

# setup.sh creates these, but the runner has to join kubedok-proxy to reach
# nginx by name, so create them up front. ensure_network is idempotent.
docker network create kubedok-postgres >/dev/null 2>&1 || true
docker network create kubedok-proxy    >/dev/null 2>&1 || true
docker network connect kubedok-proxy "${RUNNER}" >/dev/null 2>&1 || true

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 0 — the documented install flow'

# This suite used to copy every file into place and then run setup.sh, which
# proved the installer worked but never proved the INSTRUCTIONS did. The
# documented flow was "download setup.sh and run it", which cannot work:
# setup.sh sources scripts/common.sh. Test the instructions, not just the code.

inrun "mkdir -p ${WORK}/solo && cp ${SERVE_DIR}/setup.sh ${WORK}/solo/setup.sh && chmod +x ${WORK}/solo/setup.sh"
solo_out="$(inrun "cd ${WORK}/solo && ./setup.sh 2>&1 || true")"

if grep -q 'git clone' <<<"${solo_out}"; then
  pass 'a lone setup.sh explains that the repository must be cloned'
else
  fails 'a lone setup.sh does not tell the user to clone'
  printf '%s\n' "${solo_out}" | head -4 | sed 's/^/      /'
fi

if inrun "cd ${WORK}/solo && ./setup.sh >/dev/null 2>&1"; then
  fails 'a lone setup.sh exited 0 — it must refuse to run'
else
  pass 'a lone setup.sh exits non-zero'
fi

# A real clone, which is what the documentation now tells people to do.
inrun "rm -rf ${WORK}/clone && git clone -q file://${REPO_MIRROR} ${WORK}/clone" \
  && pass 'git clone succeeds' \
  || fails 'git clone failed'

for f in setup.sh update.sh scripts/common.sh compose/server.yml compose/postgres.yml; do
  if inrun "test -f ${WORK}/clone/${f}"; then
    pass "clone contains ${f}"
  else
    fails "clone is missing ${f}"
  fi
done

# Prove setup.sh in a clone gets past bootstrap and into common.sh's own code:
# an unreachable release URL must fail at manifest download, not at sourcing.
if ! inrun "test -x ${WORK}/clone/setup.sh"; then
  fails 'no clone to test the bootstrap against'
else
  boot_out="$(inrun "cd ${WORK}/clone && KUBEDOK_SKIP_DEPS=true KUBEDOK_TLS=off \
    KUBEDOK_RELEASE_BASE_URL=file:///nonexistent-on-purpose \
    KUBEDOK_ROOT=${WORK}/bootcheck ./setup.sh 2>&1 || true")"
  if grep -q 'git clone' <<<"${boot_out}"; then
    fails 'setup.sh from a clone still cannot find common.sh'
  elif grep -qiE 'could not download|Kubedok installer' <<<"${boot_out}"; then
    pass 'setup.sh from a clone gets past the bootstrap guard'
  else
    fails 'setup.sh from a clone produced unrecognised output'
    printf '%s\n' "${boot_out}" | head -4 | sed 's/^/      /'
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 1 — fresh install (setup.sh)'

if inrun "${SERVE_DIR}/setup.sh" > "${WORK}/setup.log" 2>&1; then
  pass 'setup.sh completed'
else
  fails 'setup.sh failed'
  tail -40 "${WORK}/setup.log" | sed 's/^/      /'
  abort 'cannot continue without a working install'
fi

assert_eq '1.0.0' "$(inrun "readlink -f ${INSTALL_ROOT}/current | xargs basename" | tr -d '\r')" \
  'current release symlink points at 1.0.0'
assert_fails 'a fresh install records no previous release' \
  docker exec "${RUNNER}" test -L "${INSTALL_ROOT}/previous"

# The summary once named ${KUBEDOK_ROOT}/update.sh, which nothing installed.
# Hold it to a command that exists.
UPDATER="${INSTALL_ROOT}/current/scripts/update.sh"
assert_eq 'sudo kbd update' "$(sed -n 's/^  Update  *//p' "${WORK}/setup.log" | tr -d '\r' | head -1)" \
  'the setup summary names kbd update as the updater'
assert_eq '755' "$(inrun "stat -c %a ${UPDATER}" 2>/dev/null | tr -d '\r')" \
  'the installed update.sh is mode 755'

# kbd runs the scripts by name, through `current`.
assert_eq "${INSTALL_ROOT}/current/scripts/kbd" "$(inrun 'readlink /usr/local/bin/kbd' | tr -d '\r')" \
  '/usr/local/bin/kbd links to current/scripts/kbd'
assert_eq 'Kubedok 1.0.0 (agent 1.0.0)' "$(inrun 'kbd version' | tr -d '\r')" 'kbd version names the release'
# Without KUBEDOK_ROOT, kbd finds the install it belongs to from its own path.
assert_eq 'Kubedok 1.0.0 (agent 1.0.0)' "$(inrun 'env -u KUBEDOK_ROOT kbd version' | tr -d '\r')" \
  'kbd finds its install without KUBEDOK_ROOT'
# Captured first: grep -q stops reading at a match, and under pipefail the
# writer's broken pipe would fail the check.
out="$(inrun 'kbd help' 2>&1 || true)"
if grep -qE '^  config +Show and change the settings' <<<"${out}"; then
  pass 'kbd help lists the commands'
else
  fails 'kbd help does not list config'
fi
assert_eq "${HTTP_PORT}" "$(inrun 'kbd config get http_port' | tr -d '\r')" 'kbd passes the arguments on'
# The scripts' hints name the kbd command once it is installed. No backup
# exists yet, and doctor.sh exits non-zero here for the host-port checks.
out="$(inrun 'kbd doctor' 2>&1 || true)"
if grep -q 'none yet — run kbd backup' <<<"${out}"; then
  pass 'kbd doctor says to run kbd backup'
else
  fails 'kbd doctor did not say to run kbd backup'
  grep 'Backups' <<<"${out}" | sed 's/^/      /'
fi
out="$(inrun 'kbd frobnicate' 2>&1 || true)"
if grep -q 'Unknown command: frobnicate' <<<"${out}"; then
  pass 'kbd refuses an unknown command'
else
  fails 'kbd did not refuse an unknown command'
fi
out="$(inrun 'runuser -u nobody -- kbd backup' 2>&1 || true)"
if grep -q 'Try: sudo kbd backup' <<<"${out}"; then
  pass 'kbd run without root says to use sudo kbd'
else
  fails 'kbd run without root did not point at sudo kbd'
  printf '%s\n' "${out}" | tail -3 | sed 's/^/      /'
fi

for s in postgres-password jwt-secret registry-encryption-key; do
  mode="$(inrun "stat -c %a ${INSTALL_ROOT}/secrets/${s}" 2>/dev/null | tr -d '\r')"
  assert_eq '600' "${mode}" "secret ${s} is mode 600"
done
assert_eq '700' "$(inrun "stat -c %a ${INSTALL_ROOT}/secrets" | tr -d '\r')" 'secrets dir is mode 700'
assert_eq '600' "$(inrun "stat -c %a ${INSTALL_ROOT}/config/kubedok.env" | tr -d '\r')" 'config is mode 600'

health="$(inrun 'curl -fsS http://kubedok-nginx/api/health' 2>/dev/null | tr -d '\r')"
assert_eq 'ok' "$(jq -r .status <<<"${health}" 2>/dev/null)" '/api/health reports ok'
assert_eq 'connected' "$(jq -r .database <<<"${health}" 2>/dev/null)" '/api/health reports the database connected'

version="$(inrun 'curl -fsS http://kubedok-nginx/api/version' 2>/dev/null | tr -d '\r')"
assert_eq '1.0.0' "$(jq -r .release <<<"${version}" 2>/dev/null)" '/api/version reports 1.0.0'

assert_ok 'web UI is served through nginx' \
  docker exec "${RUNNER}" curl -fsS -o /dev/null http://kubedok-nginx/

# The isolation guarantee is a security property, so assert it rather than assume.
assert_fails 'nginx cannot reach PostgreSQL' \
  docker exec kubedok-nginx sh -c 'nc -z -w2 kubedok-postgres 5432'
assert_ok 'server can reach PostgreSQL' \
  docker exec kubedok-server pg_isready -h kubedok-postgres -p 5432 -U kubedok

published="$(docker inspect -f '{{json .NetworkSettings.Ports}}' kubedok-postgres \
  | jq -r '[to_entries[] | select(.value != null)] | length')"
assert_eq '0' "${published}" 'PostgreSQL publishes no host port'

published="$(docker inspect -f '{{json .NetworkSettings.Ports}}' kubedok-server \
  | jq -r '[to_entries[] | select(.value != null)] | length')"
assert_eq '0' "${published}" 'the server publishes no host port'

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 2 — setup.sh is idempotent'

jwt_before="$(inrun "cat ${INSTALL_ROOT}/secrets/jwt-secret" | tr -d '\r\n')"
if inrun "${SERVE_DIR}/setup.sh" > "${WORK}/setup2.log" 2>&1; then
  pass 'a second setup.sh run succeeds'
else
  fails 'the second setup.sh run failed'
  tail -20 "${WORK}/setup2.log" | sed 's/^/      /'
fi
jwt_after="$(inrun "cat ${INSTALL_ROOT}/secrets/jwt-secret" | tr -d '\r\n')"
assert_eq "${jwt_before}" "${jwt_after}" 'jwt-secret is not regenerated (sessions survive)'

# The runner gives every script KUBEDOK_HTTP_PORT, KUBEDOK_HTTP_BIND and
# KUBEDOK_TLS. update.sh and the rest read kubedok.env alone, so setup.sh has
# to save what it was given; KUBEDOK_HTTP_BIND used to be lost at the next
# update, putting nginx back on every interface.
assert_eq '127.0.0.1' "$(saved_setting KUBEDOK_HTTP_BIND)" 'a setting given to setup.sh is saved'

# A re-run given nothing starts from the saved settings and keeps the
# installed release, even with the channel offering a newer one. It once fell
# back to the defaults and installed whatever stable offered, unbacked-up.
set_stable 1.0.1
if inrun "env -u KUBEDOK_HTTP_PORT -u KUBEDOK_HTTP_BIND -u KUBEDOK_TLS KUBEDOK_LOG_LEVEL=debug \
    ${SERVE_DIR}/setup.sh" > "${WORK}/setup3.log" 2>&1; then
  pass 'a re-run given only KUBEDOK_LOG_LEVEL succeeds'
else
  fails 'a re-run given only KUBEDOK_LOG_LEVEL failed'
  tail -20 "${WORK}/setup3.log" | sed 's/^/      /'
fi
assert_eq '1.0.0' "$(installed_release)" 'the re-run kept 1.0.0 although stable offers 1.0.1'
assert_eq "127.0.0.1:${HTTP_PORT}" \
  "$(docker inspect -f '{{json .HostConfig.PortBindings}}' kubedok-nginx | jq -r '."80/tcp"[0] | "\(.HostIp):\(.HostPort)"')" \
  'nginx still listens on the saved address and port'
assert_eq 'debug' "$(saved_setting KUBEDOK_LOG_LEVEL)" 'the setting the re-run was given is saved'
assert_eq 'debug' "$(container_env kubedok-server LOG_LEVEL)" 'and the server runs with it'

out="$(inrun "KUBEDOK_RELEASE=1.0.1 ${SERVE_DIR}/setup.sh" 2>&1 || true)"
if grep -q 'setup.sh does not change releases' <<<"${out}"; then
  pass 'a re-run asked for another release points at update.sh instead'
else
  fails 'a re-run asked for another release was not refused'
  printf '%s\n' "${out}" | tail -5 | sed 's/^/      /'
fi
assert_eq '1.0.0' "$(installed_release)" 'the refused re-run left the install on 1.0.0'
set_stable 1.0.0

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 2b — a TLS install re-run with nothing given stays on TLS'

# A re-run once took KUBEDOK_TLS's default and found no host in the
# environment, so it switched a TLS install to plain HTTP. A certificate for
# the host is already in place, which also means no DNS check is needed: the
# host only resolves inside this test.
TLS_HOST='kubedok.test'
inrun "set -e; d=${INSTALL_ROOT}/tls/letsencrypt/live/${TLS_HOST}; mkdir -p \$d
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout \$d/privkey.pem -out \$d/fullchain.pem -subj /CN=${TLS_HOST} \
    -addext subjectAltName=DNS:${TLS_HOST} -days 2 >/dev/null 2>&1
  chmod 644 \$d/*.pem" || abort 'could not create a test certificate'

if inrun "KUBEDOK_TLS=on KUBEDOK_HOST=${TLS_HOST} ${SERVE_DIR}/setup.sh" > "${WORK}/setup-tls.log" 2>&1; then
  pass 'setup.sh turns TLS on for a host that has a certificate'
else
  fails 'setup.sh could not turn TLS on'
  tail -20 "${WORK}/setup-tls.log" | sed 's/^/      /'
fi
assert_eq 'true' "$(container_env kubedok-nginx KUBEDOK_TLS_ENABLED)" 'nginx serves TLS'
assert_eq '301' "$(inrun 'curl -s -o /dev/null -w %{http_code} http://kubedok-nginx/' | tr -d '\r')" \
  'port 80 redirects to HTTPS'

if inrun "env -u KUBEDOK_TLS ${SERVE_DIR}/setup.sh" > "${WORK}/setup-tls2.log" 2>&1; then
  pass 'a re-run given nothing succeeds'
else
  fails 'a re-run given nothing failed'
  tail -20 "${WORK}/setup-tls2.log" | sed 's/^/      /'
fi
assert_eq 'true' "$(saved_setting KUBEDOK_TLS_ENABLED)" 'it keeps TLS on in kubedok.env'
assert_eq 'true' "$(container_env kubedok-nginx KUBEDOK_TLS_ENABLED)" 'and nginx keeps serving TLS'
assert_eq "${TLS_HOST}" "$(container_env kubedok-nginx KUBEDOK_SERVER_NAME)" 'for the saved host'

# Back to plain HTTP for the rest of the suite. An empty variable clears the host.
if inrun "KUBEDOK_TLS=off KUBEDOK_HOST= ${SERVE_DIR}/setup.sh" > "${WORK}/setup-tls3.log" 2>&1; then
  pass 'setup.sh turns TLS off again'
else
  fails 'setup.sh could not turn TLS off'
  tail -20 "${WORK}/setup-tls3.log" | sed 's/^/      /'
fi
assert_eq 'false' "$(container_env kubedok-nginx KUBEDOK_TLS_ENABLED)" 'nginx serves plain HTTP'
assert_eq '' "$(saved_setting KUBEDOK_HOST)" 'the host given empty is cleared'
inrun "rm -rf ${INSTALL_ROOT}/tls/letsencrypt/live/${TLS_HOST}"

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 2c — config.sh'

CONFIG="${INSTALL_ROOT}/current/scripts/config.sh"
out="$(inrun "${CONFIG}" 2>&1 | tr -d '\r' || true)"
if grep -qE '^  KUBEDOK_LOG_LEVEL +debug ' <<<"${out}" \
   && grep -qE '^  KUBEDOK_CLIENT_MAX_BODY_SIZE +100m \(default\) ' <<<"${out}"; then
  pass 'config.sh lists saved settings and defaults'
else
  fails 'config.sh did not list the settings as expected'
  printf '%s\n' "${out}" | head -20 | sed 's/^/      /'
fi

server_started="$(started_at kubedok-server)"
if inrun "${CONFIG} set CLIENT_MAX_BODY_SIZE=250m" > "${WORK}/config1.log" 2>&1; then
  pass 'config.sh set CLIENT_MAX_BODY_SIZE=250m'
else
  fails 'config.sh set CLIENT_MAX_BODY_SIZE=250m failed'
  tail -20 "${WORK}/config1.log" | sed 's/^/      /'
fi
assert_eq '250m' "$(saved_setting KUBEDOK_CLIENT_MAX_BODY_SIZE)" 'the value is saved in kubedok.env'
assert_eq '250m' "$(inrun "sed -n 's/^KUBEDOK_CLIENT_MAX_BODY_SIZE=//p' ${INSTALL_ROOT}/config/compose.env" | tr -d '\r')" \
  'and written into compose.env'
assert_eq '250m' "$(container_env kubedok-nginx KUBEDOK_CLIENT_MAX_BODY_SIZE)" 'nginx was restarted with it'
assert_eq "${server_started}" "$(started_at kubedok-server)" 'the server, which does not read it, was left alone'
assert_eq '250m' "$(inrun "${CONFIG} get client_max_body_size" | tr -d '\r')" 'config.sh get reads it back'

if inrun "${CONFIG} unset LOG_LEVEL" > "${WORK}/config2.log" 2>&1; then
  pass 'config.sh unset LOG_LEVEL'
else
  fails 'config.sh unset LOG_LEVEL failed'
  tail -20 "${WORK}/config2.log" | sed 's/^/      /'
fi
assert_fails 'the line is gone from kubedok.env' \
  docker exec "${RUNNER}" grep -q '^KUBEDOK_LOG_LEVEL=' "${INSTALL_ROOT}/config/kubedok.env"
assert_eq 'log' "$(container_env kubedok-server LOG_LEVEL)" 'the server is back on the default'

config_sum="$(inrun "sha256sum ${INSTALL_ROOT}/config/kubedok.env" | tr -d '\r')"
for refused in 'set LOG_LEVEL=loud|is one of' 'set HOST=x.example.com|setup.sh changes it' \
               'set RELEASE=1.0.1|update.sh changes the release' 'set NOT_A_SETTING=1|not a Kubedok setting' \
               'set SYNC_INTERVAL_SECS=5|agent.env' "set TRUST_PROXY=a\\ b|cannot hold"; do
  args="${refused%%|*}" reason="${refused#*|}"
  if out="$(inrun "${CONFIG} ${args}" 2>&1)"; then
    fails "config.sh ${args} unexpectedly succeeded"
  elif grep -q -- "${reason}" <<<"${out}"; then
    pass "config.sh ${args} is refused: ${reason}"
  else
    fails "config.sh ${args} was refused without saying '${reason}'"
    printf '%s\n' "${out}" | tail -3 | sed 's/^/      /'
  fi
done
assert_eq "${config_sum}" "$(inrun "sha256sum ${INSTALL_ROOT}/config/kubedok.env" | tr -d '\r')" \
  'refused changes leave kubedok.env as it was'

if inrun "${CONFIG} set JWT_EXPIRES_IN=30m --no-restart" > "${WORK}/config3.log" 2>&1; then
  pass 'config.sh set --no-restart'
else
  fails 'config.sh set --no-restart failed'
  tail -20 "${WORK}/config3.log" | sed 's/^/      /'
fi
assert_eq '15m' "$(container_env kubedok-server JWT_EXPIRES_IN)" '--no-restart leaves the server as it was'
inrun "${INSTALL_ROOT}/current/scripts/restart.sh server" >/dev/null 2>&1 || true
assert_eq '30m' "$(container_env kubedok-server JWT_EXPIRES_IN)" 'restart.sh then applies the saved value'

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 2d — restart.sh restarts the agent from its own settings'

# The agent keeps its image pin and settings in its own agent.env.
# restart.sh used to recreate it from the control plane's compose.env, which
# swapped in the release's agent image and dropped its host address. A
# stand-in container: what is under test is which files restart.sh uses.
AGENT_ROOT="${WORK}/opt-kubedok-agent"
mkdir -p "${AGENT_ROOT}"
cat > "${AGENT_ROOT}/docker-compose.yml" <<'YML'
name: kubedok-agent
services:
  agent:
    image: ${KUBEDOK_IMAGE_AGENT:?KUBEDOK_IMAGE_AGENT is required}
    container_name: kubedok-agent
    command: ["sleep", "infinity"]
    # The real agent uses the host network; this leaves no network behind.
    network_mode: none
    environment:
      KUBEDOK_API_URL: ${KUBEDOK_API_URL:?KUBEDOK_API_URL is required}
      KUBEDOK_HOST_ADDRESS: ${KUBEDOK_HOST_ADDRESS:-}
YML
printf 'KUBEDOK_IMAGE_AGENT=debian:bookworm-slim\nKUBEDOK_API_URL=http://agent-api.test\nKUBEDOK_HOST_ADDRESS=10.9.8.7\n' \
  > "${AGENT_ROOT}/agent.env"
if inrun "KUBEDOK_AGENT_ROOT=${AGENT_ROOT} ${INSTALL_ROOT}/current/scripts/restart.sh agent" > "${WORK}/agent.log" 2>&1; then
  pass 'restart.sh agent completed'
else
  fails 'restart.sh agent failed'
  tail -20 "${WORK}/agent.log" | sed 's/^/      /'
fi
assert_eq 'debian:bookworm-slim' "$(docker inspect -f '{{.Config.Image}}' kubedok-agent 2>/dev/null)" \
  "the agent runs agent.env's image"
assert_eq '10.9.8.7' "$(container_env kubedok-agent KUBEDOK_HOST_ADDRESS)" "and keeps agent.env's host address"
docker rm -f kubedok-agent >/dev/null 2>&1 || true

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 3 — backup.sh'

backup_path="$(inrun "${INSTALL_ROOT}/current/scripts/backup.sh --label test --quiet" | tr -d '\r')"
if [ -n "${backup_path}" ] && inrun "test -f '${backup_path}'"; then
  pass "backup created: $(basename "${backup_path}")"
else
  fails 'backup.sh produced no archive'
fi
assert_eq '600' "$(inrun "stat -c %a '${backup_path}'" 2>/dev/null | tr -d '\r')" 'the backup archive is mode 600'

contents="$(inrun "tar -tzf '${backup_path}'" | tr -d '\r')"
for entry in ./database.sql ./backup.json ./secrets/jwt-secret ./secrets/registry-encryption-key; do
  if grep -qx -- "${entry}" <<<"${contents}"; then
    pass "backup contains ${entry}"
  else
    fails "backup is missing ${entry}"
  fi
done

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 4 — update.sh 1.0.0 → 1.0.1, from the install'

# Operators run the copy in the release tree, not the clone, which they may
# have deleted. It has to find common.sh beside itself.
out="$(inrun "${UPDATER} --check 1.0.1" 2>&1 || true)"
if grep -q 'Available : 1.0.1' <<<"${out}"; then
  pass 'the installed update.sh --check reports 1.0.1'
else
  fails 'the installed update.sh --check did not report 1.0.1'
  printf '%s\n' "${out}" | tail -5 | sed 's/^/      /'
fi
assert_eq '1.0.0' "$(inrun "readlink -f ${INSTALL_ROOT}/current | xargs basename" | tr -d '\r')" \
  'update.sh --check left the install on 1.0.0'

if inrun "${UPDATER} 1.0.1" > "${WORK}/update.log" 2>&1; then
  pass 'the installed update.sh completed'
else
  fails 'the installed update.sh failed'
  tail -40 "${WORK}/update.log" | sed 's/^/      /'
fi

assert_eq '1.0.1' "$(inrun "readlink -f ${INSTALL_ROOT}/current | xargs basename" | tr -d '\r')" \
  'current now points at 1.0.1'
version="$(inrun 'curl -fsS http://kubedok-nginx/api/version' 2>/dev/null | tr -d '\r')"
assert_eq '1.0.1' "$(jq -r .release <<<"${version}" 2>/dev/null)" '/api/version reports 1.0.1'
assert_ok '1.0.0 is retained on disk for rollback' \
  docker exec "${RUNNER}" test -f "${INSTALL_ROOT}/releases/1.0.0/release.json"
assert_eq '1.0.0' "$(previous_link)" 'previous points at 1.0.0, the release the update replaced'
assert_fails 'the update left no staging area' docker exec "${RUNNER}" test -e "${INSTALL_ROOT}/.staging"

assert_eq 'Kubedok 1.0.1 (agent 1.0.0)' "$(inrun 'kbd version' | tr -d '\r')" 'kbd follows current to 1.0.1'

# The staged release must carry an updater too, or the next update has none.
assert_eq '755' "$(inrun "stat -c %a ${INSTALL_ROOT}/releases/1.0.1/scripts/update.sh" 2>/dev/null | tr -d '\r')" \
  'the 1.0.1 release tree carries update.sh, mode 755'
assert_ok "1.0.1's update.sh is the published one" \
  docker exec "${RUNNER}" cmp -s "${SERVE_DIR}/update.sh" "${INSTALL_ROOT}/releases/1.0.1/scripts/update.sh"

jwt_after_update="$(inrun "cat ${INSTALL_ROOT}/secrets/jwt-secret" | tr -d '\r\n')"
assert_eq "${jwt_before}" "${jwt_after_update}" 'the update did not rotate jwt-secret'

# update.sh rebuilds compose.env from kubedok.env, so what config.sh saved holds.
assert_eq '250m' "$(container_env kubedok-nginx KUBEDOK_CLIENT_MAX_BODY_SIZE)" \
  'nginx keeps the body size config.sh set'
assert_eq '30m' "$(container_env kubedok-server JWT_EXPIRES_IN)" 'the server keeps the token lifetime config.sh set'
assert_ok "the 1.0.1 release tree carries config.sh" \
  docker exec "${RUNNER}" test -x "${INSTALL_ROOT}/releases/1.0.1/scripts/config.sh"

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 5 — update guards'

# current is 1.0.1 now, so this runs the copy the update staged.
if inrun "${UPDATER} 1.0.1" 2>&1 | grep -q 'Already on 1.0.1'; then
  pass 'a no-op update is detected by the staged update.sh'
else
  fails 'updating to the installed version was not detected as a no-op'
fi

# --force installs the installed release again: the server and nginx are
# recreated with nothing about them changed, the database is left running.
server_started="$(started_at kubedok-server)"
nginx_started="$(started_at kubedok-nginx)"
postgres_started="$(started_at kubedok-postgres)"
if out="$(inrun "${UPDATER} --force 1.0.1" 2>&1)"; then
  pass 'update.sh --force on the installed release completes'
else
  fails 'update.sh --force on the installed release failed'
  printf '%s\n' "${out}" | tail -20 | sed 's/^/      /'
fi
if grep -q 'Installing 1.0.1 again, with the same images' <<<"${out}"; then
  pass 'it says the images are the same'
else
  fails 'it did not say the images are the same'
fi
if [ "$(started_at kubedok-server)" != "${server_started}" ]; then
  pass 'the server was recreated'
else
  fails 'the server was not recreated'
fi
if [ "$(started_at kubedok-nginx)" != "${nginx_started}" ]; then
  pass 'nginx was recreated'
else
  fails 'nginx was not recreated'
fi
assert_eq "${postgres_started}" "$(started_at kubedok-postgres)" 'PostgreSQL, whose image did not change, kept running'
assert_eq '250m' "$(container_env kubedok-nginx KUBEDOK_CLIENT_MAX_BODY_SIZE)" 'nginx came back with the saved settings'
assert_eq '1.0.1' "$(installed_release)" 'current still points at 1.0.1'
assert_eq '1.0.0' "$(previous_link)" 'previous still points at 1.0.0, not at 1.0.1 itself'
assert_fails 'the reinstall left no staging area' docker exec "${RUNNER}" test -e "${INSTALL_ROOT}/.staging"

# 1.0.1 published again with a new server image, as release.sh does for a
# version that is published already. A plain run still has nothing to do;
# --force installs the new image and records the new manifest.
cid="$(docker create kubedok-server:dev)"
docker commit --change 'LABEL kubedok.test=republished' "${cid}" "${REPUBLISHED_IMAGE}" >/dev/null
docker rm "${cid}" >/dev/null
push_component server "${REPUBLISHED_IMAGE}" 1.0.1
write_manifest 1.0.1 1.0.0
if inrun "${UPDATER} 1.0.1" 2>&1 | grep -q 'Already on 1.0.1'; then
  pass 'without --force, a republished installed version is still a no-op'
else
  fails 'without --force, a republished installed version was not a no-op'
fi
if out="$(inrun "${UPDATER} -f 1.0.1" 2>&1)"; then
  pass 'update.sh -f installs the republished 1.0.1'
else
  fails 'update.sh -f on the republished 1.0.1 failed'
  printf '%s\n' "${out}" | tail -20 | sed 's/^/      /'
fi
if grep -q 'new images for server$' <<<"$(tr -d '\r' <<<"${out}")"; then
  pass 'it names the image that changed'
else
  fails 'it did not name the server image as the one that changed'
fi
assert_eq "$(digest_of server 1.0.1)" "$(docker inspect -f '{{.Config.Image}}' kubedok-server 2>/dev/null)" \
  'the server runs the republished image'
assert_eq "$(digest_of server 1.0.1)" \
  "$(inrun "jq -r .images.server ${INSTALL_ROOT}/releases/1.0.1/release.json" | tr -d '\r')" \
  'the installed manifest records it'
assert_eq '1.0.0' "$(previous_link)" 'previous still points at 1.0.0'

# The rest run the repository-root copy, with common.sh under scripts/, so
# running update.sh from a clone stays covered.
# A PostgreSQL major bump must never be applied by a routine update.
out="$(inrun "${SERVE_DIR}/update.sh 2.0.0" 2>&1 || true)"
if grep -q 'major-version upgrade' <<<"${out}"; then
  pass 'update.sh refuses a PostgreSQL major-version change'
else
  fails 'update.sh did NOT refuse a PostgreSQL major-version change'
  printf '%s\n' "${out}" | tail -5 | sed 's/^/      /'
fi
assert_eq '1.0.1' "$(inrun "readlink -f ${INSTALL_ROOT}/current | xargs basename" | tr -d '\r')" \
  'the refused update left the install on 1.0.1'

# A manifest whose image is a tag rather than a digest must be rejected.
jq '.images.server = "localhost:5050/kubedok-server:1.0.1"' "${SERVE_DIR}/releases/1.0.1.json" \
  > "${SERVE_DIR}/releases/1.0.2.json"
jq '.release = "1.0.2"' "${SERVE_DIR}/releases/1.0.2.json" > "${SERVE_DIR}/releases/1.0.2.tmp"
mv "${SERVE_DIR}/releases/1.0.2.tmp" "${SERVE_DIR}/releases/1.0.2.json"
out="$(inrun "${SERVE_DIR}/update.sh 1.0.2" 2>&1 || true)"
if grep -q 'not digest-pinned' <<<"${out}"; then
  pass 'a tag-pinned manifest is rejected'
else
  fails 'a tag-pinned manifest was NOT rejected'
  printf '%s\n' "${out}" | tail -5 | sed 's/^/      /'
fi

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 6 — a failed update leaves nothing behind'

# Each of these fails after the backup, once staging has begun. The staged
# tree used to stay in releases/, where rollback.sh took the highest version
# that was not current for its target: the release that had just failed.
# The installed updater runs them, as an operator would.
zero_digest="sha256:$(printf '%064d' 0)"

# An image that cannot be pulled: die before any container changes.
jq --arg ref "localhost:${REG_PORT}/kubedok-server@${zero_digest}" \
  '.release = "1.0.3" | .images.server = $ref' \
  "${SERVE_DIR}/releases/1.0.1.json" > "${SERVE_DIR}/releases/1.0.3.json"
if out="$(inrun "${UPDATER} 1.0.3" 2>&1)"; then
  fails 'an update to an unpullable image unexpectedly succeeded'
else
  if grep -q 'Nothing has changed yet' <<<"${out}"; then
    pass 'an unpullable image stops the update before anything changes'
  else
    fails 'an unpullable image did not stop the update at the pull'
    printf '%s\n' "${out}" | tail -5 | sed 's/^/      /'
  fi
fi
assert_update_left_nothing 'unpullable 1.0.3' '1.0.0 1.0.1' '1.0.1' '1.0.0'

# A server that comes up healthy but reports another release: the update
# swaps the containers, fails the smoke test through nginx, and has to put
# 1.0.1's back. The entrypoint is the image's own, behind `env`.
entrypoint="$(docker image inspect kubedok-server:dev --format '{{json .Config.Entrypoint}}' \
  | jq -c '["env", "KUBEDOK_RELEASE_VERSION=0.0.0-not-1.0.4"] + .')"
cid="$(docker create kubedok-server:dev)"
docker commit --change "ENTRYPOINT ${entrypoint}" "${cid}" "${WRONG_RELEASE_IMAGE}" >/dev/null
docker rm "${cid}" >/dev/null
push_component server   "${WRONG_RELEASE_IMAGE}" 1.0.4
push_component nginx    kubedok-nginx:dev        1.0.4
push_component postgres kubedok-postgres:dev     1.0.4
write_manifest 1.0.4 1.0.0
if out="$(inrun "${UPDATER} 1.0.4" 2>&1)"; then
  fails 'an update whose server reports the wrong release unexpectedly succeeded'
else
  if grep -q 'restoring 1.0.1' <<<"${out}"; then
    pass 'a failed smoke test restores 1.0.1'
  else
    fails 'a failed smoke test did not restore 1.0.1'
    printf '%s\n' "${out}" | tail -5 | sed 's/^/      /'
  fi
fi
assert_eq "$(digest_of server 1.0.1)" "$(docker inspect -f '{{.Config.Image}}' kubedok-server 2>/dev/null)" \
  "the server runs 1.0.1's image again"
reported=''
for _ in $(seq 1 60); do
  reported="$(inrun 'curl -fsS http://kubedok-nginx/api/version' 2>/dev/null | tr -d '\r' \
    | jq -r '.release // empty' 2>/dev/null || true)"
  [ "${reported}" = '1.0.1' ] && break
  sleep 2
done
assert_eq '1.0.1' "${reported}" '/api/version reports 1.0.1 again'
assert_update_left_nothing 'smoke-tested 1.0.4' '1.0.0 1.0.1' '1.0.1' '1.0.0'

# A forced reinstall replaces the tree `current` points at, so a failed one
# must leave that tree and the images it pinned exactly as they were. 1.0.1 is
# published again with the server that reports the wrong release.
sum_before="$(tree_sum 1.0.1)"
cp "${SERVE_DIR}/releases/1.0.1.json" "${WORK}/1.0.1.json.published"
jq --arg ref "$(digest_of server 1.0.4)" '.images.server = $ref' \
  "${WORK}/1.0.1.json.published" > "${SERVE_DIR}/releases/1.0.1.json"
if out="$(inrun "${UPDATER} --force 1.0.1" 2>&1)"; then
  fails 'a forced reinstall whose server reports the wrong release unexpectedly succeeded'
else
  if grep -q 'restoring 1.0.1' <<<"${out}"; then
    pass 'a failed forced reinstall restores 1.0.1'
  else
    fails 'a failed forced reinstall did not restore 1.0.1'
    printf '%s\n' "${out}" | tail -5 | sed 's/^/      /'
  fi
fi
mv "${WORK}/1.0.1.json.published" "${SERVE_DIR}/releases/1.0.1.json"
assert_eq "$(digest_of server 1.0.1)" "$(docker inspect -f '{{.Config.Image}}' kubedok-server 2>/dev/null)" \
  "the server runs the installed 1.0.1 image again"
reported=''
for _ in $(seq 1 60); do
  reported="$(inrun 'curl -fsS http://kubedok-nginx/api/version' 2>/dev/null | tr -d '\r' \
    | jq -r '.release // empty' 2>/dev/null || true)"
  [ "${reported}" = '1.0.1' ] && break
  sleep 2
done
assert_eq '1.0.1' "${reported}" '/api/version reports 1.0.1 again'
assert_eq "${sum_before}" "$(tree_sum 1.0.1)" 'the installed 1.0.1 tree is exactly as it was'
assert_update_left_nothing 'forced 1.0.1' '1.0.0 1.0.1' '1.0.1' '1.0.0'

# A release that is already on disk, kept for rollback, must come out of a
# failed update to it exactly as it went in. Its manifest is swapped for one
# that cannot be pulled, so staging it would have overwritten release.json.
sum_before="$(tree_sum 1.0.0)"
cp "${SERVE_DIR}/releases/1.0.0.json" "${WORK}/1.0.0.json.published"
jq --arg ref "localhost:${REG_PORT}/kubedok-server@${zero_digest}" '.images.server = $ref' \
  "${WORK}/1.0.0.json.published" > "${SERVE_DIR}/releases/1.0.0.json"
if inrun "${UPDATER} 1.0.0" >/dev/null 2>&1; then
  fails 'the update to an unpullable 1.0.0 unexpectedly succeeded'
else
  pass 'an update to 1.0.0, already on disk, fails at the pull'
fi
mv "${WORK}/1.0.0.json.published" "${SERVE_DIR}/releases/1.0.0.json"
assert_eq "${sum_before}" "$(tree_sum 1.0.0)" 'the 1.0.0 tree on disk is exactly as it was'
assert_update_left_nothing 're-staged 1.0.0' '1.0.0 1.0.1' '1.0.1' '1.0.0'

# Every file of the tree is required: one the source does not serve stops
# the update, and says which. The "optional" fetches used to exit the script
# anyway, with their error sent to /dev/null.
jq '.release = "1.0.5"' "${SERVE_DIR}/releases/1.0.1.json" > "${SERVE_DIR}/releases/1.0.5.json"
mv "${SERVE_DIR}/scripts/restore.sh" "${WORK}/restore.sh.hidden"
if out="$(inrun "${UPDATER} 1.0.5" 2>&1)"; then
  fails 'an update missing restore.sh unexpectedly succeeded'
else
  if grep -q 'Could not download .*/scripts/restore.sh' <<<"${out}"; then
    pass 'a file that cannot be fetched stops the update, by name'
  else
    fails 'a file that cannot be fetched did not stop the update with its name'
    printf '%s\n' "${out}" | tail -5 | sed 's/^/      /'
  fi
fi
mv "${WORK}/restore.sh.hidden" "${SERVE_DIR}/scripts/restore.sh"
assert_update_left_nothing 'unfetchable 1.0.5' '1.0.0 1.0.1' '1.0.1' '1.0.0'

listing="$(inrun "${INSTALL_ROOT}/current/scripts/rollback.sh --list" | tr -d '\r' || true)"
assert_eq '1.0.0 1.0.1' "$(awk '{print $1}' <<<"${listing}" | xargs)" 'rollback.sh --list shows 1.0.0 and 1.0.1'
assert_eq '1.0.1' "$(awk '$2 == "current" {print $1}' <<<"${listing}")" 'rollback.sh --list marks 1.0.1 current'
assert_eq '1.0.0' "$(awk '$2 == "previous" {print $1}' <<<"${listing}")" 'rollback.sh --list marks 1.0.0 previous'

# Answering no at the prompt shows the default target without rolling back.
out="$(inrun "echo n | ${INSTALL_ROOT}/current/scripts/rollback.sh" 2>&1 || true)"
if grep -q 'Rolling back  1.0.1 → 1.0.0' <<<"${out}"; then
  pass 'rollback.sh with no version still targets 1.0.0'
else
  fails 'rollback.sh with no version does not target 1.0.0'
  printf '%s\n' "${out}" | grep 'Rolling back' | sed 's/^/      /'
fi

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 6b — kbd clean'

# What an install gathers: an image no release names any more, pulled by
# digest alone as update.sh pulls, and the staging area of a killed update.
# The suite's other images all carry tags, which clean leaves alone.
cid="$(docker create kubedok-server:dev)"
docker commit --change 'LABEL kubedok.test=stale' "${cid}" "${STALE_IMAGE}" >/dev/null
docker rm "${cid}" >/dev/null
docker tag "${STALE_IMAGE}" "localhost:${REG_PORT}/kubedok-server:stale"
docker push -q "localhost:${REG_PORT}/kubedok-server:stale" >/dev/null 2>&1 || abort 'could not push the stale image'
STALE_REF="$(docker image inspect "localhost:${REG_PORT}/kubedok-server:stale" \
  --format '{{range .RepoDigests}}{{println .}}{{end}}' | grep "^localhost:${REG_PORT}/kubedok-server@" | head -1 | tr -d '\n')"
docker image rm "${STALE_IMAGE}" "localhost:${REG_PORT}/kubedok-server:stale" >/dev/null 2>&1 || true
inrun "docker pull -q ${STALE_REF}" >/dev/null 2>&1 || abort 'could not pull the stale image by digest'
inrun "mkdir -p ${INSTALL_ROOT}/.staging/9.9.9"

out="$(inrun 'kbd clean --dry-run' 2>&1 || true)"
if grep -qF "${STALE_REF}" <<<"${out}"; then
  pass 'kbd clean --dry-run lists the image no release uses'
else
  fails 'kbd clean --dry-run does not list the image no release uses'
  printf '%s\n' "${out}" | tail -12 | sed 's/^/      /'
fi
if grep -qF "${INSTALL_ROOT}/.staging" <<<"${out}"; then
  pass 'and the staging area a killed update left'
else
  fails 'kbd clean --dry-run does not list the staging area'
fi
if grep -qF "$(digest_of server 1.0.1)" <<<"${out}"; then
  fails "kbd clean would remove 1.0.1's server image"
else
  pass "1.0.1's server image is not on the list"
fi
assert_ok 'the dry run removed no image' docker image inspect "${STALE_REF}"
assert_ok 'nor the staging area' docker exec "${RUNNER}" test -d "${INSTALL_ROOT}/.staging/9.9.9"

if inrun 'kbd clean --yes' > "${WORK}/clean.log" 2>&1; then
  pass 'kbd clean --yes completed'
else
  fails 'kbd clean --yes failed'
  tail -20 "${WORK}/clean.log" | sed 's/^/      /'
fi
assert_fails 'the image no release uses is gone' docker image inspect "${STALE_REF}"
assert_fails 'the staging area is gone' docker exec "${RUNNER}" test -e "${INSTALL_ROOT}/.staging"
assert_ok "1.0.1's images stay" docker image inspect "$(digest_of server 1.0.1)"
assert_ok "1.0.0's stay too: it is on disk for a rollback" docker image inspect "$(digest_of server 1.0.0)"
assert_ok 'a tagged image no release uses is left alone' \
  docker image inspect "localhost:${REG_PORT}/kubedok-server:1.0.4"
assert_eq '1.0.0 1.0.1' "$(release_entries)" 'without --releases, every release tree stays'
out="$(inrun 'kbd clean --yes' 2>&1 || true)"
if grep -q 'Nothing to clean' <<<"${out}"; then
  pass 'a second run has nothing to clean'
else
  fails 'a second run still found something to clean'
fi

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 7 — rollback.sh 1.0.1 → 1.0.0'

if inrun "${INSTALL_ROOT}/current/scripts/rollback.sh --yes" > "${WORK}/rollback.log" 2>&1; then
  pass 'rollback.sh completed'
else
  fails 'rollback.sh failed'
  tail -30 "${WORK}/rollback.log" | sed 's/^/      /'
fi
assert_eq '1.0.0' "$(inrun "readlink -f ${INSTALL_ROOT}/current | xargs basename" | tr -d '\r')" \
  'current is back to 1.0.0'
version="$(inrun 'curl -fsS http://kubedok-nginx/api/version' 2>/dev/null | tr -d '\r')"
assert_eq '1.0.0' "$(jq -r .release <<<"${version}" 2>/dev/null)" '/api/version reports 1.0.0 again'

# The rollback used the record up. 1.0.1 is still on disk and is the highest
# release that is not current, which is where a second rollback used to go:
# forward, to the release just rolled back from.
assert_fails 'the rollback cleared previous' docker exec "${RUNNER}" test -L "${INSTALL_ROOT}/previous"
listing="$(inrun "${INSTALL_ROOT}/current/scripts/rollback.sh --list" | tr -d '\r' || true)"
assert_eq '1.0.0  current|1.0.1' "$(paste -sd'|' - <<<"${listing}")" \
  'rollback.sh --list marks 1.0.0 current and nothing previous'
out="$(inrun "${INSTALL_ROOT}/current/scripts/rollback.sh --yes" 2>&1 || true)"
if grep -q 'No previous release is recorded' <<<"${out}"; then
  pass 'a second rollback.sh refuses instead of rolling forward'
else
  fails 'a second rollback.sh did not refuse'
  printf '%s\n' "${out}" | tail -5 | sed 's/^/      /'
fi
assert_eq '1.0.0' "$(installed_release)" 'the refused rollback left the install on 1.0.0'

# The rollback left 1.0.1 on disk, neither current nor previous now.
out="$(inrun 'kbd clean --releases --dry-run' 2>&1 || true)"
if grep -qF "${INSTALL_ROOT}/releases/1.0.1" <<<"${out}"; then
  pass 'kbd clean --releases lists the 1.0.1 tree'
else
  fails 'kbd clean --releases does not list the 1.0.1 tree'
  printf '%s\n' "${out}" | tail -8 | sed 's/^/      /'
fi
if inrun 'kbd clean --releases --yes' > "${WORK}/clean2.log" 2>&1; then
  pass 'kbd clean --releases --yes completed'
else
  fails 'kbd clean --releases --yes failed'
  tail -20 "${WORK}/clean2.log" | sed 's/^/      /'
fi
assert_eq '1.0.0' "$(release_entries)" 'only the current release tree is left'
assert_eq '1.0.0' "$(installed_release)" 'and the install is still on it'

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 8 — restore.sh'

# Write a marker row, then restore a backup taken before it existed: the row
# must be gone afterwards, which proves the restore really replaced the data.
inrun "docker exec kubedok-postgres psql -U kubedok -d kubedok -qc \
  \"CREATE TABLE IF NOT EXISTS kubedok_restore_marker(id int)\"" >/dev/null 2>&1
inrun "docker exec kubedok-postgres psql -U kubedok -d kubedok -qc \
  \"INSERT INTO kubedok_restore_marker VALUES (42)\"" >/dev/null 2>&1
marker="$(inrun "docker exec kubedok-postgres psql -U kubedok -d kubedok -tAc \
  'SELECT count(*) FROM kubedok_restore_marker'" | tr -d '\r ')"
assert_eq '1' "${marker}" 'marker row written before restore'

if inrun "${INSTALL_ROOT}/current/scripts/restore.sh '${backup_path}' --yes" > "${WORK}/restore.log" 2>&1; then
  pass 'restore.sh completed'
else
  fails 'restore.sh failed'
  tail -30 "${WORK}/restore.log" | sed 's/^/      /'
fi

still_there="$(inrun "docker exec kubedok-postgres psql -U kubedok -d kubedok -tAc \
  \"SELECT count(*) FROM information_schema.tables WHERE table_name='kubedok_restore_marker'\"" | tr -d '\r ')"
assert_eq '0' "${still_there}" 'the marker table is gone — the restore replaced the data'

health="$(inrun 'curl -fsS http://kubedok-nginx/api/health' 2>/dev/null | tr -d '\r')"
assert_eq 'connected' "$(jq -r .database <<<"${health}" 2>/dev/null)" 'the API is healthy after the restore'

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 9 — status.sh and doctor.sh'

assert_ok 'status.sh runs' docker exec "${RUNNER}" "${INSTALL_ROOT}/current/scripts/status.sh"

# doctor.sh checks host port listeners, which live on the Docker host rather
# than in this runner, so a non-zero exit here is expected. What matters is
# that it produces a report instead of crashing.
doctor_out="$(inrun "${INSTALL_ROOT}/current/scripts/doctor.sh" 2>&1 || true)"
if grep -q 'Kubedok doctor' <<<"${doctor_out}"; then
  pass 'doctor.sh produces a report'
else
  fails 'doctor.sh did not produce a report'
fi
for expected in 'Current release' 'Secret: jwt-secret' 'Network isolation'; do
  if grep -q "${expected}" <<<"${doctor_out}"; then
    pass "doctor.sh checks '${expected}'"
  else
    fails "doctor.sh is missing the '${expected}' check"
  fi
done

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 10 — uninstall.sh keeps data by default'

if inrun "${INSTALL_ROOT}/current/scripts/uninstall.sh --yes" > "${WORK}/uninstall.log" 2>&1; then
  pass 'uninstall.sh completed'
else
  fails 'uninstall.sh failed'
  tail -20 "${WORK}/uninstall.log" | sed 's/^/      /'
fi
assert_fails 'containers are gone' docker inspect kubedok-server
assert_fails 'the kbd command is gone' docker exec "${RUNNER}" test -L /usr/local/bin/kbd
assert_ok 'the PostgreSQL volume survives' docker volume inspect kubedok_postgres_data
assert_ok 'secrets survive' docker exec "${RUNNER}" test -f "${INSTALL_ROOT}/secrets/registry-encryption-key"
assert_ok 'backups survive' docker exec "${RUNNER}" test -d "${INSTALL_ROOT}/backups"

# ═══════════════════════════════════════════════════════════════════════════
printf '\n%s────────────────────────────────────────%s\n' "${c_blue}" "${c_off}"
printf '  %s%d passed%s' "${c_green}" "${PASS}" "${c_off}"
[ "${FAIL}" -gt 0 ] && printf ', %s%d failed%s' "${c_red}" "${FAIL}" "${c_off}"
printf '\n%s────────────────────────────────────────%s\n\n' "${c_blue}" "${c_off}"

[ "${FAIL}" -eq 0 ]
