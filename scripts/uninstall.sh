#!/usr/bin/env bash
#
# Remove the Kubedok containers, networks, and installed release tree.
#
#   uninstall.sh                # keeps the database, secrets, and backups
#   uninstall.sh --purge-data   # ALSO deletes the database volume and secrets
#
# Data deletion is a separate, explicit flag. The default leaves everything
# recoverable: the PostgreSQL volume, /opt/kubedok/secrets, and the backups
# all survive, so re-running setup.sh brings the install straight back.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

PURGE_DATA=false
ASSUME_YES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --purge-data) PURGE_DATA=true; shift ;;
    --yes|-y) ASSUME_YES=true; shift ;;
    -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_root
require_cmd docker
load_config
acquire_lock 120

printf '\n'
if [ "${PURGE_DATA}" = "true" ]; then
  err 'This will PERMANENTLY DELETE:'
  printf '    • the PostgreSQL volume (kubedok_postgres_data) — all your data\n'
  printf '    • %s — including registry-encryption-key\n' "${KUBEDOK_SECRETS_DIR}"
  printf '    • %s — every backup\n' "${KUBEDOK_BACKUPS_DIR}"
  printf '\n'
  err 'Registry credentials and certificates will be unrecoverable.'
else
  printf '  This removes the containers, networks, and release tree.\n'
  printf '  KEPT: the database volume, secrets, backups, and TLS certificates.\n'
  printf '  Re-running setup.sh restores the install as it was.\n'
fi
printf '\n'

if [ "${ASSUME_YES}" != "true" ]; then
  if [ "${PURGE_DATA}" = "true" ]; then
    printf '  Type DELETE EVERYTHING to confirm: '
    read -r answer
    [ "${answer}" = "DELETE EVERYTHING" ] || die "Aborted."
  else
    printf '  Continue? [y/N] '
    read -r answer
    case "${answer}" in y|Y|yes|YES) ;; *) die "Aborted." ;; esac
  fi
fi

log "Stopping containers"
for project in agent nginx server postgres; do
  compose "${project}" down >/dev/null 2>&1 || true
done
for name in kubedok-agent kubedok-nginx kubedok-server kubedok-postgres; do
  docker rm -f "${name}" >/dev/null 2>&1 || true
done
ok "Containers removed"

log "Removing networks"
for net in "${KUBEDOK_NETWORK_PROXY}" "${KUBEDOK_NETWORK_DB}"; do
  docker network rm "${net}" >/dev/null 2>&1 || true
done
ok "Networks removed"

if command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now kubedok-cert-renew.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/kubedok-cert-renew.timer /etc/systemd/system/kubedok-cert-renew.service
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

log "Removing release tree"
remove_kbd_link
rm -rf "${KUBEDOK_RELEASES_DIR}" "${KUBEDOK_CURRENT_LINK}" "${KUBEDOK_PREVIOUS_LINK}" "${KUBEDOK_STAGING_DIR}"
ok "Release tree removed"

if [ "${PURGE_DATA}" = "true" ]; then
  log "Deleting data"
  docker volume rm kubedok_postgres_data >/dev/null 2>&1 || true
  docker volume rm kubedok_agent_state kubedok_agent_wg >/dev/null 2>&1 || true
  rm -rf "${KUBEDOK_SECRETS_DIR}" "${KUBEDOK_BACKUPS_DIR}" "${KUBEDOK_TLS_DIR}" "${KUBEDOK_CONFIG_DIR}"
  rm -rf "${KUBEDOK_ROOT}"
  ok "All data deleted"
  printf '\n  Kubedok has been completely removed.\n\n'
else
  printf '\n'
  ok "Kubedok removed"
  printf '\n  Kept:\n'
  printf '    Database volume   kubedok_postgres_data\n'
  printf '    Secrets           %s\n' "${KUBEDOK_SECRETS_DIR}"
  printf '    Backups           %s\n' "${KUBEDOK_BACKUPS_DIR}"
  printf '    Certificates      %s\n' "${KUBEDOK_TLS_DIR}"
  printf '\n  Delete them with: %s --purge-data\n\n' "$0"
fi
