#!/usr/bin/env bash
#
# Restart one component, or everything in dependency order.
#
#   restart.sh            # all, in order: postgres → server → nginx
#   restart.sh server
#   restart.sh nginx
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

require_root
require_installed
require_cmd docker
load_config

COMPONENT="${1:-all}"

restart_one() {
  local project="$1" container="kubedok-$1" timeout="$2"
  log "Restarting ${project}"
  compose "${project}" up -d --force-recreate
  if wait_for_container_health "${container}" "${timeout}"; then
    ok "${project} is healthy"
  else
    die "${project} did not become healthy. Check: docker logs ${container}"
  fi
}

# The agent is its own install, with its own settings and image pin in
# agent.env. Recreating it from the control plane's compose.env instead gave
# it the release's agent image and dropped its API URL and host address.
AGENT_ENV="${KUBEDOK_AGENT_ROOT}/agent.env"
restart_agent() {
  log "Restarting agent"
  # shellcheck disable=SC2046
  $(compose_cmd) --env-file "${AGENT_ENV}" -f "${KUBEDOK_AGENT_ROOT}/docker-compose.yml" \
    up -d --force-recreate
  ok "agent restarted"
}

case "${COMPONENT}" in
  postgres) restart_one postgres 180 ;;
  server)   restart_one server 300 ;;
  nginx)    restart_one nginx 120 ;;
  agent)
    [ -f "${AGENT_ENV}" ] || die "No agent is installed on this host (${AGENT_ENV} does not exist)."
    restart_agent
    ;;
  all)
    # Order matters: the server waits on the database, nginx proxies the server.
    restart_one postgres 180
    restart_one server 300
    restart_one nginx 120
    if [ -f "${AGENT_ENV}" ]; then
      restart_agent
    fi
    if wait_for_http "$(local_base_url)/api/health" 60; then
      ok "API is responding at $(local_base_url)"
    else
      warn "Containers are up but /api/health is not responding yet."
    fi
    ;;
  -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "Unknown component: ${COMPONENT}. Expected one of: postgres, server, nginx, agent, all." ;;
esac
