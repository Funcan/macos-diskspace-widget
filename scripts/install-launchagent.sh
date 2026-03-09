#!/usr/bin/env zsh
set -euo pipefail

APP_NAME="MacDiskMonitor"
LABEL="com.local.macdiskmonitor"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="$HOME/Library/Application Support/mac-disk-monitor"
BIN_PATH="$INSTALL_DIR/$APP_NAME"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$INSTALL_DIR"
mkdir -p "$HOME/Library/LaunchAgents"

cd "$ROOT_DIR"
swift build -c release
cp ".build/release/$APP_NAME" "$BIN_PATH"
chmod +x "$BIN_PATH"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN_PATH</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
</dict>
</plist>
EOF

if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)" "$PLIST_PATH" || true
fi

launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl enable "gui/$(id -u)/$LABEL"

echo "Installed and started $APP_NAME via $LABEL"
