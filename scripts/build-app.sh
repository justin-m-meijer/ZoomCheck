#!/bin/bash
# Builds ZoomCheck.app into ./build (ad-hoc signed).
# UNIVERSAL=1 builds for both Apple silicon and Intel (requires full Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --show-bin-path)"

APP="build/ZoomCheck.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/ZoomCheck" "$APP/Contents/MacOS/ZoomCheck"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"

echo "Built $APP"
echo "Move it to /Applications, then give it Full Disk Access in System Settings → Privacy & Security."
