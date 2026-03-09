#!/usr/bin/env zsh
set -euo pipefail

APP_NAME="MacDiskMonitor"
LABEL="com.local.macdiskmonitor"
INSTALL_DIR="$HOME/Library/Application Support/mac-disk-monitor"
BIN_PATH="$INSTALL_DIR/$APP_NAME"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)" "$PLIST_PATH" || true
fi

launchctl disable "gui/$(id -u)/$LABEL" || true
rm -f "$PLIST_PATH"
rm -f "$BIN_PATH"

if [[ -d "$INSTALL_DIR" ]] && [[ -z "$(ls -A "$INSTALL_DIR")" ]]; then
  rmdir "$INSTALL_DIR"
fi

echo "Uninstalled $APP_NAME launch agent and binary"
