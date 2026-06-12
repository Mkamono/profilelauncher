#!/bin/bash
# Build ProfileLauncher.app from Sources/main.swift + Info.plist
# Usage: ./build.sh   (produces ./ProfileLauncher.app)
set -euo pipefail
cd "$(dirname "$0")"

APP="ProfileLauncher.app"
BIN_NAME="ProfileLauncher"

echo "==> Cleaning previous build"
rm -rf "$APP"

echo "==> Creating app bundle layout"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

echo "==> Compiling Swift"
swiftc -O \
  -o "$APP/Contents/MacOS/$BIN_NAME" \
  Sources/main.swift

echo "==> Installing Info.plist"
cp Info.plist "$APP/Contents/Info.plist"

echo "==> Ad-hoc code signing (required for LaunchServices / default browser)"
codesign --force --deep --sign - "$APP"

echo "==> Installing default rules if none exist"
CONFIG_DIR="$HOME/Library/Application Support/ProfileLauncher"
if [ ! -f "$CONFIG_DIR/rules.json" ]; then
  mkdir -p "$CONFIG_DIR"
  cp rules.example.json "$CONFIG_DIR/rules.json"
  echo "    -> installed $CONFIG_DIR/rules.json (edit this to set your rules)"
else
  echo "    -> existing rules kept at $CONFIG_DIR/rules.json"
fi

echo ""
echo "Done: $(pwd)/$APP"
echo "Next:"
echo "  1) Test:  ./$APP/Contents/MacOS/$BIN_NAME 'https://github.com'"
echo "  2) Move to /Applications:  mv '$APP' /Applications/"
echo "  3) Register it, then set as default browser in System Settings > Desktop & Dock."
