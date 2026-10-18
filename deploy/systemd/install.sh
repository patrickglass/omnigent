#!/bin/sh
# Installs (or removes) Omnigent as systemd --user services: a LAN-reachable
# server (omnigent.service, `omnigent server --host 0.0.0.0`) plus the host
# daemon that executes sessions on this machine. The host unit itself is
# managed by `omnigent host enable`; this script only adds a drop-in that
# orders it after the server.
#
# These are *user* units, not system-wide ones: the host daemon needs your
# HOME, your PATH (node/npm/tmux/bwrap, and the harness CLIs it launches —
# claude, codex, ...), and your locally-stored credentials, none of which a
# dedicated system service account would have.
#
# Usage:
#   ./install.sh                 install, enable, and start both services
#   ./install.sh --no-start      install and enable the server, but don't start
#   ./install.sh --uninstall     stop, disable, and remove both services
#
# By default user units only run while you have an active login session.
# To keep them running after you log out (e.g. on a headless/home server),
# enable linger for your user (`loginctl enable-linger`).

set -eu

SERVER_UNIT=omnigent.service
HOST_UNIT=omnigent-host.service
SERVER_URL=http://127.0.0.1:6767
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVER_UNIT_PATH="$UNIT_DIR/$SERVER_UNIT"
DROP_IN_DIR="$UNIT_DIR/$HOST_UNIT.d"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TEMPLATE="$SCRIPT_DIR/$SERVER_UNIT"
DROP_IN_SOURCE="$SCRIPT_DIR/$HOST_UNIT.d/omnigent-server.conf"

ACTION=install
START=true

for arg in "$@"; do
  case "$arg" in
    --uninstall) ACTION=uninstall ;;
    --no-start) START=false ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: '$1' not found on PATH" >&2
    exit 1
  }
}

# Managed terminals refuse tmux older than 3.3. Ubuntu 22.04's apt tmux is
# 3.2a, so it must come from a newer release or a source build.
require_tmux() {
  command -v tmux >/dev/null 2>&1 || {
    echo "ERROR: tmux 3.3 or newer is required, and tmux is not on PATH" >&2
    exit 1
  }
  version=$(tmux -V | sed -e 's/^tmux //' -e 's/^next-//')
  major=${version%%.*}
  minor=$(printf '%s' "${version#*.}" | sed 's/[^0-9].*//')
  if [ "${major:-0}" -lt 3 ] || { [ "$major" -eq 3 ] && [ "${minor:-0}" -lt 3 ]; }; then
    echo "ERROR: tmux 3.3 or newer is required (found tmux $version)" >&2
    exit 1
  fi
}

require_bwrap() {
  command -v bwrap >/dev/null 2>&1 || {
    echo "ERROR: bubblewrap (bwrap) is required on Linux to sandbox agent terminals" >&2
    echo "       Install it with: sudo apt install bubblewrap" >&2
    exit 1
  }
}

require systemctl

if [ "$ACTION" = uninstall ]; then
  if command -v omnigent >/dev/null 2>&1; then
    omnigent host disable || true
  fi
  rm -rf "$DROP_IN_DIR"
  if [ -f "$SERVER_UNIT_PATH" ]; then
    systemctl --user disable --now "$SERVER_UNIT" >/dev/null 2>&1 || true
    rm -f "$SERVER_UNIT_PATH"
    echo "Removed $SERVER_UNIT_PATH"
  fi
  systemctl --user daemon-reload
  exit 0
fi

require omnigent
require_tmux
require_bwrap
OMNIGENT_BIN=$(command -v omnigent)

mkdir -p "$UNIT_DIR" "$DROP_IN_DIR"

# sed-escape the substituted values (PATH commonly contains '&' via shell
# expansions and always contains '/').
escape() {
  printf '%s' "$1" | sed -e 's/[&/\]/\\&/g'
}

sed \
  -e "s|{{OMNIGENT_BIN}}|$(escape "$OMNIGENT_BIN")|" \
  -e "s|{{OMNIGENT_PATH}}|$(escape "$PATH")|" \
  "$TEMPLATE" >"$SERVER_UNIT_PATH"
cat "$DROP_IN_SOURCE" >"$DROP_IN_DIR/omnigent-server.conf"

echo "Wrote $SERVER_UNIT_PATH"
echo "Wrote $DROP_IN_DIR/omnigent-server.conf"

systemctl --user daemon-reload

if [ "$START" = true ]; then
  systemctl --user enable "$SERVER_UNIT"
  # restart (not start) so re-running the installer applies unit changes.
  systemctl --user restart "$SERVER_UNIT"
  echo "Started $SERVER_UNIT — check with: systemctl --user status $SERVER_UNIT"
  omnigent host enable --server "$SERVER_URL"
else
  systemctl --user enable "$SERVER_UNIT"
  echo "Enabled $SERVER_UNIT (not started) — start with: systemctl --user start $SERVER_UNIT"
  echo "Then install the host service with: omnigent host enable --server $SERVER_URL"
fi

echo
echo "First install? Create the admin account in the web UI, then sign the host in:"
echo "    omnigent login $SERVER_URL && systemctl --user restart $HOST_UNIT"

if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
  echo
  echo "Note: these units stop when you log out of every session, unless"
  echo "linger is enabled for your user. To keep them running (e.g. on a"
  echo "headless/home server), run:"
  echo "    loginctl enable-linger $USER"
fi
