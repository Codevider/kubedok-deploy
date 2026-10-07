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
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

AGENT_ROOT="${KUBEDOK_AGENT_ROOT:-/opt/kubedok-agent}"
RELEASE_REF=""
CHECK_ONLY=false

while [ $# -gt 0 ]; do
  case "$1" in
    --release) RELEASE_REF="$2"; shift 2 ;;
    --check) CHECK_ONLY=true; shift ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_root
require_cmd docker curl jq

[ -f "${AGENT_ROOT}/agent.env" ] \
  || die "No agent is installed at ${AGENT_ROOT}. Install one with agent-install.sh."

# shellcheck disable=SC1091
set -a; . "${AGENT_ROOT}/agent.env"; set +a

CURRENT_AGENT="${KUBEDOK_AGENT_RELEASE:-unknown}"
CURRENT_IMAGE="${KUBEDOK_IMAGE_AGENT:-}"

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
trap 'rm -f "${MANIFEST}"' EXIT
resolve_manifest "${RELEASE_REF}" "${MANIFEST}" >/dev/null

NEW_RELEASE="$(manifest_field release "${MANIFEST}")"
NEW_AGENT="$(manifest_field agentVersion "${MANIFEST}")"
NEW_IMAGE="$(manifest_image agent "${MANIFEST}")"
MIN_AGENT="$(manifest_field minimumAgentVersion "${MANIFEST}")"

printf '\n'
printf '  Installed agent   %s\n' "${CURRENT_AGENT}"
printf '  Target agent      %s  (release %s)\n' "${NEW_AGENT}" "${NEW_RELEASE}"
printf '  Compatibility     server requires agent >= %s\n' "${MIN_AGENT}"
printf '\n'

if [ "${CURRENT_IMAGE}" = "${NEW_IMAGE}" ]; then
  ok "Already on agent ${NEW_AGENT}. Nothing to do."
  exit 0
fi

if [ "${CHECK_ONLY}" = "true" ]; then
  printf '  An update is available. Run without --check to apply.\n\n'
  exit 0
fi

log "Pulling ${NEW_IMAGE}"
docker pull -q "${NEW_IMAGE}" >/dev/null || die "Could not pull ${NEW_IMAGE}"

# Keep the old reference so a failed start can be undone on this host alone.
PREVIOUS_IMAGE="${CURRENT_IMAGE}"

sed -i.bak "s|^KUBEDOK_IMAGE_AGENT=.*|KUBEDOK_IMAGE_AGENT=${NEW_IMAGE}|" "${AGENT_ROOT}/agent.env"
sed -i.bak "s|^KUBEDOK_AGENT_RELEASE=.*|KUBEDOK_AGENT_RELEASE=${NEW_AGENT}|" "${AGENT_ROOT}/agent.env"
rm -f "${AGENT_ROOT}/agent.env.bak"

log "Restarting the agent"
# shellcheck disable=SC2046
$(compose_cmd) --env-file "${AGENT_ROOT}/agent.env" -f "${AGENT_ROOT}/docker-compose.yml" up -d

sleep 6
state="$(docker inspect -f '{{.State.Status}}' kubedok-agent 2>/dev/null || echo missing)"
if [ "${state}" != "running" ]; then
  err "The agent did not start on ${NEW_AGENT} (state: ${state}). Reverting."
  docker logs --tail 30 kubedok-agent 2>&1 | sed 's/^/      /' >&2 || true
  sed -i "s|^KUBEDOK_IMAGE_AGENT=.*|KUBEDOK_IMAGE_AGENT=${PREVIOUS_IMAGE}|" "${AGENT_ROOT}/agent.env"
  sed -i "s|^KUBEDOK_AGENT_RELEASE=.*|KUBEDOK_AGENT_RELEASE=${CURRENT_AGENT}|" "${AGENT_ROOT}/agent.env"
  # shellcheck disable=SC2046
  $(compose_cmd) --env-file "${AGENT_ROOT}/agent.env" -f "${AGENT_ROOT}/docker-compose.yml" up -d
  die "Reverted to ${CURRENT_AGENT}."
fi

ok "Agent updated to ${NEW_AGENT}"
