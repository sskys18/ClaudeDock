#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SUPPORT_DIR="$HOME/Library/Application Support/ClaudeDock/bin"
INSTALL_BIN="$APP_SUPPORT_DIR/ClaudeDock"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/com.sskys.ClaudeDock.plist"
LOG_DIR="$HOME/Library/Logs/ClaudeDock"
STDOUT_LOG="$LOG_DIR/stdout.log"
STDERR_LOG="$LOG_DIR/stderr.log"
LABEL="com.sskys.ClaudeDock"
UID_VALUE="$(id -u)"

mkdir -p "$APP_SUPPORT_DIR" "$PLIST_DIR" "$LOG_DIR"

swift build -c release --package-path "$REPO_ROOT"
install -m 755 "$REPO_ROOT/.build/release/ClaudeDock" "$INSTALL_BIN"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_BIN</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$REPO_ROOT</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CODEX_HOME</key>
    <string>$REPO_ROOT/.codex</string>
    <key>CLAUDEDOCK_WORKSPACE_ROOT</key>
    <string>$REPO_ROOT</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>LimitLoadToSessionType</key>
  <array>
    <string>Aqua</string>
  </array>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$STDOUT_LOG</string>
  <key>StandardErrorPath</key>
  <string>$STDERR_LOG</string>
</dict>
</plist>
PLIST

plutil -lint "$PLIST_PATH" >/dev/null
launchctl bootout "gui/$UID_VALUE" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID_VALUE" "$PLIST_PATH"
launchctl kickstart -kp "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true

"$REPO_ROOT/scripts/configure_codex_statusline.py"

echo "Installed binary: $INSTALL_BIN"
echo "Installed LaunchAgent: $PLIST_PATH"
echo "Configured status line in: $HOME/.codex/config.toml"
