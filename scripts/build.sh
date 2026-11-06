#!/usr/bin/env bash
# Builds Plexxed.app into ./build. Usage: scripts/build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
if ! [ -f "$BREW_PREFIX/lib/libmpv.dylib" ]; then
    echo "libmpv not found in $BREW_PREFIX. Install it with: brew install mpv" >&2
    exit 1
fi

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Plexxed.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Plexxed" "$APP/Contents/MacOS/Plexxed"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
codesign -f -s - "$APP" >/dev/null
echo "Built $APP"
