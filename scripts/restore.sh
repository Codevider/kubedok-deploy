#!/usr/bin/env bash
#
# Restore a Kubedok backup. Destructive and deliberately awkward.
#
#   kbd restore /opt/kubedok/backups/kubedok-20260115T103000Z.tar.gz
#   kbd restore --latest
#   kbd restore --list
#
# This replaces the current database contents. It stops the server first so
# nothing writes during the restore, and it takes a safety backup of what is
# there now before overwriting it.
#
# The archive's secrets replace this install's, so the data's encrypted
# fields stay readable, except postgres-password: the database here was
# created with this install's, and a dump carries no roles to change it.
# --keep-current-secrets keeps them all.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

ARCHIVE=""
ASSUME_YES=false
RESTORE_SECRETS=true

while [ $# -gt 0 ]; do
  case "$1" in
    --latest)
      ARCHIVE="$(find "${KUBEDOK_BACKUPS_DIR}" -maxdepth 1 -name 'kubedok-*.tar.gz' | sort | tail -n1)"
      [ -n "${ARCHIVE}" ] || die "No backups found in ${KUBEDOK_BACKUPS_DIR}"
      shift ;;
    --list)
      find "${KUBEDOK_BACKUPS_DIR}" -maxdepth 1 -name 'kubedok-*.tar.gz' -printf '%TY-%Tm-%Td %TH:%TM  %10s  %p\n' 2>/dev/null | sort
      exit 0 ;;
    --yes|-y) ASSUME_YES=true; shift ;;
    --keep-current-secrets) RESTORE_SECRETS=false; shift ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *) ARCHIVE="$1"; shift ;;
  esac
done

require_root
require_installed
require_cmd docker tar
load_config
acquire_lock 300

[ -n "${ARCHIVE}" ] || die "Which backup? Pass a path, or --latest. List them with --list."
[ -f "${ARCHIVE}" ] || die "Backup not found: ${ARCHIVE}"

PG_USER="${KUBEDOK_POSTGRES_USER:-kubedok}"
PG_DB="${KUBEDOK_POSTGRES_DB:-kubedok}"

STAGE="$(mktemp -d)"
cleanup() { rm -rf "${STAGE}"; }
trap cleanup EXIT

log "Reading ${ARCHIVE}"
tar -xzf "${ARCHIVE}" -C "${STAGE}"
[ -f "${STAGE}/database.sql" ] || die "Archive has no database.sql — is this a Kubedok backup?"

BACKUP_RELEASE="$(jq -r '.release // "unknown"' "${STAGE}/backup.json" 2>/dev/null || echo unknown)"
BACKUP_CREATED="$(jq -r '.createdAt // "unknown"' "${STAGE}/backup.json" 2>/dev/null || echo unknown)"
CURRENT_VERSION="$(current_release 2>/dev/null || echo unknown)"

printf '\n'
printf '  Archive        %s\n' "${ARCHIVE}"
printf '  Taken          %s\n' "${BACKUP_CREATED}"
printf '  From release   %s\n' "${BACKUP_RELEASE}"
printf '  Into release   %s\n' "${CURRENT_VERSION}"
printf '\n'

if [ "${BACKUP_RELEASE}" != "unknown" ] && [ "${CURRENT_VERSION}" != "unknown" ] \
   && [ "${BACKUP_RELEASE}" != "${CURRENT_VERSION}" ]; then
  warn "This backup came from ${BACKUP_RELEASE} but ${CURRENT_VERSION} is installed."
  if semver_ge "${CURRENT_VERSION}" "${BACKUP_RELEASE}"; then
    warn "Restoring an older schema under newer code. The server may fail to start."
    warn "Consider rolling back to ${BACKUP_RELEASE} first: $(command_hint rollback)"
  fi
  printf '\n'
fi

err "This ERASES the current contents of database '${PG_DB}'."
if [ "${ASSUME_YES}" != "true" ]; then
  printf '  Type the word RESTORE to continue: '
  read -r answer
  [ "${answer}" = "RESTORE" ] || die "Aborted."
fi

# Whatever is in the database right now is about to be destroyed, so capture
# it first — a restore of the wrong archive should still be recoverable.
log "Taking a safety backup of the current state"
SAFETY="$("${SCRIPT_DIR}/backup.sh" --label "pre-restore" --quiet)" \
  || warn "Safety backup failed — continuing because you asked for the restore."
[ -n "${SAFETY:-}" ] && ok "Safety backup: ${SAFETY}"

log "Stopping the server so nothing writes during the restore"
compose server stop >/dev/null 2>&1 || true

# `pg_dump --clean` only emits DROP statements for objects that were in the
# dump, so anything created after the backup would survive and leave a hybrid
# schema behind — precisely the wrong outcome when restoring after a bad
# update. Dropping the schema first makes the restore a true replace.
log "Resetting the public schema"
if ! docker exec -i kubedok-postgres psql -v ON_ERROR_STOP=1 -U "${PG_USER}" -d "${PG_DB}" \
     -c 'DROP SCHEMA IF EXISTS public CASCADE' \
     -c 'CREATE SCHEMA public' \
     > "${STAGE}/reset.log" 2>&1; then
  err "Could not reset the schema:"
  tail -20 "${STAGE}/reset.log" | sed 's/^/      /' >&2
  compose server start >/dev/null 2>&1 || true
  die "Restore aborted before any data was replaced. The safety backup is at ${SAFETY:-<none>}."
fi
ok "Schema reset"

log "Restoring the database"
if ! docker exec -i kubedok-postgres psql -v ON_ERROR_STOP=1 -U "${PG_USER}" -d "${PG_DB}" < "${STAGE}/database.sql" > "${STAGE}/restore.log" 2>&1; then
  err "Restore failed:"
  tail -30 "${STAGE}/restore.log" | sed 's/^/      /' >&2
  warn "Starting the server again so the install is not left down."
  compose server start >/dev/null 2>&1 || true
  die "Database restore aborted. The safety backup is at ${SAFETY:-<none>}."
fi
ok "Database restored"

if [ "${RESTORE_SECRETS}" = "true" ] && [ -d "${STAGE}/secrets" ]; then
  # The encryption key must match the data: rows encrypted under the backup's
  # registry-encryption-key cannot be read with the current one.
  #
  # postgres-password stays this install's. PostgreSQL takes the password only
  # when it creates its data directory, and a dump carries no roles, so the
  # database here still has this install's. Copying another install's over
  # it left the server logging in with a password the database refuses.
  log "Restoring secrets from the archive"
  ensure_secrets_dir
  restored=()
  for secret in "${STAGE}/secrets/"*; do
    name="$(basename "${secret}")"
    # Plain files only: an archive made elsewhere could hold a link.
    if [ "${name}" = "postgres-password" ] || [ ! -f "${secret}" ] || [ -L "${secret}" ]; then
      continue
    fi
    # Written over in place, owned by root, whatever the archive recorded.
    cp -- "${secret}" "${KUBEDOK_SECRETS_DIR}/${name}"
    chmod 600 "${KUBEDOK_SECRETS_DIR}/${name}"
    restored+=("${name}")
  done
  ok "Secrets restored: ${restored[*]:-none} (registry credentials stay decryptable)"
  if [ -f "${STAGE}/secrets/postgres-password" ] \
     && [ "$(cat "${STAGE}/secrets/postgres-password")" != "$(cat "${KUBEDOK_SECRETS_DIR}/postgres-password" 2>/dev/null)" ]; then
    ok "Kept this install's postgres-password: the archive's is for another database"
  fi
else
  warn "Keeping the current secrets. If registry-encryption-key differs from the"
  warn "one in the archive, stored registry credentials will not decrypt."
fi

log "Starting the server"
compose server up -d
wait_for_container_health kubedok-server 300 \
  || die "The server did not come back up. Check: docker logs kubedok-server"

if wait_for_http "$(local_base_url)/api/health" 60; then
  ok "Restore complete and the API is responding"
else
  warn "The server is running but /api/health is not responding yet."
fi

printf '\n'
[ -n "${SAFETY:-}" ] && printf '  Pre-restore snapshot: %s\n\n' "${SAFETY}"
