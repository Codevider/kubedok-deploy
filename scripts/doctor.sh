#!/usr/bin/env bash
#
# Diagnose a Kubedok install: Docker, DNS, ports, disk, memory, TLS, networks.
#
# Read-only. Exits non-zero if any check FAILs, so it can gate a deploy.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

load_config

FAILURES=0
WARNINGS=0

pass() { printf '  %s✓%s %-28s %s\n' "${_c_green}" "${_c_reset}" "$1" "${2:-}"; }
fail() { printf '  %s✗%s %-28s %s\n' "${_c_red}"   "${_c_reset}" "$1" "${2:-}"; FAILURES=$((FAILURES+1)); }
note() { printf '  %s!%s %-28s %s\n' "${_c_yellow}" "${_c_reset}" "$1" "${2:-}"; WARNINGS=$((WARNINGS+1)); }

section() { printf '\n  %s%s%s\n' "${_c_blue}" "$1" "${_c_reset}"; }

printf '\n  %sKubedok doctor%s\n' "${_c_blue}" "${_c_reset}"

# ── Host ─────────────────────────────────────────────────────────────────────
section 'Host'

arch="$(uname -m)"
case "${arch}" in
  x86_64|amd64|aarch64|arm64) pass 'CPU architecture' "${arch}" ;;
  *) fail 'CPU architecture' "${arch} — images are published for amd64 and arm64 only" ;;
esac

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  pass 'Operating system' "$(. /etc/os-release && echo "${PRETTY_NAME:-${ID}}")"
else
  note 'Operating system' 'could not read /etc/os-release'
fi

avail_kb="$(df -Pk "${KUBEDOK_ROOT}" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
avail_gb=$(( avail_kb / 1024 / 1024 ))
if [ "${avail_gb}" -ge 10 ]; then
  pass 'Disk space' "${avail_gb} GB free on ${KUBEDOK_ROOT}"
elif [ "${avail_gb}" -ge 3 ]; then
  note 'Disk space' "${avail_gb} GB free — image pulls and backups need headroom"
else
  fail 'Disk space' "${avail_gb} GB free — too low to pull a release safely"
fi

mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
mem_mb=$(( mem_kb / 1024 ))
if [ "${mem_mb}" -eq 0 ]; then
  note 'Memory' 'could not read /proc/meminfo'
elif [ "${mem_mb}" -ge 2000 ]; then
  pass 'Memory' "${mem_mb} MB"
elif [ "${mem_mb}" -ge 1000 ]; then
  note 'Memory' "${mem_mb} MB — PostgreSQL and the API together want 2 GB"
else
  fail 'Memory' "${mem_mb} MB — below the practical minimum"
fi

# ── Docker ───────────────────────────────────────────────────────────────────
section 'Docker'

if docker version >/dev/null 2>&1; then
  pass 'Docker Engine' "$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
else
  fail 'Docker Engine' 'not installed, or the daemon is unreachable'
fi

if docker compose version >/dev/null 2>&1; then
  pass 'Docker Compose' "$(docker compose version --short 2>/dev/null)"
elif command -v docker-compose >/dev/null 2>&1; then
  note 'Docker Compose' 'legacy docker-compose found; the v2 plugin is preferred'
else
  fail 'Docker Compose' 'not available'
fi

for tool in curl openssl jq flock; do
  if command -v "${tool}" >/dev/null 2>&1; then
    pass "Command: ${tool}" ''
  else
    fail "Command: ${tool}" 'missing'
  fi
done

for net in "${KUBEDOK_NETWORK_DB}" "${KUBEDOK_NETWORK_PROXY}"; do
  if docker network inspect "${net}" >/dev/null 2>&1; then
    pass "Network: ${net}" "$(docker network inspect "${net}" -f '{{len .Containers}}')  container(s)"
  else
    fail "Network: ${net}" 'missing — run setup.sh'
  fi
done

# ── Install ──────────────────────────────────────────────────────────────────
section 'Install'

if [ -d "${KUBEDOK_ROOT}" ]; then
  pass 'Install directory' "${KUBEDOK_ROOT}"
else
  fail 'Install directory' "${KUBEDOK_ROOT} does not exist"
fi

if release="$(current_release 2>/dev/null)"; then
  pass 'Current release' "${release}"
else
  fail 'Current release' 'no current symlink — the install is incomplete'
fi

if [ -f "${KUBEDOK_CONFIG_FILE}" ]; then
  perms="$(stat -c '%a' "${KUBEDOK_CONFIG_FILE}" 2>/dev/null || echo '?')"
  if [ "${perms}" = "600" ]; then
    pass 'Configuration' "${KUBEDOK_CONFIG_FILE}"
  else
    note 'Configuration' "mode ${perms}, expected 600"
  fi
else
  fail 'Configuration' 'missing'
fi

if [ -d "${KUBEDOK_SECRETS_DIR}" ]; then
  dperms="$(stat -c '%a' "${KUBEDOK_SECRETS_DIR}" 2>/dev/null || echo '?')"
  [ "${dperms}" = "700" ] && pass 'Secrets directory' "mode ${dperms}" \
                          || note 'Secrets directory' "mode ${dperms}, expected 700"
  for s in postgres-password jwt-secret registry-encryption-key; do
    if [ -s "${KUBEDOK_SECRETS_DIR}/${s}" ]; then
      sperms="$(stat -c '%a' "${KUBEDOK_SECRETS_DIR}/${s}" 2>/dev/null || echo '?')"
      [ "${sperms}" = "600" ] && pass "Secret: ${s}" '' || note "Secret: ${s}" "mode ${sperms}, expected 600"
    else
      fail "Secret: ${s}" 'missing or empty'
    fi
  done
else
  fail 'Secrets directory' 'missing'
fi

# ── Containers ───────────────────────────────────────────────────────────────
section 'Containers'

for name in kubedok-postgres kubedok-server kubedok-nginx; do
  if ! docker inspect "${name}" >/dev/null 2>&1; then
    fail "${name}" 'does not exist'
    continue
  fi
  state="$(docker inspect -f '{{.State.Status}}' "${name}")"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${name}")"
  restarts="$(docker inspect -f '{{.RestartCount}}' "${name}")"
  if [ "${state}" = "running" ] && { [ "${health}" = "healthy" ] || [ "${health}" = "none" ]; }; then
    if [ "${restarts}" -gt 5 ]; then
      note "${name}" "running but has restarted ${restarts} times"
    else
      pass "${name}" "${state}/${health}"
    fi
  else
    fail "${name}" "${state}/${health}"
  fi
done

if docker inspect kubedok-agent >/dev/null 2>&1; then
  pass 'kubedok-agent' "$(docker inspect -f '{{.State.Status}}' kubedok-agent)"
else
  printf '  %s·%s %-28s %s\n' "${_c_dim}" "${_c_reset}" 'kubedok-agent' 'not installed on this host'
fi

# ── Networking ───────────────────────────────────────────────────────────────
section 'Networking'

check_port() {
  local port="$1" label="$2"
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn "sport = :${port}" 2>/dev/null | grep -q ":${port}"; then
      pass "Port ${port}" "${label}"
    else
      fail "Port ${port}" "nothing is listening (${label})"
    fi
  else
    note "Port ${port}" 'ss not available — cannot check listeners'
  fi
}

check_port "${KUBEDOK_HTTP_PORT:-80}" 'HTTP'
[ "${KUBEDOK_TLS_ENABLED:-false}" = "true" ] && check_port "${KUBEDOK_HTTPS_PORT:-443}" 'HTTPS'

BASE="$(local_base_url)"
if health_json="$(local_curl -fsS --max-time 10 "${BASE}/api/health" 2>/dev/null)"; then
  status="$(jq -r '.status // "?"' <<<"${health_json}")"
  db="$(jq -r '.database // "?"' <<<"${health_json}")"
  [ "${status}" = "ok" ] && pass 'API /api/health' "status=${status} database=${db}" \
                         || fail 'API /api/health' "status=${status} database=${db}"
else
  fail 'API /api/health' "no response from ${BASE}"
fi

if local_curl -fsS --max-time 10 -o /dev/null "${BASE}/" 2>/dev/null; then
  pass 'Web UI' "served at ${BASE}/"
else
  fail 'Web UI' "not served at ${BASE}/"
fi

# Network isolation is a security property, so verify it rather than trust it.
if docker inspect kubedok-nginx >/dev/null 2>&1 && docker inspect kubedok-postgres >/dev/null 2>&1; then
  if docker exec kubedok-nginx sh -c 'nc -z -w2 kubedok-postgres 5432' >/dev/null 2>&1; then
    fail 'Network isolation' 'nginx can reach PostgreSQL — it should not be on that network'
  else
    pass 'Network isolation' 'nginx cannot reach PostgreSQL'
  fi
fi

if docker inspect kubedok-postgres >/dev/null 2>&1; then
  published="$(docker inspect -f '{{json .NetworkSettings.Ports}}' kubedok-postgres | jq -r '[to_entries[] | select(.value != null)] | length')"
  if [ "${published}" = "0" ]; then
    pass 'PostgreSQL exposure' 'not published to the host'
  else
    note 'PostgreSQL exposure' 'port 5432 is published (KUBEDOK_PUBLIC_POSTGRES) — debugging only'
  fi
fi

# ── DNS and TLS ──────────────────────────────────────────────────────────────
section 'DNS and TLS'

if [ -n "${KUBEDOK_HOST:-}" ] && [ "${KUBEDOK_HOST}" != "_" ]; then
  resolved="$(getent ahosts "${KUBEDOK_HOST}" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
  if [ -n "${resolved}" ]; then
    pass 'DNS resolution' "${KUBEDOK_HOST} → ${resolved}"
  else
    fail 'DNS resolution' "${KUBEDOK_HOST} does not resolve"
  fi
else
  note 'DNS' 'KUBEDOK_HOST is not set — no hostname to check'
fi

if [ "${KUBEDOK_TLS_ENABLED:-false}" = "true" ]; then
  cert="${KUBEDOK_TLS_DIR}/letsencrypt/live/${KUBEDOK_HOST}/fullchain.pem"
  if [ -f "${cert}" ]; then
    if end_date="$(openssl x509 -enddate -noout -in "${cert}" 2>/dev/null | cut -d= -f2)"; then
      end_epoch="$(date -d "${end_date}" +%s 2>/dev/null || echo 0)"
      now_epoch="$(date +%s)"
      days=$(( (end_epoch - now_epoch) / 86400 ))
      if [ "${days}" -gt 30 ]; then
        pass 'TLS certificate' "valid for ${days} more days"
      elif [ "${days}" -gt 0 ]; then
        note 'TLS certificate' "expires in ${days} days — check the renewal timer"
      else
        fail 'TLS certificate' 'expired'
      fi
    else
      fail 'TLS certificate' 'unreadable'
    fi
  else
    fail 'TLS certificate' "TLS is enabled but ${cert} is missing"
  fi

  if systemctl is-enabled kubedok-cert-renew.timer >/dev/null 2>&1; then
    pass 'Renewal timer' 'enabled'
  else
    note 'Renewal timer' "not enabled — run $(command_hint cert-renew) --install-timer"
  fi
else
  note 'TLS' 'disabled — traffic including login credentials is sent in the clear'
fi

# ── Backups ──────────────────────────────────────────────────────────────────
section 'Backups'

count="$(find "${KUBEDOK_BACKUPS_DIR}" -maxdepth 1 -name 'kubedok-*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')"
if [ "${count}" -gt 0 ]; then
  latest="$(find "${KUBEDOK_BACKUPS_DIR}" -maxdepth 1 -name 'kubedok-*.tar.gz' | sort | tail -n1)"
  age_days=$(( ( $(date +%s) - $(stat -c %Y "${latest}") ) / 86400 ))
  if [ "${age_days}" -le 7 ]; then
    pass 'Backups' "${count} on disk, newest ${age_days} day(s) old"
  else
    note 'Backups' "newest is ${age_days} days old — consider scheduling ${KUBEDOK_CURRENT_LINK}/scripts/backup.sh"
  fi
else
  note 'Backups' "none yet — run $(command_hint backup)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
printf '\n'
if [ "${FAILURES}" -eq 0 ] && [ "${WARNINGS}" -eq 0 ]; then
  printf '  %sEverything looks healthy.%s\n\n' "${_c_green}" "${_c_reset}"
  exit 0
elif [ "${FAILURES}" -eq 0 ]; then
  printf '  %s%d warning(s), no failures.%s\n\n' "${_c_yellow}" "${WARNINGS}" "${_c_reset}"
  exit 0
else
  printf '  %s%d failure(s)%s and %d warning(s).\n\n' "${_c_red}" "${FAILURES}" "${_c_reset}" "${WARNINGS}"
  exit 1
fi
