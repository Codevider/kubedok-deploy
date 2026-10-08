#!/usr/bin/env bash
#
# Kubedok updater.
#
#   sudo /opt/kubedok/current/scripts/update.sh           # latest on the configured channel
#   sudo /opt/kubedok/current/scripts/update.sh 1.3.0     # a specific release
#   sudo /opt/kubedok/current/scripts/update.sh --check   # report only, change nothing
#   sudo /opt/kubedok/current/scripts/update.sh --force   # also when already on it: pull, recreate
#
# Every release tree carries its own copy beside common.sh. From a clone of
# the repository, ./update.sh at its root works the same way.
#
# Order of operations is deliberate: back up before pulling, update the server
# before nginx, and only record the new release as current once it has served
# real traffic through the proxy. `current` moving is the commit point. A run
# that fails before it leaves releases/ and `previous` exactly as they were.
#
# Rollback caveat: rolling an image back does NOT roll back a database
# migration. See https://github.com/glikaj/kubedok/blob/main/docs/release-process.md
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap: common.sh is under scripts/ in the repository, and beside this
# script once installed.
if [ -f "${SCRIPT_DIR}/scripts/common.sh" ]; then
  # shellcheck source=scripts/common.sh
  . "${SCRIPT_DIR}/scripts/common.sh"
elif [ -f "${SCRIPT_DIR}/common.sh" ]; then
  # shellcheck source=scripts/common.sh
  . "${SCRIPT_DIR}/common.sh"
else
  echo "Cannot find common.sh beside update.sh or in scripts/ next to it" >&2
  exit 1
fi

CHECK_ONLY=false
FORCE=false
TARGET_REF=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=true; shift ;;
    -f|--force) FORCE=true; shift ;;
    -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *) TARGET_REF="$1"; shift ;;
  esac
done

require_root "$@"
require_installed
require_cmd docker curl jq openssl flock
load_config

TARGET_REF="${TARGET_REF:-${KUBEDOK_RELEASE:-stable}}"

# ── 1. Lock ──────────────────────────────────────────────────────────────────
acquire_lock 600

# However the run ends, it leaves no staged tree or temporary file behind. Set
# only once the lock is held, so the staging area is this run's alone; it also
# clears whatever a run killed outright (SIGKILL, power loss) left in it.
NEW_MANIFEST_TMP=""
PREVIOUS_COMPOSE_ENV=""
discard_leftovers() {
  rm -rf "${KUBEDOK_STAGING_DIR:?}" 2>/dev/null || true
  rm -f "${NEW_MANIFEST_TMP}" "${PREVIOUS_COMPOSE_ENV}" 2>/dev/null || true
}
trap discard_leftovers EXIT

# ── 2. Current release ───────────────────────────────────────────────────────
CURRENT_VERSION="$(current_release || true)"
[ -n "${CURRENT_VERSION}" ] || die "No current release is recorded. Is this a complete install?"
CURRENT_MANIFEST="${KUBEDOK_RELEASES_DIR}/${CURRENT_VERSION}/release.json"
log "Installed release: ${CURRENT_VERSION}"

# ── 3 + 4. Resolve and validate the target ───────────────────────────────────
log "Resolving '${TARGET_REF}'"
NEW_MANIFEST_TMP="$(mktemp)"
resolve_manifest "${TARGET_REF}" "${NEW_MANIFEST_TMP}" >/dev/null
NEW_VERSION="$(manifest_field release "${NEW_MANIFEST_TMP}")"

# --force installs the installed release again, through every step below: the
# backup, the pull, the smoke tests, and a restore when they fail. Its manifest
# is fetched afresh, so a version published again since is installed with its
# new images; with the same images, the server and nginx are recreated anyway.
REINSTALL=false
if [ "${NEW_VERSION}" = "${CURRENT_VERSION}" ]; then
  if [ "${FORCE}" != "true" ]; then
    ok "Already on ${CURRENT_VERSION}. Nothing to do. --force installs it again."
    exit 0
  fi
  REINSTALL=true
  republished=""
  for component in server nginx postgres; do
    if [ "$(jq -r --arg c "${component}" '.images[$c]' "${CURRENT_MANIFEST}")" \
         != "$(manifest_image "${component}" "${NEW_MANIFEST_TMP}")" ]; then
      republished="${republished:+${republished}, }${component}"
    fi
  done
  if [ -n "${republished}" ]; then
    log "Installing ${CURRENT_VERSION} again: it was published again since, with new images for ${republished}"
  else
    log "Installing ${CURRENT_VERSION} again, with the same images"
  fi
else
  log "Target release: ${NEW_VERSION}"
fi

# Refuse a downgrade unless it is asked for explicitly by version, because a
# downgrade cannot undo migrations the newer release already applied.
if ! semver_ge "${NEW_VERSION}" "${CURRENT_VERSION}"; then
  if is_semver "${TARGET_REF}"; then
    warn "${NEW_VERSION} is older than the installed ${CURRENT_VERSION}."
    warn "Database migrations already applied by ${CURRENT_VERSION} will NOT be reverted."
    warn "Use rollback.sh instead unless you know the schema is compatible."
  else
    die "Channel '${TARGET_REF}' offers ${NEW_VERSION}, which is older than the installed ${CURRENT_VERSION}. Refusing."
  fi
fi

# Too-large a jump: the intermediate release contains migrations this one
# assumes have already run. A release that names itself as the floor starts a
# new baseline, which no earlier install can update to at all.
MIN_FROM="$(manifest_field minimumUpgradeFrom "${NEW_MANIFEST_TMP}")"
if ! semver_ge "${CURRENT_VERSION}" "${MIN_FROM}"; then
  if [ "${MIN_FROM}" = "${NEW_VERSION}" ]; then
    die "Cannot update ${CURRENT_VERSION} → ${NEW_VERSION}. ${NEW_VERSION} starts a new baseline that no earlier release updates to: it is only installed fresh, on an empty database."
  fi
  die "Cannot update ${CURRENT_VERSION} → ${NEW_VERSION} directly. That release requires at least ${MIN_FROM} installed first. Update to ${MIN_FROM} and try again."
fi

# PostgreSQL major upgrades need a dump and reload, never an image swap.
CURRENT_PG_MAJOR="$(jq -r '.postgresMajor' "${CURRENT_MANIFEST}" 2>/dev/null || echo "")"
NEW_PG_MAJOR="$(manifest_field postgresMajor "${NEW_MANIFEST_TMP}")"
if [ -n "${CURRENT_PG_MAJOR}" ] && [ "${CURRENT_PG_MAJOR}" != "${NEW_PG_MAJOR}" ]; then
  die "Release ${NEW_VERSION} expects PostgreSQL ${NEW_PG_MAJOR}, but this install runs ${CURRENT_PG_MAJOR}.
    A major-version upgrade requires a dump and reload and is deliberately not
    automated here. Back up first, then follow the PostgreSQL upgrade section
    in https://github.com/glikaj/kubedok/blob/main/docs/infrastructure.md."
fi

if [ "${CHECK_ONLY}" = "true" ]; then
  printf '\n'
  printf '  Installed : %s\n' "${CURRENT_VERSION}"
  printf '  Available : %s  (published %s)\n' "${NEW_VERSION}" "$(manifest_field publishedAt "${NEW_MANIFEST_TMP}")"
  printf '  Notes     : %s\n' "$(jq -r '.notes // "—"' "${NEW_MANIFEST_TMP}")"
  printf '\n  Run without --check to apply.\n\n'
  exit 0
fi

# Agents older than the new floor keep running but stop being supported.
report_outdated_agents() {
  local min_agent="$1"
  local base; base="$(local_base_url)"
  local versions
  versions="$(local_curl -fsS --max-time 10 "${base}/api/health" >/dev/null 2>&1 && echo ok || echo unreachable)"
  [ "${versions}" = "ok" ] || return 0
  warn "After this update, agents older than ${min_agent} are unsupported."
  warn "Update them with: $(command_hint agent-update)"
}
report_outdated_agents "$(manifest_field minimumAgentVersion "${NEW_MANIFEST_TMP}")"

# ── 5. Back up ───────────────────────────────────────────────────────────────
log "Backing up before changing anything"
BACKUP_PATH=""
if [ -x "${KUBEDOK_CURRENT_LINK}/scripts/backup.sh" ]; then
  BACKUP_PATH="$("${KUBEDOK_CURRENT_LINK}/scripts/backup.sh" --label "pre-update-${NEW_VERSION}" --quiet)" \
    || die "Backup failed. Refusing to update. Fix the backup first — an update without one is not recoverable."
  ok "Backup: ${BACKUP_PATH}"
else
  die "backup.sh is missing from the current release. Refusing to update without a backup."
fi

# ── Stage the new release tree ───────────────────────────────────────────────
# Built outside releases/: until the commit, nothing that lists releases
# (rollback.sh, the pruning below) can see it, and a tree already on disk for
# this version, kept from an earlier install of it, stays untouched. A failed
# run discards it on the way out; the commit moves it into releases/.
NEW_RELEASE_DIR="${KUBEDOK_RELEASES_DIR}/${NEW_VERSION}"
STAGED_DIR="${KUBEDOK_STAGING_DIR}/${NEW_VERSION}"
log "Staging ${NEW_VERSION}"
rm -rf "${KUBEDOK_STAGING_DIR:?}"
mkdir -p "${STAGED_DIR}/compose" "${STAGED_DIR}/scripts"
mv "${NEW_MANIFEST_TMP}" "${STAGED_DIR}/release.json"
chmod 644 "${STAGED_DIR}/release.json"

# Every file is required, scripts included: a tree without cert-renew.sh
# stops renewing its certificate, one without backup.sh refuses the next
# update. fetch_url exits on a failure, and the staged tree goes with it.
for file in postgres.yml postgres.public.yml server.yml nginx.yml agent.yml; do
  fetch_url "${KUBEDOK_RELEASE_BASE_URL}/compose/${file}" "${STAGED_DIR}/compose/${file}"
done
for file in common.sh doctor.sh backup.sh restore.sh status.sh logs.sh restart.sh \
            config.sh rollback.sh agent-install.sh agent-update.sh cert-renew.sh uninstall.sh kbd; do
  fetch_url "${KUBEDOK_RELEASE_BASE_URL}/scripts/${file}" "${STAGED_DIR}/scripts/${file}"
  chmod 755 "${STAGED_DIR}/scripts/${file}"
done
# The updater is published at the repository root and installed beside
# common.sh, so the next update runs the copy that came with this release.
fetch_url "${KUBEDOK_RELEASE_BASE_URL}/update.sh" "${STAGED_DIR}/scripts/update.sh"
chmod 755 "${STAGED_DIR}/scripts/update.sh"
ok "Release tree staged"

# Drive the staged compose files while `current` still points at the old
# release, so a failure leaves a consistent install behind.
export KUBEDOK_COMPOSE_DIR="${STAGED_DIR}/compose"

PREVIOUS_COMPOSE_ENV="$(mktemp)"
cp "$(compose_env_file)" "${PREVIOUS_COMPOSE_ENV}"

restore_previous() {
  err "Update failed — restoring ${CURRENT_VERSION}"
  cp "${PREVIOUS_COMPOSE_ENV}" "$(compose_env_file)"
  export KUBEDOK_COMPOSE_DIR="${KUBEDOK_RELEASES_DIR}/${CURRENT_VERSION}/compose"
  compose server up -d >/dev/null 2>&1 || true
  compose nginx up -d >/dev/null 2>&1 || true
  err "Containers restored to ${CURRENT_VERSION}."
  err "The database was NOT rolled back. If ${NEW_VERSION} applied migrations,"
  err "restore the backup explicitly: $(command_hint restore) ${BACKUP_PATH}"
  exit 1
}

# ── 6. Pull exact digests ────────────────────────────────────────────────────
log "Pulling ${NEW_VERSION} images"
for component in postgres server nginx; do
  ref="$(manifest_image "${component}" "${STAGED_DIR}/release.json")"
  docker pull -q "${ref}" >/dev/null || die "Could not pull ${component}: ${ref}. Nothing has changed yet."
  ok "Pulled ${component}"
done

write_compose_env "${STAGED_DIR}/release.json" >/dev/null

# PostgreSQL only restarts when its digest actually changed, so a routine
# application update does not bounce the database.
CURRENT_PG_IMAGE="$(jq -r '.images.postgres' "${CURRENT_MANIFEST}" 2>/dev/null || echo "")"
NEW_PG_IMAGE="$(manifest_image postgres "${STAGED_DIR}/release.json")"
if [ "${CURRENT_PG_IMAGE}" != "${NEW_PG_IMAGE}" ]; then
  log "PostgreSQL image changed — restarting the database"
  compose postgres up -d || restore_previous
  wait_for_container_health kubedok-postgres 180 || restore_previous
  ok "PostgreSQL healthy"
else
  debug "PostgreSQL image unchanged, leaving it running"
fi

# Compose leaves a container alone when nothing about it changed, which
# --force is asked to override. The database keeps the rule above.
RECREATE=()
if [ "${FORCE}" = "true" ]; then
  RECREATE=(--force-recreate)
fi

# ── 7 + 8. Server first ──────────────────────────────────────────────────────
log "Updating the server"
compose server up -d ${RECREATE[@]+"${RECREATE[@]}"} || restore_previous
wait_for_container_health kubedok-server 300 || restore_previous

if ! wait_for_http "$(local_base_url)/api/health" 120; then
  err "/api/health did not respond after the server update"
  restore_previous
fi
ok "Server ${NEW_VERSION} is healthy"

# ── 9. nginx ─────────────────────────────────────────────────────────────────
log "Updating nginx"
compose nginx up -d ${RECREATE[@]+"${RECREATE[@]}"} || restore_previous
wait_for_container_health kubedok-nginx 120 || restore_previous
ok "nginx updated"

# ── 10. Smoke tests through the proxy ────────────────────────────────────────
log "Running smoke tests through nginx"
BASE="$(local_base_url)"

if ! wait_for_http "${BASE}/api/health" 60; then
  err "Smoke test failed: ${BASE}/api/health"
  restore_previous
fi
ok "  /api/health responds"

REPORTED="$(local_curl -fsS --max-time 10 "${BASE}/api/version" | jq -r '.release // empty' 2>/dev/null || true)"
if [ "${REPORTED}" != "${NEW_VERSION}" ]; then
  err "Smoke test failed: /api/version reports '${REPORTED}', expected '${NEW_VERSION}'"
  restore_previous
fi
ok "  /api/version reports ${NEW_VERSION}"

if ! local_curl -fsS --max-time 10 -o /dev/null "${BASE}/"; then
  err "Smoke test failed: the web UI is not being served at ${BASE}/"
  restore_previous
fi
ok "  web UI is served"

DB_STATUS="$(local_curl -fsS --max-time 10 "${BASE}/api/health" | jq -r '.database // empty' 2>/dev/null || true)"
if [ "${DB_STATUS}" != "connected" ]; then
  err "Smoke test failed: database reports '${DB_STATUS}'"
  restore_previous
fi
ok "  database is connected"

# ── 11. Commit ───────────────────────────────────────────────────────────────
# The staged tree takes its place in releases/, replacing one already there
# for this version; the replaced one is set aside in the staging area, which
# goes on exit. Then `previous` moves before `current`: an interruption between
# the two leaves rollback.sh nothing to do, rather than a target one release
# further back than the operator expects.
#
# Installed again, the replaced tree is the one `current` names, which points
# at nothing between the two moves. The lock keeps the other lifecycle scripts
# out meanwhile, and `previous` stays where it was: the release before this one.
if [ -e "${NEW_RELEASE_DIR}" ]; then
  mv "${NEW_RELEASE_DIR}" "${KUBEDOK_STAGING_DIR}/replaced-${NEW_VERSION}"
fi
mv "${STAGED_DIR}" "${NEW_RELEASE_DIR}"
# compose.env names the manifest it was generated from: name the one that stays.
write_compose_env "${NEW_RELEASE_DIR}/release.json" >/dev/null
if [ "${REINSTALL}" != "true" ]; then
  set_previous_release "${CURRENT_VERSION}"
fi
set_current_release "${NEW_VERSION}"
set_config KUBEDOK_RELEASE "${TARGET_REF}"
ok "Recorded ${NEW_VERSION} as current"
# An install set up before the kbd command existed gets it here.
install_kbd_link

# ── 12. Keep the previous release for rollback, prune older ones ─────────────
KEEP="${KUBEDOK_KEEP_RELEASES:-3}"
mapfile -t all_releases < <(list_releases)
if [ "${#all_releases[@]}" -gt "${KEEP}" ]; then
  prune_count=$(( ${#all_releases[@]} - KEEP ))
  for old in "${all_releases[@]:0:${prune_count}}"; do
    [ "${old}" = "${NEW_VERSION}" ] && continue
    [ "${old}" = "${CURRENT_VERSION}" ] && continue
    rm -rf "${KUBEDOK_RELEASES_DIR:?}/${old}"
    debug "pruned old release tree ${old}"
  done
fi

printf '\n'
if [ "${REINSTALL}" = "true" ]; then
  ok "Installed ${NEW_VERSION} again"
  printf '\n'
  if ROLLBACK_TARGET="$(previous_release)"; then
    printf '  Rollback     %s  (back to %s)\n' "$(command_hint rollback)" "${ROLLBACK_TARGET}"
  fi
else
  ok "Updated ${CURRENT_VERSION} → ${NEW_VERSION}"
  printf '\n'
  printf '  Rollback     %s  (back to %s)\n' "$(command_hint rollback)" "${CURRENT_VERSION}"
fi
printf '  Backup taken %s\n' "${BACKUP_PATH}"
printf '  Status       %s\n' "$(command_hint status)"
printf '\n'
