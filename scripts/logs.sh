#!/usr/bin/env bash
#
# Tail logs for one component, or all of them interleaved.
#
#   kbd logs                 # all components, following
#   kbd logs server          # one component
#   kbd logs server -n 200   # last 200 lines
#   kbd logs nginx --no-follow
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

require_installed
require_cmd docker

COMPONENT="all"
LINES=100
FOLLOW=true

while [ $# -gt 0 ]; do
  case "$1" in
    postgres|server|nginx|agent|all) COMPONENT="$1"; shift ;;
    -n|--lines) LINES="$2"; shift 2 ;;
    --no-follow) FOLLOW=false; shift ;;
    -h|--help) sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1. Expected one of: postgres, server, nginx, agent, all." ;;
  esac
done

args=(--tail "${LINES}")
[ "${FOLLOW}" = "true" ] && args+=(--follow)

if [ "${COMPONENT}" = "all" ]; then
  names=()
  for n in kubedok-postgres kubedok-server kubedok-nginx kubedok-agent; do
    docker inspect "${n}" >/dev/null 2>&1 && names+=("${n}")
  done
  [ ${#names[@]} -gt 0 ] || die "No Kubedok containers exist yet."
  # `docker logs` handles one container at a time, so fan out and prefix.
  pids=()
  for n in "${names[@]}"; do
    ( docker logs "${args[@]}" "${n}" 2>&1 | sed "s/^/[${n#kubedok-}] /" ) &
    pids+=("$!")
  done
  trap 'kill "${pids[@]}" 2>/dev/null || true' INT TERM EXIT
  wait
else
  name="kubedok-${COMPONENT}"
  docker inspect "${name}" >/dev/null 2>&1 || die "Container ${name} does not exist."
  exec docker logs "${args[@]}" "${name}"
fi
