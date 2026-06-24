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

@test "git_commit_plugins is a no-op when COMMIT_AFTER_UPDATE is unset" {
  cfg="$(mkcfg)"
  run env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    COMMIT_AFTER_UPDATE=""
    sudo() { echo "GIT-TOUCHED"; }   # must not run when disabled
    git_commit_plugins owner /site woocommerce && echo done
  ' _ "$SCRIPT"
  rm -f "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"done"* ]]
  [[ "$output" != *"GIT-TOUCHED"* ]]
}

@test "git_commit_plugins skips when path is not a git repo" {
  cfg="$(mkcfg)"
  run env FORGE_WP_UPDATE_CONFIG="$cfg" SOURCED_ONLY=1 bash -c '
    source "$1"
    COMMIT_AFTER_UPDATE=1
    sudo() { return 1; }             # rev-parse fails => not a repo
    git_commit_plugins owner /site woocommerce && echo done
  ' _ "$SCRIPT"
  rm -f "$cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"done"* ]]
}

@test "git_commit_plugins commits only plugin paths, leaves other files" {
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
    git_commit_plugins owner "'"$repo"'" woocommerce
  ' _ "$SCRIPT"

  last_msg="$(git -C "$repo" log -1 --pretty=%s)"
  pending="$(git -C "$repo" status --porcelain)"
  rm -rf "$repo" "$cfg"

  [[ "$last_msg" == *"same-major update woocommerce"* ]]   # plugin committed
  [[ "$pending" == *"index.php"* ]]                         # other file still dirty
  [[ "$pending" != *"plugins/woocommerce"* ]]               # plugin no longer dirty
}
