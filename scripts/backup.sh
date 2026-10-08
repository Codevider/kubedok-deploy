#!/usr/bin/env bash
#
# Back up the database, the deployment secrets, and the configuration.
#
#   kbd backup                     # timestamped backup
#   kbd backup --label pre-upgrade # add a label to the filename
#   kbd backup --quiet             # print only the resulting path
#
# The secrets are in the archive on purpose: a database restored without
# registry-encryption-key leaves every stored registry credential and
# certificate permanently undecryptable. That makes the archive as sensitive
# as the database itself — it is written 0600 into a 0700 directory.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

LABEL=""
QUIET=false

while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    --quiet|-q) QUIET=true; shift ;;
    -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

say() { [ "${QUIET}" = "true" ] || log "$@"; }
say_ok() { [ "${QUIET}" = "true" ] || ok "$@"; }

require_root
require_installed
require_cmd docker
load_config

PG_USER="${KUBEDOK_POSTGRES_USER:-kubedok}"
PG_DB="${KUBEDOK_POSTGRES_DB:-kubedok}"

docker inspect kubedok-postgres >/dev/null 2>&1 \
  || die "The kubedok-postgres container does not exist. Nothing to back up."

[ "$(docker inspect -f '{{.State.Running}}' kubedok-postgres)" = "true" ] \
  || die "kubedok-postgres is not running. Start it first: $(command_hint restart) postgres"

mkdir -p "${KUBEDOK_BACKUPS_DIR}"
chmod 700 "${KUBEDOK_BACKUPS_DIR}"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="kubedok-${TIMESTAMP}${LABEL:+-${LABEL}}"
STAGE="$(mktemp -d)"
ARCHIVE="${KUBEDOK_BACKUPS_DIR}/${NAME}.tar.gz"

cleanup() { rm -rf "${STAGE}"; }
trap cleanup EXIT

say "Dumping ${PG_DB}"
# Runs inside the container over the local socket, which the image trusts, so
# no password has to cross the command line.
if ! docker exec kubedok-postgres pg_dump -U "${PG_USER}" --clean --if-exists "${PG_DB}" > "${STAGE}/database.sql" 2>"${STAGE}/pg_dump.err"; then
  err "pg_dump failed:"
  sed 's/^/      /' "${STAGE}/pg_dump.err" >&2
  die "Backup aborted."
fi
rm -f "${STAGE}/pg_dump.err"
say_ok "Database dumped ($(du -h "${STAGE}/database.sql" | cut -f1))"

say "Collecting secrets and configuration"
mkdir -p "${STAGE}/secrets" "${STAGE}/config"
cp -a "${KUBEDOK_SECRETS_DIR}/." "${STAGE}/secrets/" 2>/dev/null || true
[ -f "${KUBEDOK_CONFIG_FILE}" ] && cp -a "${KUBEDOK_CONFIG_FILE}" "${STAGE}/config/"
CURRENT="$(current_release 2>/dev/null || echo unknown)"
[ -f "${KUBEDOK_CURRENT_LINK}/release.json" ] \
  && cp -a "${KUBEDOK_CURRENT_LINK}/release.json" "${STAGE}/release.json"

cat > "${STAGE}/backup.json" <<JSON
{
  "schemaVersion": 1,
  "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "release": "${CURRENT}",
  "label": "${LABEL}",
  "postgresUser": "${PG_USER}",
  "postgresDb": "${PG_DB}",
  "contains": ["database.sql", "secrets", "config", "release.json"]
}
JSON

say "Writing ${ARCHIVE}"
( umask 077; tar -czf "${ARCHIVE}" -C "${STAGE}" . )
chmod 600 "${ARCHIVE}"

# Keep a bounded history so backups cannot fill the disk silently.
KEEP="${KUBEDOK_KEEP_BACKUPS:-10}"
mapfile -t existing < <(find "${KUBEDOK_BACKUPS_DIR}" -maxdepth 1 -name 'kubedok-*.tar.gz' -printf '%f\n' | sort)
if [ "${#existing[@]}" -gt "${KEEP}" ]; then
  for old in "${existing[@]:0:$(( ${#existing[@]} - KEEP ))}"; do
    rm -f "${KUBEDOK_BACKUPS_DIR:?}/${old}"
    [ "${QUIET}" = "true" ] || debug "pruned old backup ${old}"
  done
fi

if [ "${QUIET}" = "true" ]; then
  printf '%s' "${ARCHIVE}"
else
  ok "Backup complete: ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
  warn "This archive contains secrets. Store it as securely as the database."
fi
