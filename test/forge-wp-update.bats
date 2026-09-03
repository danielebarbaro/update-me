#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../forge-wp-update.sh"
}

mkcfg() {
  cfg="$(mktemp)"
  printf 'SERVER_NAME=s1\nSITES_ROOT=%s\nLOG=/tmp/fwu.log\nHEALTHCHECK_CODES="200 301 302"\nIGNORE_FILENAME=.forge-wp-update-ignore\n' "${1:-/home}" > "$cfg"
  echo "$cfg"
}

@test "missing config file fails fast with clear message" {
  run env FORGE_WP_UPDATE_CONFIG=/nonexistent/config bash "$SCRIPT" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"config"* ]]
}

@test "invalid argument prints usage and exits non-zero" {
  cfg="$(mkcfg)"
  run env FORGE_WP_UPDATE_CONFIG="$cfg" bash "$SCRIPT" bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
  rm -f "$cfg"
}

@test "same_major true within a major, false across" {
  cfg="$(mkcfg)"
  run env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    same_major "1.2.3" "1.9.0" && echo same1
    same_major "1.2.3" "2.0.0" || echo diff1
    same_major "10.1" "10.99.4" && echo same2
  ' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"same1"* ]]
  [[ "$output" == *"diff1"* ]]
  [[ "$output" == *"same2"* ]]
  rm -f "$cfg"
}

@test "major strips odd version strings and defaults empty to 0" {
  cfg="$(mkcfg)"
  run env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    echo "v=$(major "v3.4.5")"
    echo "e=$(major "")"
  ' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"v=3"* ]]
  [[ "$output" == *"e=0"* ]]
  rm -f "$cfg"
}

@test "parse_owner extracts owner from path under SITES_ROOT" {
  cfg="$(mkcfg)"
  run env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    parse_owner "/home/alice/example.com/"
    echo "$PS_OWNER"
  ' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"alice"* ]]
  rm -f "$cfg"
}

@test "is_healthy_code accepts configured codes, rejects others" {
  cfg="$(mkcfg)"
  run env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    is_healthy_code 200 && echo ok200
    is_healthy_code 301 && echo ok301
    is_healthy_code 500 || echo no500
  ' _ "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok200"* ]]
  [[ "$output" == *"ok301"* ]]
  [[ "$output" == *"no500"* ]]
  rm -f "$cfg"
}

@test "health_check is unhealthy when wp-cli fails" {
  cfg="$(mkcfg)"
  run env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    wp_as() { return 1; }       # simulate wp-cli fatal
    health_check owner /site && echo healthy || echo unhealthy
  ' _ "$SCRIPT"
  rm -f "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unhealthy"* ]]
}

@test "health_check is unhealthy when home url is empty" {
  cfg="$(mkcfg)"
  run env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    wp_as() { echo ""; return 0; }   # wp ok but no home url
    health_check owner /site && echo healthy || echo unhealthy
  ' _ "$SCRIPT"
  rm -f "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unhealthy"* ]]
}

@test "health_check is healthy on configured code from home url" {
  cfg="$(mkcfg)"
  run env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    wp_as() { echo "https://example.test"; return 0; }
    curl() { echo "200"; }            # stub fetch
    health_check owner /site && echo healthy || echo unhealthy
  ' _ "$SCRIPT"
  rm -f "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"healthy"* ]]
  [[ "$output" != *"unhealthy"* ]]
}

@test "git_commit_updates is a no-op when COMMIT_AFTER_UPDATE is unset" {
  cfg="$(mkcfg)"
  run env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    COMMIT_AFTER_UPDATE=""
    sudo() { echo "GIT-TOUCHED"; }   # must not run when disabled
    git_commit_updates owner /site plugins woocommerce && echo done
  ' _ "$SCRIPT"
  rm -f "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"done"* ]]
  [[ "$output" != *"GIT-TOUCHED"* ]]
}

@test "git_commit_updates skips when path is not a git repo" {
  cfg="$(mkcfg)"
  run env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    COMMIT_AFTER_UPDATE=1
    sudo() { return 1; }             # rev-parse fails => not a repo
    git_commit_updates owner /site plugins woocommerce && echo done
  ' _ "$SCRIPT"
  rm -f "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"done"* ]]
}

@test "git_commit_updates commits only plugin paths, leaves other files" {
  cfg="$(mkcfg)"
  repo="$(mktemp -d)"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t.test
  git -C "$repo" config user.name tester
  mkdir -p "$repo/wp-content/plugins/woocommerce"
  echo v1 > "$repo/wp-content/plugins/woocommerce/main.php"
  echo home > "$repo/index.php"
  git -C "$repo" add -A; git -C "$repo" commit -qm init
  # Dirty both a plugin and an unrelated file.
  echo v2 > "$repo/wp-content/plugins/woocommerce/main.php"
  echo changed > "$repo/index.php"

  # sudo stub: strip "-u <user>" and "-H", run the rest as the current user.
  env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    COMMIT_AFTER_UPDATE=1
    sudo() { while [ "$1" = "-u" ] || [ "$1" = "-H" ]; do
               if [ "$1" = "-u" ]; then shift 2; else shift; fi; done; "$@"; }
    git_commit_updates owner "'"$repo"'" plugins woocommerce
  ' _ "$SCRIPT"

  last_msg="$(git -C "$repo" log -1 --pretty=%s)"
  pending="$(git -C "$repo" status --porcelain)"
  rm -rf "$repo" "$cfg"

  [[ "$last_msg" == *"same-major update woocommerce"* ]]   # plugin committed
  [[ "$pending" == *"index.php"* ]]                         # other file still dirty
  [[ "$pending" != *"plugins/woocommerce"* ]]               # plugin no longer dirty
}

# Build a site repo cloned from a bare remote; echoes "<remote> <work>".
mk_repo_with_remote() {
  local remote work
  remote="$(mktemp -d)"; work="$(mktemp -d)"
  git init --bare -q "$remote"
  git clone -q "$remote" "$work"
  git -C "$work" config user.email t@t.test
  git -C "$work" config user.name tester
  git -C "$work" checkout -q -b main
  mkdir -p "$work/wp-content/plugins/woocommerce"
  echo v1 > "$work/wp-content/plugins/woocommerce/main.php"
  git -C "$work" add -A; git -C "$work" commit -qm init
  git -C "$work" push -q -u origin main
  echo v2 > "$work/wp-content/plugins/woocommerce/main.php"   # dirty the plugin
  echo "$remote $work"
}

sudo_passthrough='sudo() { while [ "$1" = "-u" ] || [ "$1" = "-H" ]; do if [ "$1" = "-u" ]; then shift 2; else shift; fi; done; "$@"; }'

@test "git_commit_updates does not push when PUSH_AFTER_COMMIT is unset" {
  cfg="$(mkcfg)"
  read -r remote work <<< "$(mk_repo_with_remote)"
  env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"; '"$sudo_passthrough"'
    COMMIT_AFTER_UPDATE=1; PUSH_AFTER_COMMIT=""
    git_commit_updates owner "'"$work"'" plugins woocommerce
  ' _ "$SCRIPT"
  remote_msg="$(git -C "$remote" log -1 --pretty=%s main)"
  rm -rf "$remote" "$work" "$cfg"
  [[ "$remote_msg" == "init" ]]                              # remote unchanged
}

@test "git_commit_updates pushes to remote when PUSH_AFTER_COMMIT is set" {
  cfg="$(mkcfg)"
  read -r remote work <<< "$(mk_repo_with_remote)"
  env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"; '"$sudo_passthrough"'
    COMMIT_AFTER_UPDATE=1; PUSH_AFTER_COMMIT=1
    git_commit_updates owner "'"$work"'" plugins woocommerce
  ' _ "$SCRIPT"
  remote_msg="$(git -C "$remote" log -1 --pretty=%s main)"
  rm -rf "$remote" "$work" "$cfg"
  [[ "$remote_msg" == *"same-major update woocommerce"* ]]   # remote got the commit
}

# wp-cli stderr must be attributed: raw stderr lands in the log unlabelled and
# before the site's own line, which reads as if it came from the previous site.
@test "wp_as logs wp-cli stderr prefixed with the site path" {
  log="$(mktemp)"; cfg="$(mktemp)"
  printf 'SERVER_NAME=s1\nSITES_ROOT=/home\nLOG=%s\n' "$log" > "$cfg"
  run env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    sudo() { echo "https://site.test"; echo "PHP Warning:  boom" >&2; }
    out="$(wp_as owner /home/owner/site.test option get home)"
    echo "out=$out"
  ' _ "$SCRIPT"
  logged="$(cat "$log")"
  rm -f "$log" "$cfg"
  [[ "$output" == *"out=https://site.test"* ]]                        # stdout still reaches the caller
  [[ "$logged" == *"/home/owner/site.test: wp-cli: PHP Warning:  boom"* ]]
}

@test "wp_as propagates the wp-cli exit status through the stderr capture" {
  log="$(mktemp)"; cfg="$(mktemp)"
  printf 'SERVER_NAME=s1\nSITES_ROOT=/home\nLOG=%s\n' "$log" > "$cfg"
  run env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    sudo() { echo "Error: no such site" >&2; return 7; }
    wp_as owner /home/owner/site.test option get home >/dev/null; echo "st=$?"
  ' _ "$SCRIPT"
  rm -f "$log" "$cfg"
  [[ "$output" == *"st=7"* ]]
}

# --- ignore file, core and theme entries -----------------------------------

mk_site_with_ignore() {
  site="$(mktemp -d)"
  printf '%s\n' "$@" > "$site/.forge-wp-update-ignore"
  echo "$site"
}

@test "load_ignores splits plugin slugs, theme: entries and core" {
  cfg="$(mkcfg)"
  site="$(mk_site_with_ignore 'akismet' '# a comment' 'theme:avada' 'core' '')"
  run env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    load_ignores "$2"
    echo "plugins=${IGNORED_PLUGINS[*]}"
    echo "themes=${IGNORED_THEMES[*]}"
    echo "core=$IGNORE_CORE"
  ' _ "$SCRIPT" "$site"
  rm -rf "$site" "$cfg"
  [[ "$output" == *"plugins=akismet"* ]]
  [[ "$output" == *"themes=avada"* ]]
  [[ "$output" == *"core=1"* ]]
}

@test "load_ignores leaves everything empty when the site has no ignore file" {
  cfg="$(mkcfg)"
  site="$(mktemp -d)"
  run env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    load_ignores "$2"
    echo "n=${#IGNORED_PLUGINS[@]}${#IGNORED_THEMES[@]} core=[$IGNORE_CORE]"
  ' _ "$SCRIPT" "$site"
  rm -rf "$site" "$cfg"
  [[ "$output" == *"n=00 core=[]"* ]]
}

# --- collect_updates -------------------------------------------------------

# Runs collect_updates against a stubbed wp-cli listing. $CSV is the listing,
# $TYPE the extension type, and the ignore arrays are set by the caller.
collect_with() {
  cfg="$(mktemp)"; log="$(mktemp)"
  printf 'SERVER_NAME=s1\nSITES_ROOT=/home\nLOG=%s\n' "$log" > "$cfg"
  env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    wp_as() { printf "%s\n" "$CSV"; }
    IGNORED_PLUGINS=(${IG_PLUGINS:-}); IGNORED_THEMES=(${IG_THEMES:-}); IGNORE_CORE=""
    collect_updates owner /home/owner/site.test "$TYPE"
    echo "names=${UPD_NAMES[*]:-} offered=$UPD_OFFERED"
  ' _ "$SCRIPT"
  cat "$log"
  rm -f "$cfg" "$log"
}

@test "collect_updates keeps same-major updates and counts what was offered" {
  run env TYPE=plugin CSV='name,version,update_version
akismet,5.3,5.4
woocommerce,8.1,9.0' bash -c 'SCRIPT="'"$SCRIPT"'"; '"$(declare -f collect_with)"'; collect_with'
  [[ "$output" == *"names=akismet offered=2"* ]]
  [[ "$output" == *"skip plugin woocommerce (8.1 -> 9.0) major bump"* ]]
}

@test "collect_updates reports an empty listing as zero offered" {
  run env TYPE=plugin CSV='name,version,update_version' bash -c 'SCRIPT="'"$SCRIPT"'"; '"$(declare -f collect_with)"'; collect_with'
  [[ "$output" == *"names= offered=0"* ]]
}

@test "collect_updates applies theme exclusions to themes only" {
  run env TYPE=theme IG_THEMES=avada IG_PLUGINS=twentytwentyfour CSV='name,version,update_version
avada,7.11,7.12
twentytwentyfour,1.1,1.2' bash -c 'SCRIPT="'"$SCRIPT"'"; '"$(declare -f collect_with)"'; collect_with'
  [[ "$output" == *"skip theme avada (excluded)"* ]]
  [[ "$output" == *"names=twentytwentyfour offered=2"* ]]
}

# --- core ------------------------------------------------------------------

# Runs update_core with wp-cli stubbed by $STUB, a case statement keyed on the
# wp-cli subcommand, and prints the log plus every wp-cli call made.
core_with() {
  cfg="$(mktemp)"; log="$(mktemp)"
  printf 'SERVER_NAME=s1\nSITES_ROOT=/home\nLOG=%s\n' "$log" > "$cfg"
  env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    FAILURES=0; DRY_RUN="${DRY:-}"; IGNORE_CORE="${IGN:-}"
    CURRENT_SITE_OWNER=""; CURRENT_SITE_PATH=""
    wp_as() { local o="$1" p="$2"; shift 2; echo "CALL: $*" >> "'"$CALLS"'"; eval "$STUB"; }
    health_check() { [ "${HEALTHY:-1}" = 1 ]; }
    update_core owner /home/owner/site.test; echo "rc=$? failures=$FAILURES"
  ' _ "$SCRIPT"
  cat "$log"
  rm -f "$cfg" "$log"
}

@test "update_core skips the site when its ignore file contains core" {
  CALLS="$(mktemp)"
  run env IGN=1 STUB='true' bash -c 'SCRIPT="'"$SCRIPT"'"; CALLS="'"$CALLS"'"; '"$(declare -f core_with)"'; core_with'
  calls="$(cat "$CALLS")"; rm -f "$CALLS"
  [[ "$output" == *"skip core (excluded)"* ]]
  [[ "$output" == *"rc=0 failures=0"* ]]
  [ -z "$calls" ]                                   # wp-cli never touched
}

@test "update_core applies only minor releases and runs update-db" {
  CALLS="$(mktemp)"; MARK="$BATS_TEST_TMPDIR/bumped"
  run env MARK="$MARK" STUB='case "$1 $2" in "core version") if [ -f "$MARK" ]; then echo 6.8.2; else echo 6.8.1; fi ;; "core update") : > "$MARK" ;; esac' \
    bash -c 'SCRIPT="'"$SCRIPT"'"; CALLS="'"$CALLS"'"; '"$(declare -f core_with)"'; core_with'
  calls="$(cat "$CALLS")"; rm -f "$CALLS" "$MARK"
  [[ "$calls" == *"core update --minor"* ]]
  [[ "$calls" == *"core update-db"* ]]
  [[ "$calls" != *"--version"* ]]                   # never a major, never a rollback
  [[ "$output" == *"core updated 6.8.1 -> 6.8.2"* ]]
  [[ "$output" == *"rc=0 failures=0"* ]]
}

@test "update_core rolls the core files back to the previous version when the site goes down" {
  CALLS="$(mktemp)"; MARK="$BATS_TEST_TMPDIR/bumped"
  run env MARK="$MARK" HEALTHY=0 STUB='case "$1 $2" in "core version") if [ -f "$MARK" ]; then echo 6.8.2; else echo 6.8.1; fi ;; "core update") [ "$3" = "--minor" ] && : > "$MARK" ;; esac' \
    bash -c 'SCRIPT="'"$SCRIPT"'"; CALLS="'"$CALLS"'"; '"$(declare -f core_with)"'; core_with'
  calls="$(cat "$CALLS")"; rm -f "$CALLS" "$MARK"
  [[ "$calls" == *"core update --version=6.8.1 --force"* ]]
  [[ "$output" == *"unhealthy after core update, rolling back to 6.8.1"* ]]
  [[ "$output" == *"rc=1 failures=1"* ]]            # site left out of the rest of the run
}

@test "update_core changes nothing in dry-run" {
  CALLS="$(mktemp)"
  run env DRY=--dry-run STUB='case "$1 $2" in "core version") echo 6.8.1 ;; esac' \
    bash -c 'SCRIPT="'"$SCRIPT"'"; CALLS="'"$CALLS"'"; '"$(declare -f core_with)"'; core_with'
  calls="$(cat "$CALLS")"; rm -f "$CALLS"
  [[ "$calls" != *"core update --minor"* ]]
  [[ "$calls" == *"core check-update --minor"* ]]
  [[ "$output" == *"rc=0 failures=0"* ]]
}

# --- plugins and themes together -------------------------------------------

# Runs update_extensions with wp-cli stubbed: $P_CSV and $T_CSV are the plugin
# and theme listings, $HEALTHY decides the post-update check. Every wp-cli call
# is appended to $CALLS.
ext_with() {
  cfg="$(mktemp)"; log="$(mktemp)"
  printf 'SERVER_NAME=s1\nSITES_ROOT=/home\nLOG=%s\n' "$log" > "$cfg"
  env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    FAILURES=0; DRY_RUN=""; UPDATE_THEMES="${THEMES-1}"
    IGNORED_PLUGINS=(); IGNORED_THEMES=(); IGNORE_CORE=""
    CURRENT_SITE_OWNER=""; CURRENT_SITE_PATH=""
    wp_as() {
      local o="$1" p="$2"; shift 2
      echo "CALL: $*" >> "'"$CALLS"'"
      case "$1 $2" in
        "plugin list") printf "%s\n" "$P_CSV" ;;
        "theme list")  printf "%s\n" "$T_CSV" ;;
      esac
    }
    health_check() { [ "${HEALTHY:-1}" = 1 ]; }
    git_commit_updates() { echo "COMMIT: $3 ${*:4}" >> "'"$CALLS"'"; }
    report_leftovers() { :; }
    update_extensions owner /home/owner/site.test; echo "failures=$FAILURES"
  ' _ "$SCRIPT"
  cat "$log"
  rm -f "$cfg" "$log"
}

@test "update_extensions updates themes by default and commits each type separately" {
  CALLS="$(mktemp)"
  run env P_CSV='name,version,update_version
akismet,5.3,5.4' T_CSV='name,version,update_version
twentytwentyfour,1.1,1.2' bash -c 'SCRIPT="'"$SCRIPT"'"; CALLS="'"$CALLS"'"; '"$(declare -f ext_with)"'; ext_with'
  calls="$(cat "$CALLS")"; rm -f "$CALLS"
  [[ "$calls" == *"plugin update akismet"* ]]
  [[ "$calls" == *"theme update twentytwentyfour"* ]]
  [[ "$calls" == *"COMMIT: plugins akismet"* ]]
  [[ "$calls" == *"COMMIT: themes twentytwentyfour"* ]]
  [[ "$output" == *"failures=0"* ]]
}

@test "update_extensions leaves themes alone when UPDATE_THEMES is empty" {
  CALLS="$(mktemp)"
  run env THEMES= P_CSV='name,version,update_version
akismet,5.3,5.4' T_CSV='name,version,update_version
twentytwentyfour,1.1,1.2' bash -c 'SCRIPT="'"$SCRIPT"'"; CALLS="'"$CALLS"'"; '"$(declare -f ext_with)"'; ext_with'
  calls="$(cat "$CALLS")"; rm -f "$CALLS"
  [[ "$calls" == *"plugin update akismet"* ]]
  [[ "$calls" != *"theme"* ]]                       # not even listed
}

@test "update_extensions rolls themes back before plugins when the site goes down" {
  CALLS="$(mktemp)"
  run env HEALTHY=0 P_CSV='name,version,update_version
akismet,5.3,5.4' T_CSV='name,version,update_version
twentytwentyfour,1.1,1.2' bash -c 'SCRIPT="'"$SCRIPT"'"; CALLS="'"$CALLS"'"; '"$(declare -f ext_with)"'; ext_with'
  calls="$(cat "$CALLS")"; rm -f "$CALLS"
  [[ "$calls" == *"theme update twentytwentyfour --version=1.1"* ]]
  [[ "$calls" == *"plugin update akismet --version=5.3"* ]]
  # themes first: the theme rollback line comes before the plugin one
  theme_at="$(printf '%s\n' "$calls" | grep -n -- "theme update twentytwentyfour --version" | cut -d: -f1)"
  plugin_at="$(printf '%s\n' "$calls" | grep -n -- "plugin update akismet --version" | cut -d: -f1)"
  [ "$theme_at" -lt "$plugin_at" ]
  [[ "$calls" != *"COMMIT:"* ]]                     # nothing committed on a rollback
  [[ "$output" == *"failures=1"* ]]
}
