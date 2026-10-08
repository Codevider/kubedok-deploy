# shellcheck shell=bash
# shellcheck disable=SC2034  # this is a library; its variables are used by the scripts that source it
#
# Shared library for every Kubedok deployment script. Sourced, never executed.
#
# Callers are expected to `set -Eeuo pipefail` themselves.

# ── Install layout ───────────────────────────────────────────────────────────
# KUBEDOK_ROOT is overridable so the whole tree can be exercised in a test
# sandbox without touching a real /opt/kubedok.
KUBEDOK_ROOT="${KUBEDOK_ROOT:-/opt/kubedok}"

KUBEDOK_RELEASES_DIR="${KUBEDOK_ROOT}/releases"
KUBEDOK_CURRENT_LINK="${KUBEDOK_ROOT}/current"
KUBEDOK_PREVIOUS_LINK="${KUBEDOK_ROOT}/previous"
# Where update.sh builds a release tree before it is known to work. Outside
# releases/, so nothing that lists releases ever sees a half-made one.
KUBEDOK_STAGING_DIR="${KUBEDOK_ROOT}/.staging"
KUBEDOK_CONFIG_DIR="${KUBEDOK_ROOT}/config"
KUBEDOK_CONFIG_FILE="${KUBEDOK_CONFIG_DIR}/kubedok.env"
KUBEDOK_SECRETS_DIR="${KUBEDOK_ROOT}/secrets"
KUBEDOK_BACKUPS_DIR="${KUBEDOK_ROOT}/backups"
KUBEDOK_TLS_DIR="${KUBEDOK_ROOT}/tls"
KUBEDOK_LOCK_FILE="${KUBEDOK_ROOT}/.lock"
# The agent is a separate install with its own settings (agent-install.sh).
KUBEDOK_AGENT_ROOT="${KUBEDOK_AGENT_ROOT:-/opt/kubedok-agent}"

KUBEDOK_RELEASE_BASE_URL="${KUBEDOK_RELEASE_BASE_URL:-https://raw.githubusercontent.com/glikaj/kubedok-deploy/main}"

# Manifest formats this tooling understands. A manifest declaring anything else
# means the install is older than the release it is being pointed at.
KUBEDOK_SUPPORTED_SCHEMA_VERSION=1

KUBEDOK_NETWORK_DB="kubedok-postgres"
KUBEDOK_NETWORK_PROXY="kubedok-proxy"

# ── Output ───────────────────────────────────────────────────────────────────
# Default to plain, then turn colour on for an interactive terminal. Assigning
# unconditionally first keeps these defined on every path.
_c_reset=''; _c_red=''; _c_green=''; _c_yellow=''; _c_blue=''; _c_dim=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _c_reset=$'\033[0m'; _c_red=$'\033[31m'; _c_green=$'\033[32m'
  _c_yellow=$'\033[33m'; _c_blue=$'\033[34m'; _c_dim=$'\033[2m'
fi

log()   { printf '%s==>%s %s\n' "${_c_blue}" "${_c_reset}" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "${_c_green}" "${_c_reset}" "$*"; }
warn()  { printf '%s  !%s %s\n' "${_c_yellow}" "${_c_reset}" "$*" >&2; }
err()   { printf '%s  ✗%s %s\n' "${_c_red}" "${_c_reset}" "$*" >&2; }
debug() { [ -n "${KUBEDOK_DEBUG:-}" ] && printf '%s    %s%s\n' "${_c_dim}" "$*" "${_c_reset}" >&2 || true; }
die()   { err "$*"; exit 1; }

# ── Preconditions ────────────────────────────────────────────────────────────
require_root() {
  [ "$(id -u)" -eq 0 ] || die "This script must run as root. Try: sudo ${KUBEDOK_INVOKED_AS:-$0} $*"
}

require_cmd() {
  local missing=()
  local c
  for c in "$@"; do
    command -v "${c}" >/dev/null 2>&1 || missing+=("${c}")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "Missing required command(s): ${missing[*]}. Run setup.sh first, or install them manually."
  fi
}

require_installed() {
  [ -d "${KUBEDOK_ROOT}" ] || die "Kubedok is not installed at ${KUBEDOK_ROOT}. Run setup.sh first."
  [ -f "${KUBEDOK_CONFIG_FILE}" ] || die "Missing ${KUBEDOK_CONFIG_FILE}. Run setup.sh first."
}

# `docker compose` (plugin) or `docker-compose` (legacy standalone).
compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    printf 'docker compose'
  elif command -v docker-compose >/dev/null 2>&1; then
    printf 'docker-compose'
  else
    die "Docker Compose is not available. Run setup.sh to install it."
  fi
}

# ── Locking ──────────────────────────────────────────────────────────────────
# Serialises setup/update/rollback/restore against each other. Two concurrent
# updates racing on the same database is the failure mode this prevents.
acquire_lock() {
  local timeout="${1:-0}"
  exec 9>"${KUBEDOK_LOCK_FILE}"
  if [ "${timeout}" -gt 0 ]; then
    flock -w "${timeout}" 9 \
      || die "Another Kubedok operation holds the lock (${KUBEDOK_LOCK_FILE}). Waited ${timeout}s."
  else
    flock -n 9 \
      || die "Another Kubedok operation is already running (${KUBEDOK_LOCK_FILE})."
  fi
}

# ── Configuration ────────────────────────────────────────────────────────────
load_config() {
  [ -f "${KUBEDOK_CONFIG_FILE}" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "${KUBEDOK_CONFIG_FILE}"
  set +a
}

# Loads kubedok.env under the caller's environment, for setup.sh: a setting
# given on the command line wins over the saved one. GIVEN_SETTINGS names the
# settings the caller gave, so they can be saved in place of the old values.
GIVEN_SETTINGS=""
load_config_under_env() {
  local key pair given=()
  GIVEN_SETTINGS=""
  for key in ${KUBEDOK_SETTINGS} ${KUBEDOK_OWNED_SETTINGS}; do
    if [ -n "${!key+x}" ]; then
      GIVEN_SETTINGS="${GIVEN_SETTINGS:+${GIVEN_SETTINGS} }${key}"
      given+=("${key}=${!key}")
    fi
  done
  load_config
  for pair in ${given[@]+"${given[@]}"}; do
    export "${pair?}"
  done
}

setting_given() { [[ " ${GIVEN_SETTINGS} " == *" $1 "* ]]; }

config_has() { grep -q "^$1=" "${KUBEDOK_CONFIG_FILE}" 2>/dev/null; }

# The saved value, as the scripts read it: sourced, so quotes in a hand-edited
# line come out the way load_config sees them. Empty when it is not saved.
saved_config_value() {
  config_has "$1" || return 0
  (
    unset "$1"
    # shellcheck disable=SC1090
    . "${KUBEDOK_CONFIG_FILE}"
    printf '%s' "${!1-}"
  )
}

# Set one KEY=VALUE in the config file, in place, keeping every other line
# and the order they are in.
set_config() {
  local key="$1" value="$2" tmp
  mkdir -p "${KUBEDOK_CONFIG_DIR}"
  touch "${KUBEDOK_CONFIG_FILE}"
  tmp="$(mktemp)"
  KEY="${key}" VALUE="${value}" awk '
    BEGIN { prefix = ENVIRON["KEY"] "="; line = prefix ENVIRON["VALUE"] }
    index($0, prefix) == 1 { if (!done) print line; done = 1; next }
    { print }
    END { if (!done) print line }
  ' "${KUBEDOK_CONFIG_FILE}" > "${tmp}"
  cat "${tmp}" > "${KUBEDOK_CONFIG_FILE}"
  rm -f "${tmp}"
  chmod 600 "${KUBEDOK_CONFIG_FILE}"
}

unset_config() {
  local key="$1" tmp
  [ -f "${KUBEDOK_CONFIG_FILE}" ] || return 0
  tmp="$(mktemp)"
  KEY="${key}" awk 'index($0, ENVIRON["KEY"] "=") != 1' "${KUBEDOK_CONFIG_FILE}" > "${tmp}"
  cat "${tmp}" > "${KUBEDOK_CONFIG_FILE}"
  rm -f "${tmp}"
  chmod 600 "${KUBEDOK_CONFIG_FILE}"
}

# ── Settings ─────────────────────────────────────────────────────────────────
# What kubedok.env holds. config.sh changes these on a running install and
# restarts what reads them; setup.sh saves any of them it is given.
KUBEDOK_SETTINGS="KUBEDOK_LOG_LEVEL KUBEDOK_CORS_ORIGIN KUBEDOK_JWT_EXPIRES_IN KUBEDOK_TRUST_PROXY
  KUBEDOK_CLIENT_MAX_BODY_SIZE KUBEDOK_HTTP_PORT KUBEDOK_HTTPS_PORT KUBEDOK_HTTP_BIND KUBEDOK_HTTPS_BIND
  KUBEDOK_PUBLIC_POSTGRES KUBEDOK_POSTGRES_BIND KUBEDOK_POSTGRES_PORT KUBEDOK_LETSENCRYPT_EMAIL"

# Saved as well, but each is changed by its own script: setup.sh decides the
# host and TLS, since a certificate is involved; update.sh moves the release;
# and the database was created with its user and name, which never change.
KUBEDOK_OWNED_SETTINGS="KUBEDOK_HOST KUBEDOK_TLS KUBEDOK_TLS_ENABLED KUBEDOK_RELEASE
  KUBEDOK_POSTGRES_USER KUBEDOK_POSTGRES_DB"

# The container that reads a setting, restarted to apply it, or `none` for one
# that only a script reads, the next time it runs. Fails for anything else.
setting_applies_to() {
  case "$1" in
    KUBEDOK_LOG_LEVEL|KUBEDOK_CORS_ORIGIN|KUBEDOK_JWT_EXPIRES_IN|KUBEDOK_TRUST_PROXY)
      printf 'server' ;;
    KUBEDOK_CLIENT_MAX_BODY_SIZE|KUBEDOK_HTTP_PORT|KUBEDOK_HTTPS_PORT|KUBEDOK_HTTP_BIND|KUBEDOK_HTTPS_BIND)
      printf 'nginx' ;;
    KUBEDOK_PUBLIC_POSTGRES|KUBEDOK_POSTGRES_BIND|KUBEDOK_POSTGRES_PORT)
      printf 'postgres' ;;
    KUBEDOK_LETSENCRYPT_EMAIL)
      printf 'none' ;;
    *) return 1 ;;
  esac
}

# Dies unless VALUE is one KEY can take. Empty always is: it means the default.
# kubedok.env is sourced by bash and compose.env is read by Compose, so no
# value may contain anything either would need quoted.
check_setting() {
  local key="$1" value="$2"
  local plain='^[A-Za-z0-9_.:/@,*=+%-]*$'
  local port='^[1-9][0-9]{0,4}$'
  local ipv4='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'

  [ -n "${value}" ] || return 0
  [[ "${value}" =~ ${plain} ]] \
    || die "${key}: '${value}' has a character a setting cannot hold. Use letters, digits and _ . : / @ , * = + % - only."

  case "${key}" in
    KUBEDOK_LOG_LEVEL)
      case "${value}" in error|warn|log|debug|verbose) ;;
        *) die "${key} is one of: error, warn, log, debug, verbose (got '${value}')." ;;
      esac ;;
    KUBEDOK_CORS_ORIGIN)
      [ "${value}" = "*" ] || [[ "${value}" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(,https?://[A-Za-z0-9.-]+(:[0-9]+)?)*$ ]] \
        || die "${key} is * or a comma-separated list of origins such as https://app.example.com (got '${value}')." ;;
    KUBEDOK_JWT_EXPIRES_IN)
      # A bare number would be read as milliseconds.
      [[ "${value}" =~ ^[1-9][0-9]*(s|m|h|d|w|y)$ ]] \
        || die "${key} is a number with a unit, s, m, h, d, w or y, such as 15m (got '${value}')." ;;
    KUBEDOK_CLIENT_MAX_BODY_SIZE)
      [[ "${value}" =~ ^[0-9]+[kKmMgG]?$ ]] \
        || die "${key} is an nginx size such as 100m or 1g (got '${value}')." ;;
    KUBEDOK_HTTP_PORT|KUBEDOK_HTTPS_PORT|KUBEDOK_POSTGRES_PORT)
      [[ "${value}" =~ ${port} ]] && [ "${value}" -le 65535 ] \
        || die "${key} is a port, 1 to 65535 (got '${value}')." ;;
    KUBEDOK_HTTP_BIND|KUBEDOK_HTTPS_BIND|KUBEDOK_POSTGRES_BIND)
      [[ "${value}" =~ ${ipv4} ]] \
        || die "${key} is an IPv4 address to listen on, such as 0.0.0.0 or 127.0.0.1 (got '${value}')." ;;
    KUBEDOK_PUBLIC_POSTGRES|KUBEDOK_TLS_ENABLED)
      case "${value}" in true|false) ;; *) die "${key} is true or false (got '${value}')." ;; esac ;;
    KUBEDOK_LETSENCRYPT_EMAIL)
      [[ "${value}" =~ ^[^@]+@[^@]+\.[^@]+$ ]] \
        || die "${key} is an email address (got '${value}')." ;;
    KUBEDOK_HOST)
      [[ "${value}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
        || die "${key} is a DNS name such as kubedok.example.com (got '${value}')." ;;
    KUBEDOK_TLS)
      case "${value}" in off|on|auto) ;; *) die "${key} is off, on or auto (got '${value}')." ;; esac ;;
    KUBEDOK_RELEASE)
      is_semver "${value}" || [[ "${value}" =~ ^[a-z][a-z0-9-]*$ ]] \
        || die "${key} is a channel name such as stable, or a version X.Y.Z (got '${value}')." ;;
    KUBEDOK_POSTGRES_USER|KUBEDOK_POSTGRES_DB)
      [[ "${value}" =~ ^[a-z_][a-z0-9_]*$ ]] \
        || die "${key} is lower-case letters, digits and _ (got '${value}')." ;;
  esac
}

# ── Secrets ──────────────────────────────────────────────────────────────────
# Generated once, on the host, and never regenerated. Losing jwt-secret logs
# everyone out; losing registry-encryption-key makes stored registry
# credentials and certificates permanently undecryptable.
#
# All three are root-owned 0600 inside a 0700 directory. That is safe even
# though the PostgreSQL container runs as uid 999: its entrypoint reads
# POSTGRES_PASSWORD_FILE while still root, exports the value, and unsets the
# _FILE variable before re-executing itself as postgres. The server container
# runs as root. Verified against the real images, not assumed.
ensure_secrets_dir() {
  mkdir -p "${KUBEDOK_SECRETS_DIR}"
  chmod 700 "${KUBEDOK_SECRETS_DIR}"
}

ensure_secret() {
  local name="$1" mode="${2:-0600}"
  local path="${KUBEDOK_SECRETS_DIR}/${name}"

  ensure_secrets_dir

  if [ -s "${path}" ]; then
    debug "secret ${name} already exists, leaving it alone"
    chmod "${mode}" "${path}"
    return 0
  fi

  ( umask 077; openssl rand -hex 32 > "${path}" )
  chmod "${mode}" "${path}"
  ok "Generated secret: ${name}"
}

read_secret() {
  local name="$1"
  local path="${KUBEDOK_SECRETS_DIR}/${name}"
  [ -r "${path}" ] || die "Secret ${name} is missing or unreadable at ${path}."
  tr -d '\r\n' < "${path}"
}

ensure_all_secrets() {
  ensure_secret postgres-password 0600
  ensure_secret jwt-secret 0600
  ensure_secret registry-encryption-key 0600
}

# ── Release manifests ────────────────────────────────────────────────────────
is_semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# 0 when $1 >= $2.
semver_ge() {
  [ "$1" = "$2" ] && return 0
  local lower
  lower="$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)"
  [ "${lower}" = "$2" ]
}

fetch_url() {
  local url="$1" dest="$2"
  debug "fetching ${url}"
  curl -fsSL --retry 3 --retry-delay 2 --max-time 60 -o "${dest}" "${url}" \
    || die "Could not download ${url}"
}

# Resolve a channel name or exact version into a local manifest file.
# Prints the path to the downloaded manifest on stdout.
resolve_manifest() {
  local ref="$1" dest="$2"

  if is_semver "${ref}"; then
    fetch_url "${KUBEDOK_RELEASE_BASE_URL}/releases/${ref}.json" "${dest}"
  else
    local channel_file
    channel_file="$(mktemp)"
    fetch_url "${KUBEDOK_RELEASE_BASE_URL}/channels/${ref}.json" "${channel_file}"

    local manifest_path
    manifest_path="$(jq -r '.manifest // empty' "${channel_file}")"
    local channel_release
    channel_release="$(jq -r '.release // empty' "${channel_file}")"
    rm -f "${channel_file}"

    if [ -z "${manifest_path}" ] || [ -z "${channel_release}" ]; then
      die "Channel '${ref}' has no published release yet. Pin an exact version with KUBEDOK_RELEASE=X.Y.Z."
    fi

    fetch_url "${KUBEDOK_RELEASE_BASE_URL}/${manifest_path}" "${dest}"
  fi

  validate_manifest "${dest}"
  printf '%s' "${dest}"
}

# Structural validation. Mirrors releases/release.schema.json; kept as
# explicit jq checks so a production host needs no JSON-Schema validator.
validate_manifest() {
  local file="$1"

  jq -e . "${file}" >/dev/null 2>&1 || die "Release manifest is not valid JSON: ${file}"

  local schema_version
  schema_version="$(jq -r '.schemaVersion // empty' "${file}")"
  [ -n "${schema_version}" ] || die "Release manifest has no schemaVersion."
  if [ "${schema_version}" != "${KUBEDOK_SUPPORTED_SCHEMA_VERSION}" ]; then
    die "Release manifest declares schemaVersion ${schema_version}, but this tooling understands ${KUBEDOK_SUPPORTED_SCHEMA_VERSION}. Update the deployment scripts first."
  fi

  local field
  for field in release publishedAt postgresMajor minimumAgentVersion minimumUpgradeFrom agentVersion; do
    jq -e --arg f "${field}" 'has($f) and (.[$f] != null)' "${file}" >/dev/null \
      || die "Release manifest is missing required field: ${field}"
  done

  # The release names a directory under releases/, so hold it to the schema.
  local release
  release="$(jq -r '.release' "${file}")"
  is_semver "${release}" || die "Release manifest's release is not a version (X.Y.Z): ${release}"
  # The agent is versioned apart from the release; agent-install.sh and
  # agent-update.sh record this, and the server reports it.
  local agent_version
  agent_version="$(jq -r '.agentVersion' "${file}")"
  is_semver "${agent_version}" || die "Release manifest's agentVersion is not a version (X.Y.Z): ${agent_version}"

  local component ref
  for component in server nginx postgres agent; do
    ref="$(jq -r --arg c "${component}" '.images[$c] // empty' "${file}")"
    [ -n "${ref}" ] || die "Release manifest is missing image reference: ${component}"
    # Digests only. A tag can be repointed after publication; a digest cannot.
    [[ "${ref}" == *"@sha256:"* ]] \
      || die "Image reference for '${component}' is not digest-pinned: ${ref}"
  done

  debug "manifest $(jq -r .release "${file}") validated"
}

manifest_field() { jq -r --arg f "$1" '.[$f]' "$2"; }
manifest_image() { jq -r --arg c "$1" '.images[$c]' "$2"; }

# ── Installed state ──────────────────────────────────────────────────────────
current_release() {
  [ -L "${KUBEDOK_CURRENT_LINK}" ] || return 1
  basename "$(readlink -f "${KUBEDOK_CURRENT_LINK}")"
}

current_manifest() {
  local rel
  rel="$(current_release)" || return 1
  printf '%s/%s/release.json' "${KUBEDOK_RELEASES_DIR}" "${rel}"
}

# Atomic symlink swap, so the link is never briefly missing.
point_link_at_release() {
  local link="$1" version="$2"
  local target="${KUBEDOK_RELEASES_DIR}/${version}"
  [ -d "${target}" ] || die "Release directory does not exist: ${target}"
  ln -sfn "${target}" "${link}.tmp"
  mv -Tf "${link}.tmp" "${link}"
}

set_current_release() { point_link_at_release "${KUBEDOK_CURRENT_LINK}" "$1"; }

# The kbd command. It links through `current`, so it always runs the current
# release's scripts and needs setting up only once; setup.sh and update.sh
# both make sure it is there. A kbd that is not this install's is left alone.
KUBEDOK_KBD_LINK="/usr/local/bin/kbd"
install_kbd_link() {
  local target="${KUBEDOK_CURRENT_LINK}/scripts/kbd"
  [ -x "${target}" ] || return 0
  if [ -L "${KUBEDOK_KBD_LINK}" ]; then
    case "$(readlink "${KUBEDOK_KBD_LINK}")" in
      "${target}") return 0 ;;
      */current/scripts/kbd) ;;
      *) warn "${KUBEDOK_KBD_LINK} is not Kubedok's, so the kbd command is not installed. The scripts are in ${KUBEDOK_CURRENT_LINK}/scripts."
         return 0 ;;
    esac
  elif [ -e "${KUBEDOK_KBD_LINK}" ]; then
    warn "${KUBEDOK_KBD_LINK} is not Kubedok's, so the kbd command is not installed. The scripts are in ${KUBEDOK_CURRENT_LINK}/scripts."
    return 0
  fi
  mkdir -p "$(dirname "${KUBEDOK_KBD_LINK}")"
  ln -sfn "${target}" "${KUBEDOK_KBD_LINK}"
  ok "Installed the kbd command (${KUBEDOK_KBD_LINK})"
}

kbd_installed() {
  [ "$(readlink "${KUBEDOK_KBD_LINK}" 2>/dev/null)" = "${KUBEDOK_CURRENT_LINK}/scripts/kbd" ]
}

remove_kbd_link() {
  if kbd_installed; then
    rm -f "${KUBEDOK_KBD_LINK}"
  fi
}

# How to tell the operator to run one of the scripts: `kbd <name>`, or the
# script's path where the kbd command is not installed.
command_hint() {
  if kbd_installed; then
    printf 'kbd %s' "$1"
  else
    printf '%s/scripts/%s.sh' "${KUBEDOK_CURRENT_LINK}" "$1"
  fi
}

# The release that was current before the last successful update: where
# rollback.sh goes when it is not given a version. update.sh records it as it
# commits and a rollback clears it, so it never names a release that failed
# to install, or the one a rollback just left.
previous_release() {
  [ -L "${KUBEDOK_PREVIOUS_LINK}" ] || return 1
  basename "$(readlink "${KUBEDOK_PREVIOUS_LINK}")"
}

set_previous_release() { point_link_at_release "${KUBEDOK_PREVIOUS_LINK}" "$1"; }
clear_previous_release() { rm -f "${KUBEDOK_PREVIOUS_LINK}"; }

# Release trees on disk, oldest first. Only X.Y.Z directories are releases.
list_releases() {
  find "${KUBEDOK_RELEASES_DIR}" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V \
    || true
}

# ── Docker networks ──────────────────────────────────────────────────────────
ensure_network() {
  local name="$1"
  if docker network inspect "${name}" >/dev/null 2>&1; then
    debug "network ${name} exists"
  else
    docker network create --driver bridge "${name}" >/dev/null \
      || die "Could not create Docker network: ${name}"
    ok "Created network: ${name}"
  fi
}

ensure_networks() {
  ensure_network "${KUBEDOK_NETWORK_DB}"
  ensure_network "${KUBEDOK_NETWORK_PROXY}"
}

# ── Compose ──────────────────────────────────────────────────────────────────
# Writes the env file every compose invocation is driven from: install paths,
# the resolved image digests, and the user's config. Regenerated from the
# manifest on each run so it can never drift from the active release. A second
# argument writes it somewhere else, which config.sh reads its defaults from.
write_compose_env() {
  local manifest="$1"
  local dest="${2:-${KUBEDOK_CONFIG_DIR}/compose.env}"

  mkdir -p "${KUBEDOK_CONFIG_DIR}"

  {
    printf '# Generated by Kubedok deployment scripts. Do not edit.\n'
    printf '# Source of truth: %s and %s\n' "${KUBEDOK_CONFIG_FILE}" "${manifest}"
    printf 'KUBEDOK_ROOT=%s\n' "${KUBEDOK_ROOT}"
    printf 'KUBEDOK_SECRETS_DIR=%s\n' "${KUBEDOK_SECRETS_DIR}"
    printf 'KUBEDOK_TLS_DIR=%s\n' "${KUBEDOK_TLS_DIR}"
    printf 'KUBEDOK_IMAGE_SERVER=%s\n' "$(manifest_image server "${manifest}")"
    printf 'KUBEDOK_IMAGE_NGINX=%s\n' "$(manifest_image nginx "${manifest}")"
    printf 'KUBEDOK_IMAGE_POSTGRES=%s\n' "$(manifest_image postgres "${manifest}")"
    printf 'KUBEDOK_IMAGE_AGENT=%s\n' "$(manifest_image agent "${manifest}")"
    printf 'KUBEDOK_RELEASE_VERSION=%s\n' "$(manifest_field release "${manifest}")"
    printf 'KUBEDOK_GIT_REVISION=%s\n' "$(jq -r '.gitRevision // ""' "${manifest}")"
    printf 'KUBEDOK_AGENT_VERSION=%s\n' "$(manifest_field agentVersion "${manifest}")"
    printf 'KUBEDOK_MINIMUM_AGENT_VERSION=%s\n' "$(manifest_field minimumAgentVersion "${manifest}")"
    printf 'KUBEDOK_POSTGRES_USER=%s\n' "${KUBEDOK_POSTGRES_USER:-kubedok}"
    printf 'KUBEDOK_POSTGRES_DB=%s\n' "${KUBEDOK_POSTGRES_DB:-kubedok}"
    printf 'KUBEDOK_POSTGRES_HOST=%s\n' "kubedok-postgres"
    printf 'KUBEDOK_SERVER_CONTAINER=%s\n' "kubedok-server"
    printf 'KUBEDOK_HOST=%s\n' "${KUBEDOK_HOST:-_}"
    printf 'KUBEDOK_TLS_ENABLED=%s\n' "${KUBEDOK_TLS_ENABLED:-false}"
    printf 'KUBEDOK_HTTP_PORT=%s\n' "${KUBEDOK_HTTP_PORT:-80}"
    printf 'KUBEDOK_HTTPS_PORT=%s\n' "${KUBEDOK_HTTPS_PORT:-443}"
    printf 'KUBEDOK_HTTP_BIND=%s\n' "${KUBEDOK_HTTP_BIND:-0.0.0.0}"
    printf 'KUBEDOK_HTTPS_BIND=%s\n' "${KUBEDOK_HTTPS_BIND:-0.0.0.0}"
    printf 'KUBEDOK_CORS_ORIGIN=%s\n' "${KUBEDOK_CORS_ORIGIN:-*}"
    printf 'KUBEDOK_JWT_EXPIRES_IN=%s\n' "${KUBEDOK_JWT_EXPIRES_IN:-15m}"
    printf 'KUBEDOK_TRUST_PROXY=%s\n' "${KUBEDOK_TRUST_PROXY:-1}"
    printf 'KUBEDOK_LOG_LEVEL=%s\n' "${KUBEDOK_LOG_LEVEL:-log}"
    printf 'KUBEDOK_CLIENT_MAX_BODY_SIZE=%s\n' "${KUBEDOK_CLIENT_MAX_BODY_SIZE:-100m}"
    printf 'KUBEDOK_POSTGRES_BIND=%s\n' "${KUBEDOK_POSTGRES_BIND:-127.0.0.1}"
    printf 'KUBEDOK_POSTGRES_PORT=%s\n' "${KUBEDOK_POSTGRES_PORT:-5432}"
    printf 'KUBEDOK_API_URL=%s\n' "${KUBEDOK_API_URL:-http://127.0.0.1:${KUBEDOK_HTTP_PORT:-80}}"
    printf 'KUBEDOK_REGISTRATION_TOKEN=%s\n' "${KUBEDOK_REGISTRATION_TOKEN:-}"
    printf 'KUBEDOK_HOST_ADDRESS=%s\n' "${KUBEDOK_HOST_ADDRESS:-}"
    printf 'KUBEDOK_SYNC_INTERVAL_SECS=%s\n' "${KUBEDOK_SYNC_INTERVAL_SECS:-15}"
    printf 'KUBEDOK_AGENT_LOG=%s\n' "${KUBEDOK_AGENT_LOG:-kubedok_agent=info}"
  } > "${dest}"

  chmod 600 "${dest}"
  printf '%s' "${dest}"
}

compose_env_file() { printf '%s/compose.env' "${KUBEDOK_CONFIG_DIR}"; }

# Where certbot keeps a host's certificate, and where nginx reads it.
certificate_path() { printf '%s/letsencrypt/live/%s/fullchain.pem' "${KUBEDOK_TLS_DIR}" "$1"; }

# compose <project> <compose args...>
# project is one of: postgres | server | nginx | agent
#
# KUBEDOK_COMPOSE_DIR lets update.sh drive the *staged* release's compose files
# while `current` still points at the old release — the symlink only moves once
# the new release has proven itself.
compose() {
  local project="$1"; shift
  local dir="${KUBEDOK_COMPOSE_DIR:-${KUBEDOK_CURRENT_LINK}/compose}"
  local env_file
  env_file="$(compose_env_file)"

  [ -f "${env_file}" ] || die "Missing ${env_file}. Run setup.sh or update.sh first."

  local files=(-f "${dir}/${project}.yml")
  if [ "${project}" = "postgres" ] && [ "${KUBEDOK_PUBLIC_POSTGRES:-false}" = "true" ]; then
    files+=(-f "${dir}/postgres.public.yml")
  fi

  # shellcheck disable=SC2046
  $(compose_cmd) --env-file "${env_file}" "${files[@]}" "$@"
}

# ── Waiting ──────────────────────────────────────────────────────────────────
wait_for_container_health() {
  local name="$1" timeout="${2:-120}"
  local deadline=$(( SECONDS + timeout ))
  local status

  while true; do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${name}" 2>/dev/null || echo missing)"
    case "${status}" in
      healthy|running) return 0 ;;
      missing) : ;;
      exited|dead) die "Container ${name} exited while starting. Check: docker logs ${name}" ;;
    esac
    if (( SECONDS >= deadline )); then
      err "Container ${name} did not become healthy within ${timeout}s (last status: ${status})."
      docker logs --tail 40 "${name}" 2>&1 | sed 's/^/      /' >&2 || true
      return 1
    fi
    sleep 2
  done
}

wait_for_http() {
  local url="$1" timeout="${2:-120}"
  local deadline=$(( SECONDS + timeout ))

  while ! local_curl -fsS --max-time 5 -o /dev/null "${url}" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep 2
  done
  return 0
}

# Talking to the install from the host itself.
#
# Once TLS is on, port 80 answers everything except the ACME path with a
# redirect to https://<KUBEDOK_HOST>/, and the certificate is for that name,
# not for 127.0.0.1. So the local URL carries the hostname, and local_curl()
# pins it to loopback with --resolve and follows the redirect: the request
# never leaves the machine, even when DNS points at a CDN, and the real
# certificate still has to validate. Before the first certificate exists nginx
# serves plain HTTP and there is nothing to follow.
#
# KUBEDOK_LOCAL_BASE_URL overrides all of this for the cases where loopback is
# not the right address: nginx bound to a specific interface, a non-default
# HTTPS port behind the redirect, or the scripts running from inside a
# container on the proxy network. It is used verbatim.
local_base_url() {
  if [ -n "${KUBEDOK_LOCAL_BASE_URL:-}" ]; then
    printf '%s' "${KUBEDOK_LOCAL_BASE_URL%/}"
    return 0
  fi
  if [ -n "${KUBEDOK_HOST:-}" ] && [ "${KUBEDOK_HOST}" != "_" ]; then
    printf 'http://%s:%s' "${KUBEDOK_HOST}" "${KUBEDOK_HTTP_PORT:-80}"
  else
    printf 'http://127.0.0.1:%s' "${KUBEDOK_HTTP_PORT:-80}"
  fi
}

# curl for URLs from local_base_url. Takes exactly the arguments curl takes.
local_curl() {
  local opts=()
  if [ -z "${KUBEDOK_LOCAL_BASE_URL:-}" ] \
    && [ -n "${KUBEDOK_HOST:-}" ] && [ "${KUBEDOK_HOST}" != "_" ]; then
    opts+=(--resolve "${KUBEDOK_HOST}:${KUBEDOK_HTTP_PORT:-80}:127.0.0.1"
           --resolve "${KUBEDOK_HOST}:${KUBEDOK_HTTPS_PORT:-443}:127.0.0.1"
           --location --max-redirs 3)
  fi
  curl ${opts[@]+"${opts[@]}"} "$@"
}
