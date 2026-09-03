#!/usr/bin/env bash
#
# forge-wp-update.sh — same-major WordPress updates via wp-cli on Forge.
#
# For each discovered WordPress install:
#   - core is updated to the latest MINOR/PATCH release (major releases are
#     always left to a human), then update-db is run
#   - plugins and themes are updated to the latest SAME-MAJOR version
# The database is never dumped or restored. After each stage the site's home URL
# is health-checked; on failure that stage's changes are rolled back.
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
# Theme updates are on by default. Set to "" in the config to turn them off for
# the whole server, or exclude a single theme with "theme:<slug>" in a site's
# ignore file. Core minor updates are always applied unless a site's ignore file
# contains "core".
[ -z "${UPDATE_THEMES+x}" ] && UPDATE_THEMES="1"
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

# load_ignores <path>: parse the site's exclude file into IGNORED_PLUGINS,
# IGNORED_THEMES and IGNORE_CORE. A bare slug excludes a plugin, "theme:<slug>"
# excludes a theme, "core" excludes the core update for that site.
load_ignores() {
  local file="$1/$IGNORE_FILENAME" raw
  IGNORED_PLUGINS=()
  IGNORED_THEMES=()
  IGNORE_CORE=""
  [ -r "$file" ] || return 0
  while IFS= read -r raw || [ -n "$raw" ]; do
    raw="${raw%%#*}"
    raw="${raw//[[:space:]]/}"
    [ -n "$raw" ] || continue
    case "$raw" in
      core)    IGNORE_CORE=1 ;;
      theme:*) IGNORED_THEMES+=("${raw#theme:}") ;;
      *)       IGNORED_PLUGINS+=("$raw") ;;
    esac
  done < "$file"
}

# git_commit_updates <owner> <path> <plugins|themes> <slug...>: opt-in,
# best-effort. If the site is a git repo, stage the updated dirs for that type
# and commit them. Plugins and themes get separate commits so either can be
# reverted alone. Core files are never committed. Never fails the run.
git_commit_updates() {
  local owner="$1" path="$2" type="$3"; shift 3
  [ -n "$COMMIT_AFTER_UPDATE" ] || return 0
  [ "$#" -gt 0 ] || return 0
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
  for slug in "$@"; do paths+=("wp-content/$type/$slug"); done

  # Commit ONLY the updated paths. A path-scoped commit ignores whatever else is
  # staged or dirty, so unrelated site changes are never swept in.
  if [ -z "$(sudo -u "$owner" -H git -C "$path" status --porcelain -- "${paths[@]}" 2>>"$LOG")" ]; then
    log "$path: no $type file changes to commit"
  else
    # Redirect runs as root (the script's user), which owns $LOG; sudo only drops
    # privileges for git itself, so SC2024 does not apply here.
    # shellcheck disable=SC2024
    if sudo -u "$owner" -H git -C "$path" \
        -c "user.name=$GIT_COMMIT_NAME" -c "user.email=$GIT_COMMIT_EMAIL" \
        commit -m "chore($type): same-major update $*" -- "${paths[@]}" >>"$LOG" 2>&1; then
      log "$path: committed $type update ($*)"
      if [ -n "$PUSH_AFTER_COMMIT" ]; then
        # shellcheck disable=SC2024
        if sudo -u "$owner" -H git -C "$path" push >>"$LOG" 2>&1; then
          log "$path: pushed $type update to remote"
        else
          log "ERROR: $path git push failed (check remote and credentials)"
        fi
      fi
    else
      log "ERROR: $path git commit failed for $type"
    fi
  fi
}

# report_leftovers <owner> <path>: log any other pending changes left in the
# working tree after the run's commits, without committing them.
report_leftovers() {
  local owner="$1" path="$2" others count
  [ -n "$COMMIT_AFTER_UPDATE" ] || return 0
  sudo -u "$owner" -H git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  others="$(sudo -u "$owner" -H git -C "$path" status --porcelain 2>>"$LOG")"
  if [ -n "$others" ]; then
    count="$(printf '%s\n' "$others" | grep -c '')"
    log "$path: $count other uncommitted file(s) left in repo, not committed (review manually)"
  fi
}

# collect_updates <owner> <path> <plugin|theme>: fill UPD_NAMES and UPD_OLDS with
# the same-major, non-excluded updates wp-cli offers. UPD_OFFERED counts every
# update offered, so "none available" stays distinguishable from "all filtered".
collect_updates() {
  local owner="$1" path="$2" type="$3"
  UPD_NAMES=()
  UPD_OLDS=()
  UPD_OFFERED=0

  local csv status
  csv="$(wp_as "$owner" "$path" "$type" list --update=available --fields=name,version,update_version --format=csv)"; status=$?
  if [ "$status" -ne 0 ]; then
    log "ERROR: $path wp-cli failed listing ${type}s (status=$status)"
    return 1
  fi

  local -a ignored=()
  if [ "$type" = "theme" ]; then
    ignored=("${IGNORED_THEMES[@]:-}")
  else
    ignored=("${IGNORED_PLUGINS[@]:-}")
  fi

  # wp-cli prints the csv header even with zero results, so a non-empty $csv
  # does not mean there are updates: count the data rows instead.
  local name cur new ig skip
  while IFS=, read -r name cur new; do
    [ "$name" = "name" ] && continue
    [ -z "$name" ] && continue
    UPD_OFFERED=$((UPD_OFFERED+1))
    skip=0
    for ig in "${ignored[@]:-}"; do
      [ "$ig" = "$name" ] && skip=1 && break
    done
    if [ "$skip" = 1 ]; then
      log "$path: skip $type $name (excluded)"
      continue
    fi
    if ! same_major "$cur" "$new"; then
      log "$path: skip $type $name ($cur -> $new) major bump"
      continue
    fi
    UPD_NAMES+=("$name")
    UPD_OLDS+=("$cur")
  done <<< "$csv"
  return 0
}

# update_core <owner> <path>: apply WordPress core minor and patch releases only,
# then health-check. Major releases are always left to a human. On failure the
# core FILES are put back; the database is never dumped or restored, because a
# minor release does not migrate the schema.
# Returns 1 when the site must be left alone for the rest of the run.
update_core() {
  local owner="$1" path="$2"
  if [ -n "$IGNORE_CORE" ]; then
    log "$path: skip core (excluded)"
    return 0
  fi

  local old new status
  old="$(wp_as "$owner" "$path" core version)"; status=$?
  if [ "$status" -ne 0 ] || [ -z "$old" ]; then
    log "ERROR: $path cannot read core version (wp-cli status=$status), skipping core"
    FAILURES=$((FAILURES+1))
    return 1
  fi

  if [ -n "$DRY_RUN" ]; then
    log "$path: DRY-RUN core is $old, minor updates offered:"
    wp_as "$owner" "$path" core check-update --minor --fields=version --format=csv >> "$LOG" 2>&1
    return 0
  fi

  CURRENT_SITE_OWNER="$owner"
  CURRENT_SITE_PATH="$path"
  if ! wp_as "$owner" "$path" core update --minor >> "$LOG" 2>&1; then
    log "ERROR: $path core update --minor failed"
    FAILURES=$((FAILURES+1))
    return 1
  fi

  new="$(wp_as "$owner" "$path" core version)"
  if [ "$new" = "$old" ]; then
    log "$path: core already at latest minor ($old)"
    return 0
  fi
  log "$path: core updated $old -> $new"
  if ! wp_as "$owner" "$path" core update-db >> "$LOG" 2>&1; then
    log "ERROR: $path core update-db failed after $old -> $new"
  fi

  if health_check "$owner" "$path"; then
    log "$path: healthy after core update"
    return 0
  fi

  log "ERROR: $path unhealthy after core update, rolling back to $old"
  if wp_as "$owner" "$path" core update --version="$old" --force >> "$LOG" 2>&1; then
    wp_as "$owner" "$path" core update-db >> "$LOG" 2>&1 || true
    log "$path: rolled back core to $old"
  else
    log "ERROR: $path core rollback to $old failed"
  fi
  if health_check "$owner" "$path"; then
    log "$path: healthy after core rollback"
  else
    log "ERROR: $path STILL unhealthy after core rollback"
  fi
  FAILURES=$((FAILURES+1))
  return 1
}

# update_extensions <owner> <path>: apply eligible plugin and theme updates, then
# health-check once. If the site is down afterwards every update applied in this
# run is rolled back, themes first, so the site is back where it started.
update_extensions() {
  local owner="$1" path="$2"
  local -a p_names=() p_olds=() t_names=() t_olds=()

  if collect_updates "$owner" "$path" plugin; then
    if [ "${#UPD_NAMES[@]}" -gt 0 ]; then
      p_names=("${UPD_NAMES[@]}")
      p_olds=("${UPD_OLDS[@]}")
    elif [ "$UPD_OFFERED" -eq 0 ]; then
      log "$path: no plugin updates available"
    else
      log "$path: no eligible plugin ($UPD_OFFERED update(s) all filtered out)"
    fi
  else
    FAILURES=$((FAILURES+1))
  fi

  if [ -n "$UPDATE_THEMES" ]; then
    if collect_updates "$owner" "$path" theme; then
      if [ "${#UPD_NAMES[@]}" -gt 0 ]; then
        t_names=("${UPD_NAMES[@]}")
        t_olds=("${UPD_OLDS[@]}")
      elif [ "$UPD_OFFERED" -eq 0 ]; then
        log "$path: no theme updates available"
      else
        log "$path: no eligible theme ($UPD_OFFERED update(s) all filtered out)"
      fi
    else
      FAILURES=$((FAILURES+1))
    fi
  fi

  if [ "${#p_names[@]}" -eq 0 ] && [ "${#t_names[@]}" -eq 0 ]; then
    return 0
  fi

  if [ -n "$DRY_RUN" ]; then
    [ "${#p_names[@]}" -gt 0 ] && log "$path: DRY-RUN would update plugin(s): ${p_names[*]}"
    [ "${#t_names[@]}" -gt 0 ] && log "$path: DRY-RUN would update theme(s): ${t_names[*]}"
    return 0
  fi

  CURRENT_SITE_OWNER="$owner"
  CURRENT_SITE_PATH="$path"
  if [ "${#p_names[@]}" -gt 0 ]; then
    log "$path: updating ${#p_names[@]} plugin(s): ${p_names[*]}"
    if ! wp_as "$owner" "$path" plugin update "${p_names[@]}" >> "$LOG" 2>&1; then
      log "ERROR: $path plugin update command failed"
      FAILURES=$((FAILURES+1))
    fi
  fi
  if [ "${#t_names[@]}" -gt 0 ]; then
    log "$path: updating ${#t_names[@]} theme(s): ${t_names[*]}"
    if ! wp_as "$owner" "$path" theme update "${t_names[@]}" >> "$LOG" 2>&1; then
      log "ERROR: $path theme update command failed"
      FAILURES=$((FAILURES+1))
    fi
  fi

  if health_check "$owner" "$path"; then
    log "$path: healthy after update"
    [ "${#p_names[@]}" -gt 0 ] && git_commit_updates "$owner" "$path" plugins "${p_names[@]}"
    [ "${#t_names[@]}" -gt 0 ] && git_commit_updates "$owner" "$path" themes "${t_names[@]}"
    report_leftovers "$owner" "$path"
    return 0
  fi

  log "ERROR: $path unhealthy after update, rolling back"
  local i
  local -a pairs=()
  for i in "${!t_names[@]}"; do pairs+=("${t_names[$i]}" "${t_olds[$i]}"); done
  [ "${#pairs[@]}" -gt 0 ] && rollback_type "$owner" "$path" theme "${pairs[@]}"
  pairs=()
  for i in "${!p_names[@]}"; do pairs+=("${p_names[$i]}" "${p_olds[$i]}"); done
  [ "${#pairs[@]}" -gt 0 ] && rollback_type "$owner" "$path" plugin "${pairs[@]}"
  if health_check "$owner" "$path"; then
    log "$path: healthy after rollback"
  else
    log "ERROR: $path STILL unhealthy after rollback"
  fi
  FAILURES=$((FAILURES+1))
}

# rollback_type <owner> <path> <plugin|theme> <slug> <version> [<slug> <version>...]:
# put each updated extension back to the version it had before this run. Pairs are
# passed flat rather than by array reference so this still runs on bash 3.2.
rollback_type() {
  local owner="$1" path="$2" type="$3"; shift 3
  local name old
  while [ "$#" -ge 2 ]; do
    name="$1"; old="$2"; shift 2
    if wp_as "$owner" "$path" "$type" update "$name" --version="$old" >> "$LOG" 2>&1; then
      log "$path: rolled back $type $name to $old"
    else
      log "ERROR: $path rollback failed for $type $name"
    fi
  done
}

# update_site <owner> <path>: core first, then plugins and themes. A core failure
# leaves the extensions alone: one broken thing at a time is enough.
update_site() {
  local owner="$1" path="$2"
  load_ignores "$path"
  update_core "$owner" "$path" || { CURRENT_SITE_PATH=""; CURRENT_SITE_OWNER=""; return 0; }
  update_extensions "$owner" "$path"
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
