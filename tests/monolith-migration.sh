#!/usr/bin/env bash
#
# End-to-end test for migrate-from-monolith.sh and agent-install.sh --adopt.
#
#   tests/monolith-migration.sh
#
# Moves a real single-container install (approxx/kubedok-server:0.0.11) to the
# release the stable channel names, with real images all the way:
#
#   - the old install holds data made through its own API, and a real 0.0.11
#     agent runs a MongoDB service on a named volume, two services that reach
#     it by name (one on glibc, one on musl), and a web service with a host
#     port; an HTTPS load balancer is set up for web;
#   - --check and --dry-run change nothing;
#   - a migration that fails after the old container stopped puts it back;
#   - the migration itself; the old agent reconnecting to the new install,
#     and taking the overlay the new server sends it without failing;
#   - --adopt moving it to the new agent as the same host, which gets its DNS
#     records with no deploy; then every service redeployed, in the order the
#     migration prints, with MongoDB keeping its data and both of its users
#     reaching it throughout.
#
# Unlike integration.sh it needs network access: the images come from Docker
# Hub. The scripts run in a Debian container, as setup.sh does on a server, and
# the agents in a Docker-in-Docker container, so nothing here touches the
# host's own containers. Takes about 20 minutes.
#
# The old container is started as the 0.0.x docs had it, `docker run -d --rm
# --name kubedok-server -p 80:80`: its data on an anonymous volume that --rm
# deletes with it, under the name the new install's server takes. With
# KUBEDOK_TEST_OLD_STYLE=kept it keeps that name but is kept when it stops,
# with a named volume and a restart policy, so it has to move aside instead.
#
# To test a release that is not published, point KUBEDOK_TEST_MANIFEST at its
# manifest. Images it names on localhost:PORT come from a registry container
# published there, named by KUBEDOK_TEST_REGISTRY: the agent host reaches it
# at the same address.
set -Eeuo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK="${KUBEDOK_TEST_WORK:-/private/tmp/kubedok-migration-test}"
INSTALL_ROOT="${WORK}/opt-kubedok"
SERVE_DIR="${WORK}/serve"
CLONE="${WORK}/clone"

RUNNER="kdtest-runner"        # runs the scripts, as a server would
OLD="kubedok-server"          # the single-container install, as the 0.0.x docs named it
OLD_STYLE="${KUBEDOK_TEST_OLD_STYLE:-docs}"
OLD_VOLUME="kdtest-monolith-data" # kept style only; docs style gets an anonymous one
OLD_DATA_VOLUME=""                # the volume its data is on, whatever its kind
OLD_ASIDE="kubedok-monolith"      # where the migration moves a kept one
KEEPER="kubedok-monolith-data"    # what holds a --rm one's data once it is removed
AGENT_HOST="kdtest-host"      # Docker-in-Docker: the managed host
NET="kdtest-net"              # where agents reach the control plane
API_HOST="kubedok.test"       # the name agents know it by
HTTP_PORT="${KUBEDOK_TEST_HTTP_PORT:-18090}"
BASE="http://127.0.0.1:${HTTP_PORT}/api"

OLD_IMAGE="${KUBEDOK_TEST_OLD_IMAGE:-approxx/kubedok-server:0.0.11}"
OLD_AGENT_IMAGE="${KUBEDOK_TEST_OLD_AGENT_IMAGE:-approxx/kubedok-agent:0.0.11}"
MANIFEST="${KUBEDOK_TEST_MANIFEST:-${DEPLOY_DIR}/releases/$(jq -r .release "${DEPLOY_DIR}/channels/stable.json").json}"
STABLE="$(jq -r .release "${MANIFEST}")"
REGISTRY="${KUBEDOK_TEST_REGISTRY:-}"
REGISTRY_PROXY="kdtest-registry-proxy"
MONGO_IMAGE="mongo:7.0"

PASS=0
FAIL=0

c_green=$'\033[32m'; c_red=$'\033[31m'; c_blue=$'\033[34m'; c_dim=$'\033[2m'; c_off=$'\033[0m'

step()  { printf '\n%s▸ %s%s\n' "${c_blue}" "$*" "${c_off}"; }
pass()  { printf '  %s✓%s %s\n' "${c_green}" "${c_off}" "$*"; PASS=$((PASS+1)); }
fails() { printf '  %s✗%s %s\n' "${c_red}" "${c_off}" "$*"; FAIL=$((FAIL+1)); }
info()  { printf '  %s%s%s\n' "${c_dim}" "$*" "${c_off}"; }
# To stderr, so it shows from inside a command substitution too.
abort() { printf '\n%sABORT:%s %s\n\n' "${c_red}" "${c_off}" "$*" >&2; exit 1; }

assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3"; else fails "$3 — expected '$1', got '$2'"; fi
}
assert_ok() {
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "${what}"; else fails "${what}"; fi
}
assert_fails() {
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then fails "${what} — it succeeded"; else pass "${what}"; fi
}
assert_contains() {
  if printf '%s' "$1" | grep -qF -- "$2"; then pass "$3"; else fails "$3 — '$2' not in the output"; fi
}

inrun()  { docker exec -i "${RUNNER}" bash -lc "$*"; }
onhost() { docker exec -i "${AGENT_HOST}" sh -c "$*"; }

# What mongo's users last logged: "ok" while they get through to it by name.
consumer_ok() {
  local name="$1" deadline last=""
  deadline=$(( $(date +%s) + ${2:-90} ))
  while true; do
    last="$(onhost "docker logs --tail 1 shop-${name} 2>&1" 2>/dev/null || true)"
    [ "${last}" = "ok" ] && return 0
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      info "${name} last logged: ${last:-nothing}"
      return 1
    fi
    sleep 3
  done
}
# JavaScript, without single quotes, run against mongo's shop database.
mongo_eval() { onhost "docker exec shop-mongo mongosh --quiet shop --eval '$1'"; }

# The API, as a browser would reach it: the old install and the new one are
# published on the same address. The access token is kept in a file, so that
# one renewed inside a command substitution holds for the calls after it.
TOKEN_FILE="${WORK}/token"
api_once() {
  local method="$1" path="$2" body="${3:-}" token
  token="$(cat "${TOKEN_FILE}" 2>/dev/null || true)"
  local args=(-sS -X "${method}" "${BASE}${path}" -H 'content-type: application/json')
  [ -n "${token}" ] && args+=(-H "Authorization: Bearer ${token}")
  [ -n "${body}" ] && args+=(-d "${body}")
  curl "${args[@]}"
}
# Access tokens last 15 minutes, which setting up the old install can outlast;
# one that has expired is renewed, once.
api() {
  local out
  out="$(api_once "$@")"
  if [[ "${out}" == *'"statusCode":401'* ]] && [ -n "${ADMIN_EMAIL:-}" ] && [[ "$2" != /auth/* ]]; then
    login >/dev/null
    out="$(api_once "$@")"
  fi
  printf '%s' "${out}"
}
# Signs in, keeps the token for api() and prints it.
login() {
  curl -sS -X POST "${BASE}/auth/login" -H 'content-type: application/json' \
    -d "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASSWORD}\"}" 2>/dev/null \
    | jq -r '.accessToken // empty' 2>/dev/null | tee "${TOKEN_FILE}" || true
}
# List responses are an array, or one under items.
JQ_ITEMS='def items: if type == "array" then . else (.items // .data // []) end;'
items() { jq -c "${JQ_ITEMS} items"; }

wait_healthy() {
  local name="$1" timeout="${2:-180}" deadline status
  deadline=$(( $(date +%s) + timeout ))
  while true; do
    status="$(docker container inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${name}" 2>/dev/null || echo missing)"
    [ "${status}" = "healthy" ] && return 0
    [ "$(date +%s)" -ge "${deadline}" ] && return 1
    sleep 2
  done
}

# Polls a jq expression against GET PATH until it prints WANT.
wait_for() {
  local path="$1" expr="$2" want="$3" timeout="${4:-120}" deadline got=""
  deadline=$(( $(date +%s) + timeout ))
  while true; do
    got="$(api GET "${path}" 2>/dev/null | jq -r "${JQ_ITEMS} ${expr}" 2>/dev/null || true)"
    [ "${got}" = "${want}" ] && return 0
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      info "waited for ${path} ${expr} = ${want}, last: ${got}"
      return 1
    fi
    sleep 3
  done
}

service_status() { api GET "/stacks/${STACK_ID}/services/$1" | jq -r '.status // .service.status // empty'; }

wait_service_running() {
  local id="$1" timeout="${2:-240}" deadline status=""
  deadline=$(( $(date +%s) + timeout ))
  while true; do
    status="$(service_status "${id}" 2>/dev/null || true)"
    [ "${status}" = "running" ] && return 0
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      info "service ${id} is ${status:-unknown}"
      api GET "/stacks/${STACK_ID}/services/${id}" | head -c 1500; printf '\n'
      return 1
    fi
    sleep 3
  done
}

# ── Teardown ─────────────────────────────────────────────────────────────────
cleanup() {
  if [ "${KUBEDOK_TEST_KEEP:-false}" = "true" ]; then
    info "KUBEDOK_TEST_KEEP=true: left everything running for a look"
    return 0
  fi
  step 'Cleaning up'
  docker rm -f -v "${RUNNER}" "${REGISTRY_PROXY}" "${AGENT_HOST}" kubedok-nginx kubedok-server kubedok-postgres \
    kubedok-migrate-pg kubedok-migrate-source "${OLD}" "${OLD_ASIDE}" "${KEEPER}" >/dev/null 2>&1 || true
  docker volume rm "${OLD_VOLUME}" ${OLD_DATA_VOLUME:+"${OLD_DATA_VOLUME}"} kubedok_postgres_data >/dev/null 2>&1 || true
  [ -z "${REGISTRY}" ] || docker network disconnect -f "${NET}" "${REGISTRY}" >/dev/null 2>&1 || true
  docker network rm "${NET}" kubedok-proxy kubedok-postgres kubedok-migrate >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
  info 'done'
}
trap cleanup EXIT

# ── Preflight ────────────────────────────────────────────────────────────────
step 'Preflight'
command -v docker >/dev/null || abort 'docker is required'
command -v jq >/dev/null || abort 'jq is required'
docker info >/dev/null 2>&1 || abort 'the Docker daemon is not reachable'
[ -f "${MANIFEST}" ] || abort "no manifest at ${MANIFEST}"
AGENT_IMAGE="$(jq -r .images.agent "${MANIFEST}")"
REGISTRY_PORT=""
if [[ "${AGENT_IMAGE}" =~ ^localhost:([0-9]+)/ ]]; then
  REGISTRY_PORT="${BASH_REMATCH[1]}"
  [ -n "${REGISTRY}" ] || abort "the agent image is on localhost:${REGISTRY_PORT}: name its registry container with KUBEDOK_TEST_REGISTRY"
  docker container inspect "${REGISTRY}" >/dev/null 2>&1 || abort "no registry container named ${REGISTRY}"
fi
cleanup >/dev/null 2>&1 || true

for img in "${OLD_IMAGE}" debian:bookworm-slim docker:27-dind hello-world ${REGISTRY_PORT:+alpine/socat}; do
  docker pull -q "${img}" >/dev/null || abort "could not pull ${img}"
done
info "old image ${OLD_IMAGE}, target release ${STABLE}"

mkdir -p "${WORK}" "${SERVE_DIR}/releases" "${SERVE_DIR}/channels" "${SERVE_DIR}/compose" \
  "${SERVE_DIR}/scripts" "${CLONE}"
cp "${DEPLOY_DIR}"/compose/*.yml "${SERVE_DIR}/compose/"
cp "${DEPLOY_DIR}"/scripts/*.sh "${DEPLOY_DIR}/scripts/kbd" "${SERVE_DIR}/scripts/"
cp "${DEPLOY_DIR}"/setup.sh "${DEPLOY_DIR}"/update.sh "${SERVE_DIR}/"
cp "${MANIFEST}" "${SERVE_DIR}/releases/${STABLE}.json"
jq -n --arg release "${STABLE}" '{schemaVersion: 1, channel: "stable", release: $release,
  manifest: "releases/\($release).json", updatedAt: "2026-01-01T00:00:00Z"}' > "${SERVE_DIR}/channels/stable.json"
# A release whose nginx exits at once, for the migration that has to fail
# after the old container stopped.
HELLO="$(docker image inspect hello-world --format '{{index .RepoDigests 0}}')"
jq --arg nginx "${HELLO}" '.release = "9.9.9" | .images.nginx = $nginx' \
  "${MANIFEST}" > "${SERVE_DIR}/releases/9.9.9.json"
# The clone an operator runs the migration from, uncommitted changes included.
cp -R "${DEPLOY_DIR}/setup.sh" "${DEPLOY_DIR}/update.sh" "${DEPLOY_DIR}/migrate-from-monolith.sh" \
  "${DEPLOY_DIR}/scripts" "${DEPLOY_DIR}/compose" "${CLONE}/"

# ── The old install ──────────────────────────────────────────────────────────
step 'A 0.0.11 install with data, and a 0.0.11 agent'

docker network create "${NET}" >/dev/null
case "${OLD_STYLE}" in
  docs)
    docker run -d --rm --name "${OLD}" --network "${NET}" --network-alias "${API_HOST}" \
      -p "127.0.0.1:${HTTP_PORT}:80" "${OLD_IMAGE}" >/dev/null ;;
  kept)
    docker run -d --name "${OLD}" --restart unless-stopped --network "${NET}" --network-alias "${API_HOST}" \
      -p "127.0.0.1:${HTTP_PORT}:80" -v "${OLD_VOLUME}:/var/lib/postgresql/data" "${OLD_IMAGE}" >/dev/null ;;
  *) abort "unknown KUBEDOK_TEST_OLD_STYLE ${OLD_STYLE}: docs or kept" ;;
esac
wait_healthy "${OLD}" 240 || abort 'the old install did not become healthy'
OLD_DATA_VOLUME="$(docker container inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' "${OLD}")"
info "old install started ${OLD_STYLE} style, its data on ${OLD_DATA_VOLUME:0:20}"
info "old install on 127.0.0.1:${HTTP_PORT}"

# Test values for this throwaway install only.
ADMIN_EMAIL="admin@kdtest.test"
ADMIN_PASSWORD="Kd-$(openssl rand -hex 8)-1a"
REGISTRY_PASSWORD="registry-$(openssl rand -hex 6)"
TOKEN=""
api POST /auth/bootstrap "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASSWORD}\"}" >/dev/null
TOKEN="$(login)"
[ -n "${TOKEN}" ] || abort 'could not sign in to the old install'

ENV_ID="$(api POST /environments '{"templateId":"envtpl_docker","name":"Production","isDefault":true}' | jq -r '.id // empty')"
[ -n "${ENV_ID}" ] || abort 'could not create an environment'
REGISTRY_ID="$(api POST /registries "{\"environmentId\":\"${ENV_ID}\",\"name\":\"ghcr\",\"url\":\"ghcr.io\",\"username\":\"kdtest\",\"password\":\"${REGISTRY_PASSWORD}\"}" | jq -r '.id // empty')"
[ -n "${REGISTRY_ID}" ] || abort 'could not create a registry'
openssl req -x509 -newkey rsa:2048 -nodes -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" \
  -days 30 -subj "/CN=app.kdtest.test" >/dev/null 2>&1
CERT_ID="$(jq -n --arg env "${ENV_ID}" --rawfile cert "${WORK}/cert.pem" --rawfile key "${WORK}/key.pem" \
  '{environmentId: $env, name: "app", certificatePem: $cert, privateKeyPem: $key}' \
  | curl -sS -X POST "${BASE}/certificates" -H 'content-type: application/json' -H "Authorization: Bearer ${TOKEN}" -d @- \
  | jq -r '.id // empty')"
[ -n "${CERT_ID}" ] || abort 'could not create a certificate'
REG_TOKEN="$(api POST /hosts/registration-tokens "{\"environmentId\":\"${ENV_ID}\"}" | jq -r '.token // empty')"
[ -n "${REG_TOKEN}" ] || abort 'could not create a registration token'

# The managed host, with the agent the old install's registration command ran.
docker run -d --privileged --name "${AGENT_HOST}" --network "${NET}" -v "${WORK}:${WORK}" \
  -e DOCKER_TLS_CERTDIR= docker:27-dind >/dev/null
for _ in $(seq 1 60); do onhost 'docker info' >/dev/null 2>&1 && break; sleep 1; done
onhost 'docker info' >/dev/null 2>&1 || abort 'the agent host did not start'
onhost 'apk add --no-cache bash curl jq' >/dev/null || abort 'could not install tools on the agent host'
if [ -n "${REGISTRY_PORT}" ]; then
  # The agent host pulls the release's agent from localhost:PORT as well.
  docker network connect "${NET}" "${REGISTRY}"
  docker run -d --name "${REGISTRY_PROXY}" --network "container:${AGENT_HOST}" alpine/socat \
    "TCP-LISTEN:${REGISTRY_PORT},fork,reuseaddr" "TCP:${REGISTRY}:5000" >/dev/null
fi
onhost "docker run -d --name kubedok-agent --restart unless-stopped --privileged --network host \
  -v /var/run/docker.sock:/var/run/docker.sock -v kubedok-agent-state:/var/lib/kubedok-agent \
  -e KUBEDOK_API_URL=http://${API_HOST} -e KUBEDOK_REGISTRATION_TOKEN=${REG_TOKEN} ${OLD_AGENT_IMAGE}" >/dev/null \
  || abort 'could not start the old agent'
wait_for /hosts 'items | map(.status) | join(",")' online 120 \
  || abort 'the old agent did not come online'
HOST_ID="$(api GET /hosts | items | jq -r '.[0].id')"
info "host ${HOST_ID} online"

STACK_ID="$(api POST /stacks "{\"environmentId\":\"${ENV_ID}\",\"name\":\"shop\"}" | jq -r '.id // empty')"
[ -n "${STACK_ID}" ] || abort 'could not create a stack'
# Creates a service without deploying it; prints its id.
create_service() {
  local resp id
  resp="$(api POST "/stacks/${STACK_ID}/services" "$1")"
  id="$(printf '%s' "${resp}" | jq -r '.service.id // .id // empty' 2>/dev/null || true)"
  [ -n "${id}" ] || abort "could not create a service: ${resp}"
  printf '%s' "${id}"
}
# Save & Deploy. A host that has only just registered is refused until its
# overlay is set up, a moment later, and a stack takes one deployment at a time.
# 0.0.11 can also lose an agent's answer, and the request then waits a minute
# and gives up without a word.
deploy_service() {
  local resp deadline
  deadline=$(( $(date +%s) + 300 ))
  while true; do
    resp="$(api PATCH "/stacks/${STACK_ID}/services/$1?deploy=true" '{"description":"deployed by the test"}' 2>/dev/null || true)"
    case "${resp}" in
      ''|*"Overlay is not ready"*|*"already has a deployment in progress"*|*"timed out"*)
        [ "$(date +%s)" -lt "${deadline}" ] || abort "could not deploy $1: ${resp:-no answer}" ;;
      *'"statusCode":4'*|*'"statusCode":5'*) abort "could not deploy $1: ${resp}" ;;
      *) return 0 ;;
    esac
    sleep 2
  done
}
# Deploys a service on the old install and waits for it to run, deploying it
# again when an answer lost on the way leaves it waiting.
deploy_running() {
  local attempt deadline lost status=""
  for attempt in 1 2 3; do
    deploy_service "$1"
    deadline=$(( $(date +%s) + ${2:-240} ))
    lost=$(( $(date +%s) + 90 ))   # still not deployed by then: the deploy was lost
    while true; do
      status="$(service_status "$1" 2>/dev/null || true)"
      [ "${status}" = "running" ] && return 0
      if [ "$(date +%s)" -ge "${deadline}" ] \
         || { [ "${status}" = "not_deployed" ] && [ "$(date +%s)" -ge "${lost}" ]; }; then
        break
      fi
      sleep 3
    done
    info "attempt ${attempt} did not get $1 running (${status:-no status})"
  done
  return 1
}
WEB_ID="$(create_service '{"name":"web","image":"nginx:1.27-alpine","replicas":1,
  "ports":[{"containerPort":80,"hostPort":8080,"protocol":"tcp"}]}')"
deploy_running "${WEB_ID}" || abort 'the web service did not start on the old agent'

# MongoDB on a named volume, and two services that reach it by its name, set up
# as 0.0.x had them: api on glibc (the mongo image's own shell), worker on musl
# (node on Alpine). Each logs "ok" every 3 seconds while it gets through.
MONGO_ID="$(create_service "$(jq -nc --arg image "${MONGO_IMAGE}" '{name: "mongo", image: $image,
  volumes: [{source: "shop-mongo-data", target: "/data/db", readOnly: false}]}')")"
deploy_running "${MONGO_ID}" 300 || abort 'mongo did not start on the old agent'
API_ID="$(create_service "$(jq -nc --arg image "${MONGO_IMAGE}" '{name: "api", image: $image,
  dependsOn: ["mongo"], env: {MONGO_URL: "mongodb://mongo:27017/shop"}, entrypoint: ["bash", "-c"],
  command: ["while true; do if mongosh --quiet \"$MONGO_URL\" --eval \"db.pings.insertOne({at: new Date()})\" >/dev/null 2>&1; then echo ok; else echo fail; fi; sleep 3; done"]}')")"
WORKER_ID="$(create_service "$(jq -nc '{name: "worker", image: "node:22-alpine", dependsOn: ["mongo"],
  entrypoint: ["node", "-e"],
  command: ["setInterval(() => { const s = require(\"net\").connect(27017, \"mongo\"); s.setTimeout(3000); s.on(\"connect\", () => { console.log(\"ok\"); s.destroy(); }); s.on(\"error\", (e) => console.log(\"fail \" + e.code)); s.on(\"timeout\", () => { console.log(\"fail timeout\"); s.destroy(); }); }, 3000);"]}')")"
deploy_running "${API_ID}" || abort 'api did not start on the old agent'
deploy_running "${WORKER_ID}" 300 || abort 'worker did not start on the old agent'
consumer_ok api 120 || abort 'api does not reach mongo on the old install'
consumer_ok worker 120 || abort 'worker does not reach mongo on the old install'
[ "$(mongo_eval 'db.markers.insertOne({_id: "before-migration"}).acknowledged')" = "true" ] \
  || abort 'could not write to mongo'
pass 'the old agent runs mongo on a named volume, and api and worker reach it by name'
EDGE_ID="$(create_service "{\"name\":\"edge\",\"serviceType\":\"load_balancer\",\"image\":\"nginx:alpine\",
  \"ports\":[{\"containerPort\":443,\"hostPort\":8443,\"protocol\":\"tcp\"}],\"certificateId\":\"${CERT_ID}\",
  \"routingRules\":[{\"protocol\":\"https\",\"host\":\"app.kdtest.test\",\"listenPort\":443,\"pathPrefix\":\"/\",
  \"targetServiceId\":\"${WEB_ID}\",\"targetServiceName\":\"web\",\"targetPort\":80}]}")"
# Not deployed here: a 0.0.11 agent in a container cannot start a load balancer,
# because it bind-mounts the nginx config from a path inside its own container.
# The new agent deploys it for the first time, after the move.
pass 'the old agent runs web; an HTTPS load balancer with a certificate is set up'

# 0.0.11 could record a command's result and then write SENT over it, leaving a
# finished command looking unfinished. Databases it ran for a while have them;
# this one gets one for certain.
docker exec "${OLD}" psql -X -q -U kubedok -d kubedok -c "UPDATE agent_commands SET status = 'SENT'
  WHERE id = (SELECT id FROM agent_commands WHERE status::text = 'SUCCEEDED' AND type = 'overlay.configure'
              ORDER BY \"issuedAt\" LIMIT 1)" >/dev/null

# ── The runner ───────────────────────────────────────────────────────────────
step 'Starting the Linux runner'
docker network create kubedok-postgres >/dev/null 2>&1 || true
docker network create kubedok-proxy >/dev/null 2>&1 || true
docker run -d --name "${RUNNER}" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${WORK}:${WORK}" \
  -e "KUBEDOK_ROOT=${INSTALL_ROOT}" \
  -e "KUBEDOK_RELEASE_BASE_URL=file://${SERVE_DIR}" \
  -e "KUBEDOK_LOCAL_BASE_URL=http://kubedok-nginx" \
  -e 'KUBEDOK_HTTPS_BIND=127.0.0.1' \
  -e "KUBEDOK_HTTPS_PORT=$((HTTP_PORT + 1))" \
  -e 'KUBEDOK_SKIP_DEPS=true' \
  -e 'NO_COLOR=1' \
  debian:bookworm-slim sleep infinity >/dev/null
inrun "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  --no-install-recommends ca-certificates curl openssl jq util-linux iproute2 docker.io > /tmp/apt.log 2>&1" \
  || abort 'could not install tools in the runner'
inrun 'set -e
  arch="$(uname -m)"
  mkdir -p /usr/libexec/docker/cli-plugins
  curl -fsSL "https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-linux-${arch}" \
    -o /usr/libexec/docker/cli-plugins/docker-compose
  chmod +x /usr/libexec/docker/cli-plugins/docker-compose' || abort 'could not install Docker Compose in the runner'
docker network connect kubedok-proxy "${RUNNER}" >/dev/null 2>&1 || true
info 'runner ready'

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 1 — --check reports and changes nothing'
set +e
out="$(inrun "cd ${CLONE} && ./migrate-from-monolith.sh --container ${OLD} --check 2>&1")"; status=$?
set -e
assert_eq 0 "${status}" '--check exits 0'
assert_contains "${out}" "Ready to migrate" 'it says the install is ready'
assert_contains "${out}" "whose result was written over" 'it closes the finished command 0.0.11 left looking unfinished, rather than wait for it'
assert_contains "${out}" "Encryption key from the running API" 'it reads the key the API runs with'
assert_contains "${out}" "opens every stored credential (2 values)" 'the key opens the registry password and the certificate'
assert_contains "${out}" "1 load balancer(s) with a certificate" 'it finds the load balancer to convert'
assert_contains "${out}" "shop: api, worker, then mongo" 'it says to redeploy mongo'"'"'s users before mongo'
if [ "${OLD_STYLE}" = docs ]; then
  assert_contains "${out}" "was started with --rm and keeps its data on an anonymous volume" \
    'it warns that the data goes with the container'
  assert_contains "${out}" "docker create --name ${KEEPER} -v ${OLD_DATA_VOLUME}:/var/lib/postgresql/data" \
    'and says how to keep it until the migration, mounting it by name'
  assert_contains "${out}" "leaves the name free when it stops" 'it sees the old container has the new server'"'"'s name'
else
  assert_contains "${out}" "the migration renames it ${OLD_ASIDE} when it stops it" 'it says the old container moves aside'
fi
assert_eq true "$(docker container inspect -f '{{.State.Running}}' "${OLD}")" 'the old install still runs'

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 2 — --dry-run rehearses on a copy and changes nothing'
set +e
out="$(inrun "cd ${CLONE} && ./migrate-from-monolith.sh --container ${OLD} --dry-run 2>&1")"; status=$?
set -e
assert_eq 0 "${status}" '--dry-run exits 0'
assert_contains "${out}" "Rehearsal passed" 'the rehearsal passes'
assert_contains "${out}" "History matches 1.4.8's first 2 of 39 migrations" 'the history is 0.0.11'"'"'s'
assert_contains "${out}" "Applied the 37 migrations the old database was missing" 'the 37 missing migrations apply'
assert_contains "${out}" "Schema identical to a fresh ${STABLE} database" "the result matches a fresh ${STABLE}"
[ "${status}" -eq 0 ] || printf '%s\n' "${out}" | tail -30 | sed 's/^/      /'
assert_eq true "$(docker container inspect -f '{{.State.Running}}' "${OLD}")" 'the old install still runs'
assert_fails 'no scratch database is left' docker container inspect kubedok-migrate-pg
assert_fails 'no scratch network is left' docker network inspect kubedok-migrate
assert_fails 'no install was made' inrun "test -e ${INSTALL_ROOT}"

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 3 — a migration that fails after the stop puts the old install back'
set +e
out="$(inrun "cd ${CLONE} && KUBEDOK_RELEASE=9.9.9 ./migrate-from-monolith.sh --container ${OLD} --yes 2>&1")"; status=$?
set -e
[ "${status}" -ne 0 ] && pass 'the migration fails' || fails 'the migration with a broken nginx succeeded'
assert_contains "${out}" "Going back to ${OLD}" 'it says it goes back'
assert_contains "${out}" "${OLD} is running again" 'it says the old install runs again'
# The data volume a container keeps at /var/lib/postgresql/data.
data_volume_of() {
  docker container inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' "$1" 2>/dev/null || true
}
assert_eq true "$(docker container inspect -f '{{.State.Running}}' "${OLD}")" 'the old install runs'
wait_healthy "${OLD}" 240 && pass 'and is healthy' || fails 'the old install is not healthy'
assert_eq "$(docker image inspect -f '{{.Id}}' "${OLD_IMAGE}")" "$(docker container inspect -f '{{.Image}}' "${OLD}")" \
  "${OLD} is the old install again, not the new server"
assert_eq "${OLD_DATA_VOLUME}" "$(data_volume_of "${OLD}")" 'on its own data'
assert_eq unless-stopped "$(docker container inspect -f '{{.HostConfig.RestartPolicy.Name}}' "${OLD}")" 'and restarts by itself'
if [ "${OLD_STYLE}" = docs ]; then
  assert_eq false "$(docker container inspect -f '{{.HostConfig.AutoRemove}}' "${OLD}")" 'started again without --rm'
  assert_fails "the ${KEEPER} the migration made is gone again" docker container inspect "${KEEPER}"
else
  assert_fails "${OLD_ASIDE} is gone: the old container has its name back" docker container inspect "${OLD_ASIDE}"
fi
for c in kubedok-nginx kubedok-postgres kubedok-migrate-pg kubedok-migrate-source; do
  assert_fails "no ${c} container is left" docker container inspect "${c}"
done
assert_fails 'no database volume is left' docker volume inspect kubedok_postgres_data
assert_fails "${INSTALL_ROOT} is gone" inrun "test -e ${INSTALL_ROOT}"
assert_ok 'the unfinished install was moved aside' inrun "ls -d ${INSTALL_ROOT}.failed-*"
inrun "rm -rf ${INSTALL_ROOT}.failed-*"
TOKEN="$(login)"
[ -n "${TOKEN}" ] && pass 'the old install signs in' || fails 'the old install no longer signs in'
wait_for /hosts 'items | map(.status) | join(",")' online 120 \
  && pass 'the old agent is connected to it again' || fails 'the old agent did not reconnect'

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 4 — the migration'
if [ "${OLD_STYLE}" = docs ]; then
  # Going back started it without --rm; a first migration meets a --rm one,
  # so it is made that again, on the same data.
  docker stop "${OLD}" >/dev/null && docker rm "${OLD}" >/dev/null
  docker run -d --rm --name "${OLD}" --network "${NET}" --network-alias "${API_HOST}" \
    -p "127.0.0.1:${HTTP_PORT}:80" -v "${OLD_DATA_VOLUME}:/var/lib/postgresql/data" "${OLD_IMAGE}" >/dev/null
  wait_healthy "${OLD}" 240 || abort 'the old install did not come back as a --rm container'
  wait_for /hosts 'items | map(.status) | join(",")' online 120 || abort 'the old agent did not reconnect'
fi
OLD_ID_BEFORE="$(docker container inspect -f '{{.Id}}' "${OLD}")"
OLD_JWT="$(docker exec "${OLD}" cat /var/lib/postgresql/data/.kubedok-secrets/jwt-secret)"
OLD_KEY="$(docker exec "${OLD}" cat /var/lib/postgresql/data/.kubedok-secrets/registry-encryption-key)"
set +e
out="$(inrun "cd ${CLONE} && ./migrate-from-monolith.sh --container ${OLD} --yes 2>&1")"; status=$?
set -e
assert_eq 0 "${status}" 'the migration succeeds'
[ "${status}" -eq 0 ] || printf '%s\n' "${out}" | tail -40 | sed 's/^/      /'
assert_contains "${out}" "Migrated ${OLD} to Kubedok ${STABLE}" 'it says it migrated'
assert_contains "${out}" "shop: api, worker, then mongo" 'its next steps give the order to redeploy in'
if [ "${OLD_STYLE}" = docs ]; then
  assert_fails 'the old container is gone, as --rm has it' docker container inspect "${OLD_ID_BEFORE}"
  assert_eq "${OLD_DATA_VOLUME}" "$(data_volume_of "${KEEPER}")" "its data is kept, held by ${KEEPER}"
  assert_contains "${out}" "docker run -d --name ${OLD} --restart unless-stopped" 'its next steps say how to start it again'
  assert_ok 'with its environment kept beside the backups' inrun "ls ${INSTALL_ROOT}/backups/monolith-*.env"
else
  assert_eq false "$(docker container inspect -f '{{.State.Running}}' "${OLD_ASIDE}")" "the old container is stopped, as ${OLD_ASIDE}"
  assert_eq no "$(docker container inspect -f '{{.HostConfig.RestartPolicy.Name}}' "${OLD_ASIDE}")" 'and will not start again by itself'
  assert_eq "${OLD_DATA_VOLUME}" "$(data_volume_of "${OLD_ASIDE}")" 'on its own data, untouched'
  assert_contains "${out}" "docker rename ${OLD_ASIDE} ${OLD}" 'its next steps say how to go back'
fi
for c in kubedok-postgres kubedok-server kubedok-nginx; do
  wait_healthy "${c}" 120 && pass "${c} is healthy" || fails "${c} is not healthy"
done
assert_contains "$(docker port kubedok-nginx)" "127.0.0.1:${HTTP_PORT}" 'nginx listens where the old install did'
assert_eq "${STABLE}" "$(curl -fsS "${BASE}/version" | jq -r .release)" "the API reports ${STABLE}"

TOKEN="$(login)"
[ -n "${TOKEN}" ] && pass 'the old password signs in' || fails 'the old password does not sign in'
assert_eq true "$(api GET /auth/me | jq -r '.role.isSuperAdmin // .user.role.isSuperAdmin')" 'the old admin is Super Admin'
assert_eq "${HOST_ID}" "$(api GET /hosts | items | jq -r 'map(.id) | join(",")')" 'the one host is the same host'
assert_eq "${EDGE_ID}" "$(api GET /certificates | items | jq -r '.[0].usedBy[0].serviceId // empty')" \
  'the certificate is used by the load balancer'
assert_eq '["'"${CERT_ID}"'"]' "$(docker exec kubedok-postgres psql -tA -U kubedok -d kubedok -c \
  "SELECT \"configJson\"->'certificateIds' FROM stack_services WHERE id = '${EDGE_ID}'" | tr -d ' ')" \
  'the load balancer keeps its certificate as certificateIds'
assert_eq f "$(docker exec kubedok-postgres psql -tA -U kubedok -d kubedok -c 'SELECT bool_or("autoCleanup") FROM hosts')" \
  'host clean-up is off'
assert_eq "${OLD_KEY}" "$(inrun "cat ${INSTALL_ROOT}/secrets/registry-encryption-key")" 'the encryption key carried over'
[ "${OLD_JWT}" != "$(inrun "cat ${INSTALL_ROOT}/secrets/jwt-secret")" ] && pass 'the JWT secret is new' || fails 'the JWT secret was kept'
ENC="$(docker exec kubedok-postgres psql -tA -U kubedok -d kubedok -c "SELECT \"passwordEnc\" FROM container_registries WHERE id = '${REGISTRY_ID}'")"
assert_eq "${REGISTRY_PASSWORD}" "$(printf '%s' "${ENC}" | docker exec -i kubedok-server node -e '
  const { RegistryCryptoService } = require("/app/apps/api/dist/registries/registry-crypto.service.js");
  const key = require("fs").readFileSync("/run/secrets/registry-encryption-key", "utf8").trim();
  const svc = new RegistryCryptoService({ get: () => key });
  process.stdout.write(svc.decrypt(require("fs").readFileSync(0, "utf8").trim()));')" \
  'the server decrypts the registry password'
assert_ok 'the first backup is the migrated data' inrun "ls ${INSTALL_ROOT}/backups/kubedok-*-migrated.tar.gz"
assert_ok 'the old database is kept as it was' inrun "ls ${INSTALL_ROOT}/backups/monolith-*.sql.gz"

pg() { docker exec kubedok-postgres psql -X -tA -U kubedok -d kubedok -c "$1"; }
MIGRATED_AT="$(pg 'SELECT now()')"
assert_eq 0 "$(pg "SELECT count(*) FROM agent_commands WHERE status::text IN ('PENDING','SENT') AND \"completedAt\" IS NOT NULL")" \
  'no finished command reads as unfinished'

# The agents' address now reaches the new install.
docker network connect --alias "${API_HOST}" "${NET}" kubedok-nginx
wait_for /hosts 'items | map(.status) | join(",")' online 120 \
  && pass 'the old agent reconnects to the new install' || fails 'the old agent did not reconnect'
assert_eq running "$(service_status "${WEB_ID}")" 'web still runs'
consumer_ok api 60 && pass 'api still reaches mongo' || fails 'api lost mongo'
consumer_ok worker 60 && pass 'worker still reaches mongo' || fails 'worker lost mongo'

# The new server's overlay sweep sends a connected host its overlay where it
# differs from what the host applied last, which for the old agent is the
# overlay as 0.0.11 built it. The old agent has to take it, and then be left
# alone: one that failed would be sent it again every few minutes.
configures() {
  pg "SELECT count(*) FILTER (WHERE status::text = 'SUCCEEDED') || ' of ' || count(*)
        FROM agent_commands WHERE type = 'overlay.configure' AND \"issuedAt\" > '${MIGRATED_AT}'"
}
sleep 75
sent="$(configures)"
info "overlay.configure sent to the old agent since the move: ${sent#* of } (${sent% of *} succeeded)"
[ "${sent% of *}" = "${sent#* of }" ] && pass 'the old agent took every overlay it was sent' \
  || fails "not every overlay sent to the old agent succeeded: ${sent}"
sleep 65
assert_eq "${sent}" "$(configures)" 'and is sent nothing more'
consumer_ok worker 30 && pass 'worker still reaches mongo' || fails 'worker lost mongo once the old agent took the overlay'

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 5 — --adopt moves the agent, as the same host'
AGENT_VERSION="$(jq -r .agentVersion "${MANIFEST}")"
# Data where a redeploy leaves it behind: api runs the mongo image, which
# declares /data/db a volume and makes it home, so it got an anonymous one.
onhost 'docker exec shop-api sh -c "head -c 2500000 /dev/urandom > /data/db/kept-by-api"'
set +e
out="$(onhost "cd ${CLONE} && KUBEDOK_RELEASE_BASE_URL=file://${SERVE_DIR} NO_COLOR=1 bash scripts/agent-install.sh --adopt 2>&1")"; status=$?
set -e
assert_eq 0 "${status}" '--adopt succeeds'
[ "${status}" -eq 0 ] || printf '%s\n' "${out}" | tail -30 | sed 's/^/      /'
assert_contains "${out}" "runs as host ${HOST_ID}" 'it reports the same host'
assert_contains "${out}" "shop-api keeps 2 MB in /data/db on an anonymous volume" \
  'it warns about data a redeploy would leave behind'
case "${out}" in
  *'shop-mongo keeps'*) fails 'it warns about mongo, whose data is on a named volume' ;;
  *) pass 'and not about mongo, whose data is on a named volume' ;;
esac
assert_eq "${AGENT_IMAGE}" \
  "$(onhost "docker container inspect -f '{{.Config.Image}}' kubedok-agent")" 'the new agent runs the release'"'"'s image'
assert_eq false "$(onhost "docker container inspect -f '{{.State.Running}}' kubedok-agent-pre-adopt")" 'the old agent is kept, stopped'
wait_for /hosts 'items | map(.agentVersion + " " + .status) | join(",")' \
  "${AGENT_VERSION} online" 120 && pass "the host is online on agent ${AGENT_VERSION}" || fails 'the host is not online on the new agent'
assert_eq "${HOST_ID}" "$(api GET /hosts | items | jq -r 'map(.id) | join(",")')" 'still one host, the same one'
consumer_ok api 60 && pass 'api still reaches mongo' || fails 'api lost mongo when the agent moved'
consumer_ok worker 60 && pass 'worker still reaches mongo' || fails 'worker lost mongo when the agent moved'

# The new agent starts with no overlay applied, and says so: the server sends it
# the overlay, and with it the DNS records its forwarder serves, with no deploy.
MONGO_IP="$(pg "SELECT \"overlayIp\" FROM service_dns_records WHERE \"serviceId\" = '${MONGO_ID}'")"
dns_answer() {
  onhost "docker exec shop-worker node -e 'require(\"dns\").lookup(\"mongo.shop.kubedok.local\", (e, a) => console.log(e ? e.code : a))'" 2>/dev/null || true
}
deadline=$(( $(date +%s) + 90 ))
until [ "$(dns_answer)" = "${MONGO_IP}" ] || [ "$(date +%s)" -ge "${deadline}" ]; do sleep 3; done
assert_eq "${MONGO_IP}" "$(dns_answer)" "the new agent's DNS forwarder answers for mongo, with no deploy"

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 6 — deploys work through the adopted agent'
# The container of a service on the host, by the label the agent gives it.
running_container() { onhost "docker ps -q --filter label=kubedok.service.name=$1" | head -n1; }
# Redeploys a service and waits for a new running container to replace NAME's.
redeploy() {
  local id="$1" name="$2" before after="" deadline resp
  before="$(running_container "${name}")"
  deadline=$(( $(date +%s) + 240 ))
  # Refused while the stack's previous deployment finishes.
  while resp="$(api POST "/stacks/${STACK_ID}/services/${id}/redeploy" '{}')"; [[ "${resp}" == *'"statusCode":409'* ]]; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      info "${name}: ${resp}"
      return 1
    fi
    sleep 3
  done
  # Done once the new container runs under the service's own name, which the
  # agent gives it last.
  deadline=$(( $(date +%s) + 240 ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    after="$(running_container "${name}")"
    if [ -n "${after}" ] && [ "${after}" != "${before}" ] && [ "$(service_status "${id}")" = "running" ] \
       && [ "$(onhost "docker container inspect -f '{{.Id}}' shop-${name}" 2>/dev/null | cut -c1-12)" = "${after}" ]; then
      return 0
    fi
    sleep 3
  done
  info "${name}: before ${before:-none}, after ${after:-none}, status $(service_status "${id}")"
  api GET "/stacks/${STACK_ID}/services/${id}" | head -c 2000; printf '\n'
  return 1
}
# Every service once, in the order the migration prints: the ones that connect
# to others first, then the ones they connect to. A new container finds mongo
# through the agent's DNS forwarder; one 0.0.11 started found it through a
# Docker network alias, which a new mongo container no longer has.
redeploy "${WORKER_ID}" worker && pass 'worker redeploys' || fails 'worker did not redeploy'
consumer_ok worker 90 && pass 'the new worker (musl) reaches the old mongo by name' || fails 'the new worker cannot reach mongo'
redeploy "${API_ID}" api && pass 'api redeploys' || fails 'api did not redeploy'
consumer_ok api 90 && pass 'the new api (glibc) reaches the old mongo by name' || fails 'the new api cannot reach mongo'
redeploy "${MONGO_ID}" mongo && pass 'mongo redeploys' || fails 'mongo did not redeploy'
assert_eq 1 "$(mongo_eval 'db.markers.countDocuments({_id: "before-migration"})')" 'mongo kept its data'
assert_contains "$(onhost "docker container inspect -f '{{range .Mounts}}{{.Name}} {{end}}' shop-mongo")" \
  shop-mongo-data 'on the same named volume'
consumer_ok api 90 && pass 'api reaches the new mongo' || fails 'api cannot reach the new mongo'
consumer_ok worker 90 && pass 'worker reaches the new mongo' || fails 'worker cannot reach the new mongo'
redeploy "${WEB_ID}" web && pass 'web redeploys, onto the host port its old container held' || fails 'web did not redeploy'
deploy_service "${EDGE_ID}"
wait_service_running "${EDGE_ID}" 240 && pass 'the HTTPS load balancer deploys with its carried-over certificate' \
  || fails 'the load balancer did not deploy'
assert_contains "$(onhost "docker exec \$(docker ps -q --filter label=kubedok.service.name=edge | head -n1) nginx -T 2>&1")" \
  'ssl_certificate' 'its nginx serves the certificate'

printf '\n%s passed, %s failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
