#!/usr/bin/env bash
#
# Show and change the install's settings.
#
#   kbd config                              # every setting and its value
#   kbd config get LOG_LEVEL                # one value
#   kbd config set LOG_LEVEL=debug          # save it and apply it
#   kbd config set CLIENT_MAX_BODY_SIZE=500m CORS_ORIGIN=https://app.example.com
#   kbd config unset LOG_LEVEL              # back to the default
#   kbd config set LOG_LEVEL=debug --no-restart  # save only; kbd restart applies it
#
# A change is checked, saved in config/kubedok.env and written into
# compose.env, and only the containers that read it restart, the database
# first. The KUBEDOK_ prefix is optional.
#
# The host and TLS mode involve the certificate, so setup.sh changes them, and
# update.sh changes the release. An agent keeps its settings in
# /opt/kubedok-agent/agent.env.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

usage() { sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# How the operator ran this, for usage errors: `kbd config`, or the script.
ME="${KUBEDOK_INVOKED_AS:-config.sh}"

RESTART=true
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-restart) RESTART=false ;;
    -h|--help) usage; exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done

COMMAND="show"
if [ ${#ARGS[@]} -gt 0 ]; then
  COMMAND="${ARGS[0]}"
  ARGS=("${ARGS[@]:1}")
fi

require_root
require_installed
require_cmd docker jq flock
load_config

MANIFEST="$(current_manifest)" || die "No current release is recorded. Is this a complete install?"
[ -f "${MANIFEST}" ] || die "The current release has no manifest at ${MANIFEST}."

# What every setting comes to, defaults included: compose.env written from the
# saved settings into a scratch file, so no default is restated here.
EFFECTIVE="$(mktemp)"
trap 'rm -f "${EFFECTIVE}"' EXIT
refresh_effective() { write_compose_env "${MANIFEST}" "${EFFECTIVE}" >/dev/null; }
refresh_effective

# LOG_LEVEL, log_level and KUBEDOK_LOG_LEVEL all name KUBEDOK_LOG_LEVEL.
full_name() {
  local name="${1^^}"
  printf 'KUBEDOK_%s' "${name#KUBEDOK_}"
}

# The setting a name refers to, if config.sh changes it. Otherwise dies,
# saying what does.
changeable() {
  local name
  name="$(full_name "$1")"
  if setting_applies_to "${name}" >/dev/null; then
    printf '%s' "${name}"
    return 0
  fi
  case "${name}" in
    KUBEDOK_HOST|KUBEDOK_TLS)
      die "${name} involves the certificate, so setup.sh changes it. From a clone of kubedok-deploy:
      sudo ${name}=<value> ./setup.sh
    A re-run keeps the installed release and every other setting." ;;
    KUBEDOK_TLS_ENABLED)
      die "setup.sh decides KUBEDOK_TLS_ENABLED from KUBEDOK_TLS and the host. Change those with it instead." ;;
    KUBEDOK_RELEASE)
      die "update.sh changes the release: $(command_hint update) <version or channel>" ;;
    KUBEDOK_POSTGRES_USER|KUBEDOK_POSTGRES_DB)
      die "The database was created with ${name}, so it cannot change on an existing install." ;;
    KUBEDOK_API_URL|KUBEDOK_HOST_ADDRESS|KUBEDOK_REGISTRATION_TOKEN|KUBEDOK_SYNC_INTERVAL_SECS|KUBEDOK_AGENT_LOG)
      die "${name} is the agent's. It keeps its settings in ${KUBEDOK_AGENT_ROOT}/agent.env: edit it there, then run: $(command_hint restart) agent" ;;
    *)
      die "${name} is not a Kubedok setting. The containers receive only the ones ${ME} lists." ;;
  esac
}

effective_value() {
  local key="$1" line
  case "${key}" in
    KUBEDOK_HOST) printf '%s' "${KUBEDOK_HOST:-}"; return 0 ;;
    KUBEDOK_TLS) printf '%s' "${KUBEDOK_TLS:-auto}"; return 0 ;;
    KUBEDOK_RELEASE) printf '%s' "${KUBEDOK_RELEASE:-stable}"; return 0 ;;
    KUBEDOK_PUBLIC_POSTGRES) printf '%s' "${KUBEDOK_PUBLIC_POSTGRES:-false}"; return 0 ;;
  esac
  line="$(grep -m1 "^${key}=" "${EFFECTIVE}" || true)"
  if [ -n "${line}" ]; then
    printf '%s' "${line#*=}"
  else
    printf '%s' "${!key:-}"
  fi
}

is_setting() {
  local key
  for key in ${KUBEDOK_SETTINGS} ${KUBEDOK_OWNED_SETTINGS}; do
    [ "${key}" = "$1" ] && return 0
  done
  return 1
}

# ── show ─────────────────────────────────────────────────────────────────────
show_row() { printf '  %-30s %-36s %s\n' "$1" "$2" "$3"; }

show_settings() {
  local key value applies

  printf '\n'
  show_row 'Setting' 'Value' 'Takes effect'
  for key in ${KUBEDOK_SETTINGS}; do
    value="$(effective_value "${key}")"
    if [ -z "$(saved_config_value "${key}")" ]; then
      value="${value:+${value} (default)}"
      value="${value:-(not set)}"
    fi
    applies="$(setting_applies_to "${key}")"
    case "${applies}" in
      none) applies='at the next certificate request' ;;
      *) applies="${applies} restarts" ;;
    esac
    show_row "${key}" "${value}" "${applies}"
  done

  printf '\n'
  show_row 'KUBEDOK_HOST' "${KUBEDOK_HOST:-(none)}" 'setup.sh'
  show_row 'KUBEDOK_TLS' "${KUBEDOK_TLS:-auto}, HTTPS $([ "${KUBEDOK_TLS_ENABLED:-false}" = "true" ] && echo on || echo off)" 'setup.sh'
  show_row 'KUBEDOK_RELEASE' "${KUBEDOK_RELEASE:-stable}, $(current_release) installed" "$(command_hint update)"
  show_row 'KUBEDOK_POSTGRES_USER' "$(effective_value KUBEDOK_POSTGRES_USER)" 'fixed at install'
  show_row 'KUBEDOK_POSTGRES_DB' "$(effective_value KUBEDOK_POSTGRES_DB)" 'fixed at install'
  printf '\n  Saved in %s. Change one with: %s set KEY=VALUE\n\n' \
    "${KUBEDOK_CONFIG_FILE}" "$(command_hint config)"
}

# ── set / unset ──────────────────────────────────────────────────────────────
CHANGED=()
# The commands that put every changed setting back, should a restart fail.
REVERT=()

remember_old() {
  local key="$1"
  if config_has "${key}"; then
    REVERT+=("set ${key#KUBEDOK_}=$(saved_config_value "${key}")")
  else
    REVERT+=("unset ${key#KUBEDOK_}")
  fi
}

set_settings() {
  [ ${#ARGS[@]} -gt 0 ] || die "Usage: ${ME} set KEY=VALUE [KEY=VALUE ...]"

  # Every value is checked before any is saved.
  local pair key value i keys=() values=()
  for pair in "${ARGS[@]}"; do
    [[ "${pair}" == *=* ]] || die "Expected KEY=VALUE, got '${pair}'. To go back to a default: ${ME} unset KEY"
    key="$(changeable "${pair%%=*}")"
    value="${pair#*=}"
    check_setting "${key}" "${value}"
    keys+=("${key}")
    values+=("${value}")
  done

  acquire_lock
  for i in "${!keys[@]}"; do
    key="${keys[$i]}"
    value="${values[$i]}"
    if config_has "${key}" && [ "$(saved_config_value "${key}")" = "${value}" ]; then
      ok "${key} is already '${value}'"
      continue
    fi
    remember_old "${key}"
    set_config "${key}" "${value}"
    CHANGED+=("${key}")
  done
}

unset_settings() {
  [ ${#ARGS[@]} -gt 0 ] || die "Usage: ${ME} unset KEY [KEY ...]"

  local name key keys=()
  for name in "${ARGS[@]}"; do
    [[ "${name}" != *=* ]] || die "unset takes names, not values: ${ME} unset ${name%%=*}"
    key="$(changeable "${name}")"
    keys+=("${key}")
  done

  acquire_lock
  for key in "${keys[@]}"; do
    if [ -z "$(saved_config_value "${key}")" ]; then
      unset_config "${key}"
      ok "${key} is already the default"
      continue
    fi
    remember_old "${key}"
    unset_config "${key}"
    # load_config only assigns what the file holds, so the old value would
    # otherwise outlive its line.
    unset "${key}"
    CHANGED+=("${key}")
  done
}

warn_about_changes() {
  local key
  for key in "${CHANGED[@]}"; do
    case "${key}" in
      KUBEDOK_HTTP_PORT)
        if [ "${KUBEDOK_TLS_ENABLED:-false}" = "true" ] && [ "${KUBEDOK_HTTP_PORT:-80}" != "80" ]; then
          warn "Let's Encrypt validates on port 80. With nginx on ${KUBEDOK_HTTP_PORT}, certificate renewal fails unless port 80 reaches it."
        fi ;;
      KUBEDOK_PUBLIC_POSTGRES|KUBEDOK_POSTGRES_BIND)
        if [ "${KUBEDOK_PUBLIC_POSTGRES:-false}" = "true" ] && [ "${KUBEDOK_POSTGRES_BIND:-127.0.0.1}" != "127.0.0.1" ]; then
          warn "PostgreSQL is now published on ${KUBEDOK_POSTGRES_BIND}:${KUBEDOK_POSTGRES_PORT:-5432}, beyond this host."
        fi ;;
    esac
  done
}

# Writes the changes into compose.env and restarts what reads them, the
# database before the server before nginx.
apply_changes() {
  if [ ${#CHANGED[@]} -eq 0 ]; then
    ok "Nothing changed."
    return 0
  fi

  load_config
  write_compose_env "${MANIFEST}" >/dev/null
  ok "Saved ${CHANGED[*]} in ${KUBEDOK_CONFIG_FILE}"
  warn_about_changes

  local key c components=" "
  for key in "${CHANGED[@]}"; do
    c="$(setting_applies_to "${key}")"
    [[ "${components}" == *" ${c} "* ]] || components="${components}${c} "
  done

  if [[ "${components}" == *" none "* ]]; then
    log "KUBEDOK_LETSENCRYPT_EMAIL is used the next time a certificate is requested. An ACME account registered before keeps the address it has."
  fi

  for c in postgres server nginx; do
    [[ "${components}" == *" ${c} "* ]] || continue
    if [ "${RESTART}" != "true" ]; then
      log "Not restarted. Apply with: $(command_hint restart) ${c}"
      continue
    fi
    if ! "${SCRIPT_DIR}/restart.sh" "${c}"; then
      err "${c} did not come back with the new settings, which stay saved."
      err "To put them back as they were:"
      local revert
      for revert in "${REVERT[@]}"; do
        printf '      %s %s\n' "$(command_hint config)" "${revert}" >&2
      done
      exit 1
    fi
  done
}

case "${COMMAND}" in
  show|list)
    [ ${#ARGS[@]} -eq 0 ] || die "Usage: ${ME} [show]"
    show_settings
    ;;
  get)
    [ ${#ARGS[@]} -eq 1 ] || die "Usage: ${ME} get KEY"
    key="$(full_name "${ARGS[0]}")"
    is_setting "${key}" || die "${key} is not a Kubedok setting."
    printf '%s\n' "$(effective_value "${key}")"
    ;;
  set)
    set_settings
    apply_changes
    ;;
  unset)
    unset_settings
    apply_changes
    ;;
  *)
    die "Unknown command: ${COMMAND}. Expected show, get, set or unset."
    ;;
esac
