#!/usr/bin/env bash
#
# forge-wp-update installer. Run on each Forge server:
#   curl -fsSL https://raw.githubusercontent.com/danielebarbaro/update-me/main/install.sh | sudo bash
#
set -uo pipefail

REPO_RAW="${FORGE_WP_UPDATE_REPO_RAW:-https://raw.githubusercontent.com/danielebarbaro/update-me/main}"
BIN="/usr/local/bin/forge-wp-update"
CONFIG_DIR="/etc/forge-wp-update"
CONFIG="$CONFIG_DIR/config"
CRON="/etc/cron.d/forge-wp-update"

say()  { printf '\n>> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "Run as root or with sudo (writes to /etc and /usr/local/bin)."; }

need_root

# Prompts must read from the terminal, not stdin: `curl ... | bash` leaves stdin
# bound to the piped script, so interactive `read` would get EOF.
[ -r /dev/tty ] || die "No terminal for prompts. Download install.sh and run it directly (e.g. 'sudo bash install.sh'), not piped."

# 1. Dependency check.
say "Checking dependencies"
command -v curl >/dev/null || die "curl not found."
command -v find >/dev/null || die "find not found."
command -v sudo >/dev/null || die "sudo not found."
if ! command -v wp >/dev/null; then
  read -r -p "wp-cli not found. Install it now? [y/N] " ans </dev/tty
  [ "$ans" = "y" ] || die "wp-cli is required. Install it and re-run."
  curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp \
    || die "wp-cli download failed."
  chmod 755 /usr/local/bin/wp
fi

# 2. Read the existing config, if any.
# Re-running the installer must never drop settings someone added by hand, so
# the current values become the prompt defaults and every key is written back.
if [ -r "$CONFIG" ]; then
  say "Reading existing $CONFIG"
  # shellcheck source=/dev/null
  . "$CONFIG" || die "Existing config is not valid bash: $CONFIG"
fi
SERVER_NAME="${SERVER_NAME:-}"
SITES_ROOT="${SITES_ROOT:-/home}"
LOG="${LOG:-/var/log/forge-wp-update.log}"
HEALTHCHECK_CODES="${HEALTHCHECK_CODES:-200 301 302}"
IGNORE_FILENAME="${IGNORE_FILENAME:-.forge-wp-update-ignore}"
# Unset means "not configured yet" and takes the default; an empty value is a
# deliberate "off" and is kept, hence ${VAR-default} and not ${VAR:-default}.
UPDATE_THEMES="${UPDATE_THEMES-1}"
COMMIT_AFTER_UPDATE="${COMMIT_AFTER_UPDATE-}"
GIT_COMMIT_NAME="${GIT_COMMIT_NAME:-forge-wp-update}"
GIT_COMMIT_EMAIL="${GIT_COMMIT_EMAIL:-forge-wp-update@localhost}"
PUSH_AFTER_COMMIT="${PUSH_AFTER_COMMIT-}"

# 3. Prompt for the values that identify this server. Enter keeps what is shown.
say "Configuration"
read -r -p "SERVER_NAME (unique, e.g. server-1)${SERVER_NAME:+ [$SERVER_NAME]}: " INPUT </dev/tty
SERVER_NAME="${INPUT:-$SERVER_NAME}"
[ -n "$SERVER_NAME" ] || die "SERVER_NAME is required."
read -r -p "SITES_ROOT [$SITES_ROOT]: " INPUT </dev/tty
SITES_ROOT="${INPUT:-$SITES_ROOT}"
read -r -p "Log file path [$LOG]: " INPUT </dev/tty
LOG_PATH="${INPUT:-$LOG}"

# 4. Write /etc/forge-wp-update/config.
say "Writing $CONFIG"
install -d -m 755 "$CONFIG_DIR"
umask 177
cat > "$CONFIG" <<EOF
SERVER_NAME="$SERVER_NAME"
SITES_ROOT="$SITES_ROOT"
LOG="$LOG_PATH"
HEALTHCHECK_CODES="$HEALTHCHECK_CODES"
IGNORE_FILENAME="$IGNORE_FILENAME"
UPDATE_THEMES="$UPDATE_THEMES"
COMMIT_AFTER_UPDATE="$COMMIT_AFTER_UPDATE"
GIT_COMMIT_NAME="$GIT_COMMIT_NAME"
GIT_COMMIT_EMAIL="$GIT_COMMIT_EMAIL"
PUSH_AFTER_COMMIT="$PUSH_AFTER_COMMIT"
EOF
umask 022
chmod 600 "$CONFIG"

# 5. Install the script.
say "Installing $BIN"
curl -fsSL "$REPO_RAW/forge-wp-update.sh" -o "$BIN" || die "Failed to download forge-wp-update.sh"
chmod 755 "$BIN"

# 6. Install cron (runs as root so it can sudo -u owner; replaced, never duplicated).
say "Installing cron at $CRON"
cat > "$CRON" <<EOF
# forge-wp-update. Managed by install.sh. Daily WordPress updates at 04:00.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 4 * * *   root  forge-wp-update >> $LOG_PATH 2>&1
EOF
chmod 644 "$CRON"

# 7. Verify with a dry-run.
say "Verifying (dry-run)"
if forge-wp-update --dry-run; then
  say "Install complete. Cron scheduled daily at 04:00. Edit $CRON to change timing."
else
  die "Dry-run failed. Check $CONFIG and that wp-cli runs for your sites."
fi
