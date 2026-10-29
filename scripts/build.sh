#!/usr/bin/env zsh
# Wraps `swift build`, embedding git version info into the binary as an
# Info.plist (__TEXT,__info_plist) so Bundle.main.infoDictionary can read it.
# Any arguments are passed through to `swift build`.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="$(git describe --tags --always --dirty)"
COMMIT="$(git rev-parse HEAD)"
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  DIRTY=true
else
  DIRTY=false
fi

PLIST_PATH="$ROOT_DIR/.build/Info.plist"
mkdir -p "$(dirname "$PLIST_PATH")"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>MacDiskMonitor</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>GitCommit</key>
  <string>$COMMIT</string>
  <key>GitDirty</key>
  <$DIRTY/>
</dict>
</plist>
EOF

# SwiftPM only relinks when sources change, so remove the old binary to make
# sure a new tag or dirty state still ends up embedded.
rm -f "$(swift build --show-bin-path "$@")/MacDiskMonitor"

swift build "$@" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST_PATH"
