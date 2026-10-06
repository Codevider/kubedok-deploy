#!/usr/bin/env bash
#
# End-to-end test for the Kubedok deployment scripts.
#
#   tests/integration.sh
#
# Exercises the real scripts against a real Docker daemon: install, backup,
# update, rollback, restore, uninstall, plus the guards that are supposed to
# refuse unsafe operations.
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

# ── Teardown ─────────────────────────────────────────────────────────────────
cleanup() {
  step 'Cleaning up'
  docker rm -f kubedok-nginx kubedok-server kubedok-postgres kubedok-agent >/dev/null 2>&1 || true
  docker rm -f "${RUNNER}" "${REG_NAME}" >/dev/null 2>&1 || true
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
cp "${DEPLOY_DIR}"/scripts/*.sh  "${SERVE_DIR}/scripts/"
cp "${DEPLOY_DIR}"/setup.sh "${DEPLOY_DIR}"/update.sh "${SERVE_DIR}/"
cp "${DEPLOY_DIR}/releases/release.schema.json" "${SERVE_DIR}/releases/"
chmod +x "${SERVE_DIR}"/*.sh "${SERVE_DIR}"/scripts/*.sh
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
    '{schemaVersion:1, release:$release, publishedAt:$published,
      images:{server:$server, nginx:$nginx, postgres:$postgres, agent:$agent},
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

jq -n '{schemaVersion:1, channel:"stable", release:"1.0.0",
        manifest:"releases/1.0.0.json", updatedAt:"2026-01-01T00:00:00Z"}' \
  > "${SERVE_DIR}/channels/stable.json"

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

# The summary once named ${KUBEDOK_ROOT}/update.sh, which nothing installed.
# Hold it to a path that exists.
UPDATER="${INSTALL_ROOT}/current/scripts/update.sh"
assert_eq "${UPDATER}" "$(sed -n 's/^  Update  *//p' "${WORK}/setup.log" | tr -d '\r' | head -1)" \
  'the setup summary names current/scripts/update.sh as the updater'
assert_eq '755' "$(inrun "stat -c %a ${UPDATER}" 2>/dev/null | tr -d '\r')" \
  'the installed update.sh is mode 755'

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

# The staged release must carry an updater too, or the next update has none.
assert_eq '755' "$(inrun "stat -c %a ${INSTALL_ROOT}/releases/1.0.1/scripts/update.sh" 2>/dev/null | tr -d '\r')" \
  'the 1.0.1 release tree carries update.sh, mode 755'
assert_ok "1.0.1's update.sh is the published one" \
  docker exec "${RUNNER}" cmp -s "${SERVE_DIR}/update.sh" "${INSTALL_ROOT}/releases/1.0.1/scripts/update.sh"

jwt_after_update="$(inrun "cat ${INSTALL_ROOT}/secrets/jwt-secret" | tr -d '\r\n')"
assert_eq "${jwt_before}" "${jwt_after_update}" 'the update did not rotate jwt-secret'

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 5 — update guards'

# current is 1.0.1 now, so this runs the copy the update staged.
if inrun "${UPDATER} 1.0.1" 2>&1 | grep -q 'Already on 1.0.1'; then
  pass 'a no-op update is detected by the staged update.sh'
else
  fails 'updating to the installed version was not detected as a no-op'
fi

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
step 'TEST 6 — rollback.sh 1.0.1 → 1.0.0'

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

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 7 — restore.sh'

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
step 'TEST 8 — status.sh and doctor.sh'

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
step 'TEST 9 — uninstall.sh keeps data by default'

if inrun "${INSTALL_ROOT}/current/scripts/uninstall.sh --yes" > "${WORK}/uninstall.log" 2>&1; then
  pass 'uninstall.sh completed'
else
  fails 'uninstall.sh failed'
  tail -20 "${WORK}/uninstall.log" | sed 's/^/      /'
fi
assert_fails 'containers are gone' docker inspect kubedok-server
assert_ok 'the PostgreSQL volume survives' docker volume inspect kubedok_postgres_data
assert_ok 'secrets survive' docker exec "${RUNNER}" test -f "${INSTALL_ROOT}/secrets/registry-encryption-key"
assert_ok 'backups survive' docker exec "${RUNNER}" test -d "${INSTALL_ROOT}/backups"

# ═══════════════════════════════════════════════════════════════════════════
printf '\n%s────────────────────────────────────────%s\n' "${c_blue}" "${c_off}"
printf '  %s%d passed%s' "${c_green}" "${PASS}" "${c_off}"
[ "${FAIL}" -gt 0 ] && printf ', %s%d failed%s' "${c_red}" "${FAIL}" "${c_off}"
printf '\n%s────────────────────────────────────────%s\n\n' "${c_blue}" "${c_off}"

[ "${FAIL}" -eq 0 ]
