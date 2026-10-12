#!/usr/bin/env bash
#
# End-to-end test for agent-update.sh.
#
#   tests/agent-update.sh
#
# Starts a stand-in agent the way the docker run command from Register host in
# the Kubedok UI starts the real one, then updates it with agent-update.sh. The
# update must take the agent over without losing its volumes or settings, put
# the original back as it was when the new agent fails, refuse what it cannot
# carry over before changing anything, and leave an agent that later updates
# treat like one agent-install.sh set up.
#
# The stand-in only waits. It is built as agent 1.0.0, 1.0.1, and a 1.0.2 that
# exits at once, and pushed to a throwaway registry so the manifests name
# genuine digests; the manifests are served over file://. The scripts need
# root and Linux, so they run in a Debian container driving this Docker
# daemon, with the Docker CLI and Compose copied out of KUBEDOK_TEST_CLI_IMAGE.
#
# The scripts name the agent's container kubedok-agent, so the test stops
# before doing anything if this daemon runs one it did not start.
set -Eeuo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK="${KUBEDOK_TEST_WORK:-/private/tmp/kubedok-agent-update}"
SERVE_DIR="${WORK}/serve"
# A clone of this repository, and a copy of its scripts alone, which has to
# download the compose file.
CLONE="${WORK}/clone"
SCRIPTS_ONLY="${WORK}/scripts-only"
AGENT_ROOT="${WORK}/opt-kubedok-agent"

REG_NAME="kubedok-agent-test-registry"
REG_PORT="${KUBEDOK_TEST_REGISTRY_PORT:-5051}"
REGISTRY="localhost:${REG_PORT}"
RUNNER="kubedok-agent-test-runner"
CLI_IMAGE="${KUBEDOK_TEST_CLI_IMAGE:-docker:27-cli}"
BASE_IMAGE="${KUBEDOK_TEST_BASE_IMAGE:-alpine:3.20}"
# On every image the test builds, so on every container made from one: the
# clean-up removes those and nothing else.
TEST_LABEL="kubedok-test=agent-update"
STATE_VOL="kubedok-agent-test-state"
WG_VOL="kubedok-agent-test-wg"
EXTRA_VOL="kubedok-agent-test-extra"
TOKEN="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

PASS=0
FAIL=0
OUT=""
RC=0

c_green=$'\033[32m'; c_red=$'\033[31m'; c_blue=$'\033[34m'; c_dim=$'\033[2m'; c_off=$'\033[0m'

step()  { printf '\n%s▸ %s%s\n' "${c_blue}" "$*" "${c_off}"; }
pass()  { printf '  %s✓%s %s\n' "${c_green}" "${c_off}" "$*"; PASS=$((PASS+1)); }
fails() { printf '  %s✗%s %s\n' "${c_red}" "${c_off}" "$*"; FAIL=$((FAIL+1)); }
info()  { printf '  %s%s%s\n' "${c_dim}" "$*" "${c_off}"; }
abort() { printf '\n%sABORT:%s %s\n\n' "${c_red}" "${c_off}" "$*"; exit 1; }

# Run a command inside the Linux runner container.
inrun() { docker exec -i "${RUNNER}" bash -lc "$*"; }

# Runs a script in the runner, leaving its output in OUT and its status in RC.
# KUBEDOK_TEST_VERBOSE=true prints the output too.
run() {
  set +e
  OUT="$(inrun "$*" 2>&1)"
  RC=$?
  set -e
  if [ "${KUBEDOK_TEST_VERBOSE:-false}" = true ]; then
    printf '%s\n' "${OUT}" | sed "s/^/      ${c_dim}│${c_off} /"
  fi
}

assert_eq() {
  local expected="$1" actual="$2" what="$3"
  if [ "${expected}" = "${actual}" ]; then
    pass "${what}"
  else
    fails "${what} — expected '${expected}', got '${actual}'"
  fi
}

# The last run's output holds a text.
assert_said() {
  if grep -qF -- "$1" <<<"${OUT}"; then
    pass "$2"
  else
    fails "$2 — the output lacks '$1'"
    printf '%s\n' "${OUT}" | tail -15 | sed 's/^/      /'
  fi
}

assert_succeeded() {
  if [ "${RC}" -eq 0 ]; then
    pass "$1"
  else
    fails "$1 — exit status ${RC}"
    printf '%s\n' "${OUT}" | tail -15 | sed 's/^/      /'
  fi
}

assert_failed() {
  if [ "${RC}" -ne 0 ]; then pass "$1"; else fails "$1 — it succeeded"; fi
}

agent_id()     { docker container inspect -f '{{.Id}}' kubedok-agent 2>/dev/null || true; }
agent_field()  { docker container inspect -f "$1" kubedok-agent 2>/dev/null || true; }
container_env() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null | sed -n "s/^$2=//p"
}
mount_at() {
  docker container inspect kubedok-agent 2>/dev/null \
    | jq -r --arg d "$1" '.[0].Mounts[] | select(.Destination == $d) | .Name'
}
identity() { docker exec kubedok-agent cat /var/lib/kubedok-agent/agent-state.json 2>/dev/null || true; }
# agent.env has this line. Read whole first: grep -q stopping early would fail
# the pipe.
env_file_line() {
  local content
  content="$(inrun "cat ${AGENT_ROOT}/agent.env" 2>/dev/null)"
  grep -qxF -- "$1" <<<"${content}"
}
digest_of() {
  docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "${REGISTRY}/kubedok-agent:$1" \
    | grep "^${REGISTRY}/kubedok-agent@" | head -1
}

# The agent as the Kubedok UI's command starts it, on test volumes.
start_ui_agent() {
  docker run -d --name kubedok-agent --restart unless-stopped --privileged --network host \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${STATE_VOL}:/var/lib/kubedok-agent" \
    -v "${WG_VOL}:/etc/wireguard" \
    -e KUBEDOK_API_URL=http://127.0.0.1:9 \
    -e "KUBEDOK_REGISTRATION_TOKEN=${TOKEN}" \
    "$@" "${REGISTRY}/kubedok-agent:1.0.0" >/dev/null
}

# ── Teardown ─────────────────────────────────────────────────────────────────
cleanup() {
  step 'Cleaning up'
  docker ps -aq --filter "label=${TEST_LABEL}" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker rm -f "${RUNNER}" "${REG_NAME}" >/dev/null 2>&1 || true
  docker volume rm "${STATE_VOL}" "${WG_VOL}" "${EXTRA_VOL}" >/dev/null 2>&1 || true
  docker images -q --filter "label=${TEST_LABEL}" | sort -u | xargs -r docker image rm -f >/dev/null 2>&1 || true
  rm -rf "${WORK}" 2>/dev/null || true
  info 'done'
}

# ── Preflight ────────────────────────────────────────────────────────────────
step 'Preflight'
command -v docker >/dev/null || abort 'docker is required'
command -v jq >/dev/null || abort 'jq is required'
docker info >/dev/null 2>&1 || abort 'the Docker daemon is not reachable'
for name in kubedok-agent kubedok-agent-replaced; do
  labels="$(docker container inspect -f '{{json .Config.Labels}}' "${name}" 2>/dev/null)" || continue
  [ "$(jq -r '.["kubedok-test"] // empty' <<<"${labels}")" = agent-update ] \
    || abort "this Docker daemon runs a ${name} container the test did not start. Run the test where no agent runs."
done
trap cleanup EXIT
cleanup >/dev/null 2>&1 || true

mkdir -p "${SERVE_DIR}/releases" "${SERVE_DIR}/channels" "${SERVE_DIR}/compose" \
         "${CLONE}" "${SCRIPTS_ONLY}" "${WORK}/bin"
cp -R "${DEPLOY_DIR}/scripts" "${DEPLOY_DIR}/compose" "${CLONE}/"
cp -R "${DEPLOY_DIR}/scripts" "${SCRIPTS_ONLY}/"
cp "${DEPLOY_DIR}/compose/agent.yml" "${SERVE_DIR}/compose/"
info "workspace ${WORK}"

# ── The stand-in agent, three times ──────────────────────────────────────────
step 'Publishing the stand-in agent to a throwaway registry'

docker run -d --name "${REG_NAME}" -p "127.0.0.1:${REG_PORT}:5000" registry:2 >/dev/null
for _ in $(seq 1 30); do
  curl -fsS "http://127.0.0.1:${REG_PORT}/v2/" -o /dev/null 2>/dev/null && break
  sleep 1
done
curl -fsS "http://127.0.0.1:${REG_PORT}/v2/" -o /dev/null || abort 'the test registry did not come up'

# Its image sets what the real one does, so that the settings a takeover
# carries over are told apart from the image's own.
build_agent() {
  local version="$1" cmd="$2"
  if ! docker build -q -t "${REGISTRY}/kubedok-agent:${version}" - >/dev/null <<EOF
FROM ${BASE_IMAGE}
LABEL ${TEST_LABEL} org.opencontainers.image.version=${version}
ENV KUBEDOK_STATE_FILE=/var/lib/kubedok-agent/agent-state.json \
    KUBEDOK_SYNC_INTERVAL_SECS=15 \
    RUST_LOG=kubedok_agent=info
VOLUME ["/var/lib/kubedok-agent", "/etc/wireguard"]
CMD ${cmd}
EOF
  then
    abort "could not build agent ${version}"
  fi
  docker push -q "${REGISTRY}/kubedok-agent:${version}" >/dev/null \
    || abort "could not push agent ${version}"
  [ -n "$(digest_of "${version}")" ] || abort "could not read agent ${version}'s digest"
}
build_agent 1.0.0 '["sh", "-c", "trap \"exit 0\" TERM; while :; do sleep 1; done"]'
build_agent 1.0.1 '["sh", "-c", "trap \"exit 0\" TERM; while :; do sleep 1; done"]'
build_agent 1.0.2 '["sh", "-c", "exit 3"]'

# Release X ships agent X. The other images are never started.
for v in 1.0.0 1.0.1 1.0.2; do
  jq -n --arg v "${v}" --arg agent "$(digest_of "${v}")" \
    '{schemaVersion:1, release:$v, publishedAt:"2026-01-01T00:00:00Z",
      images:{server:$agent, nginx:$agent, postgres:$agent, agent:$agent},
      builtFrom:{server:"0", nginx:"0", postgres:"0", agent:"0"}, agentVersion:$v,
      postgresMajor:16, minimumAgentVersion:"1.0.0", minimumUpgradeFrom:"1.0.0"}' \
    > "${SERVE_DIR}/releases/${v}.json"
done
jq -n '{schemaVersion:1, channel:"stable", release:"1.0.1",
        manifest:"releases/1.0.1.json", updatedAt:"2026-01-01T00:00:00Z"}' \
  > "${SERVE_DIR}/channels/stable.json"
info 'agents 1.0.0, 1.0.1 and 1.0.2 published; stable is 1.0.1'

# ── Linux runner ─────────────────────────────────────────────────────────────
step 'Starting the Linux runner'

docker run -d --name "${RUNNER}" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${WORK}:${WORK}" \
  -e "KUBEDOK_AGENT_ROOT=${AGENT_ROOT}" \
  -e "KUBEDOK_RELEASE_BASE_URL=file://${SERVE_DIR}" \
  -e 'NO_COLOR=1' \
  debian:bookworm-slim sleep infinity >/dev/null

inrun "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  --no-install-recommends ca-certificates curl jq > /tmp/apt.log 2>&1" \
  || { docker exec "${RUNNER}" tail -20 /tmp/apt.log 2>/dev/null | sed 's/^/      /'; abort 'could not install tools in the runner'; }

# Copied out of an image rather than installed: Debian's docker.io comes with
# no Compose v2, and the plugin would otherwise have to be downloaded.
cli="$(docker create "${CLI_IMAGE}")" || abort "could not create a container from ${CLI_IMAGE}"
docker cp "${cli}:/usr/local/bin/docker" "${WORK}/bin/docker" >/dev/null
docker cp "${cli}:/usr/local/libexec/docker/cli-plugins/docker-compose" "${WORK}/bin/docker-compose" >/dev/null
docker rm "${cli}" >/dev/null
inrun "install -m 755 ${WORK}/bin/docker /usr/local/bin/docker \
  && install -D -m 755 ${WORK}/bin/docker-compose /usr/local/libexec/docker/cli-plugins/docker-compose" \
  || abort 'could not install the Docker CLI in the runner'
inrun 'docker compose version' >/dev/null || abort 'the runner has no Docker Compose'
info "runner ready ($(inrun 'docker compose version --short' 2>/dev/null | tr -d '\r'))"

UPDATE="${CLONE}/scripts/agent-update.sh"

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 1 — no agent on the host'

run "${UPDATE} --release 1.0.1"
assert_failed 'agent-update.sh fails'
assert_said 'No agent runs on this host' 'and says no agent runs here'

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 2 — what a takeover cannot carry over stops it before any change'

start_ui_agent -e TZ=UTC -v "${EXTRA_VOL}:/data"
before="$(agent_id)"
run "${UPDATE} --release 1.0.1"
assert_failed 'agent-update.sh fails'
assert_said 'It was started with TZ' 'it names the setting it cannot carry over'
assert_said 'It mounts /data as well' 'and the mount'
assert_eq "${before}" "$(agent_id)" 'the agent is the same container'
assert_eq 'true' "$(agent_field '{{.State.Running}}')" 'and still runs'
if inrun "test -e ${AGENT_ROOT}"; then fails "${AGENT_ROOT} was created"; else pass "${AGENT_ROOT} was not created"; fi
docker rm -f kubedok-agent >/dev/null

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 3 — an agent started by the Kubedok UI command'

# The UI's command plus settings a takeover has to carry over: a passed one
# agent-install.sh never writes, the log level under its own name, a value
# that needs quoting, and one equal to the image's default.
start_ui_agent \
  -e KUBEDOK_OVERLAY_PUBLIC_IP=203.0.113.7 \
  -e RUST_LOG=kubedok_agent=debug \
  -e 'KUBEDOK_HOST_ADDRESS=edge host (eu)' \
  -e KUBEDOK_SYNC_INTERVAL_SECS=15
docker exec kubedok-agent sh -c 'echo identity-1 > /var/lib/kubedok-agent/agent-state.json'
ORIGINAL="$(agent_id)"
info "the agent runs as ${ORIGINAL:0:12}"

run "${CLONE}/scripts/agent-install.sh --token ${TOKEN} --api-url http://127.0.0.1:9"
assert_failed 'agent-install.sh refuses to install a second agent'
assert_said 'An agent already runs on this host' 'and says one runs already'

run "${UPDATE} --release 1.0.0"
assert_succeeded 'agent-update.sh to the agent it runs succeeds'
assert_said 'Already on agent 1.0.0' 'and finds nothing to do, though the agent runs from a tag'

run "${UPDATE} --release 1.0.1 --check"
assert_succeeded 'agent-update.sh --check succeeds'
assert_said 'Installed agent   1.0.0' 'it reads the installed agent from the image'
assert_said 'An update is available' 'it finds the update'
assert_said "moves the agent under ${AGENT_ROOT}" 'and says the update takes the agent over'
assert_eq "${ORIGINAL}" "$(agent_id)" '--check leaves the agent alone'
if inrun "test -e ${AGENT_ROOT}"; then fails "--check created ${AGENT_ROOT}"; else pass "--check writes nothing"; fi

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 4 — a new agent that fails puts the original back'

# From the scripts alone: the compose file comes from the release URL.
run "${SCRIPTS_ONLY}/scripts/agent-update.sh --release 1.0.2"
assert_failed 'agent-update.sh to the broken agent fails'
assert_said 'Putting the original back' 'it puts the original back'
assert_said 'The original agent is back, unchanged' 'and says it is back'
assert_eq "${ORIGINAL}" "$(agent_id)" 'kubedok-agent is the original container'
assert_eq 'true' "$(agent_field '{{.State.Running}}')" 'and it runs'
assert_eq 'unless-stopped' "$(agent_field '{{.HostConfig.RestartPolicy.Name}}')" 'with its restart policy'
assert_eq 'identity-1' "$(identity)" 'and its identity'
assert_eq '' "$(docker ps -aq --filter name='^kubedok-agent-replaced$')" 'no replaced container is left'
assert_eq '' "$(docker ps -aq --filter label=com.docker.compose.project=kubedok-agent)" 'no Compose container is left'
if inrun "test -e ${AGENT_ROOT}"; then fails "${AGENT_ROOT} is left"; else pass "${AGENT_ROOT} is gone again"; fi

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 5 — the takeover'

# No --release, and no control plane to ask: the stable channel's agent.
run "${UPDATE}"
assert_succeeded 'agent-update.sh succeeds'
assert_said 'Agent updated to 1.0.1' 'and reports agent 1.0.1'
if grep -q 'not created by Docker Compose' <<<"${OUT}"; then
  fails 'Compose warns about the volumes it did not create'
else
  pass 'Compose takes the volumes as they are, without a warning'
fi
TAKEN_OVER="$(agent_id)"
if [ -n "${TAKEN_OVER}" ] && [ "${TAKEN_OVER}" != "${ORIGINAL}" ]; then
  pass 'kubedok-agent is a new container'
else
  fails "kubedok-agent is not a new container (${TAKEN_OVER:-none})"
fi
assert_eq "$(digest_of 1.0.1)" "$(agent_field '{{.Config.Image}}')" 'it runs agent 1.0.1 by digest'
assert_eq 'kubedok-agent' "$(agent_field '{{index .Config.Labels "com.docker.compose.project"}}')" \
  'from the kubedok-agent Compose project'
assert_eq 'unless-stopped' "$(agent_field '{{.HostConfig.RestartPolicy.Name}}')" 'restarting unless stopped'
assert_eq "${STATE_VOL}" "$(mount_at /var/lib/kubedok-agent)" 'on the state volume it was started with'
assert_eq "${WG_VOL}" "$(mount_at /etc/wireguard)" 'and the WireGuard volume'
assert_eq 'identity-1' "$(identity)" 'with its identity'
assert_eq '' "$(docker ps -aq --filter name='^kubedok-agent-replaced$')" 'the original container is gone'

assert_eq 'http://127.0.0.1:9' "$(container_env kubedok-agent KUBEDOK_API_URL)" 'the API URL is carried over'
assert_eq "${TOKEN}" "$(container_env kubedok-agent KUBEDOK_REGISTRATION_TOKEN)" 'the registration token too'
assert_eq '203.0.113.7' "$(container_env kubedok-agent KUBEDOK_OVERLAY_PUBLIC_IP)" 'the overlay public IP'
assert_eq 'kubedok_agent=debug' "$(container_env kubedok-agent RUST_LOG)" 'the log level'
assert_eq 'edge host (eu)' "$(container_env kubedok-agent KUBEDOK_HOST_ADDRESS)" 'a value that needed quoting'
assert_eq '' "$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' kubedok-agent | grep '^KUBEDOK_DNS_UPSTREAM=' || true)" \
  'a setting nobody set stays unset'

assert_eq '600' "$(inrun "stat -c %a ${AGENT_ROOT}/agent.env" | tr -d '\r')" 'agent.env is readable by root alone'
for line in "KUBEDOK_IMAGE_AGENT=$(digest_of 1.0.1)" 'KUBEDOK_AGENT_RELEASE=1.0.1' \
            "KUBEDOK_AGENT_STATE_VOLUME=${STATE_VOL}" "KUBEDOK_AGENT_WG_VOLUME=${WG_VOL}" \
            'KUBEDOK_AGENT_VOLUMES_EXTERNAL=true' 'KUBEDOK_AGENT_LOG=kubedok_agent=debug' \
            "KUBEDOK_HOST_ADDRESS='edge host (eu)'"; do
  if env_file_line "${line}"; then pass "agent.env holds ${line}"; else fails "agent.env lacks ${line}"; fi
done
if inrun "grep -q '^KUBEDOK_SYNC_INTERVAL_SECS=' ${AGENT_ROOT}/agent.env"; then
  fails "agent.env holds the image's own KUBEDOK_SYNC_INTERVAL_SECS"
else
  pass "agent.env leaves out what the image sets"
fi

# ═══════════════════════════════════════════════════════════════════════════
step 'TEST 6 — the taken-over agent updates like any other'

run "${UPDATE} --release 1.0.0"
assert_succeeded 'agent-update.sh to agent 1.0.0 succeeds'
assert_said 'Agent updated to 1.0.0' 'and reports agent 1.0.0'
assert_eq "$(digest_of 1.0.0)" "$(agent_field '{{.Config.Image}}')" 'it runs agent 1.0.0'
assert_eq "${STATE_VOL}" "$(mount_at /var/lib/kubedok-agent)" 'still on the same state volume'
assert_eq 'identity-1' "$(identity)" 'with its identity'
assert_eq '203.0.113.7' "$(container_env kubedok-agent KUBEDOK_OVERLAY_PUBLIC_IP)" 'and its settings'
if env_file_line 'KUBEDOK_AGENT_RELEASE=1.0.0'; then pass 'agent.env records agent 1.0.0'; else fails 'agent.env does not record agent 1.0.0'; fi

run "${UPDATE} --release 1.0.0"
assert_said 'Already on agent 1.0.0' 'a second run finds nothing to do'

# ═══════════════════════════════════════════════════════════════════════════
printf '\n%s passed, %s failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
