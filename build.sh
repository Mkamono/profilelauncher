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
# Ask the binary which file it will actually read, so we seed THAT exact path
# (env var / ~/.config / App Support) instead of guessing — avoids the
# "edited the wrong file" confusion.
CONFIG_FILE="$("$APP/Contents/MacOS/$BIN_NAME" --config-path)"
if [ ! -f "$CONFIG_FILE" ]; then
  mkdir -p "$(dirname "$CONFIG_FILE")"
  cp rules.example.json "$CONFIG_FILE"
  echo "    -> installed $CONFIG_FILE (edit this to set your rules)"
else
  echo "    -> existing rules kept at $CONFIG_FILE"
fi

echo ""
echo "Done: $(pwd)/$APP"
echo "Next:"
echo "  1) Test:  ./$APP/Contents/MacOS/$BIN_NAME 'https://github.com'"
echo "  2) Move to /Applications:  mv '$APP' /Applications/"
echo "  3) Register it, then set as default browser in System Settings > Desktop & Dock."
