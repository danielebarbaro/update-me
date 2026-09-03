#!/usr/bin/env bash
#
# forge-wp-update.sh — same-major WordPress plugin updates via wp-cli on Forge.
#
# Updates each discovered WordPress install's plugins to the latest SAME-MAJOR
# version. Major bumps are skipped. Core, themes, and the database are never
# touched. After updating a site, its home URL is health-checked; on failure
# the run's updates for that site are rolled back.
#
# Usage:
#   forge-wp-update            # apply updates
#   forge-wp-update --dry-run  # show what would change, change nothing
#
# Must run as root (or as a user with passwordless sudo) so it can drop to each
# site owner with sudo -u.
#
set -uo pipefail

# --- Load config -----------------------------------------------------------
CONFIG="${FORGE_WP_UPDATE_CONFIG:-/etc/forge-wp-update/config}"
if [ ! -r "$CONFIG" ]; then
  echo "forge-wp-update: config not found or unreadable: $CONFIG" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG"

# Validate required values.
for var in SERVER_NAME SITES_ROOT LOG; do
  if [ -z "${!var:-}" ]; then
    echo "forge-wp-update: missing required config value: $var (in $CONFIG)" >&2
    exit 1
  fi
done

# Defaults (override in config if needed).
[ -z "${HEALTHCHECK_CODES+x}" ] && HEALTHCHECK_CODES="200 301 302"
[ -z "${IGNORE_FILENAME+x}" ] && IGNORE_FILENAME=".forge-wp-update-ignore"
# Opt-in: when set, commit updated plugin files to the site's git repo (if any).
[ -z "${COMMIT_AFTER_UPDATE+x}" ] && COMMIT_AFTER_UPDATE=""
[ -z "${GIT_COMMIT_NAME+x}" ] && GIT_COMMIT_NAME="forge-wp-update"
[ -z "${GIT_COMMIT_EMAIL+x}" ] && GIT_COMMIT_EMAIL="forge-wp-update@localhost"
# Opt-in: push to the tracked remote after a successful commit (never forced).
[ -z "${PUSH_AFTER_COMMIT+x}" ] && PUSH_AFTER_COMMIT=""

log() { echo "$(date '+%F %T') [wp-update] $*" >> "$LOG"; }

# major <version> -> leading integer before first dot, non-digits stripped.
major() {
  local v="${1%%.*}"
  v="${v//[!0-9]/}"
  echo "${v:-0}"
}

# same_major <v1> <v2> -> exit 0 if same major, else 1.
same_major() {
  [ "$(major "$1")" = "$(major "$2")" ]
}

# parse_owner <path> -> sets PS_OWNER to first segment under SITES_ROOT.
parse_owner() {
  local rel="${1#"$SITES_ROOT"/}"
  PS_OWNER="${rel%%/*}"
}

# is_healthy_code <code> -> exit 0 if code is in HEALTHCHECK_CODES.
is_healthy_code() {
  local code="$1" c
  # shellcheck disable=SC2086
  for c in $HEALTHCHECK_CODES; do
    [ "$code" = "$c" ] && return 0
  done
  return 1
}

# Run wp-cli as the site owner. stdout is returned to the caller; stderr is
# buffered and written to the log one prefixed line at a time. Raw stderr would
# land in the log unlabelled and ahead of the site's own log line (wp-cli writes
# it while running, log() writes after), which makes PHP warnings from one site
# look like they belong to the previous one.
wp_as() {
  local owner="$1" path="$2"; shift 2
  local err status line
  err="$(mktemp 2>/dev/null)" || err=""
  if [ -z "$err" ]; then
    sudo -u "$owner" -H wp --path="$path" "$@" 2>>"$LOG"
    return $?
  fi
  sudo -u "$owner" -H wp --path="$path" "$@" 2>"$err"; status=$?
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && log "$path: wp-cli: $line"
  done < "$err"
  rm -f "$err"
  return "$status"
}

# health_check <owner> <path> -> exit 0 if home URL returns a healthy code.
# A wp-cli failure or an unreadable/empty home URL counts as UNHEALTHY: if we
# cannot confirm the site is up we must not assume it is, or rollback never fires.
health_check() {
  local owner="$1" path="$2" url code status
  url="$(wp_as "$owner" "$path" option get home)"; status=$?
  if [ "$status" -ne 0 ] || [ -z "$url" ]; then
    log "$path: cannot read home url (wp-cli status=$status), treating as unhealthy"
    return 1
  fi
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>>"$LOG")"
  if is_healthy_code "$code"; then
    return 0
  fi
  log "$path: health check got HTTP $code from $url"
  return 1
}

# git_commit_plugins <owner> <path> <slug...>: opt-in, best-effort. If the site
# is a git repo, stage the updated plugin dirs and commit. Never fails the run.
git_commit_plugins() {
  local owner="$1" path="$2"; shift 2
  [ -n "$COMMIT_AFTER_UPDATE" ] || return 0
  if ! command -v git >/dev/null; then
    log "$path: git not found, skip commit"
    return 0
  fi
  if ! sudo -u "$owner" -H git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "$path: not a git repo, skip commit"
    return 0
  fi
  local -a paths=()
  local slug
  for slug in "$@"; do paths+=("wp-content/plugins/$slug"); done

  # Commit ONLY the updated plugin paths. A path-scoped commit ignores whatever
  # else is staged or dirty, so unrelated site changes are never swept in.
  if [ -z "$(sudo -u "$owner" -H git -C "$path" status --porcelain -- "${paths[@]}" 2>>"$LOG")" ]; then
    log "$path: no plugin file changes to commit"
  else
    # Redirect runs as root (the script's user), which owns $LOG; sudo only drops
    # privileges for git itself, so SC2024 does not apply here.
    # shellcheck disable=SC2024
    if sudo -u "$owner" -H git -C "$path" \
        -c "user.name=$GIT_COMMIT_NAME" -c "user.email=$GIT_COMMIT_EMAIL" \
        commit -m "chore(plugins): same-major update $*" -- "${paths[@]}" >>"$LOG" 2>&1; then
      log "$path: committed plugin update ($*)"
      if [ -n "$PUSH_AFTER_COMMIT" ]; then
        # shellcheck disable=SC2024
        if sudo -u "$owner" -H git -C "$path" push >>"$LOG" 2>&1; then
          log "$path: pushed plugin update to remote"
        else
          log "ERROR: $path git push failed (check remote and credentials)"
        fi
      fi
    else
      log "ERROR: $path git commit failed"
    fi
  fi

  # Report any other pending changes left in the working tree (not committed).
  local others count
  others="$(sudo -u "$owner" -H git -C "$path" status --porcelain 2>>"$LOG")"
  if [ -n "$others" ]; then
    count="$(printf '%s\n' "$others" | grep -c '')"
    log "$path: $count other uncommitted file(s) left in repo, not committed (review manually)"
  fi
}

# update_site <owner> <path>: filter, apply, verify, rollback on failure.
update_site() {
  local owner="$1" path="$2"
  local ignore_file="$path/$IGNORE_FILENAME"
  local -a ignored=()
  if [ -r "$ignore_file" ]; then
    local raw
    while IFS= read -r raw || [ -n "$raw" ]; do
      raw="${raw%%#*}"
      raw="${raw//[[:space:]]/}"
      [ -n "$raw" ] && ignored+=("$raw")
    done < "$ignore_file"
  fi

  local csv status
  csv="$(wp_as "$owner" "$path" plugin list --update=available --fields=name,version,update_version --format=csv)"; status=$?
  if [ "$status" -ne 0 ]; then
    log "ERROR: $path wp-cli failed listing plugins (status=$status), skipping site"
    FAILURES=$((FAILURES+1))
    return 0
  fi

  # wp-cli prints the csv header even with zero results, so a non-empty $csv
  # does not mean there are updates: count the data rows instead.
  local -a names=() olds=()
  local name cur new ig skip
  local offered=0
  while IFS=, read -r name cur new; do
    [ "$name" = "name" ] && continue
    [ -z "$name" ] && continue
    offered=$((offered+1))
    skip=0
    for ig in "${ignored[@]:-}"; do
      [ "$ig" = "$name" ] && skip=1 && break
    done
    if [ "$skip" = 1 ]; then
      log "$path: skip $name (excluded)"
      continue
    fi
    if ! same_major "$cur" "$new"; then
      log "$path: skip $name ($cur -> $new) major bump"
      continue
    fi
    names+=("$name")
    olds+=("$cur")
  done <<< "$csv"

  if [ "$offered" -eq 0 ]; then
    log "$path: no plugin updates available"
    return 0
  fi
  if [ "${#names[@]}" -eq 0 ]; then
    log "$path: nothing eligible ($offered update(s) all filtered out)"
    return 0
  fi

  if [ -n "$DRY_RUN" ]; then
    log "$path: DRY-RUN would update: ${names[*]}"
    wp_as "$owner" "$path" plugin update "${names[@]}" --dry-run >> "$LOG" 2>&1
    return 0
  fi

  CURRENT_SITE_OWNER="$owner"
  CURRENT_SITE_PATH="$path"
  log "$path: updating ${#names[@]} plugin(s): ${names[*]}"
  if ! wp_as "$owner" "$path" plugin update "${names[@]}" >> "$LOG" 2>&1; then
    log "ERROR: $path plugin update command failed"
    FAILURES=$((FAILURES+1))
  fi

  if health_check "$owner" "$path"; then
    log "$path: healthy after update"
    git_commit_plugins "$owner" "$path" "${names[@]}"
  else
    log "ERROR: $path unhealthy after update, rolling back"
    local i
    for i in "${!names[@]}"; do
      if wp_as "$owner" "$path" plugin update "${names[$i]}" --version="${olds[$i]}" >> "$LOG" 2>&1; then
        log "$path: rolled back ${names[$i]} to ${olds[$i]}"
      else
        log "ERROR: $path rollback failed for ${names[$i]}"
      fi
    done
    if health_check "$owner" "$path"; then
      log "$path: healthy after rollback"
    else
      log "ERROR: $path STILL unhealthy after rollback"
    fi
    FAILURES=$((FAILURES+1))
  fi
  CURRENT_SITE_PATH=""
  CURRENT_SITE_OWNER=""
}

# Deactivate maintenance mode for any in-flight site on exit.
cleanup() {
  if [ -n "${CURRENT_SITE_PATH:-}" ] && [ -n "${CURRENT_SITE_OWNER:-}" ]; then
    sudo -u "$CURRENT_SITE_OWNER" -H wp --path="$CURRENT_SITE_PATH" maintenance-mode deactivate >/dev/null 2>&1 || true
  fi
}

# Allow tests to source functions without running.
[ -n "${SOURCED_ONLY:-}" ] && return 0

# --- Main ------------------------------------------------------------------
DRY_RUN=""
case "${1:-}" in
  ""|run) ;;
  --dry-run) DRY_RUN="--dry-run" ;;
  *) echo "Usage: $0 [--dry-run]" >&2; exit 1 ;;
esac

trap cleanup EXIT

# Single-run lock (skip silently if a run is already in progress).
LOCK="/var/lock/forge-wp-update.lock"
exec 9>"$LOCK" 2>/dev/null || true
if command -v flock >/dev/null && ! flock -n 9; then
  echo "forge-wp-update: another run is in progress" >&2
  exit 0
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null
if ! { : >> "$LOG"; } 2>/dev/null; then
  echo "forge-wp-update: log file not writable: $LOG" >&2
  exit 1
fi

if ! command -v wp >/dev/null; then
  echo "forge-wp-update: wp-cli not found on PATH" >&2
  exit 1
fi

FAILURES=0
CURRENT_SITE_PATH=""
CURRENT_SITE_OWNER=""
log "=== START (server=$SERVER_NAME${DRY_RUN:+ DRY-RUN}) ==="

while IFS= read -r marker; do
  path="$(dirname "$marker")"
  parse_owner "$path/"
  [ -z "$PS_OWNER" ] && continue
  if ! id "$PS_OWNER" >/dev/null 2>&1; then
    log "WARN: owner '$PS_OWNER' not found, skip $path"
    continue
  fi
  update_site "$PS_OWNER" "$path"
done < <(
  find "$SITES_ROOT" -maxdepth 5 \
    \( -name '.?*' -o -name node_modules -o -name vendor \) -prune -o \
    -type f -name wp-config.php -print 2>/dev/null
)

log "=== DONE ==="

if [ "$FAILURES" -gt 0 ]; then
  log "=== FAILED: $FAILURES error(s) ==="
  exit 1
fi
