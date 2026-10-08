#!/usr/bin/env bash
#
# Roll the server and nginx back to the previously installed release.
#
#   rollback.sh            # undo the last update: back to the release it replaced
#   rollback.sh 1.2.0      # to a specific release still on disk
#   rollback.sh --list     # the releases on disk, current and previous marked
#
# With no version, the target is `previous`, which update.sh records as it
# commits. A rollback clears it, so a second rollback never rolls forward to
# the release the first one left; name a version, or update, to move on.
#
# This rolls back CONTAINERS ONLY. Database migrations applied by the newer
# release are NOT reverted — that is why migrations must be expand/contract
# and why destructive changes never ship alongside the code that needs them.
# If the schema is genuinely incompatible, restore a backup instead.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

TARGET=""
ASSUME_YES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=true; shift ;;
    --list)
      cur="$(current_release 2>/dev/null || true)"
      prev="$(previous_release 2>/dev/null || true)"
      list_releases | while read -r rel; do
        if [ "${rel}" = "${cur}" ]; then
          printf '%s  current\n' "${rel}"
        elif [ "${rel}" = "${prev}" ]; then
          printf '%s  previous (rollback.sh with no version goes back to it)\n' "${rel}"
        else
          printf '%s\n' "${rel}"
        fi
      done
      exit 0 ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *) TARGET="$1"; shift ;;
  esac
done

require_root
require_installed
require_cmd docker jq
load_config
acquire_lock 300

CURRENT_VERSION="$(current_release || true)"
[ -n "${CURRENT_VERSION}" ] || die "No current release recorded."

if [ -z "${TARGET}" ]; then
  TARGET="$(previous_release || true)"
  [ -n "${TARGET}" ] || die "No previous release is recorded. update.sh records the release it replaces, and a rollback clears that record. To go to a release on disk, name it: $(command_hint rollback) <version> (--list shows them)."
fi
[ "${TARGET}" != "${CURRENT_VERSION}" ] || die "${TARGET} is already the current release."

TARGET_DIR="${KUBEDOK_RELEASES_DIR}/${TARGET}"
[ -f "${TARGET_DIR}/release.json" ] \
  || die "Release ${TARGET} is not on disk (looked for ${TARGET_DIR}/release.json). Available: $(list_releases | tr '\n' ' ')"

printf '\n'
printf '  Rolling back  %s → %s\n' "${CURRENT_VERSION}" "${TARGET}"
printf '\n'
warn "Containers roll back. The database schema does NOT."
warn "If ${CURRENT_VERSION} applied a migration ${TARGET} cannot read, this will not start."
printf '\n'

if [ "${ASSUME_YES}" != "true" ]; then
  printf '  Continue? [y/N] '
  read -r answer
  case "${answer}" in y|Y|yes|YES) ;; *) die "Aborted." ;; esac
fi

log "Backing up before rolling back"
BACKUP_PATH="$("${SCRIPT_DIR}/backup.sh" --label "pre-rollback-${TARGET}" --quiet)" \
  || die "Backup failed. Refusing to roll back without one."
ok "Backup: ${BACKUP_PATH}"

export KUBEDOK_COMPOSE_DIR="${TARGET_DIR}/compose"
write_compose_env "${TARGET_DIR}/release.json" >/dev/null

log "Pulling ${TARGET} images"
for component in server nginx; do
  ref="$(manifest_image "${component}" "${TARGET_DIR}/release.json")"
  docker pull -q "${ref}" >/dev/null || die "Could not pull ${component}: ${ref}"
done

log "Starting ${TARGET}"
compose server up -d
if ! wait_for_container_health kubedok-server 300; then
  err "The server did not come up on ${TARGET}."
  err "The schema may be incompatible. Restore a backup taken on ${TARGET}:"
  err "  $(command_hint restore) --list"
  exit 1
fi

compose nginx up -d
wait_for_container_health kubedok-nginx 120 || die "nginx did not come up on ${TARGET}."

if ! wait_for_http "$(local_base_url)/api/health" 90; then
  die "Rolled back, but /api/health is not responding. Check: docker logs kubedok-server"
fi

set_current_release "${TARGET}"
clear_previous_release
ok "Rolled back to ${TARGET}"
printf '\n  Backup of the pre-rollback state: %s\n\n' "${BACKUP_PATH}"
