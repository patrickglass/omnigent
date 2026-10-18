#!/bin/sh
# Installs (or removes) the Omnigent systemd --user service: runs
# `omnigent host ""` (local mode — spawns/reuses the local server and
# registers this machine as a host) so it starts at login and restarts on
# failure, instead of a terminal tab you have to keep open.
#
# This is a *user* unit, not a system-wide one: the host daemon needs your
# HOME, your PATH (node/npm/tmux/bwrap, and the harness CLIs it launches —
# claude, codex, ...), and your locally-stored credentials, none of which a
# dedicated system service account would have.
#
# Usage:
#   ./install.sh                 install, enable, and start the service
#   ./install.sh --no-start      install and enable, but don't start now
#   ./install.sh --uninstall     stop, disable, and remove the service
#
# By default a user unit only runs while you have an active login session.
# To keep it running after you log out (e.g. on a headless/home server), the
# installer offers to enable linger for your user (`loginctl enable-linger`).

set -eu

UNIT_NAME=omnigent.service
UNIT_DIR="$HOME/.config/systemd/user"
UNIT_PATH="$UNIT_DIR/$UNIT_NAME"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TEMPLATE="$SCRIPT_DIR/omnigent.service"

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

require systemctl

if [ "$ACTION" = uninstall ]; then
  if [ -f "$UNIT_PATH" ]; then
    systemctl --user disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
    rm -f "$UNIT_PATH"
    systemctl --user daemon-reload
    echo "Removed $UNIT_PATH"
  else
    echo "No unit installed at $UNIT_PATH"
  fi
  exit 0
fi

require omnigent
OMNIGENT_BIN=$(command -v omnigent)

mkdir -p "$UNIT_DIR"

# sed-escape the substituted values (PATH commonly contains '&' via shell
# expansions and always contains '/').
escape() {
  printf '%s' "$1" | sed -e 's/[&/\]/\\&/g'
}

sed \
  -e "s|{{OMNIGENT_BIN}}|$(escape "$OMNIGENT_BIN")|" \
  -e "s|{{OMNIGENT_PATH}}|$(escape "$PATH")|" \
  "$TEMPLATE" >"$UNIT_PATH"

echo "Wrote $UNIT_PATH"

systemctl --user daemon-reload

if [ "$START" = true ]; then
  systemctl --user enable --now "$UNIT_NAME"
  echo "Started $UNIT_NAME — check with: systemctl --user status $UNIT_NAME"
else
  systemctl --user enable "$UNIT_NAME"
  echo "Enabled $UNIT_NAME (not started) — start with: systemctl --user start $UNIT_NAME"
fi

if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
  echo
  echo "Note: this unit stops when you log out of every session, unless"
  echo "linger is enabled for your user. To keep it running (e.g. on a"
  echo "headless/home server), run:"
  echo "    loginctl enable-linger $USER"
fi
