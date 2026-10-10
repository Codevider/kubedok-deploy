#!/usr/bin/env bash
#
# Install the Kubedok agent on a Docker host.
#
#   agent-install.sh --token <registration-token> --api-url https://kubedok.example.com
#   agent-install.sh --token <token>                 # on the control-plane host
#   agent-install.sh --adopt [--api-url <url>]       # take over an agent started by hand
#
# Runs on any Docker host, with or without a Kubedok control plane installed.
# The agent is deliberately a separate install (/opt/kubedok-agent) with its
# own lifecycle: updating the control plane must never restart every agent.
#
# Generate the registration token in the Kubedok UI first. --adopt needs none:
# it moves an agent started with `docker run`, as the single-container
# releases had it, to this release's agent, as the same host.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/common.sh" ]; then
  # shellcheck source=common.sh
  . "${SCRIPT_DIR}/common.sh"
else
  echo "Cannot find common.sh next to agent-install.sh" >&2
  exit 1
fi

AGENT_ROOT="${KUBEDOK_AGENT_ROOT:-/opt/kubedok-agent}"
TOKEN=""
API_URL=""
HOST_ADDRESS=""
RELEASE_REF=""
ADOPT=false
ADOPT_CONTAINER="kubedok-agent"

while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    --api-url) API_URL="$2"; shift 2 ;;
    --host-address) HOST_ADDRESS="$2"; shift 2 ;;
    --release) RELEASE_REF="$2"; shift 2 ;;
    --adopt) ADOPT=true; shift ;;
    --container) ADOPT_CONTAINER="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_root
require_cmd docker curl jq

# ── Adopting an agent started by hand ────────────────────────────────────────
# The agent's identity is its state file (agent id, key, host id and WireGuard
# keys). Copied into this layout's volume, the new agent loads it and
# reconnects as the same host: nothing registers again, and nothing running on
# the host is touched. Registering anew instead would make a second host.
ADOPT_ASIDE="kubedok-agent-pre-adopt"
ADOPT_STEP=""   # how far it got, for undo_adopt
ADOPT_MADE_ROOT=false

# Settings agent.env and the compose file carry. Anything else set on the old
# container would be lost, so it is refused rather than dropped.
ADOPT_CARRIED=" KUBEDOK_API_URL KUBEDOK_REGISTRATION_TOKEN KUBEDOK_HOST_ADDRESS KUBEDOK_STATE_FILE KUBEDOK_SYNC_INTERVAL_SECS RUST_LOG AGENT_STATE_VOLUME "

adopt_env() { printf '%s\n' "${ADOPT_ENV}" | sed -n "s/^$1=//p" | tail -n1; }

undo_adopt() {
  local status=$?
  [ "${status}" -ne 0 ] && [ -n "${ADOPT_STEP}" ] || return 0
  set +e
  err "Adoption failed. Putting ${ADOPT_CONTAINER} back."
  if [ -f "${AGENT_ROOT}/docker-compose.yml" ] && [ -f "${AGENT_ROOT}/agent.env" ]; then
    # shellcheck disable=SC2046
    $(compose_cmd) --env-file "${AGENT_ROOT}/agent.env" -f "${AGENT_ROOT}/docker-compose.yml" down >/dev/null 2>&1
  fi
  if [ "${ADOPT_STEP}" = "stopped" ] || [ "${ADOPT_STEP}" = "stopping" ]; then
    if docker container inspect "${ADOPT_ASIDE}" >/dev/null 2>&1; then
      docker rm -f kubedok-agent >/dev/null 2>&1
      docker rename "${ADOPT_ASIDE}" "${ADOPT_CONTAINER}" >/dev/null 2>&1
    fi
    docker update --restart "${ADOPT_RESTART}" "${ADOPT_CONTAINER}" >/dev/null 2>&1
    if docker start "${ADOPT_CONTAINER}" >/dev/null 2>&1; then
      err "${ADOPT_CONTAINER} is running again, as before."
    else
      err "Could not start ${ADOPT_CONTAINER} again. Start it with: docker start ${ADOPT_CONTAINER}"
    fi
  fi
  docker volume rm kubedok_agent_state kubedok_agent_wg >/dev/null 2>&1
  if [ "${ADOPT_MADE_ROOT}" = "true" ]; then
    rm -rf "${AGENT_ROOT}"
  else
    rm -f "${AGENT_ROOT}/agent.env" "${AGENT_ROOT}/docker-compose.yml"
  fi
  exit "${status}"
}

# What Kubedok's containers on this host keep in anonymous volumes: a redeploy
# makes a new container with new, empty ones, so that data would be left
# behind. Under a megabyte is not worth a word: mongo's empty /data/configdb
# beside a named /data/db, or the history a client keeps in its home.
report_anonymous_volumes() {
  local container vol dest kb
  while IFS= read -r container; do
    [ -n "${container}" ] || continue
    while read -r vol dest; do
      [[ "${vol}" =~ ^[0-9a-f]{64}$ ]] || continue
      kb="$(docker run --rm --network none -v "${vol}:/v:ro" --entrypoint du "${AGENT_IMAGE}" -sk /v 2>/dev/null | cut -f1 || true)"
      [[ "${kb}" =~ ^[0-9]+$ ]] && [ "${kb}" -ge 1024 ] || continue
      warn "${container} keeps $(( kb / 1024 )) MB in ${dest} on an anonymous volume (${vol:0:12}). Redeployed, it starts with an empty one: move the data to a named volume first."
    done < <(docker container inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{println .Name .Destination}}{{end}}{{end}}' "${container}" 2>/dev/null || true)
  done < <(docker ps -a --filter label=kubedok.managed=true --format '{{.Names}}')
}

adopt_agent() {
  [ ! -f "${AGENT_ROOT}/agent.env" ] \
    || die "An agent is already installed at ${AGENT_ROOT}. Update it with agent-update.sh."
  docker container inspect "${ADOPT_CONTAINER}" >/dev/null 2>&1 \
    || die "No container named ${ADOPT_CONTAINER} to adopt. Name it with --container."
  [ -z "$(docker container inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "${ADOPT_CONTAINER}")" ] \
    || die "${ADOPT_CONTAINER} is run by Docker Compose, not by hand, so there is nothing to adopt."
  ! docker container inspect "${ADOPT_ASIDE}" >/dev/null 2>&1 \
    || die "A container named ${ADOPT_ASIDE} exists, from an earlier adoption. Remove it if it is no longer needed."
  ! docker volume inspect kubedok_agent_state >/dev/null 2>&1 \
    || die "The volume kubedok_agent_state already exists. Remove it if it is not in use, then run this again."
  # Checked before anything stops: the new agent runs under Compose.
  docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1 \
    || die "Docker Compose is not installed on this host, and the new agent runs under it. Install Docker's docker-compose-plugin package, then run this again."

  ADOPT_ENV="$(docker container inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${ADOPT_CONTAINER}")"
  ADOPT_RESTART="$(docker container inspect -f '{{.HostConfig.RestartPolicy.Name}}' "${ADOPT_CONTAINER}")"
  ADOPT_RESTART="${ADOPT_RESTART:-no}"
  local state_file name value image_env unsupported=()
  state_file="$(adopt_env KUBEDOK_STATE_FILE)"
  [ "${state_file:-/var/lib/kubedok-agent/agent-state.json}" = "/var/lib/kubedok-agent/agent-state.json" ] \
    || die "${ADOPT_CONTAINER} keeps its state in ${state_file}, which this cannot carry over. Move it by hand."
  [ -n "$(docker container inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/kubedok-agent"}}x{{end}}{{end}}' "${ADOPT_CONTAINER}")" ] \
    || die "${ADOPT_CONTAINER} keeps no state in a volume, so it has no identity to carry over."
  # What the old image sets itself is not a setting anyone made.
  image_env="$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' \
    "$(docker container inspect -f '{{.Image}}' "${ADOPT_CONTAINER}")" 2>/dev/null || true)"
  while IFS='=' read -r name value; do
    case "${name}" in KUBEDOK_*|RUST_*) ;; *) continue ;; esac
    [ -n "${value}" ] || continue
    printf '%s\n' "${image_env}" | grep -qxF -- "${name}=${value}" && continue
    [[ "${ADOPT_CARRIED}" == *" ${name} "* ]] || unsupported+=("${name}")
  done <<<"${ADOPT_ENV}"
  [ ${#unsupported[@]} -eq 0 ] \
    || die "${ADOPT_CONTAINER} is set with ${unsupported[*]}, which the managed agent does not carry. Move it by hand to keep them."

  [ -n "${API_URL}" ] || API_URL="$(adopt_env KUBEDOK_API_URL)"
  [ -n "${API_URL}" ] || die "Which control plane? Pass --api-url."
  [ -n "${HOST_ADDRESS}" ] || HOST_ADDRESS="$(adopt_env KUBEDOK_HOST_ADDRESS)"

  # The new agent speaks to the new server only. A control plane that does not
  # report a release is still the single-container one.
  log "Checking the control plane at ${API_URL}"
  local server_release
  server_release="$(curl -fsS --max-time 15 "${API_URL}/api/version" 2>/dev/null | jq -r '.release // empty' 2>/dev/null || true)"
  [ -n "${server_release}" ] \
    || die "${API_URL} does not report a release, so it is not running a current Kubedok. Move the control plane first (migrate-from-monolith.sh), then the agents."
  ok "Control plane runs ${server_release}"
  if [ -z "${RELEASE_REF}" ]; then
    if is_semver "${server_release}"; then RELEASE_REF="${server_release}"; else RELEASE_REF="stable"; fi
  fi

  local manifest
  manifest="$(mktemp)"
  resolve_manifest "${RELEASE_REF}" "${manifest}" >/dev/null
  AGENT_IMAGE="$(manifest_image agent "${manifest}")"
  AGENT_VERSION="$(manifest_field agentVersion "${manifest}")"
  rm -f "${manifest}"
  log "Pulling agent ${AGENT_VERSION}"
  docker pull -q "${AGENT_IMAGE}" >/dev/null || die "Could not pull ${AGENT_IMAGE}"

  # Read through the new image, which has a shell; the old one may not.
  local host_id
  host_id="$(docker run --rm --network none --volumes-from "${ADOPT_CONTAINER}:ro" --entrypoint cat \
      "${AGENT_IMAGE}" /var/lib/kubedok-agent/agent-state.json 2>/dev/null \
    | jq -r 'select(.agent_id and .agent_key and .host_id) | .host_id' 2>/dev/null || true)"
  [ -n "${host_id}" ] \
    || die "${ADOPT_CONTAINER} has no complete agent state (agent id, key and host id), so it has no identity to carry over."
  ok "Host ${host_id}"

  # The old agent stops first: its state is then still, and two agents with
  # one identity would both take the host's commands. Its containers keep
  # running meanwhile.
  [ -d "${AGENT_ROOT}" ] || ADOPT_MADE_ROOT=true
  trap undo_adopt EXIT
  log "Stopping ${ADOPT_CONTAINER}"
  ADOPT_STEP="stopping"
  docker update --restart no "${ADOPT_CONTAINER}" >/dev/null
  docker stop -t 30 "${ADOPT_CONTAINER}" >/dev/null || die "Could not stop ${ADOPT_CONTAINER}."
  docker rename "${ADOPT_CONTAINER}" "${ADOPT_ASIDE}" || die "Could not set ${ADOPT_CONTAINER} aside."
  ADOPT_STEP="stopped"

  log "Copying the agent's state"
  mkdir -p "${AGENT_ROOT}"
  chmod 700 "${AGENT_ROOT}"
  docker volume create kubedok_agent_state >/dev/null
  docker volume create kubedok_agent_wg >/dev/null
  docker run --rm --network none --volumes-from "${ADOPT_ASIDE}:ro" \
    -v kubedok_agent_state:/adopt/state -v kubedok_agent_wg:/adopt/wg --entrypoint sh "${AGENT_IMAGE}" -c \
    'cp -a /var/lib/kubedok-agent/. /adopt/state/ && if [ -d /etc/wireguard ]; then cp -a /etc/wireguard/. /adopt/wg/; fi' \
    || die "Could not copy the agent's state."

  if [ -f "${SCRIPT_DIR}/../compose/agent.yml" ]; then
    install -m 644 "${SCRIPT_DIR}/../compose/agent.yml" "${AGENT_ROOT}/docker-compose.yml"
  elif [ -f "${KUBEDOK_CURRENT_LINK}/compose/agent.yml" ]; then
    install -m 644 "${KUBEDOK_CURRENT_LINK}/compose/agent.yml" "${AGENT_ROOT}/docker-compose.yml"
  else
    fetch_url "${KUBEDOK_RELEASE_BASE_URL}/compose/agent.yml" "${AGENT_ROOT}/docker-compose.yml"
  fi
  local sync rust_log
  sync="$(adopt_env KUBEDOK_SYNC_INTERVAL_SECS)"
  rust_log="$(adopt_env RUST_LOG)"
  {
    printf '# Written by agent-install.sh --adopt. Edit KUBEDOK_API_URL here and re-run restart.\n'
    printf 'KUBEDOK_IMAGE_AGENT=%s\n' "${AGENT_IMAGE}"
    printf 'KUBEDOK_API_URL=%s\n' "${API_URL}"
    printf 'KUBEDOK_REGISTRATION_TOKEN=\n'
    printf 'KUBEDOK_HOST_ADDRESS=%s\n' "${HOST_ADDRESS}"
    printf 'KUBEDOK_SYNC_INTERVAL_SECS=%s\n' "${sync:-15}"
    printf 'KUBEDOK_AGENT_LOG=%s\n' "${rust_log:-kubedok_agent=info}"
    printf 'KUBEDOK_AGENT_RELEASE=%s\n' "${AGENT_VERSION}"
  } > "${AGENT_ROOT}/agent.env"
  chmod 600 "${AGENT_ROOT}/agent.env"

  log "Starting agent ${AGENT_VERSION}"
  # shellcheck disable=SC2046
  $(compose_cmd) --env-file "${AGENT_ROOT}/agent.env" -f "${AGENT_ROOT}/docker-compose.yml" up -d \
    || die "Could not start the new agent."

  # Proof it is the same host: the agent says it loaded the state it was given,
  # and stays up.
  local deadline=$(( SECONDS + 90 )) logs
  while true; do
    [ "$(docker container inspect -f '{{.State.Running}}' kubedok-agent 2>/dev/null)" = "true" ] || {
      docker logs --tail 30 kubedok-agent 2>&1 | sed 's/^/      /' >&2
      die "The new agent stopped."
    }
    logs="$(docker logs kubedok-agent 2>&1 | grep 'Loaded existing agent state' || true)"
    if [[ "${logs}" == *"${host_id}"* ]]; then
      break
    fi
    if (( SECONDS >= deadline )); then
      docker logs --tail 30 kubedok-agent 2>&1 | sed 's/^/      /' >&2
      die "The new agent did not load the old agent's state."
    fi
    sleep 2
  done
  sleep 5
  [ "$(docker container inspect -f '{{.State.Running}}' kubedok-agent 2>/dev/null)" = "true" ] || die "The new agent stopped."
  ADOPT_STEP=""
  trap - EXIT

  ok "Agent ${AGENT_VERSION} runs as host ${host_id}"
  report_anonymous_volumes
  printf '\n'
  printf '  Config   %s/agent.env\n' "${AGENT_ROOT}"
  printf '  Logs     docker logs -f kubedok-agent\n'
  printf '  Update   %s/agent-update.sh\n' "${SCRIPT_DIR}"
  printf '\n'
  printf '  The old agent is stopped and kept as %s, with its volumes. Once the\n' "${ADOPT_ASIDE}"
  printf '  host shows up and deploys work, remove it: docker rm -v %s\n' "${ADOPT_ASIDE}"
  printf '  Its state volume, kubedok-agent-state, can go too once every load balancer\n'
  printf '  on this host has been deployed again: newer agents mount their config from it.\n'
  printf '\n'
  printf '  Then redeploy each service on this host once, the ones that connect to\n'
  printf '  others before the ones they connect to, in the order the migration\n'
  printf '  printed: containers the old agent started find each other by Docker\n'
  printf '  network aliases, which new containers do not have.\n\n'
}

if [ "${ADOPT}" = "true" ]; then
  adopt_agent
  exit 0
fi

# Inherit control-plane settings when one is installed here.
if [ -f "${KUBEDOK_CONFIG_FILE}" ]; then
  load_config
  [ -z "${API_URL}" ] && API_URL="http://127.0.0.1:${KUBEDOK_HTTP_PORT:-80}"
  [ -z "${RELEASE_REF}" ] && RELEASE_REF="${KUBEDOK_RELEASE:-stable}"
fi
RELEASE_REF="${RELEASE_REF:-stable}"

[ -n "${TOKEN}" ] || die "A registration token is required: --token <token>. Generate one in the Kubedok UI."
[ -n "${API_URL}" ] || die "The API URL is required on a host without a control plane: --api-url https://kubedok.example.com"

# Resolve the agent image digest from the release manifest, so an agent is
# pinned exactly like every other component. The manifest also names the
# agent's own version, which is not the release's.
log "Resolving the agent image for release '${RELEASE_REF}'"
MANIFEST="$(mktemp)"
LOCAL_MANIFEST="${KUBEDOK_CURRENT_LINK}/release.json"
if [ -f "${LOCAL_MANIFEST}" ] && { [ "${RELEASE_REF}" = "stable" ] || [ "${RELEASE_REF}" = "$(current_release 2>/dev/null)" ]; }; then
  cp "${LOCAL_MANIFEST}" "${MANIFEST}"
  validate_manifest "${MANIFEST}"
else
  resolve_manifest "${RELEASE_REF}" "${MANIFEST}" >/dev/null
fi

AGENT_IMAGE="$(manifest_image agent "${MANIFEST}")"
AGENT_VERSION="$(manifest_field agentVersion "${MANIFEST}")"
ok "Agent image: ${AGENT_IMAGE}"

log "Checking the control plane at ${API_URL}"
if ! curl -fsS --max-time 15 -o /dev/null "${API_URL}/api/health"; then
  die "Cannot reach ${API_URL}/api/health from this host. The agent needs outbound access to the control plane."
fi
ok "Control plane reachable"

mkdir -p "${AGENT_ROOT}"
chmod 700 "${AGENT_ROOT}"

# Ship a compose file so the agent has the same lifecycle tooling everywhere,
# whether or not this host runs a control plane.
if [ -f "${KUBEDOK_CURRENT_LINK}/compose/agent.yml" ]; then
  install -m 644 "${KUBEDOK_CURRENT_LINK}/compose/agent.yml" "${AGENT_ROOT}/docker-compose.yml"
else
  fetch_url "${KUBEDOK_RELEASE_BASE_URL}/compose/agent.yml" "${AGENT_ROOT}/docker-compose.yml"
fi

{
  printf '# Generated by agent-install.sh. Edit KUBEDOK_API_URL here and re-run restart.\n'
  printf 'KUBEDOK_IMAGE_AGENT=%s\n' "${AGENT_IMAGE}"
  printf 'KUBEDOK_API_URL=%s\n' "${API_URL}"
  printf 'KUBEDOK_REGISTRATION_TOKEN=%s\n' "${TOKEN}"
  printf 'KUBEDOK_HOST_ADDRESS=%s\n' "${HOST_ADDRESS}"
  printf 'KUBEDOK_SYNC_INTERVAL_SECS=%s\n' "${KUBEDOK_SYNC_INTERVAL_SECS:-15}"
  printf 'KUBEDOK_AGENT_LOG=%s\n' "${KUBEDOK_AGENT_LOG:-kubedok_agent=info}"
  printf 'KUBEDOK_AGENT_RELEASE=%s\n' "${AGENT_VERSION}"
} > "${AGENT_ROOT}/agent.env"
chmod 600 "${AGENT_ROOT}/agent.env"
rm -f "${MANIFEST}"

log "Pulling the agent image"
docker pull -q "${AGENT_IMAGE}" >/dev/null || die "Could not pull ${AGENT_IMAGE}"

log "Starting the agent"
# shellcheck disable=SC2046
$(compose_cmd) --env-file "${AGENT_ROOT}/agent.env" -f "${AGENT_ROOT}/docker-compose.yml" up -d

sleep 5
state="$(docker inspect -f '{{.State.Status}}' kubedok-agent 2>/dev/null || echo missing)"
if [ "${state}" != "running" ]; then
  err "The agent is not running (state: ${state})."
  docker logs --tail 30 kubedok-agent 2>&1 | sed 's/^/      /' >&2 || true
  die "Agent installation failed."
fi

ok "Agent ${AGENT_VERSION} is running"
printf '\n'
printf '  Config   %s/agent.env\n' "${AGENT_ROOT}"
printf '  Logs     docker logs -f kubedok-agent\n'
if kbd_installed; then
  printf '  Update   kbd agent-update\n'
else
  printf '  Update   %s/agent-update.sh\n' "${SCRIPT_DIR}"
fi
printf '\n'
printf '  The host should appear in the Kubedok UI within a few seconds.\n\n'
