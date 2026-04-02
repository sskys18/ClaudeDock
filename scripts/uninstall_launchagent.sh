#!/usr/bin/env bash
set -euo pipefail

PLIST_PATH="$HOME/Library/LaunchAgents/com.sskys.ClaudeDock.plist"
INSTALL_BIN="$HOME/Library/Application Support/ClaudeDock/bin/ClaudeDock"
LABEL="com.sskys.ClaudeDock"
UID_VALUE="$(id -u)"

if [[ -f "$PLIST_PATH" ]]; then
  launchctl bootout "gui/$UID_VALUE" "$PLIST_PATH" >/dev/null 2>&1 || true
  rm -f "$PLIST_PATH"
fi

launchctl disable "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
rm -f "$INSTALL_BIN"

echo "Removed LaunchAgent: $PLIST_PATH"
echo "Removed binary: $INSTALL_BIN"
