#!/bin/bash
# Install ProfileLauncher: build, place in /Applications, register, launch.
# Usage: ./install.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="ProfileLauncher.app"
DEST_DIR="/Applications"
DEST="$DEST_DIR/$APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "==> Building"
./build.sh >/dev/null
echo "    built ./$APP"

echo "==> Installing to $DEST_DIR"
if [ -d "$DEST" ]; then
  echo "    existing install found; replacing"
  # Quit any running instance so the bundle can be replaced.
  pkill -f "$DEST/Contents/MacOS/ProfileLauncher" 2>/dev/null || true
  rm -rf "$DEST"
fi
cp -R "$APP" "$DEST"
echo "    installed $DEST"

echo "==> Registering with LaunchServices"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$DEST"
  echo "    registered"
else
  echo "    lsregister not found; opening once to register instead"
fi

echo "==> Launching once (registers as an http/https handler)"
open "$DEST"
sleep 1

echo "==> Requesting to become the default web browser"
echo "    (macOS may show a confirmation dialog — choose \"Use ProfileLauncher\")"
"$DEST/Contents/MacOS/ProfileLauncher" --set-default || true

# The single file the installed app actually reads (resolved by the binary).
CONFIG_FILE="$("$DEST/Contents/MacOS/ProfileLauncher" --config-path)"

echo ""
echo "==> Validating rules.json against this machine's Brave profiles"
echo ""
"$DEST/Contents/MacOS/ProfileLauncher" --check || true

echo ""
echo "Installed."
echo "If the default browser did not change, set it manually in"
echo "  System Settings > Desktop & Dock > Default web browser -> ProfileLauncher"
echo ""
echo "Active config (edit THIS file): $CONFIG_FILE"
echo "Re-validate any time:  \"$DEST/Contents/MacOS/ProfileLauncher\" --check"
echo "Diagnose problems:     \"$DEST/Contents/MacOS/ProfileLauncher\" --doctor"
echo "Logs:    ~/Library/Logs/ProfileLauncher.log"
