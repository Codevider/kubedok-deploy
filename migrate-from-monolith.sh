#!/usr/bin/env bash
#
# Move a single-container Kubedok install to the current release.
#
#   git clone https://github.com/Codevider/kubedok-deploy.git kubedok
#   cd kubedok
#   sudo ./migrate-from-monolith.sh --check     # report, change nothing
#   sudo ./migrate-from-monolith.sh --dry-run   # rehearse on a copy of the data
#   sudo ./migrate-from-monolith.sh             # migrate
#
# The single-container image (approxx/kubedok-server 0.0.x) ran PostgreSQL,
# the API and nginx in one container. This moves its data into the install
# setup.sh makes, with PostgreSQL, the server and nginx apart, and keeps the
# address it was served on, so users and agents reconnect on their own.
#
# Options:
#   --container NAME         The old container. Found by its entrypoint if not given.
#   --yes                    Do not ask before stopping the old container.
#   --force                  Go ahead although deploys, rollouts or agent commands are
#                            in flight. They are recorded as cancelled or timed out.
#   --keep-jwt-secret        Keep the old JWT signing secret. A new one is made by
#                            default: it only ends access tokens, which last minutes,
#                            and sign-ins stay valid.
#   --rotate-encryption-key  Re-encrypt the stored registry passwords and
#                            certificates under a new key. Do this when --check
#                            says the old install uses the image's built-in key.
#
# The new install takes setup.sh's settings: KUBEDOK_HOST, KUBEDOK_TLS,
# KUBEDOK_RELEASE, KUBEDOK_HTTP_PORT and the rest. Unless they are given, it
# listens where the old container was published, over plain HTTP as the old one
# did. The old container is stopped, and its restart policy is set to `no` so
# Docker never starts it beside the new install; nothing else about it, or its
# volume, is changed. If anything fails after it stops, it is started again.
#
# Why not just a dump and restore: from 1.4.9 on, releases ship their database
# migrations squashed into one, under the name of the first migration the old
# image applied. Restored as it is, the old database would look current and
# never get the 37 schema changes made since. So the data is brought forward on
# a scratch copy, with the last release that still ships those changes one by
# one, then checked against a fresh database of the target release, and only
# then installed.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "${SCRIPT_DIR}/scripts/common.sh" ] || [ ! -f "${SCRIPT_DIR}/setup.sh" ]; then
  cat >&2 <<'HINT'
migrate-from-monolith.sh needs setup.sh, scripts/ and compose/ beside it.
Clone the repository and run it from there:

  git clone https://github.com/Codevider/kubedok-deploy.git kubedok
  cd kubedok
  sudo ./migrate-from-monolith.sh --check

HINT
  exit 1
fi
# shellcheck source=scripts/common.sh
. "${SCRIPT_DIR}/scripts/common.sh"

# ── Fixed points ─────────────────────────────────────────────────────────────
# 1.4.8, the last release that ships the migrations one by one, by digest.
CHAIN_IMAGE="${KUBEDOK_MIGRATE_CHAIN_IMAGE:-approxx/kubedok-server@sha256:2a030a44c8ab96f2bf04b5c758b2f2fa564b6783dc1452aab4da99afc48afd4e}"
# How the old container is recognised, whatever it is called or tagged.
OLD_ENTRYPOINT=/usr/local/bin/kubedok-app-entrypoint.sh
# The first migration as every single-container image from 0.0.9 on applied it.
# Older images predate it and cannot be brought forward this way.
MONOLITH_INIT=20260501072234_init
MONOLITH_INIT_CHECKSUM=dbfd99664aeef39324f64f2e3feae702a91c763a36a4534f6392ecb4bb695937

SCRATCH_NET=kubedok-migrate
SCRATCH_PG=kubedok-migrate-pg
SOURCE_PG=kubedok-migrate-source

# ── Options ──────────────────────────────────────────────────────────────────
MODE=migrate
OLD_CONTAINER=""
ASSUME_YES=false
FORCE=false
KEEP_JWT=false
ROTATE_KEY=false

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --dry-run) MODE=dry-run; shift ;;
    --container)
      [ $# -ge 2 ] || die "--container needs the container's name."
      OLD_CONTAINER="$2"; shift 2 ;;
    --yes|-y) ASSUME_YES=true; shift ;;
    --force) FORCE=true; shift ;;
    --keep-jwt-secret) KEEP_JWT=true; shift ;;
    --rotate-encryption-key) ROTATE_KEY=true; shift ;;
    -h|--help) sed -n '2,/^set -Eeuo pipefail/{/^set /!p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_root "$@"

# ── Tools ────────────────────────────────────────────────────────────────────
# The host already runs Docker; jq and the like may be missing until setup.sh
# installs them, and the checks below need them first.
ensure_tools() {
  local missing=() c
  for c in curl openssl jq flock tar gzip; do
    command -v "${c}" >/dev/null 2>&1 || missing+=("${c}")
  done
  if [ ${#missing[@]} -gt 0 ] && [ "${KUBEDOK_SKIP_DEPS:-false}" != "true" ] \
     && command -v apt-get >/dev/null 2>&1; then
    log "Installing ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    { apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        ca-certificates curl openssl jq util-linux tar gzip; } >/dev/null \
      || die "Could not install ${missing[*]}. Install them and run this again."
  fi
  require_cmd docker curl openssl jq flock tar gzip
  docker info >/dev/null 2>&1 || die "Cannot talk to the Docker daemon. Is it running?"
}
ensure_tools

exec 8>/tmp/kubedok-migrate.lock
flock -n 8 || die "Another migration is already running on this host."

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK_BASE="${KUBEDOK_MIGRATE_WORKDIR:-/var/tmp}"
mkdir -p "${WORK_BASE}"
WORK="$(mktemp -d "${WORK_BASE}/kubedok-migrate.XXXXXX")"
chmod 700 "${WORK}"

# ── State the exit handler reads ─────────────────────────────────────────────
STOPPED_OLD=false      # this run stopped the old container
OLD_WAS_RUNNING=false
OLD_RESTART="no"
COMMITTED=false        # the new install is up and checked
CREATED_ROOT=false     # KUBEDOK_ROOT is this run's
CREATED_NETWORKS=""    # networks setup.sh made during this run

on_exit() {
  local status=$?
  set +e
  if [ "${status}" -ne 0 ] && [ "${STOPPED_OLD}" = "true" ] && [ "${COMMITTED}" != "true" ]; then
    rollback
  fi
  stop_source_db
  remove_scratch
  if [ "${KUBEDOK_MIGRATE_KEEP_WORK:-false}" = "true" ]; then
    warn "Kept the working files in ${WORK}. They hold secrets and the database: remove them when done."
  else
    rm -rf "${WORK}"
  fi
  exit "${status}"
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# ── The old container ────────────────────────────────────────────────────────
is_monolith() {
  [[ "$(docker container inspect -f '{{join .Config.Entrypoint " "}}' "$1" 2>/dev/null)" == *"${OLD_ENTRYPOINT}"* ]]
}

find_old_container() {
  if [ -n "${OLD_CONTAINER}" ]; then
    docker container inspect "${OLD_CONTAINER}" >/dev/null 2>&1 || die "No container named ${OLD_CONTAINER}."
    is_monolith "${OLD_CONTAINER}" \
      || die "${OLD_CONTAINER} is not a single-container Kubedok install: its entrypoint is not ${OLD_ENTRYPOINT}."
    return 0
  fi
  local name found=()
  while IFS= read -r name; do
    [ -n "${name}" ] && is_monolith "${name}" && found+=("${name}")
  done < <(docker ps -a --format '{{.Names}}')
  case "${#found[@]}" in
    0) die "No single-container Kubedok install on this host, so there is nothing to migrate. If there is one, name it with --container." ;;
    1) OLD_CONTAINER="${found[0]}" ;;
    *) die "More than one single-container install here (${found[*]}). Name the one to migrate with --container." ;;
  esac
}

old_env() { printf '%s\n' "${OLD_ENV}" | sed -n "s/^$1=//p" | tail -n1; }

read_old_facts() {
  OLD_IMAGE="$(docker container inspect -f '{{.Config.Image}}' "${OLD_CONTAINER}")"
  OLD_IMAGE_ID="$(docker container inspect -f '{{.Image}}' "${OLD_CONTAINER}")"
  OLD_WAS_RUNNING="$(docker container inspect -f '{{.State.Running}}' "${OLD_CONTAINER}")"
  OLD_RESTART="$(docker container inspect -f '{{.HostConfig.RestartPolicy.Name}}' "${OLD_CONTAINER}")"
  OLD_RESTART="${OLD_RESTART:-no}"
  OLD_ENV="$(docker container inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${OLD_CONTAINER}")"
  OLD_PGDATA="$(old_env PGDATA)"; OLD_PGDATA="${OLD_PGDATA:-/var/lib/postgresql/data}"
  OLD_PG_USER="$(old_env POSTGRES_USER)"; OLD_PG_USER="${OLD_PG_USER:-kubedok}"
  OLD_PG_DB="$(old_env POSTGRES_DB)"; OLD_PG_DB="${OLD_PG_DB:-kubedok}"
  OLD_VOLUME="$(docker container inspect -f '{{range .Mounts}}{{if eq .Destination "'"${OLD_PGDATA}"'"}}{{if .Name}}{{.Name}}{{else}}{{.Source}}{{end}}{{end}}{{end}}' "${OLD_CONTAINER}")"
  OLD_NETWORK_MODE="$(docker container inspect -f '{{.HostConfig.NetworkMode}}' "${OLD_CONTAINER}")"
  OLD_HTTP_PORT="$(docker container inspect -f '{{with index .HostConfig.PortBindings "80/tcp"}}{{(index . 0).HostPort}}{{end}}' "${OLD_CONTAINER}" 2>/dev/null || true)"
  OLD_HTTP_BIND="$(docker container inspect -f '{{with index .HostConfig.PortBindings "80/tcp"}}{{(index . 0).HostIp}}{{end}}' "${OLD_CONTAINER}" 2>/dev/null || true)"
  if [ "${OLD_NETWORK_MODE}" = "host" ]; then
    OLD_HTTP_PORT=80; OLD_HTTP_BIND=""
  fi
  OLD_COMPOSE_PROJECT="$(docker container inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "${OLD_CONTAINER}" 2>/dev/null || true)"

  # Stopping a container started with --rm deletes it, and going back needs it.
  [ "$(docker container inspect -f '{{.HostConfig.AutoRemove}}' "${OLD_CONTAINER}")" != "true" ] \
    || die "${OLD_CONTAINER} was started with --rm, so stopping it would delete it and leave nothing to go back to. Recreate it without --rm, on the same volume, and run this again."
  # The data has to be the container's own PostgreSQL.
  [ -z "$(old_env DATABASE_URL)" ] \
    || die "${OLD_CONTAINER} is set to use an external database (DATABASE_URL), which this script does not move."
}

# A file from the old data directory, read without starting PostgreSQL.
old_volume_file() {
  docker run --rm --network none --volumes-from "${OLD_CONTAINER}" --entrypoint cat \
    "${OLD_IMAGE_ID}" "${OLD_PGDATA}/$1" 2>/dev/null | tr -d '\r\n' || true
}

# The value the old entrypoint falls back to for installs older than secret
# generation, read out of the old image itself: it is not repeated here, in a
# public repository.
OLD_ENTRYPOINT_TEXT=""
legacy_default() {
  if [ -z "${OLD_ENTRYPOINT_TEXT}" ]; then
    OLD_ENTRYPOINT_TEXT="$(docker run --rm --network none --entrypoint cat "${OLD_IMAGE_ID}" "${OLD_ENTRYPOINT}" 2>/dev/null || true)"
  fi
  printf '%s\n' "${OLD_ENTRYPOINT_TEXT}" | sed -n 's/^: "\${'"$1"':=\(.*\)}"$/\1/p' | tail -n1
}

# The secrets the old API actually runs with. Its entrypoint takes each from the
# container's environment, then from PGDATA/.kubedok-secrets, then from a
# built-in default for installs made before secrets were generated, and only
# writes the file in some of those cases. So the running process is asked
# first, and the same order is followed when it is not running.
SECRET_SOURCE_JWT_SECRET=""
SECRET_SOURCE_REGISTRY_ENCRYPTION_KEY=""
read_old_secrets() {
  local dir="${WORK}/old-secrets" pid="" pair name var value source
  mkdir -p "${dir}"; chmod 700 "${dir}"
  if [ "${OLD_WAS_RUNNING}" = "true" ]; then
    pid="$(docker exec "${OLD_CONTAINER}" sh -c 'for p in /proc/[0-9]*; do
      case "$(tr "\0" " " < "$p/cmdline" 2>/dev/null)" in node*/dist/main.js*) echo "${p#/proc/}"; exit 0 ;; esac
    done' 2>/dev/null || true)"
  fi
  for pair in "jwt-secret JWT_SECRET" "registry-encryption-key REGISTRY_ENCRYPTION_KEY"; do
    name="${pair% *}"; var="${pair#* }"; value=""; source=""
    if [ -n "${pid}" ]; then
      value="$(docker exec "${OLD_CONTAINER}" sh -c "tr '\\0' '\\n' < /proc/${pid}/environ" 2>/dev/null \
        | sed -n "s/^${var}=//p" || true)"
      [ -n "${value}" ] && source="the running API"
    fi
    if [ -z "${value}" ]; then
      value="$(old_env "${var}")"
      [ -n "${value}" ] && source="the container's environment"
    fi
    if [ -z "${value}" ]; then
      value="$(old_volume_file ".kubedok-secrets/${name}")"
      [ -n "${value}" ] && source="${OLD_PGDATA}/.kubedok-secrets/${name}"
    fi
    if [ -z "${value}" ]; then
      value="$(legacy_default "KUBEDOK_LEGACY_${var}")"
      [ -n "${value}" ] && source="the image's built-in default"
    fi
    [ -n "${value}" ] || die "Could not find the old install's ${var}. Without it the stored registry credentials and certificates cannot be read; set ${var} in the environment and run this again."
    ( umask 077; printf '%s\n' "${value}" > "${dir}/${name}" )
    if [ "${value}" = "$(legacy_default "KUBEDOK_LEGACY_${var}")" ]; then
      source="the image's built-in default"
    fi
    printf -v "SECRET_SOURCE_${var}" '%s' "${source}"
  done
  [[ "$(tr -d '\r\n' < "${dir}/registry-encryption-key")" =~ ^[0-9a-fA-F]{64}$ ]] \
    || die "The old install's REGISTRY_ENCRYPTION_KEY is not 64 hex characters."
}

# ── The old database ─────────────────────────────────────────────────────────
# psql against the old database: inside the old container while it runs, and
# otherwise in a PostgreSQL started on its data directory (start_source_db).
OLD_DB_CONTAINER=""
old_psql() {
  docker exec -i "${OLD_DB_CONTAINER}" psql -X -q -v ON_ERROR_STOP=1 \
    -U "${OLD_PG_USER}" -d "${OLD_PG_DB}" "$@"
}
old_query() { old_psql -tA -c "$1"; }

wait_for_pg() {
  local container="$1" user="$2" db="$3" deadline=$(( SECONDS + ${4:-120} ))
  until docker exec "${container}" pg_isready -q -U "${user}" -d "${db}" >/dev/null 2>&1; do
    if [ "$(docker container inspect -f '{{.State.Running}}' "${container}" 2>/dev/null)" != "true" ] \
       || (( SECONDS >= deadline )); then
      docker logs --tail 20 "${container}" 2>&1 | sed 's/^/      /' >&2 || true
      return 1
    fi
    sleep 1
  done
}

# Opens the old data directory once the old container is stopped: the same
# image, as the postgres user, with no network. Never while it runs: two
# servers on one data directory corrupt it.
start_source_db() {
  [ "$(docker container inspect -f '{{.State.Running}}' "${OLD_CONTAINER}")" = "false" ] \
    || die "Refusing to open ${OLD_CONTAINER}'s data directory while the container runs."
  docker rm -f "${SOURCE_PG}" >/dev/null 2>&1 || true
  docker run -d --name "${SOURCE_PG}" --network none --user postgres \
    --volumes-from "${OLD_CONTAINER}" --entrypoint postgres "${OLD_IMAGE_ID}" \
    -D "${OLD_PGDATA}" -c listen_addresses= >/dev/null \
    || die "Could not start PostgreSQL on ${OLD_CONTAINER}'s data."
  wait_for_pg "${SOURCE_PG}" "${OLD_PG_USER}" "${OLD_PG_DB}" 180 \
    || die "PostgreSQL did not start on ${OLD_CONTAINER}'s data."
  OLD_DB_CONTAINER="${SOURCE_PG}"
}

stop_source_db() {
  docker container inspect "${SOURCE_PG}" >/dev/null 2>&1 || return 0
  docker stop -t 60 "${SOURCE_PG}" >/dev/null 2>&1 || true
  docker rm -f "${SOURCE_PG}" >/dev/null 2>&1 || true
}

dump_old_database() {
  log "Dumping the old database"
  if ! docker exec "${OLD_DB_CONTAINER}" pg_dump -U "${OLD_PG_USER}" --no-owner --no-privileges \
       "${OLD_PG_DB}" > "${WORK}/monolith.sql" 2>"${WORK}/monolith-dump.err"; then
    sed 's/^/      /' "${WORK}/monolith-dump.err" >&2
    die "Could not dump the old database."
  fi
  ok "Dumped $(du -h "${WORK}/monolith.sql" | cut -f1)"
}

# ── The report ───────────────────────────────────────────────────────────────
WARNINGS=0
note() { warn "$@"; WARNINGS=$((WARNINGS + 1)); }

# Work in flight, which the new server would resume or send again, and rows
# 0.0.x left looking like it: commands it recorded a result for and then wrote
# over with SENT (a race fixed since), commands never answered long after
# their timeout, and deployments and operations untouched for an hour. Those
# are settled on the copy (SETTLE_SQL) and hold nothing back.
CMD_OPEN="status::text IN ('PENDING','SENT')"
CMD_LOST_RESULT="${CMD_OPEN} AND \"completedAt\" IS NOT NULL"
CMD_ABANDONED="${CMD_OPEN} AND \"completedAt\" IS NULL AND \"issuedAt\" < now() - make_interval(secs => \"timeoutSeconds\" + 600)"
CMD_INFLIGHT="${CMD_OPEN} AND \"completedAt\" IS NULL AND \"issuedAt\" >= now() - make_interval(secs => \"timeoutSeconds\" + 600)"
DEPLOY_OPEN="status::text IN ('PENDING','RUNNING')"
OP_OPEN="status::text IN ('QUEUED','SENT','RUNNING')"
IDLE="\"updatedAt\" < now() - interval '1 hour'"
ROLLOUT_INFLIGHT="status::text IN ('PENDING','RUNNING','PAUSED','ROLLING_BACK')"

INFLIGHT_REPORT_SQL="SELECT
    (SELECT count(*) FROM agent_commands WHERE ${CMD_INFLIGHT}) || ' agent commands, ' ||
    (SELECT count(*) FROM deployments WHERE ${DEPLOY_OPEN} AND NOT (${IDLE})) || ' deployments, ' ||
    (SELECT count(*) FROM resource_operations WHERE ${OP_OPEN} AND NOT (${IDLE})) || ' operations, ' ||
    (SELECT count(*) FROM rollout_campaigns WHERE ${ROLLOUT_INFLIGHT}) || ' rollouts'"
INFLIGHT_SQL="SELECT (SELECT count(*) FROM agent_commands WHERE ${CMD_INFLIGHT})
  + (SELECT count(*) FROM deployments WHERE ${DEPLOY_OPEN} AND NOT (${IDLE}))
  + (SELECT count(*) FROM resource_operations WHERE ${OP_OPEN} AND NOT (${IDLE}))
  + (SELECT count(*) FROM rollout_campaigns WHERE ${ROLLOUT_INFLIGHT})"
SETTLED_REPORT_SQL="SELECT concat_ws(', ',
    nullif((SELECT count(*) FROM agent_commands WHERE ${CMD_LOST_RESULT}), 0) || ' finished agent command(s) whose result was written over',
    nullif((SELECT count(*) FROM agent_commands WHERE ${CMD_ABANDONED}), 0) || ' agent command(s) never answered',
    nullif((SELECT count(*) FROM deployments WHERE ${DEPLOY_OPEN} AND ${IDLE}), 0) || ' deployment(s)',
    nullif((SELECT count(*) FROM resource_operations WHERE ${OP_OPEN} AND ${IDLE}), 0) || ' operation(s) stuck for over an hour')"
SETTLE_SQL="BEGIN;
UPDATE agent_commands SET status = (CASE WHEN \"errorMessage\" IS NULL THEN 'SUCCEEDED' ELSE 'FAILED' END)::\"CommandStatus\"
 WHERE ${CMD_LOST_RESULT};
UPDATE agent_commands SET status = 'TIMED_OUT', \"completedAt\" = now(),
       \"errorMessage\" = 'Never answered; closed by the move from the single-container install'
 WHERE ${CMD_ABANDONED};
UPDATE deployments SET status = 'CANCELLED', \"finishedAt\" = now() WHERE ${DEPLOY_OPEN} AND ${IDLE};
UPDATE resource_operations SET status = 'CANCELLED', \"finishedAt\" = now() WHERE ${OP_OPEN} AND ${IDLE};
COMMIT;"

# Values the old image sets itself; anything else in its environment was set by
# whoever started it.
KNOWN_OLD_ENV=" PATH GOSU_VERSION LANG PG_MAJOR PG_VERSION PGDATA NODE_ENV POSTGRES_USER POSTGRES_DB PORT JWT_EXPIRES_IN CORS_ORIGIN TRUST_PROXY REDIS_HOST REDIS_PORT JWT_SECRET REGISTRY_ENCRYPTION_KEY POSTGRES_PASSWORD HOSTNAME HOME "

# Settings of the old container the new install keeps, as setup.sh settings.
CARRIED_SETTINGS=()
carry_old_settings() {
  local pair var setting value default
  for pair in "JWT_EXPIRES_IN KUBEDOK_JWT_EXPIRES_IN 15m" "CORS_ORIGIN KUBEDOK_CORS_ORIGIN *" "TRUST_PROXY KUBEDOK_TRUST_PROXY 1"; do
    read -r var setting default <<<"${pair}"
    value="$(old_env "${var}")"
    [ -n "${value}" ] && [ "${value}" != "${default}" ] || continue
    [ -z "${!setting+x}" ] || continue
    if ( check_setting "${setting}" "${value}" ) >/dev/null 2>&1; then
      CARRIED_SETTINGS+=("${setting}=${value}")
    else
      note "The old container's ${var}=${value} is not a value the new install takes; it uses the default."
    fi
  done
}

report_old_install() {
  local counts users hosts envs stacks services registries certs
  printf '\n'
  printf '  Container      %s (%s)\n' "${OLD_CONTAINER}" "$([ "${OLD_WAS_RUNNING}" = "true" ] && echo running || echo stopped)"
  printf '  Image          %s\n' "${OLD_IMAGE}"
  printf '  Data           %s on %s\n' "${OLD_PGDATA}" "${OLD_VOLUME:-<the container itself>}"
  printf '  Database       %s/%s\n' "${OLD_PG_USER}" "${OLD_PG_DB}"
  if [ -n "${OLD_HTTP_PORT}" ]; then
    printf '  Published on   %s:%s\n' "${OLD_HTTP_BIND:-0.0.0.0}" "${OLD_HTTP_PORT}"
  else
    printf '  Published on   (no port)\n'
  fi
  printf '  JWT secret     from %s\n' "${SECRET_SOURCE_JWT_SECRET}"
  printf '  Encryption key from %s\n' "${SECRET_SOURCE_REGISTRY_ENCRYPTION_KEY}"

  counts="$(old_query "SELECT (SELECT count(*) FROM users) || ' ' || (SELECT count(*) FROM hosts) || ' ' ||
    (SELECT count(*) FROM environments) || ' ' || (SELECT count(*) FROM stacks) || ' ' ||
    (SELECT count(*) FROM stack_services) || ' ' || (SELECT count(*) FROM container_registries) || ' ' ||
    (SELECT count(*) FROM load_balancer_certificates)")"
  read -r users hosts envs stacks services registries certs <<<"${counts}"
  printf '  Data held      %s users, %s hosts, %s environments, %s stacks, %s services,\n' \
    "${users}" "${hosts}" "${envs}" "${stacks}" "${services}"
  printf '                 %s registries, %s certificates (%s)\n' "${registries}" "${certs}" \
    "$(old_query "SELECT pg_size_pretty(pg_database_size(current_database()))")"
  printf '\n'
  OLD_HOST_COUNT="${hosts}"

  local size_kb free_kb
  size_kb="$(( $(old_query "SELECT pg_database_size(current_database())") / 1024 ))"
  free_kb="$(df -Pk "${WORK_BASE}" | awk 'NR == 2 { print $4 }')"
  if [ -n "${free_kb}" ] && [ "${free_kb}" -lt $(( size_kb * 3 + 262144 )) ]; then
    note "Only $(( free_kb / 1024 )) MB free in ${WORK_BASE} for the dumps of a $(( size_kb / 1024 )) MB database. Point KUBEDOK_MIGRATE_WORKDIR somewhere roomier if it runs out."
  fi

  # Migration history: the first migration must be the one the single-container
  # images from 0.0.9 on applied. The full chain is checked on the scratch copy.
  local first
  first="$(old_query "SELECT migration_name || ' ' || checksum FROM _prisma_migrations ORDER BY migration_name LIMIT 1" 2>/dev/null || true)"
  if [ "${first}" != "${MONOLITH_INIT} ${MONOLITH_INIT_CHECKSUM}" ]; then
    die "This database's migration history does not start where the single-container images from 0.0.9 on start (${first:-no history}). It cannot be brought forward by this script."
  fi
  if [ "$(old_query "SELECT count(*) FROM _prisma_migrations WHERE finished_at IS NULL OR rolled_back_at IS NOT NULL")" != "0" ]; then
    die "The old database has a failed or rolled-back migration. Start the old container once so it finishes, or fix it, before migrating."
  fi
  ok "Migration history: $(old_query "SELECT count(*) FROM _prisma_migrations") applied, as the single-container image left it"

  # The encryption key has to open what is stored, or every registry password
  # and certificate is lost on the other side.
  check_decryption old "${WORK}/old-secrets/registry-encryption-key"

  if [ "${SECRET_SOURCE_REGISTRY_ENCRYPTION_KEY}" = "the image's built-in default" ] && [ "${ROTATE_KEY}" != "true" ]; then
    note "The encryption key is the image's built-in default, which anyone can read from the public image. Run with --rotate-encryption-key to re-encrypt the stored credentials under a new key."
  fi
  if [ "${SECRET_SOURCE_JWT_SECRET}" = "the image's built-in default" ]; then
    if [ "${KEEP_JWT}" = "true" ]; then
      note "The JWT secret is the image's built-in default, readable from the public image, and --keep-jwt-secret keeps it. Leave that option out to get a new one."
    else
      ok "The JWT secret is the image's built-in default; the new install gets a new one"
    fi
  fi

  # Work in flight would be resumed, or sent again, by the new server.
  local inflight settled
  settled="$(old_query "${SETTLED_REPORT_SQL}")"
  [ -z "${settled}" ] || ok "Left by 0.0.x looking unfinished, and closed in the move: ${settled}"
  inflight="$(old_query "${INFLIGHT_REPORT_SQL}")"
  if [ "${inflight}" = "0 agent commands, 0 deployments, 0 operations, 0 rollouts" ]; then
    ok "Nothing in flight"
  elif [ "${FORCE}" = "true" ]; then
    note "In flight: ${inflight}. --force: they will be recorded as cancelled or timed out."
  else
    INFLIGHT_BLOCKS=true
    note "In flight: ${inflight}. Let them finish and run this again, or pass --force to record them as cancelled."
  fi

  local deleting
  deleting="$(old_query "SELECT string_agg(name, ', ') FROM hosts WHERE status::text = 'DELETING'")"
  [ -z "${deleting}" ] || note "Hosts being deleted: ${deleting}. The new server finishes removing them, and the stacks that ran only there, within minutes."

  local lbs
  lbs="$(old_query "SELECT count(*) FROM stack_services WHERE coalesce(\"configJson\"->>'certificateId', '') <> ''")"
  [ "${lbs}" = "0" ] || ok "${lbs} load balancer(s) with a certificate: converted to the current format"

  local networks
  networks="$(old_query "SELECT string_agg(s.name || '/' || ss.name || ' ' || (ss.\"configJson\"->'networks')::text, '; ' ORDER BY s.name, ss.name)
      FROM stack_services ss JOIN stacks s ON s.id = ss.\"stackId\"
     WHERE jsonb_typeof(ss.\"configJson\"->'networks') = 'array'
       AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(ss.\"configJson\"->'networks') n WHERE n <> 'default')")"
  [ -z "${networks}" ] || note "Services on extra Docker networks, which current releases no longer create: ${networks}. They keep running; on their next deploy they reach each other through the overlay and service links instead."
  report_services

  [ "${hosts}" = "0" ] || ok "Nightly host clean-up stays off on the ${hosts} migrated host(s); turn it on per host if wanted"

  local name extra=()
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    [[ "${KNOWN_OLD_ENV}" == *" ${name} "* ]] || extra+=("${name}")
  done < <(printf '%s\n' "${OLD_ENV}" | cut -d= -f1)
  [ ${#extra[@]} -eq 0 ] || note "Set on the old container and not carried over: ${extra[*]}"
  carry_old_settings
  [ ${#CARRIED_SETTINGS[@]} -eq 0 ] || ok "Carried over: ${CARRIED_SETTINGS[*]}"
  check_ports
}

# Each service as 0.0.x stored it: what it depends on, its environment (read
# for host names only, never printed) and the sources of its volumes.
SERVICES_SQL="SELECT coalesce(json_agg(json_build_object(
    'stack', s.name, 'name', ss.name, 'type', ss.\"serviceType\"::text, 'image', ss.image,
    'deps', CASE WHEN jsonb_typeof(ss.\"configJson\"->'dependsOn') = 'array' THEN ss.\"configJson\"->'dependsOn' ELSE '[]'::jsonb END,
    'env', CASE WHEN jsonb_typeof(ss.\"configJson\"->'env') = 'object' THEN ss.\"configJson\"->'env' ELSE '{}'::jsonb END,
    'entrypoint', CASE WHEN jsonb_typeof(ss.\"configJson\"->'entrypoint') = 'array' THEN ss.\"configJson\"->'entrypoint' ELSE '[]'::jsonb END,
    'volumes', CASE WHEN jsonb_typeof(ss.\"configJson\"->'volumes') = 'array' THEN
        (SELECT coalesce(jsonb_agg(v->>'source'), '[]'::jsonb) FROM jsonb_array_elements(ss.\"configJson\"->'volumes') v
          WHERE coalesce(v->>'source', '') <> '' AND coalesce(v->>'content', '') = '')
      ELSE '[]'::jsonb END
  ) ORDER BY s.name, ss.name), '[]') FROM stack_services ss JOIN stacks s ON s.id = ss.\"stackId\""

# Reads SERVICES_SQL's rows and prints, tab-separated:
#   NOVOLUME stack/service image   a database image with no volume of its own
#   FLOATING stack/service image   a database image on latest or no tag
# (a database image with an entrypoint of its own runs as a client, so not those)
#   ORDER    stack         order   services linked within the stack, the ones
#                                  that connect to others first
# A link is a dependsOn entry, or a sibling's name used as a host in one of the
# service's environment values (mongodb://mongo:27017, DB_HOST=db).
# shellcheck disable=SC2016  # jq's own variables
SERVICES_JQ='
def stateful: ["mongo","mongodb","postgres","postgresql","postgis","timescaledb","mysql","mariadb",
  "redis","valkey","keydb","rabbitmq","elasticsearch","opensearch","influxdb","clickhouse",
  "clickhouse-server","minio","etcd","couchdb","cassandra","neo4j","zookeeper","kafka"];
def base: sub("@.*$"; "") | split("/") | last;
def tag: if test("@sha256:") then "digest" else (base | if test(":") then sub("^[^:]*:"; "") else "" end) end;
def esc: gsub("\\."; "\\.");
(.[] | select(.type != "LOAD_BALANCER" and (.entrypoint | length) == 0)
  | select(.image | base | sub(":.*$"; "") | IN(stateful[]))
  | (if (.volumes | length) == 0 then "NOVOLUME\t\(.stack)/\(.name)\t\(.image)" else empty end),
    (if (.image | tag) == "" or (.image | tag) == "latest" then "FLOATING\t\(.stack)/\(.name)\t\(.image)" else empty end)),
(group_by(.stack)[]
  | .[0].stack as $stack
  | map(.name) as $names
  | (map(. as $s | {key: .name, value: (
        ([.deps[]? | strings] + [$names[] | select(. != $s.name) | . as $t
          | select(any($s.env[]?; tostring | test("(^|[/@=,\\s])" + ($t | esc) + "($|[:/,?\\s])")))])
        | unique | map(select(IN($names[]))))}) | from_entries) as $g
  | ([$g[][]] | unique) as $used
  | def depth($n; $seen):
      if any($seen[]; . == $n) then 0
      else ([($g[$n] // [])[] | depth(.; $seen + [$n]) + 1] | max // 0) end;
  [$names[] | select(($g[.] | length) > 0 or IN($used[]))]
  | select(length > 0)
  | map({n: ., d: depth(.; [])}) | group_by(.d) | sort_by(-.[0].d)
  | "ORDER\t\($stack)\t\(map(map(.n) | join(", ")) | join(", then "))")
'

# How the services find each other, and what a deploy changes for those that
# keep data. Fills REDEPLOY_ORDER for the summary.
REDEPLOY_ORDER=""
report_services() {
  local out kind what detail
  if ! out="$(old_query "${SERVICES_SQL}" | jq -r "${SERVICES_JQ}" 2>/dev/null)"; then
    warn "Could not read the services' settings; check their volumes and image tags before redeploying them."
    return 0
  fi
  while IFS=$'\t' read -r kind what detail; do
    case "${kind}" in
      NOVOLUME) note "${what} (${detail}) keeps no volume: its data is in the container itself, and its next deploy makes a new container that starts empty. Give it a named volume and move the data there before deploying it again." ;;
      FLOATING) note "${what} runs ${detail}: its next deploy pulls whatever that tag is then, perhaps a major version newer than the one that wrote its data. Set the image to the version it runs now before deploying it again." ;;
      ORDER) REDEPLOY_ORDER="${REDEPLOY_ORDER}    ${what}: ${detail}"$'\n' ;;
    esac
  done <<<"${out}"
  if [ -n "${REDEPLOY_ORDER}" ]; then
    ok "Services that reach others by name; after --adopt, redeploy them in this order:"
    printf '%s' "${REDEPLOY_ORDER}"
  fi
}

# Whether anything on this host listens on PORT.
port_taken() {
  if command -v ss >/dev/null 2>&1; then
    ss -Hltn 2>/dev/null | awk '{ print $4 }' | grep -qE ":$1\$"
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
  fi
}

# The new nginx publishes an HTTP and an HTTPS port, the HTTPS one even with TLS
# off. The old container only had HTTP, often behind a proxy on this host that
# holds 443, and nginx not starting would undo the whole migration, so ports
# are checked before anything stops.
PORTS_BLOCK=false
check_ports() {
  local http_port="${KUBEDOK_HTTP_PORT:-${OLD_HTTP_PORT:-80}}" https_port="${KUBEDOK_HTTPS_PORT:-443}"
  if [ "${http_port}" != "${OLD_HTTP_PORT}" ] && port_taken "${http_port}"; then
    PORTS_BLOCK=true
    note "Port ${http_port}, where the new install would serve HTTP, is in use. Free it, or pick another with KUBEDOK_HTTP_PORT."
  fi
  if port_taken "${https_port}"; then
    PORTS_BLOCK=true
    if [ "${KUBEDOK_TLS:-off}" = "off" ]; then
      note "Port ${https_port} is in use, by a proxy in front of the old install perhaps. The new install publishes an HTTPS port even without TLS: give it a free one on loopback, e.g. KUBEDOK_HTTPS_BIND=127.0.0.1 KUBEDOK_HTTPS_PORT=8443."
    else
      note "Port ${https_port} is in use, and HTTPS needs it. Free it first."
    fi
  fi
  [ "${PORTS_BLOCK}" = "true" ] || ok "Ports ${http_port} and ${https_port} are free for the new install"
}

# Opens every stored registry password and certificate key with KEY_FILE, using
# the old image's node, so it works before anything is pulled. Where = old | scratch.
check_decryption() {
  local where="$1" key_file="$2" rows sql
  sql="SELECT 'registry ' || name || E'\t' || \"passwordEnc\" FROM container_registries WHERE \"passwordEnc\" IS NOT NULL
       UNION ALL SELECT 'certificate ' || name || E'\t' || \"privateKeyPemEnc\" FROM load_balancer_certificates"
  if [ "${where}" = "old" ]; then rows="$(old_query "${sql}")"; else rows="$(scratch_query kubedok "${sql}")"; fi
  if [ -z "${rows}" ]; then
    ok "No stored registry passwords or certificates to decrypt"
    return 0
  fi
  local out
  if ! out="$( { tr -d '\r\n' < "${key_file}"; printf '\n%s\n' "${rows}"; } \
      | docker run --rm -i --network none --entrypoint node "${OLD_IMAGE_ID}" -e '
        const crypto = require("crypto");
        const lines = require("fs").readFileSync(0, "utf8").split("\n");
        const key = Buffer.from(lines.shift().trim(), "hex");
        let good = 0;
        const bad = [];
        for (const line of lines) {
          if (!line) continue;
          const tab = line.indexOf("\t");
          try {
            const buf = Buffer.from(line.slice(tab + 1), "base64");
            const d = crypto.createDecipheriv("aes-256-gcm", key, buf.subarray(0, 12), { authTagLength: 16 });
            d.setAuthTag(buf.subarray(12, 28));
            Buffer.concat([d.update(buf.subarray(28)), d.final()]);
            good++;
          } catch (e) { bad.push(line.slice(0, tab)); }
        }
        console.log(bad.length ? "cannot decrypt: " + bad.join(", ") : "decrypted " + good);
        process.exit(bad.length ? 1 : 0);' 2>&1)"; then
    die "The encryption key does not open what is stored (${out}). Migrating with it would lose them; set REGISTRY_ENCRYPTION_KEY to the right key and run this again."
  fi
  ok "Encryption key opens every stored credential (${out#decrypted } values)"
}

# ── The target release ───────────────────────────────────────────────────────
resolve_target() {
  log "Resolving release '${KUBEDOK_RELEASE:-stable}'"
  TARGET_MANIFEST="${WORK}/release.json"
  resolve_manifest "${KUBEDOK_RELEASE:-stable}" "${TARGET_MANIFEST}" >/dev/null
  TARGET_RELEASE="$(manifest_field release "${TARGET_MANIFEST}")"
  TARGET_SERVER="$(manifest_image server "${TARGET_MANIFEST}")"
  TARGET_POSTGRES="$(manifest_image postgres "${TARGET_MANIFEST}")"
  TARGET_NGINX="$(manifest_image nginx "${TARGET_MANIFEST}")"
  TARGET_AGENT_VERSION="$(manifest_field agentVersion "${TARGET_MANIFEST}")"
  [ "$(manifest_field postgresMajor "${TARGET_MANIFEST}")" = "16" ] \
    || warn "Release ${TARGET_RELEASE} runs PostgreSQL $(manifest_field postgresMajor "${TARGET_MANIFEST}"); the data moves as a dump, so that is fine."
  ok "Release ${TARGET_RELEASE}"
}

pull_images() {
  log "Pulling images"
  local ref
  for ref in "${CHAIN_IMAGE}" "${TARGET_POSTGRES}" "${TARGET_SERVER}" "${TARGET_NGINX}"; do
    docker pull -q "${ref}" >/dev/null || die "Could not pull ${ref}"
  done
  ok "Pulled the target release and the 1.4.8 server image the old migrations come from"
}

# ── The scratch copy ─────────────────────────────────────────────────────────
SCRATCH_PASSWORD=""

start_scratch() {
  remove_scratch
  docker network create --internal "${SCRATCH_NET}" >/dev/null \
    || die "Could not create the scratch network ${SCRATCH_NET}."
  SCRATCH_PASSWORD="$(openssl rand -hex 24)"
  docker run -d --name "${SCRATCH_PG}" --network "${SCRATCH_NET}" \
    -e POSTGRES_USER=kubedok -e POSTGRES_DB=kubedok -e POSTGRES_PASSWORD="${SCRATCH_PASSWORD}" \
    "${TARGET_POSTGRES}" >/dev/null || die "Could not start the scratch PostgreSQL."
  wait_for_pg "${SCRATCH_PG}" kubedok kubedok 120 || die "The scratch PostgreSQL did not start."
}

remove_scratch() {
  docker rm -f -v "${SCRATCH_PG}" >/dev/null 2>&1 || true
  docker network rm "${SCRATCH_NET}" >/dev/null 2>&1 || true
}

scratch_psql() { local db="$1"; shift; docker exec -i "${SCRATCH_PG}" psql -X -q -v ON_ERROR_STOP=1 -U kubedok -d "${db}" "$@"; }
scratch_query() { scratch_psql "$1" -tA -c "$2"; }

# Runs the Prisma CLI of IMAGE against scratch database DB.
run_prisma() {
  local image="$1" db="$2"; shift 2
  docker run --rm --network "${SCRATCH_NET}" -e CHECKPOINT_DISABLE=1 \
    -e DATABASE_URL="postgresql://kubedok:${SCRATCH_PASSWORD}@${SCRATCH_PG}:5432/${db}" \
    --entrypoint sh "${image}" -c 'cd /app/apps/api && exec ./node_modules/.bin/prisma "$@"' prisma "$@"
}

# "name checksum" for each migration an image ships, in order. Prisma's
# checksum is the SHA-256 of migration.sql.
image_migrations() {
  docker run --rm --network none --entrypoint sh "$1" -c \
    'cd /app/apps/api/prisma/migrations && for d in */; do d="${d%/}"; [ -f "$d/migration.sql" ] && echo "$d $(sha256sum "$d/migration.sql" | cut -d" " -f1)"; done' \
    | LC_ALL=C sort
}

fail_with_log() {
  err "$1"
  tail -n "${3:-30}" "$2" | sed 's/^/      /' >&2
  exit 1
}

# What a schema consists of, one line each, for comparing two databases. Enum
# values are compared as sets: values added by later migrations sit at the end,
# where a fresh database lists them in schema order, and nothing orders by them.
SCHEMA_SQL="SELECT line FROM (
  SELECT 'column ' || table_name || '.' || column_name || ' ' || data_type || '/' || udt_name
         || ' null=' || is_nullable || ' default=' || coalesce(column_default, '') AS line
    FROM information_schema.columns WHERE table_schema = 'public'
  UNION ALL
  SELECT 'constraint ' || conrelid::regclass::text || ' ' || conname || ' ' || pg_get_constraintdef(oid)
    FROM pg_constraint WHERE connamespace = 'public'::regnamespace
  UNION ALL
  SELECT 'index ' || indexname || ' ' || indexdef FROM pg_indexes WHERE schemaname = 'public'
  UNION ALL
  SELECT 'enum ' || t.typname || ' ' || string_agg(e.enumlabel, ',' ORDER BY e.enumlabel)
    FROM pg_type t JOIN pg_enum e ON e.enumtypid = t.oid
   WHERE t.typnamespace = 'public'::regnamespace GROUP BY t.typname
  UNION ALL
  SELECT 'migration ' || migration_name || ' ' || checksum FROM _prisma_migrations
) x ORDER BY line"

# The data fixes: what the releases since 0.0.x changed the meaning of, and that
# no migration converts. Run once the chain is applied.
DATA_FIXES_SQL="BEGIN;
-- A load balancer kept its one certificate as configJson.certificateId. Current
-- releases read only certificateIds, so without this every HTTPS listener loses
-- its certificate and the certificate reads as unused.
UPDATE stack_services
   SET \"configJson\" = (\"configJson\" - 'certificateId')
       || CASE WHEN coalesce(\"configJson\"->>'certificateId', '') = '' THEN '{}'::jsonb
               ELSE jsonb_build_object('certificateIds', jsonb_build_array(\"configJson\"->>'certificateId')) END
 WHERE \"configJson\" ? 'certificateId';
-- The same inside stored stack specs, which are read for stacks without service rows.
UPDATE stacks s
   SET \"normalizedSpec\" = jsonb_set(s.\"normalizedSpec\", '{services}', (
         SELECT jsonb_agg(CASE WHEN svc ? 'certificateId' THEN
                  (svc - 'certificateId')
                  || CASE WHEN coalesce(svc->>'certificateId', '') = '' THEN '{}'::jsonb
                          ELSE jsonb_build_object('certificateIds', jsonb_build_array(svc->>'certificateId')) END
                ELSE svc END ORDER BY ord)
           FROM jsonb_array_elements(s.\"normalizedSpec\"->'services') WITH ORDINALITY AS t(svc, ord)))
 WHERE jsonb_typeof(s.\"normalizedSpec\"->'services') = 'array'
   AND EXISTS (SELECT 1 FROM jsonb_array_elements(s.\"normalizedSpec\"->'services') e WHERE e ? 'certificateId');
-- Nightly host clean-up did not exist in 0.0.x, and the migration that added it
-- turned it on for every host. It removes stopped containers that are not
-- Kubedok's and unused images, so it stays off until someone turns it on.
UPDATE hosts SET \"autoCleanup\" = false;
COMMIT;"

FORCE_SQL="BEGIN;
UPDATE agent_commands SET status = 'TIMED_OUT', \"completedAt\" = now(),
       \"errorMessage\" = coalesce(\"errorMessage\", 'Interrupted by the move from the single-container install')
 WHERE status::text IN ('PENDING','SENT');
UPDATE deployments SET status = 'CANCELLED', \"finishedAt\" = now() WHERE status::text IN ('PENDING','RUNNING');
UPDATE resource_operations SET status = 'CANCELLED', \"finishedAt\" = now() WHERE status::text IN ('QUEUED','SENT','RUNNING');
UPDATE rollout_campaigns SET status = 'ABORTED', \"finishedAt\" = now(), \"nextTickAt\" = NULL
 WHERE status::text IN ('PENDING','RUNNING','PAUSED','ROLLING_BACK');
COMMIT;"

# Re-encrypts every stored value under NEW_KEY_FILE. Only the columns 0.0.x
# could have filled are expected to hold anything, and the rest are refused:
# keys derived from the encryption key (two-factor codes, the ACME account)
# would not survive a rotation.
rotate_encryption_key() {
  log "Re-encrypting stored credentials under a new key"
  local others
  others="$(scratch_query kubedok "SELECT
      (SELECT count(*) FROM acme_orders) + (SELECT count(*) FROM email_settings WHERE \"secretEnc\" IS NOT NULL)
    + (SELECT count(*) FROM users WHERE \"totpSecretEnc\" IS NOT NULL) + (SELECT count(*) FROM two_factor_challenges)
    + (SELECT count(*) FROM ai_settings WHERE \"apiKeyEnc\" IS NOT NULL)")"
  [ "${others}" = "0" ] || die "Data a single-container install cannot have holds encrypted values, so the key is not rotated."
  local rows
  rows="$(scratch_query kubedok "
    SELECT 'container_registries' || E'\t' || 'passwordEnc' || E'\t' || id || E'\t' || \"passwordEnc\" FROM container_registries WHERE \"passwordEnc\" IS NOT NULL
    UNION ALL SELECT 'load_balancer_certificates' || E'\t' || 'certificatePemEnc' || E'\t' || id || E'\t' || \"certificatePemEnc\" FROM load_balancer_certificates
    UNION ALL SELECT 'load_balancer_certificates' || E'\t' || 'privateKeyPemEnc' || E'\t' || id || E'\t' || \"privateKeyPemEnc\" FROM load_balancer_certificates
    UNION ALL SELECT 'load_balancer_certificates' || E'\t' || 'fullchainPemEnc' || E'\t' || id || E'\t' || \"fullchainPemEnc\" FROM load_balancer_certificates WHERE \"fullchainPemEnc\" IS NOT NULL")"
  ( umask 077; openssl rand -hex 32 > "${WORK}/new-secrets/registry-encryption-key" )
  [ -n "${rows}" ] || { ok "Nothing stored to re-encrypt; the new install gets a new key"; return 0; }
  { tr -d '\r\n' < "${WORK}/old-secrets/registry-encryption-key"; printf '\n'
    tr -d '\r\n' < "${WORK}/new-secrets/registry-encryption-key"; printf '\n%s\n' "${rows}"; } \
    | docker run --rm -i --network none --entrypoint node "${OLD_IMAGE_ID}" -e '
      const crypto = require("crypto");
      const lines = require("fs").readFileSync(0, "utf8").split("\n");
      const oldKey = Buffer.from(lines.shift().trim(), "hex");
      const newKey = Buffer.from(lines.shift().trim(), "hex");
      const q = (s) => "\x27" + String(s).replace(/\x27/g, "\x27\x27") + "\x27";
      console.log("BEGIN;");
      for (const line of lines) {
        if (!line) continue;
        const [table, column, id, value] = line.split("\t");
        const buf = Buffer.from(value, "base64");
        const d = crypto.createDecipheriv("aes-256-gcm", oldKey, buf.subarray(0, 12), { authTagLength: 16 });
        d.setAuthTag(buf.subarray(12, 28));
        const plain = Buffer.concat([d.update(buf.subarray(28)), d.final()]);
        const iv = crypto.randomBytes(12);
        const c = crypto.createCipheriv("aes-256-gcm", newKey, iv, { authTagLength: 16 });
        const enc = Buffer.concat([c.update(plain), c.final()]);
        const out = Buffer.concat([iv, c.getAuthTag(), enc]).toString("base64");
        console.log("UPDATE \"" + table + "\" SET \"" + column + "\" = " + q(out) + " WHERE id = " + q(id) + ";");
      }
      console.log("COMMIT;");' > "${WORK}/rotate.sql" \
    || die "Could not re-encrypt the stored credentials."
  scratch_psql kubedok < "${WORK}/rotate.sql" > "${WORK}/rotate.log" 2>&1 \
    || fail_with_log "Writing the re-encrypted values failed:" "${WORK}/rotate.log"
  rm -f "${WORK}/rotate.sql"
  ok "Re-encrypted $(printf '%s\n' "${rows}" | grep -c .) values"
}

# Credentials a deploy sends, 0.0.x against now: 0.0.x sent the environment's
# default registry's for any image without a registry of its own; current
# releases send the credentials of a registry on the image's own host. Lists
# the services whose pull changes, which matters for private images.
report_registry_matching() {
  local rows out
  rows="$(scratch_query kubedok "
    SELECT 'R' || E'\t' || \"environmentId\" || E'\t' || id || E'\t' || name || E'\t' || url || E'\t' || \"isDefault\" || E'\t' || (username IS NOT NULL AND \"passwordEnc\" IS NOT NULL)
      FROM container_registries
    UNION ALL
    SELECT 'S' || E'\t' || st.\"environmentId\" || E'\t' || st.name || '/' || ss.name || E'\t' || ss.image
      FROM stack_services ss JOIN stacks st ON st.id = ss.\"stackId\"
     WHERE ss.\"registryId\" IS NULL")"
  [ -n "${rows}" ] || return 0
  out="$(printf '%s\n' "${rows}" | docker run --rm -i --network none --entrypoint node "${TARGET_SERVER}" -e '
    let match;
    try { ({ registryServesImage: match } = require("/app/apps/api/dist/registries/registry-host.js")); }
    catch (e) { console.log("SKIP"); process.exit(0); }
    const regs = [], svcs = [];
    for (const line of require("fs").readFileSync(0, "utf8").split("\n")) {
      const f = line.split("\t");
      if (f[0] === "R") regs.push({ env: f[1], id: f[2], name: f[3], url: f[4], isDefault: f[5] === "true", creds: f[6] === "true" });
      if (f[0] === "S") svcs.push({ env: f[1], name: f[2], image: f[3] });
    }
    for (const s of svcs) {
      const inEnv = regs.filter((r) => r.env === s.env);
      const before = inEnv.find((r) => r.isDefault && r.creds);
      if (!before) continue;
      const serving = inEnv.filter((r) => match(r.url, s.image));
      const now = (serving.find((r) => r.isDefault) || serving[0]);
      const nowCreds = now && now.creds ? now : null;
      if (!nowCreds || nowCreds.id !== before.id) {
        console.log(s.name + " (" + s.image + ") pulled with " + before.name + "\x27s credentials, now " + (nowCreds ? nowCreds.name + "\x27s" : "none"));
      }
    }' 2>/dev/null || echo SKIP)"
  if [ "${out}" = "SKIP" ]; then
    warn "Could not compare registry credentials for this release; check private images after the move."
  elif [ -n "${out}" ]; then
    note "Deploys pick registry credentials by the image's host now, not the environment's default registry. Changed, which matters if the image is private (set its registry on the service):"
    printf '%s\n' "${out}" | sed 's/^/      /' >&2
  fi
}

# Brings the dump in WORK/monolith.sql forward on a scratch copy and leaves the
# result in WORK/database.sql, after checking it against a fresh database of the
# target release.
upgrade_database() {
  log "Bringing the data forward on a scratch copy"
  start_scratch
  scratch_psql kubedok < "${WORK}/monolith.sql" > "${WORK}/scratch-load.log" 2>&1 \
    || fail_with_log "Loading the old database into the scratch copy failed:" "${WORK}/scratch-load.log"
  ok "Loaded into PostgreSQL $(scratch_query kubedok 'SHOW server_version' | cut -d' ' -f1)"

  # Checked again on this copy: work may have started since the report.
  if [ "${FORCE}" != "true" ] && [ "$(scratch_query kubedok "${INFLIGHT_SQL}")" != "0" ]; then
    die "Deploys, rollouts or agent commands started while the migration ran. Let them finish and run this again, or pass --force."
  fi

  # The history has to be the start of 1.4.8's, migration for migration.
  local chain target applied i=0 line want rest count
  chain="$(image_migrations "${CHAIN_IMAGE}")" || die "Could not read the migrations in ${CHAIN_IMAGE}."
  target="$(image_migrations "${TARGET_SERVER}")" || die "Could not read the migrations in ${TARGET_SERVER}."
  [ -n "${chain}" ] && [ -n "${target}" ] || die "Could not read the migrations the server images ship."
  [ "${chain%% *}" = "${target%% *}" ] \
    || die "Release ${TARGET_RELEASE} does not start its migrations where 1.4.8's start, so this script cannot bring the data to it."
  applied="$(scratch_query kubedok "SELECT migration_name || ' ' || checksum || ' ' || (finished_at IS NOT NULL) || ' ' || (rolled_back_at IS NOT NULL) FROM _prisma_migrations ORDER BY migration_name")"
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    i=$((i + 1))
    want="$(printf '%s\n' "${chain}" | sed -n "${i}p")"
    rest="${line#* * }"
    [ "${line% "${rest}"}" = "${want}" ] && [ "${rest}" = "true false" ] \
      || die "The old migration history differs from 1.4.8's at entry ${i} (${line%% *}). It cannot be brought forward by this script."
  done <<<"${applied}"
  count="$(printf '%s\n' "${chain}" | grep -c .)"
  ok "History matches 1.4.8's first ${i} of ${count} migrations"

  run_prisma "${CHAIN_IMAGE}" kubedok migrate deploy > "${WORK}/chain.log" 2>&1 \
    || fail_with_log "Applying the old migrations failed:" "${WORK}/chain.log"
  [ "$(scratch_query kubedok "SELECT count(*) FROM _prisma_migrations WHERE finished_at IS NOT NULL AND rolled_back_at IS NULL")" = "${count}" ] \
    || fail_with_log "Not every old migration was applied:" "${WORK}/chain.log"
  ok "Applied the $((count - i)) migrations the old database was missing"

  scratch_psql kubedok -c "${DATA_FIXES_SQL}" > "${WORK}/fixes.log" 2>&1 \
    || fail_with_log "The data fixes failed:" "${WORK}/fixes.log"
  scratch_psql kubedok -c "${SETTLE_SQL}" > "${WORK}/settle.log" 2>&1 \
    || fail_with_log "Closing the work 0.0.x left unfinished failed:" "${WORK}/settle.log"
  if [ "${FORCE}" = "true" ]; then
    scratch_psql kubedok -c "${FORCE_SQL}" > "${WORK}/force.log" 2>&1 \
      || fail_with_log "Settling the work in flight failed:" "${WORK}/force.log"
  fi
  ok "Data converted: load balancer certificates, host clean-up off"

  if [ "${ROTATE_KEY}" = "true" ]; then
    rotate_encryption_key
  fi

  # From here on the history is the target's: its first migration stands for
  # everything 1.4.8 applied, and it applies its own newer ones itself.
  local init_name init_sum
  init_name="${target%%$'\n'*}"
  init_sum="${init_name#* }"
  init_name="${init_name%% *}"
  scratch_psql kubedok -c "BEGIN;
    DELETE FROM _prisma_migrations WHERE migration_name <> '${init_name}';
    UPDATE _prisma_migrations SET checksum = '${init_sum}' WHERE migration_name = '${init_name}';
    COMMIT;" > "${WORK}/rebaseline.log" 2>&1 \
    || fail_with_log "Rewriting the migration history failed:" "${WORK}/rebaseline.log"
  run_prisma "${TARGET_SERVER}" kubedok migrate deploy > "${WORK}/target.log" 2>&1 \
    || fail_with_log "Applying release ${TARGET_RELEASE}'s migrations failed:" "${WORK}/target.log"
  ok "Applied release ${TARGET_RELEASE}'s own migrations"

  # The proof: the result against a database the target release made itself.
  scratch_query kubedok "CREATE DATABASE kubedok_fresh" >/dev/null
  run_prisma "${TARGET_SERVER}" kubedok_fresh migrate deploy > "${WORK}/fresh.log" 2>&1 \
    || fail_with_log "Creating a fresh ${TARGET_RELEASE} database to compare with failed:" "${WORK}/fresh.log"
  scratch_query kubedok "${SCHEMA_SQL}" > "${WORK}/schema-migrated.txt"
  scratch_query kubedok_fresh "${SCHEMA_SQL}" > "${WORK}/schema-fresh.txt"
  if ! diff "${WORK}/schema-fresh.txt" "${WORK}/schema-migrated.txt" > "${WORK}/schema.diff"; then
    fail_with_log "The migrated schema differs from a fresh ${TARGET_RELEASE} database (< fresh, > migrated):" "${WORK}/schema.diff" 40
  fi
  run_prisma "${TARGET_SERVER}" kubedok migrate diff --from-url \
    "postgresql://kubedok:${SCRATCH_PASSWORD}@${SCRATCH_PG}:5432/kubedok" \
    --to-schema-datamodel prisma/schema.prisma --exit-code > "${WORK}/prisma-diff.log" 2>&1 \
    || fail_with_log "Prisma finds the migrated schema different from release ${TARGET_RELEASE}'s:" "${WORK}/prisma-diff.log"
  scratch_query kubedok "DROP DATABASE kubedok_fresh" >/dev/null
  ok "Schema identical to a fresh ${TARGET_RELEASE} database"

  check_decryption scratch "${WORK}/new-secrets/registry-encryption-key"
  report_registry_matching

  EXPECTED_COUNTS="$(scratch_query kubedok "${COUNTS_SQL}")"
  docker exec "${SCRATCH_PG}" pg_dump -U kubedok --clean --if-exists --no-owner --no-privileges kubedok \
    > "${WORK}/database.sql" 2>"${WORK}/database-dump.err" \
    || fail_with_log "Dumping the migrated database failed:" "${WORK}/database-dump.err"
  remove_scratch
  ok "Migrated database ready ($(du -h "${WORK}/database.sql" | cut -f1))"
}

# What must come through unchanged. Environments are left out: the server
# creates a default one at boot when there is none.
COUNTS_SQL="SELECT 'users=' || (SELECT count(*) FROM users) || ' hosts=' || (SELECT count(*) FROM hosts)
  || ' stacks=' || (SELECT count(*) FROM stacks)
  || ' services=' || (SELECT count(*) FROM stack_services) || ' registries=' || (SELECT count(*) FROM container_registries)
  || ' certificates=' || (SELECT count(*) FROM load_balancer_certificates)"

# The secrets the new install starts with: the encryption key carried over (or
# a new one, written by rotate_encryption_key), and a new JWT secret unless
# asked to keep it.
prepare_new_secrets() {
  local dir="${WORK}/new-secrets"
  mkdir -p "${dir}"; chmod 700 "${dir}"
  ( umask 077
    cp "${WORK}/old-secrets/registry-encryption-key" "${dir}/registry-encryption-key"
    if [ "${KEEP_JWT}" = "true" ]; then
      cp "${WORK}/old-secrets/jwt-secret" "${dir}/jwt-secret"
    else
      openssl rand -hex 32 > "${dir}/jwt-secret"
    fi )
}

# A backup archive of the migrated data, in kbd backup's format, for setup.sh
# to start the new install from. It stays in the backups as the install's first.
build_archive() {
  local dir="${WORK}/archive"
  mkdir -p "${dir}/secrets"; chmod 700 "${dir}" "${dir}/secrets"
  mv "${WORK}/database.sql" "${dir}/database.sql"
  install -m 600 "${WORK}/new-secrets/registry-encryption-key" "${dir}/secrets/registry-encryption-key"
  install -m 600 "${WORK}/new-secrets/jwt-secret" "${dir}/secrets/jwt-secret"
  jq -n --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg release "${TARGET_RELEASE}" \
        --arg image "${OLD_IMAGE}" --arg container "${OLD_CONTAINER}" \
    '{schemaVersion: 1, createdAt: $created, release: $release, label: "migrated",
      postgresUser: "kubedok", postgresDb: "kubedok", contains: ["database.sql", "secrets"],
      migratedFrom: {image: $image, container: $container}}' > "${dir}/backup.json"
  ARCHIVE="${WORK}/kubedok-${STAMP}-migrated.tar.gz"
  ( umask 077; tar -czf "${ARCHIVE}" -C "${dir}" . )
}

# ── The new install ──────────────────────────────────────────────────────────
check_fresh_target() {
  if [ -e "${KUBEDOK_ROOT}" ] && [ -n "$(ls -A "${KUBEDOK_ROOT}" 2>/dev/null)" ]; then
    die "${KUBEDOK_ROOT} already holds an install. The migration makes a new one; move it away first."
  fi
  docker volume inspect kubedok_postgres_data >/dev/null 2>&1 \
    && die "The volume kubedok_postgres_data already exists. The migration makes a new install; remove it first if its data is not needed."
  local name
  for name in kubedok-postgres kubedok-server kubedok-nginx; do
    docker container inspect "${name}" >/dev/null 2>&1 \
      && die "A container named ${name} already exists. The migration makes a new install; remove it first."
  done
  return 0
}

run_setup() {
  local vars=("KUBEDOK_RESTORE_FROM=${ARCHIVE}") net
  [ -n "${KUBEDOK_TLS+x}" ] || vars+=(KUBEDOK_TLS=off)
  if [ -z "${KUBEDOK_HTTP_PORT+x}" ] && [ -n "${OLD_HTTP_PORT}" ]; then
    vars+=("KUBEDOK_HTTP_PORT=${OLD_HTTP_PORT}")
  fi
  if [ -z "${KUBEDOK_HTTP_BIND+x}" ] && [ -n "${OLD_HTTP_BIND}" ] && [ "${OLD_HTTP_BIND}" != "0.0.0.0" ]; then
    if [[ "${OLD_HTTP_BIND}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      vars+=("KUBEDOK_HTTP_BIND=${OLD_HTTP_BIND}")
      # Not on loopback, so setup.sh and the checks below reach nginx there.
      if [ "${OLD_HTTP_BIND}" != "127.0.0.1" ] && [ -z "${KUBEDOK_LOCAL_BASE_URL:-}" ] && [ "${KUBEDOK_TLS:-off}" = "off" ]; then
        export KUBEDOK_LOCAL_BASE_URL="http://${OLD_HTTP_BIND}:${KUBEDOK_HTTP_PORT:-${OLD_HTTP_PORT:-80}}"
      fi
    else
      warn "The old container was published on ${OLD_HTTP_BIND}, which the new install cannot take; it listens on every address."
    fi
  fi
  vars+=(${CARRIED_SETTINGS[@]+"${CARRIED_SETTINGS[@]}"})

  for net in "${KUBEDOK_NETWORK_DB}" "${KUBEDOK_NETWORK_PROXY}"; do
    docker network inspect "${net}" >/dev/null 2>&1 || CREATED_NETWORKS="${CREATED_NETWORKS} ${net}"
  done

  log "Installing release ${TARGET_RELEASE} with setup.sh"
  env "${vars[@]}" "${SCRIPT_DIR}/setup.sh" || die "setup.sh failed."
}

verify_new_install() {
  log "Checking the new install"
  load_config
  wait_for_http "$(local_base_url)/api/health" 90 || die "The new install does not answer at $(local_base_url)/api/health."
  local got release
  got="$(docker exec kubedok-postgres psql -X -tA -U "${KUBEDOK_POSTGRES_USER:-kubedok}" -d "${KUBEDOK_POSTGRES_DB:-kubedok}" -c "${COUNTS_SQL}")"
  [ "${got}" = "${EXPECTED_COUNTS}" ] \
    || die "The new install holds different data than the migrated copy: ${got}, expected ${EXPECTED_COUNTS}."
  ok "Data present: ${got}"
  release="$(local_curl -fsS --max-time 10 "$(local_base_url)/api/version" 2>/dev/null | jq -r '.release // empty' || true)"
  [ -z "${release}" ] || ok "The API reports release ${release}"
}

# ── Rollback ─────────────────────────────────────────────────────────────────
rollback() {
  err "The migration failed. Going back to ${OLD_CONTAINER}."
  stop_source_db
  docker rm -f kubedok-nginx kubedok-server kubedok-postgres >/dev/null 2>&1 || true
  docker volume rm kubedok_postgres_data >/dev/null 2>&1 || true
  local net
  for net in ${CREATED_NETWORKS}; do
    docker network rm "${net}" >/dev/null 2>&1 || true
  done
  if [ "${CREATED_ROOT}" = "true" ] && [ -d "${KUBEDOK_ROOT}" ]; then
    if [ "$(readlink "${KUBEDOK_KBD_LINK}" 2>/dev/null)" = "${KUBEDOK_CURRENT_LINK}/scripts/kbd" ]; then
      rm -f "${KUBEDOK_KBD_LINK}"
    fi
    local aside
    aside="${KUBEDOK_ROOT}.failed-${STAMP}"
    if mv "${KUBEDOK_ROOT}" "${aside}" 2>/dev/null; then
      warn "The unfinished install is in ${aside}, for its logs and settings. It holds secrets: remove it when done."
    fi
  fi
  docker update --restart "${OLD_RESTART}" "${OLD_CONTAINER}" >/dev/null 2>&1 || true
  if [ "${OLD_WAS_RUNNING}" = "true" ]; then
    if docker start "${OLD_CONTAINER}" >/dev/null 2>&1 \
       && ( wait_for_container_health "${OLD_CONTAINER}" 240 ) >/dev/null 2>&1; then
      err "${OLD_CONTAINER} is running again, on its own data, which was never changed."
    else
      err "Could not bring ${OLD_CONTAINER} back up by itself. Start it with: docker start ${OLD_CONTAINER}"
    fi
  else
    err "${OLD_CONTAINER} was stopped before the migration and stays stopped."
  fi
}

# ── Summary ──────────────────────────────────────────────────────────────────
print_next_steps() {
  local backups="${KUBEDOK_BACKUPS_DIR}"
  printf '\n'
  printf '%s────────────────────────────────────────────────────────%s\n' "${_c_green}" "${_c_reset}"
  printf '  Migrated %s to Kubedok %s\n' "${OLD_CONTAINER}" "$(current_release 2>/dev/null || echo "${TARGET_RELEASE}")"
  printf '%s────────────────────────────────────────────────────────%s\n' "${_c_green}" "${_c_reset}"
  printf '\n'
  printf '  Encryption key   %s\n' "$([ "${ROTATE_KEY}" = "true" ] && echo "new; stored credentials re-encrypted" || echo "carried over; stored credentials stay readable")"
  printf '  JWT secret       %s\n' "$([ "${KEEP_JWT}" = "true" ] && echo "carried over" || echo "new; open pages renew their token, sign-ins stay valid")"
  printf '  First backup     %s/kubedok-%s-migrated.tar.gz\n' "${backups}" "${STAMP}"
  printf '  Old database     %s/monolith-%s.sql.gz (as the old install left it)\n' "${backups}" "${STAMP}"
  printf '\n'
  printf '  The old container is stopped, with restart policy no, and its data is\n'
  printf '  untouched. To go back, before any agent has moved to the new version:\n'
  printf '    sudo %s && docker update --restart %s %s && docker start %s\n' \
    "$(command_hint uninstall)" "${OLD_RESTART}" "${OLD_CONTAINER}" "${OLD_CONTAINER}"
  if [ -n "${OLD_COMPOSE_PROJECT}" ]; then
    printf '  It was started by Docker Compose (project %s): do not bring that project\n' "${OLD_COMPOSE_PROJECT}"
    printf '  up again, or it takes the port back.\n'
  fi
  printf '  Once you are satisfied, remove it:\n'
  printf '    docker rm %s' "${OLD_CONTAINER}"
  if [ -n "${OLD_VOLUME}" ] && [[ "${OLD_VOLUME}" != /* ]]; then
    printf ' && docker volume rm %s' "${OLD_VOLUME}"
  fi
  printf '\n\n'
  if [ "${OLD_HOST_COUNT:-0}" != "0" ]; then
    printf '  %sHosts%s: %s. Their agents reconnect to this install and their containers keep\n' "${_c_yellow}" "${_c_reset}" "${OLD_HOST_COUNT}"
    printf '  running, but an agent older than %s cannot deploy. On each host, from a clone\n' "$(manifest_field minimumAgentVersion "${TARGET_MANIFEST}")"
    printf '  of this repository, move its agent to %s, keeping the host as it is:\n' "${TARGET_AGENT_VERSION}"
    printf '    sudo ./scripts/agent-install.sh --adopt\n'
    printf '  Never register a host again with a new token: that makes a second host, and\n'
    printf '  deleting the first deletes the stacks that ran only there.\n\n'
    printf '  Then redeploy each service once. Containers 0.0.x started find each other\n'
    printf '  by Docker network aliases, which new containers do not have: one that\n'
    printf '  still runs as 0.0.x started it can lose the services redeployed before it.\n'
    printf '  So redeploy the services that connect to others before the ones they\n'
    if [ -n "${REDEPLOY_ORDER}" ]; then
      printf '  connect to, here:\n%s\n' "${REDEPLOY_ORDER}"
    else
      printf '  connect to.\n\n'
    fi
  fi
  if [ "${WARNINGS}" -gt 0 ]; then
    printf '  %s%s warning(s) above%s need a look.\n\n' "${_c_yellow}" "${WARNINGS}" "${_c_reset}"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  INFLIGHT_BLOCKS=false
  printf '\n%sKubedok: migrate from the single-container image%s\n\n' "${_c_blue}" "${_c_reset}"

  find_old_container
  read_old_facts
  log "Reading ${OLD_CONTAINER}"
  read_old_secrets
  if [ "${OLD_WAS_RUNNING}" = "true" ]; then
    OLD_DB_CONTAINER="${OLD_CONTAINER}"
  else
    start_source_db
  fi
  report_old_install

  if [ "${MODE}" = "check" ]; then
    stop_source_db
    printf '\n'
    if [ "${INFLIGHT_BLOCKS}" = "true" ] || [ "${PORTS_BLOCK}" = "true" ]; then
      warn "Not ready yet: see the warnings above."
    else
      ok "Ready to migrate. Rehearse it on a copy with --dry-run; nothing was changed."
    fi
    exit 0
  fi

  if [ "${MODE}" = "migrate" ]; then
    [ "${INFLIGHT_BLOCKS}" != "true" ] || die "Work is in flight (see above). Let it finish, or pass --force."
    [ "${PORTS_BLOCK}" != "true" ] || die "A port the new install needs is in use (see above)."
    check_fresh_target
  fi

  resolve_target
  pull_images
  prepare_new_secrets

  if [ "${MODE}" = "dry-run" ]; then
    # A live dump: a consistent snapshot while the old install keeps serving.
    dump_old_database
    stop_source_db
    upgrade_database
    printf '\n'
    ok "Rehearsal passed: the data comes forward to ${TARGET_RELEASE} intact. Nothing was changed."
    printf '\n  The migration itself stops %s, dumps it, repeats these steps on that\n' "${OLD_CONTAINER}"
    printf '  dump, and installs the result with setup.sh. Kubedok is unreachable for\n'
    printf '  those minutes; containers on your hosts keep running.\n\n'
    [ "${WARNINGS}" -eq 0 ] || warn "${WARNINGS} warning(s) above need a look first."
    exit 0
  fi

  if [ "${ASSUME_YES}" != "true" ]; then
    printf '\n  This stops %s and installs Kubedok %s in %s.\n' "${OLD_CONTAINER}" "${TARGET_RELEASE}" "${KUBEDOK_ROOT}"
    printf '  Kubedok is unreachable until it finishes; containers on your hosts keep running.\n'
    printf '  Continue? [y/N] '
    local answer=""
    read -r answer || true
    case "${answer}" in y|Y|yes|YES) ;; *) die "Aborted. Nothing was changed." ;; esac
  fi

  [ -e "${KUBEDOK_ROOT}" ] || CREATED_ROOT=true
  [ -n "$(ls -A "${KUBEDOK_ROOT}" 2>/dev/null)" ] || CREATED_ROOT=true

  # From here on, a failure brings the old container back (on_exit).
  STOPPED_OLD=true
  docker update --restart no "${OLD_CONTAINER}" >/dev/null
  if [ "${OLD_WAS_RUNNING}" = "true" ]; then
    log "Stopping ${OLD_CONTAINER}"
    docker stop -t 120 "${OLD_CONTAINER}" >/dev/null || die "Could not stop ${OLD_CONTAINER}."
    ok "${OLD_CONTAINER} stopped; Kubedok is down until the new install is up"
    start_source_db
  fi
  dump_old_database
  stop_source_db
  upgrade_database
  build_archive
  run_setup
  verify_new_install

  COMMITTED=true
  install -d -m 700 "${KUBEDOK_BACKUPS_DIR}"
  install -m 600 "${ARCHIVE}" "${KUBEDOK_BACKUPS_DIR}/kubedok-${STAMP}-migrated.tar.gz"
  ( umask 077; gzip -c "${WORK}/monolith.sql" > "${KUBEDOK_BACKUPS_DIR}/monolith-${STAMP}.sql.gz" )
  print_next_steps
}

main
