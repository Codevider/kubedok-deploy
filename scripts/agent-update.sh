#!/usr/bin/env bash
#
# Update the Kubedok agent on this host, independently of the control plane.
#
#   agent-update.sh                  # to the agent the control plane's release ships
#   agent-update.sh --release 1.3.0  # to the agent release 1.3.0 ships
#   agent-update.sh --check
#
# Agents update separately on purpose: a control-plane update must not restart
# workloads on every managed host at once. The agent has a version of its
# own (agentVersion in the release manifest); the compatibility floor is
# minimumAgentVersion there.
#
# An agent started by the docker run command from Register host in the Kubedok
# UI moves under /opt/kubedok-agent as it updates, where agent-install.sh puts
# one, with the settings and the volumes it was started with.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

AGENT_ROOT="${KUBEDOK_AGENT_ROOT:-/opt/kubedok-agent}"
AGENT_ENV="${AGENT_ROOT}/agent.env"
AGENT_COMPOSE="${AGENT_ROOT}/docker-compose.yml"
RELEASE_REF=""
CHECK_ONLY=false

while [ $# -gt 0 ]; do
  case "$1" in
    --release) RELEASE_REF="$2"; shift 2 ;;
    --check) CHECK_ONLY=true; shift ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_root
require_cmd docker curl jq
docker info >/dev/null 2>&1 || die "Cannot reach the Docker daemon."

# ── An agent the Kubedok UI's command started ────────────────────────────────
# Register host in the Kubedok UI hands out a docker run command, which leaves
# no agent.env and names the agent's volumes kubedok-agent-state and
# kubedok-agent-wg. Such an agent is taken over: it is run from here on by the
# compose file agent-install.sh installs, with agent.env holding the settings
# it was started with and naming its volumes. It keeps them: they hold its
# identity, and load balancers bind-mount files from the state volume by a
# path that names it.
TAKEOVER=false
TAKING_OVER=false
OLD_ID=""
OLD_IMAGE_ID=""
OLD_RUNNING=false
OLD_RESTART=no
# Where the original container waits while its replacement starts.
REPLACED_NAME=kubedok-agent-replaced
STATE_VOLUME=""
WG_VOLUME=""
# agent.env lines for the settings the agent was started with.
SETTINGS=()
# What stops a takeover, said before anything changes.
TAKEOVER_BLOCKERS=()
CREATED_ROOT=false
COMPOSE_BACKUP=""
MANIFEST=""

# One agent.env line. A plain value goes in bare and any other single-quoted,
# which bash, sourcing the file, and Compose, reading it, both take literally.
env_line() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  if [[ "$2" =~ ^[[:alnum:]_.,:/=@%+-]*$ ]]; then
    printf '%s=%s' "$1" "$2"
  elif [[ "$2" != *"'"* && "$2" != *$'\n'* ]]; then
    printf "%s='%s'" "$1" "$2"
  else
    return 1
  fi
}

# The volume a container, given as `docker container inspect` JSON, mounts at
# a path, or nothing.
volume_at() {
  jq -r --arg d "$2" '.[0].Mounts[] | select(.Destination == $d and .Type == "volume") | .Name' <<<"$1"
}

# Reads kubedok-agent as the docker run command left it, and notes anything a
# takeover could not carry over.
read_started_agent() {
  local json image_env setting key value line others
  json="$(docker container inspect kubedok-agent)"
  OLD_ID="$(jq -r '.[0].Id' <<<"${json}")"
  OLD_IMAGE_ID="$(jq -r '.[0].Image' <<<"${json}")"
  OLD_RUNNING="$(jq -r '.[0].State.Running' <<<"${json}")"
  OLD_RESTART="$(jq -r '.[0].HostConfig.RestartPolicy
    | if .Name == "on-failure" and (.MaximumRetryCount // 0) > 0 then "on-failure:\(.MaximumRetryCount)"
      elif (.Name // "") == "" then "no" else .Name end' <<<"${json}")"
  CURRENT_AGENT="$(jq -r '.[0].Config.Labels["org.opencontainers.image.version"] // "unknown"' <<<"${json}")"

  STATE_VOLUME="$(volume_at "${json}" /var/lib/kubedok-agent)"
  WG_VOLUME="$(volume_at "${json}" /etc/wireguard)"
  [ -n "${STATE_VOLUME}" ] && [ -n "${WG_VOLUME}" ] \
    || TAKEOVER_BLOCKERS+=("It keeps /var/lib/kubedok-agent or /etc/wireguard outside a volume.")
  others="$(jq -r '.[0].Mounts[] | .Destination
    | select(. != "/var/lib/kubedok-agent" and . != "/etc/wireguard" and . != "/var/run/docker.sock")' <<<"${json}")"
  [ -z "${others}" ] || TAKEOVER_BLOCKERS+=("It mounts ${others//$'\n'/, } as well.")

  # The settings it was started with: its environment, less what its image
  # sets, so that the new image's defaults apply. Each must be one the compose
  # file passes to the agent, or it would be lost.
  image_env="$(docker image inspect -f '{{json .Config.Env}}' "${OLD_IMAGE_ID}" 2>/dev/null)" \
    || die "Cannot read the image kubedok-agent runs (${OLD_IMAGE_ID})."
  KUBEDOK_API_URL=""
  while IFS= read -r setting; do
    key="${setting%%=*}"
    value="${setting#*=}"
    case "${key}" in
      KUBEDOK_API_URL) KUBEDOK_API_URL="${value}" ;;
      KUBEDOK_REGISTRATION_TOKEN|KUBEDOK_HOST_ADDRESS|KUBEDOK_SYNC_INTERVAL_SECS) ;;
      KUBEDOK_OVERLAY_ENDPOINT|KUBEDOK_OVERLAY_PUBLIC_IP|KUBEDOK_OVERLAY_LISTEN_PORT|KUBEDOK_OVERLAY_ENABLED) ;;
      KUBEDOK_DNS_UPSTREAM|KUBEDOK_DNS_FORWARDER_FALLBACK_ANY) ;;
      RUST_LOG) key=KUBEDOK_AGENT_LOG ;;
      KUBEDOK_STATE_FILE)
        [ "${value}" = /var/lib/kubedok-agent/agent-state.json ] \
          || TAKEOVER_BLOCKERS+=("It keeps its identity in ${value}.")
        continue ;;
      *)
        TAKEOVER_BLOCKERS+=("It was started with ${key}, which agent.env does not pass to the agent. Start it again without that setting (its identity is in its volume, so it stays the same host), then run this again.")
        continue ;;
    esac
    if line="$(env_line "${key}" "${value}")"; then
      SETTINGS+=("${line}")
    else
      TAKEOVER_BLOCKERS+=("Its ${key} setting holds a quote or a line break, which agent.env cannot hold.")
    fi
  done < <(jq -r --argjson image "${image_env}" \
    '.[0].Config.Env // [] | .[] | select(. as $e | ($image // []) | any(.[]; . == $e) | not)' <<<"${json}")
  [ -n "${KUBEDOK_API_URL}" ] || TAKEOVER_BLOCKERS+=("It was started without KUBEDOK_API_URL.")

  # From here on, Compose runs the agent.
  docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1 \
    || TAKEOVER_BLOCKERS+=("Docker Compose, which runs the agent once it is taken over, is not installed. Install it: docker-compose-plugin from Docker's repository, or docker-compose-v2 with Ubuntu's docker.io.")
  if docker container inspect "${REPLACED_NAME}" >/dev/null 2>&1; then
    TAKEOVER_BLOCKERS+=("A container named ${REPLACED_NAME} exists: the agent an earlier run replaced. Remove it if kubedok-agent runs, or rename it back to kubedok-agent if not.")
  fi
}

write_takeover_env() {
  local line
  {
    printf '# Written by agent-update.sh, which took over the agent the docker run command\n'
    printf '# from the Kubedok UI started. To change a setting, edit it here, then run:\n'
    printf '#   docker compose --env-file %s -f %s up -d\n' "${AGENT_ENV}" "${AGENT_COMPOSE}"
    printf 'KUBEDOK_IMAGE_AGENT=%s\n' "${NEW_IMAGE}"
    printf 'KUBEDOK_AGENT_RELEASE=%s\n' "${NEW_AGENT}"
    printf 'KUBEDOK_AGENT_STATE_VOLUME=%s\n' "${STATE_VOLUME}"
    printf 'KUBEDOK_AGENT_WG_VOLUME=%s\n' "${WG_VOLUME}"
    printf 'KUBEDOK_AGENT_VOLUMES_EXTERNAL=true\n'
    for line in "${SETTINGS[@]}"; do
      printf '%s\n' "${line}"
    done
  } > "${AGENT_ENV}"
  chmod 600 "${AGENT_ENV}"
}

# Undoes a takeover that did not finish: the original container returns under
# its own name, as it was, and the files written for it go.
put_original_back() {
  set +e
  local id
  err "The agent was not taken over. Putting the original back."
  id="$(docker container inspect -f '{{.Id}}' kubedok-agent 2>/dev/null)"
  if [ -n "${id}" ] && [ "${id}" != "${OLD_ID}" ]; then
    docker logs --tail 30 "${id}" 2>&1 | sed 's/^/      /' >&2
    docker rm -f "${id}" >/dev/null 2>&1
  fi
  if [ "$(docker container inspect -f '{{.Name}}' "${OLD_ID}" 2>/dev/null)" = "/${REPLACED_NAME}" ]; then
    docker rename "${OLD_ID}" kubedok-agent
  fi
  docker update --restart "${OLD_RESTART}" "${OLD_ID}" >/dev/null
  if [ "${OLD_RUNNING}" = true ]; then
    docker start "${OLD_ID}" >/dev/null
  fi
  rm -f "${AGENT_ENV}"
  if [ -n "${COMPOSE_BACKUP}" ]; then
    mv -f "${COMPOSE_BACKUP}" "${AGENT_COMPOSE}"
    COMPOSE_BACKUP=""
  else
    rm -f "${AGENT_COMPOSE}"
  fi
  if [ "${CREATED_ROOT}" = true ]; then
    rmdir "${AGENT_ROOT}" 2>/dev/null
  fi
  if [ "$(docker container inspect -f '{{.Id}} {{.State.Running}}' kubedok-agent 2>/dev/null)" = "${OLD_ID} ${OLD_RUNNING}" ]; then
    ok "The original agent is back, unchanged."
  else
    err "The original agent is not back as it was. It is container ${OLD_ID:0:12}: docker rename it to kubedok-agent if needed, and docker start it."
  fi
}

on_exit() {
  if [ "${TAKING_OVER}" = true ]; then
    put_original_back
  fi
  [ -z "${MANIFEST}" ] || rm -f "${MANIFEST}"
  [ -z "${COMPOSE_BACKUP}" ] || rm -f "${COMPOSE_BACKUP}"
}
trap on_exit EXIT

take_over() {
  local json
  log "Taking over the agent the docker run command from the Kubedok UI started"
  [ -d "${AGENT_ROOT}" ] || CREATED_ROOT=true
  mkdir -p "${AGENT_ROOT}"
  chmod 700 "${AGENT_ROOT}"
  if [ -f "${AGENT_COMPOSE}" ]; then
    COMPOSE_BACKUP="$(mktemp)"
    cp -p "${AGENT_COMPOSE}" "${COMPOSE_BACKUP}"
  fi
  TAKING_OVER=true

  if [ -f "${SCRIPT_DIR}/../compose/agent.yml" ]; then
    install -m 644 "${SCRIPT_DIR}/../compose/agent.yml" "${AGENT_COMPOSE}"
  else
    fetch_url "${KUBEDOK_RELEASE_BASE_URL}/compose/agent.yml" "${AGENT_COMPOSE}"
    chmod 644 "${AGENT_COMPOSE}"
  fi
  write_takeover_env
  ok "Its settings are in ${AGENT_ENV}"

  log "Stopping the agent"
  docker update --restart no "${OLD_ID}" >/dev/null
  docker stop -t 30 "${OLD_ID}" >/dev/null
  docker rename "${OLD_ID}" "${REPLACED_NAME}"

  log "Starting agent ${NEW_AGENT} on volumes ${STATE_VOLUME} and ${WG_VOLUME}"
  # shellcheck disable=SC2046
  $(compose_cmd) --env-file "${AGENT_ENV}" -f "${AGENT_COMPOSE}" up -d

  sleep 6
  json="$(docker container inspect kubedok-agent 2>/dev/null)" || die "The new agent's container is missing."
  [ "$(jq -r '.[0].State.Status' <<<"${json}")" = running ] \
    && [ "$(jq -r '.[0].RestartCount' <<<"${json}")" = 0 ] \
    || die "Agent ${NEW_AGENT} did not start (state: $(jq -r '.[0].State.Status' <<<"${json}"))."
  [ "$(volume_at "${json}" /var/lib/kubedok-agent)" = "${STATE_VOLUME}" ] \
    && [ "$(volume_at "${json}" /etc/wireguard)" = "${WG_VOLUME}" ] \
    || die "The new agent does not run on volumes ${STATE_VOLUME} and ${WG_VOLUME}."

  # The new agent runs: a failure from here on must not undo it.
  TAKING_OVER=false
  # Not -v: its volumes are the new agent's now.
  docker rm "${OLD_ID}" >/dev/null \
    || warn "Could not remove the original container. Remove it with: docker rm ${REPLACED_NAME}"

  ok "Agent updated to ${NEW_AGENT}"
  printf '\n'
  printf '  The agent now runs from %s, as agent-install.sh sets one up.\n' "${AGENT_ROOT}"
  printf '  Its settings are in agent.env, and it updates the same way from here on.\n'
  printf '\n'
}

# A setting as agent.env holds it, without quotes around it. Read rather than
# sourced: agent.env is the agent's, and a setting meant for it, such as
# DOCKER_HOST, must not steer this script's own docker commands.
agent_setting() {
  local value
  value="$(sed -n "s/^$1=//p" "${AGENT_ENV}" | tail -n1)"
  case "${value}" in
    \'*\'|\"*\") value="${value:1:${#value}-2}" ;;
  esac
  printf '%s' "${value}"
}

if [ -f "${AGENT_ENV}" ]; then
  KUBEDOK_API_URL="$(agent_setting KUBEDOK_API_URL)"
  CURRENT_AGENT="$(agent_setting KUBEDOK_AGENT_RELEASE)"
  CURRENT_AGENT="${CURRENT_AGENT:-unknown}"
  CURRENT_IMAGE="$(agent_setting KUBEDOK_IMAGE_AGENT)"
elif agent_started_by_docker_run; then
  TAKEOVER=true
  read_started_agent
elif docker container inspect kubedok-agent >/dev/null 2>&1; then
  die "kubedok-agent was started by Compose, but ${AGENT_ENV}, which holds its settings, is missing."
else
  die "No agent runs on this host: there is no ${AGENT_ENV} and no kubedok-agent container. Install one with agent-install.sh, or with the command from Register host in the Kubedok UI."
fi

# Default to whatever release the control plane is actually running, which is
# the version the API is guaranteed to speak to.
if [ -z "${RELEASE_REF}" ]; then
  if server_release="$(curl -fsS --max-time 10 "${KUBEDOK_API_URL}/api/version" 2>/dev/null | jq -r '.release // empty')" \
     && [ -n "${server_release}" ] && [ "${server_release}" != "dev" ]; then
    RELEASE_REF="${server_release}"
    log "Control plane runs ${server_release} — matching it"
  else
    RELEASE_REF="stable"
  fi
fi

MANIFEST="$(mktemp)"
resolve_manifest "${RELEASE_REF}" "${MANIFEST}" >/dev/null

NEW_RELEASE="$(manifest_field release "${MANIFEST}")"
NEW_AGENT="$(manifest_field agentVersion "${MANIFEST}")"
NEW_IMAGE="$(manifest_image agent "${MANIFEST}")"
MIN_AGENT="$(manifest_field minimumAgentVersion "${MANIFEST}")"

printf '\n'
if [ "${TAKEOVER}" = true ]; then
  printf "  Installed agent   %s  (started by the Kubedok UI's docker run command)\n" "${CURRENT_AGENT}"
else
  printf '  Installed agent   %s\n' "${CURRENT_AGENT}"
fi
printf '  Target agent      %s  (release %s)\n' "${NEW_AGENT}" "${NEW_RELEASE}"
printf '  Compatibility     server requires agent >= %s\n' "${MIN_AGENT}"
printf '\n'

if [ "${TAKEOVER}" = true ]; then
  # By digest: the UI's command names the image by its tag.
  digests="$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "${OLD_IMAGE_ID}")"
  if grep -qxF "${NEW_IMAGE}" <<<"${digests}"; then
    ok "Already on agent ${NEW_AGENT}. Nothing to do."
    exit 0
  fi
elif [ "${CURRENT_IMAGE}" = "${NEW_IMAGE}" ]; then
  ok "Already on agent ${NEW_AGENT}. Nothing to do."
  exit 0
fi

if [ "${TAKEOVER}" = true ] && [ ${#TAKEOVER_BLOCKERS[@]} -gt 0 ]; then
  err "An update is available, but kubedok-agent cannot be taken over, which updating it needs:"
  for blocker in "${TAKEOVER_BLOCKERS[@]}"; do
    printf '      %s\n' "${blocker}" >&2
  done
  exit 1
fi

if [ "${CHECK_ONLY}" = "true" ]; then
  printf '  An update is available. Run without --check to apply.\n'
  if [ "${TAKEOVER}" = true ]; then
    printf '  Applying it moves the agent under %s, with the settings it was\n' "${AGENT_ROOT}"
    printf '  started with and its volumes %s and %s.\n' "${STATE_VOLUME}" "${WG_VOLUME}"
  fi
  printf '\n'
  exit 0
fi

log "Pulling ${NEW_IMAGE}"
docker pull -q "${NEW_IMAGE}" >/dev/null || die "Could not pull ${NEW_IMAGE}"

if [ "${TAKEOVER}" = true ]; then
  take_over
  exit 0
fi

# Keep the old reference so a failed start can be undone on this host alone.
PREVIOUS_IMAGE="${CURRENT_IMAGE}"

sed -i.bak "s|^KUBEDOK_IMAGE_AGENT=.*|KUBEDOK_IMAGE_AGENT=${NEW_IMAGE}|" "${AGENT_ENV}"
sed -i.bak "s|^KUBEDOK_AGENT_RELEASE=.*|KUBEDOK_AGENT_RELEASE=${NEW_AGENT}|" "${AGENT_ENV}"
rm -f "${AGENT_ENV}.bak"

log "Restarting the agent"
# shellcheck disable=SC2046
$(compose_cmd) --env-file "${AGENT_ENV}" -f "${AGENT_COMPOSE}" up -d

sleep 6
state="$(docker inspect -f '{{.State.Status}}' kubedok-agent 2>/dev/null || echo missing)"
if [ "${state}" != "running" ]; then
  err "The agent did not start on ${NEW_AGENT} (state: ${state}). Reverting."
  docker logs --tail 30 kubedok-agent 2>&1 | sed 's/^/      /' >&2 || true
  sed -i "s|^KUBEDOK_IMAGE_AGENT=.*|KUBEDOK_IMAGE_AGENT=${PREVIOUS_IMAGE}|" "${AGENT_ENV}"
  sed -i "s|^KUBEDOK_AGENT_RELEASE=.*|KUBEDOK_AGENT_RELEASE=${CURRENT_AGENT}|" "${AGENT_ENV}"
  # shellcheck disable=SC2046
  $(compose_cmd) --env-file "${AGENT_ENV}" -f "${AGENT_COMPOSE}" up -d
  die "Reverted to ${CURRENT_AGENT}."
fi

ok "Agent updated to ${NEW_AGENT}"
