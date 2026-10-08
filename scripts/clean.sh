#!/usr/bin/env bash
#
# Remove what updates leave behind.
#
#   kbd clean               # show what would go, ask, remove it
#   kbd clean --dry-run     # show it only
#   kbd clean --yes         # without asking
#   kbd clean --releases    # also release trees other than current and previous
#
# Goes: Kubedok images that no release tree on disk and no agent here uses,
# such as those of releases update.sh has pruned, the ones a version published
# again replaced, and an agent's from before its update; and the staging area
# of an update that was killed. Stays: every image a release tree on disk
# names, so a rollback to it needs no registry, any image a container uses,
# and any that is tagged: the scripts pull by digest, so someone else tagged it.
#
# --releases also removes the release trees other than current and previous,
# which kbd rollback can no longer go to, and then their images. Backups are
# not touched: backup.sh keeps the newest ten.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

DRY_RUN=false
ASSUME_YES=false
RELEASES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --yes|-y) ASSUME_YES=true; shift ;;
    --releases) RELEASES=true; shift ;;
    -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_root
require_installed
require_cmd docker jq flock
load_config

# An update or a rollback in progress has a staged tree and images it is
# pulling, which would look like leftovers. The lock rules that out.
acquire_lock

CURRENT="$(current_release)" || die "No current release is recorded. Is this a complete install?"
PREVIOUS="$(previous_release || true)"

# ── What goes ────────────────────────────────────────────────────────────────
TREES=()
if [ "${RELEASES}" = "true" ]; then
  while read -r rel; do
    [ -n "${rel}" ] || continue
    [ "${rel}" = "${CURRENT}" ] || [ "${rel}" = "${PREVIOUS}" ] || TREES+=("${rel}")
  done < <(list_releases)
fi

going() {
  local rel
  for rel in ${TREES[@]+"${TREES[@]}"}; do
    [ "${rel}" = "$1" ] && return 0
  done
  return 1
}

# Every image a manifest on disk names, and the agent's. Kept are those of the
# trees that stay; the repositories they come from are where to look.
KEEP=" "
REPOS=" "
note_image() {
  local ref="$1" keep="$2"
  [ -n "${ref}" ] && [ "${ref}" != "null" ] || return 0
  [ "${keep}" = "true" ] && KEEP="${KEEP}${ref} "
  [[ "${REPOS}" == *" ${ref%@*} "* ]] || REPOS="${REPOS}${ref%@*} "
}

while read -r rel; do
  [ -n "${rel}" ] || continue
  manifest="${KUBEDOK_RELEASES_DIR}/${rel}/release.json"
  [ -f "${manifest}" ] || continue
  keep=true
  going "${rel}" && keep=false
  while read -r ref; do
    note_image "${ref}" "${keep}"
  done < <(jq -r '.images[]?' "${manifest}")
done < <(list_releases)

if [ -f "${KUBEDOK_AGENT_ROOT}/agent.env" ]; then
  note_image "$(sed -n 's/^KUBEDOK_IMAGE_AGENT=//p' "${KUBEDOK_AGENT_ROOT}/agent.env" | tail -n1)" true
fi

[ "${REPOS}" != " " ] || die "No release on disk names an image. Is this a complete install?"

# What containers use, running or stopped. docker refuses to remove those, so
# they are reported as kept rather than tried.
IN_USE=" $(docker ps -aq | xargs -r docker inspect -f '{{.Image}}' 2>/dev/null | sort -u | tr '\n' ' ')"

# The scripts pull by digest only, so a tagged image was put here by someone
# else. Removing one by digest takes its tags too, so it stays.
IMAGES=()
SIZES=()
BUSY=()
TAGGED=()
for repo in ${REPOS}; do
  rows="$(docker image ls --digests --format '{{.Repository}}@{{.Digest}}\t{{.Tag}}\t{{.Size}}' "${repo}" | sort -u)"
  tagged=" $(awk -F'\t' '$2 != "<none>" {print $1}' <<<"${rows}" | tr '\n' ' ')"
  while IFS=$'\t' read -r ref tag size; do
    [[ "${ref}" == *"@sha256:"* ]] || continue
    [[ "${KEEP}" == *" ${ref} "* ]] && continue
    if [[ "${tagged}" == *" ${ref} "* ]]; then
      [ "${tag}" = "<none>" ] || TAGGED+=("${repo}:${tag}")
      continue
    fi
    id="$(docker image inspect -f '{{.Id}}' "${ref}" 2>/dev/null || true)"
    if [ -n "${id}" ] && [[ "${IN_USE}" == *" ${id} "* ]]; then
      BUSY+=("${ref}")
      continue
    fi
    IMAGES+=("${ref}")
    SIZES+=("${size}")
  done <<<"${rows}"
done

STAGING=false
[ -e "${KUBEDOK_STAGING_DIR}" ] && STAGING=true

# ── The plan ─────────────────────────────────────────────────────────────────
printf '\n'
report_kept() {
  local ref
  for ref in ${BUSY[@]+"${BUSY[@]}"}; do
    printf '  Kept %s: no release uses it, but a container does.\n' "${ref}"
  done
  for ref in ${TAGGED[@]+"${TAGGED[@]}"}; do
    printf '  Kept %s: no release uses it, but it is tagged, which updates never do.\n' "${ref}"
  done
  if [ ${#BUSY[@]} -gt 0 ] || [ ${#TAGGED[@]} -gt 0 ]; then
    printf '\n'
  fi
}

if [ ${#IMAGES[@]} -eq 0 ] && [ ${#TREES[@]} -eq 0 ] && [ "${STAGING}" = "false" ]; then
  ok "Nothing to clean."
  report_kept
  exit 0
fi

if [ ${#IMAGES[@]} -gt 0 ]; then
  printf '  Images no release on disk or agent uses:\n'
  for i in "${!IMAGES[@]}"; do
    printf '    %s  %s\n' "${IMAGES[$i]}" "${SIZES[$i]}"
  done
  printf '\n'
fi
if [ ${#TREES[@]} -gt 0 ]; then
  printf '  Release trees other than current (%s)%s:\n' "${CURRENT}" "${PREVIOUS:+ and previous (${PREVIOUS})}"
  for rel in "${TREES[@]}"; do
    printf '    %s\n' "${KUBEDOK_RELEASES_DIR}/${rel}"
  done
  printf '\n'
fi
if [ "${STAGING}" = "true" ]; then
  printf '  What an update that was stopped left staged:\n    %s\n\n' "${KUBEDOK_STAGING_DIR}"
fi
report_kept

if [ "${DRY_RUN}" = "true" ]; then
  log "Dry run: nothing was removed."
  exit 0
fi

if [ "${ASSUME_YES}" != "true" ]; then
  printf '  Remove these? [y/N] '
  read -r answer
  case "${answer}" in y|Y|yes|YES) ;; *) die "Aborted." ;; esac
fi

# ── Removal ──────────────────────────────────────────────────────────────────
for rel in ${TREES[@]+"${TREES[@]}"}; do
  rm -rf "${KUBEDOK_RELEASES_DIR:?}/${rel}"
  ok "Removed release tree ${rel}"
done

if [ "${STAGING}" = "true" ]; then
  rm -rf "${KUBEDOK_STAGING_DIR:?}"
  ok "Removed ${KUBEDOK_STAGING_DIR}"
fi

removed=0
for ref in ${IMAGES[@]+"${IMAGES[@]}"}; do
  # Without --force: an image a container started using meanwhile stays.
  if out="$(docker image rm "${ref}" 2>&1)"; then
    removed=$(( removed + 1 ))
  else
    warn "Kept ${ref}: ${out##*: }"
  fi
done
[ ${#IMAGES[@]} -eq 0 ] || ok "Removed ${removed} of ${#IMAGES[@]} image(s)"
