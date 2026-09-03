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

# 2. Prompt for config.
say "Configuration"
read -r -p "SERVER_NAME (unique, e.g. server-1): " SERVER_NAME </dev/tty
[ -n "$SERVER_NAME" ] || die "SERVER_NAME is required."
read -r -p "SITES_ROOT [/home]: " SITES_ROOT_INPUT </dev/tty
SITES_ROOT="${SITES_ROOT_INPUT:-/home}"
read -r -p "Log file path [/var/log/forge-wp-update.log]: " LOG_INPUT </dev/tty
LOG_PATH="${LOG_INPUT:-/var/log/forge-wp-update.log}"

# 3. Write /etc/forge-wp-update/config.
say "Writing $CONFIG"
install -d -m 755 "$CONFIG_DIR"
umask 177
cat > "$CONFIG" <<EOF
SERVER_NAME="$SERVER_NAME"
SITES_ROOT="$SITES_ROOT"
LOG="$LOG_PATH"
HEALTHCHECK_CODES="200 301 302"
IGNORE_FILENAME=".forge-wp-update-ignore"
EOF
umask 022
chmod 600 "$CONFIG"

# 4. Install the script.
say "Installing $BIN"
curl -fsSL "$REPO_RAW/forge-wp-update.sh" -o "$BIN" || die "Failed to download forge-wp-update.sh"
chmod 755 "$BIN"

# 5. Install cron (runs as root so it can sudo -u owner; replaced, never duplicated).
say "Installing cron at $CRON"
cat > "$CRON" <<EOF
# forge-wp-update. Managed by install.sh. Daily WordPress updates at 04:00.
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
0 4 * * *   root  forge-wp-update >> $LOG_PATH 2>&1
EOF
chmod 644 "$CRON"

# 6. Verify with a dry-run.
say "Verifying (dry-run)"
if forge-wp-update --dry-run; then
  say "Install complete. Cron scheduled daily at 04:00. Edit $CRON to change timing."
else
  die "Dry-run failed. Check $CONFIG and that wp-cli runs for your sites."
fi
