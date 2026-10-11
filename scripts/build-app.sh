#!/bin/bash
# Builds ZoomCheck.app into ./build (ad-hoc signed, for local use).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/ZoomCheck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/ZoomCheck" "$APP/Contents/MacOS/ZoomCheck"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"

echo "Built $APP"
echo "Move it to /Applications, then give it Full Disk Access in System Settings → Privacy & Security."
