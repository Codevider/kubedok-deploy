#!/usr/bin/env bash
#
# Show containers, health, the current release, and database status.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

require_installed
require_cmd docker
load_config

CURRENT_VERSION="$(current_release 2>/dev/null || echo 'unknown')"
MANIFEST="${KUBEDOK_CURRENT_LINK}/release.json"

printf '\n'
printf '  %sKubedok%s  release %s\n' "${_c_blue}" "${_c_reset}" "${CURRENT_VERSION}"
if [ -f "${MANIFEST}" ]; then
  printf '  published %s   postgres %s   agent %s   min agent %s\n' \
    "$(jq -r '.publishedAt // "—"' "${MANIFEST}")" \
    "$(jq -r '.postgresMajor // "—"' "${MANIFEST}")" \
    "$(jq -r '.agentVersion // "—"' "${MANIFEST}")" \
    "$(jq -r '.minimumAgentVersion // "—"' "${MANIFEST}")"
fi
printf '\n'

printf '  %-18s %-10s %-12s %s\n' 'CONTAINER' 'STATE' 'HEALTH' 'UPTIME'
printf '  %s\n' '──────────────────────────────────────────────────────────────'
for name in kubedok-postgres kubedok-server kubedok-nginx kubedok-agent; do
  if ! docker inspect "${name}" >/dev/null 2>&1; then
    printf '  %-18s %s%-10s%s %-12s %s\n' "${name}" "${_c_dim}" 'absent' "${_c_reset}" '—' '—'
    continue
  fi
  state="$(docker inspect -f '{{.State.Status}}' "${name}")"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}—{{end}}' "${name}")"
  since="$(docker inspect -f '{{.State.StartedAt}}' "${name}")"
  uptime="$(date -u -d "${since}" +'%Y-%m-%d %H:%M' 2>/dev/null || echo "${since:0:16}")"

  colour="${_c_green}"
  [ "${state}" != "running" ] && colour="${_c_red}"
  [ "${health}" = "unhealthy" ] && colour="${_c_red}"
  [ "${health}" = "starting" ] && colour="${_c_yellow}"

  printf '  %-18s %s%-10s%s %-12s %s\n' "${name}" "${colour}" "${state}" "${_c_reset}" "${health}" "${uptime}"
done
printf '\n'

printf '  %-18s %s\n' 'Install' "${KUBEDOK_ROOT}"
printf '  %-18s %s\n' 'Networks' "$(docker network ls --format '{{.Name}}' | grep -c '^kubedok-' || echo 0) of 2 present"

if [ "$(docker inspect -f '{{.State.Running}}' kubedok-postgres 2>/dev/null)" = "true" ]; then
  PG_USER="${KUBEDOK_POSTGRES_USER:-kubedok}"
  PG_DB="${KUBEDOK_POSTGRES_DB:-kubedok}"
  size="$(docker exec kubedok-postgres psql -U "${PG_USER}" -d "${PG_DB}" -tAc \
    "SELECT pg_size_pretty(pg_database_size('${PG_DB}'))" 2>/dev/null || echo '—')"
  conns="$(docker exec kubedok-postgres psql -U "${PG_USER}" -d "${PG_DB}" -tAc \
    "SELECT count(*) FROM pg_stat_activity WHERE datname='${PG_DB}'" 2>/dev/null || echo '—')"
  printf '  %-18s %s, %s connection(s)\n' 'Database' "${size}" "${conns}"
else
  printf '  %-18s %snot running%s\n' 'Database' "${_c_red}" "${_c_reset}"
fi

BASE="$(local_base_url)"
if health_json="$(local_curl -fsS --max-time 5 "${BASE}/api/health" 2>/dev/null)"; then
  printf '  %-18s %s (db: %s)\n' 'API' "$(jq -r .status <<<"${health_json}")" "$(jq -r .database <<<"${health_json}")"
else
  printf '  %-18s %sunreachable at %s%s\n' 'API' "${_c_red}" "${BASE}" "${_c_reset}"
fi

if version_json="$(local_curl -fsS --max-time 5 "${BASE}/api/version" 2>/dev/null)"; then
  printf '  %-18s %s\n' 'Reported release' "$(jq -r .release <<<"${version_json}")"
fi

if [ "${KUBEDOK_TLS_ENABLED:-false}" = "true" ]; then
  cert="${KUBEDOK_TLS_DIR}/letsencrypt/live/${KUBEDOK_HOST}/fullchain.pem"
  if [ -f "${cert}" ]; then
    expiry="$(openssl x509 -enddate -noout -in "${cert}" 2>/dev/null | cut -d= -f2 || echo '—')"
    printf '  %-18s valid until %s\n' 'TLS certificate' "${expiry}"
  else
    printf '  %-18s %senabled but missing%s\n' 'TLS certificate' "${_c_red}" "${_c_reset}"
  fi
else
  printf '  %-18s %sdisabled (HTTP only)%s\n' 'TLS' "${_c_yellow}" "${_c_reset}"
fi

backups="$(find "${KUBEDOK_BACKUPS_DIR}" -maxdepth 1 -name 'kubedok-*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')"
latest="$(find "${KUBEDOK_BACKUPS_DIR}" -maxdepth 1 -name 'kubedok-*.tar.gz' 2>/dev/null | sort | tail -n1)"
printf '  %-18s %s%s\n' 'Backups' "${backups}" "${latest:+, latest $(basename "${latest}")}"
printf '\n'
