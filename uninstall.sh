#!/bin/bash
# Uninstall ProfileLauncher. Keeps your rules.json unless --purge is given.
# Usage: ./uninstall.sh [--purge]
set -euo pipefail

APP="ProfileLauncher.app"
DEST="/Applications/$APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
CONFIG_DIR="$HOME/Library/Application Support/ProfileLauncher"
LOG="$HOME/Library/Logs/ProfileLauncher.log"

echo "==> Quitting running instance"
pkill -f "$DEST/Contents/MacOS/ProfileLauncher" 2>/dev/null || true

if [ -d "$DEST" ]; then
  echo "==> Unregistering from LaunchServices"
  [ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$DEST" || true
  echo "==> Removing $DEST"
  rm -rf "$DEST"
else
  echo "    $DEST not found (already removed)"
fi

if [ "${1:-}" = "--purge" ]; then
  echo "==> Purging config and logs"
  rm -rf "$CONFIG_DIR"
  rm -f "$LOG"
else
  echo ""
  echo "Kept your config at: $CONFIG_DIR/rules.json"
  echo "Run with --purge to remove config and logs too."
fi

echo ""
echo "Note: reset your default browser in System Settings > Desktop & Dock if needed."
