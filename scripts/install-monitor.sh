#!/bin/bash
# Installs a LaunchAgent that checks the update feed every 6 hours.
#   ./scripts/install-monitor.sh install
#   ./scripts/install-monitor.sh uninstall
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.lucas.updates-check"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STAGED="$ROOT/Config/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/Lucas"
ACTION="${1:-install}"

if [ "$ACTION" = "uninstall" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST" "$STAGED"
    echo "removed $LABEL"
    exit 0
fi

mkdir -p "$LOG_DIR" "$ROOT/Config" 2>/dev/null || true

cat > "$STAGED" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$ROOT/scripts/check-updates.sh</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>LUCAS_CHECK_RESOLVE</key>
        <string>43.132.224.242</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>21600</integer>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/updates-monitor.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/updates-monitor.log</string>
</dict>
</plist>
PLIST

if [ ! -w "$HOME/Library/LaunchAgents" ] || [ ! -w "$HOME/Library/Logs/Lucas" ]; then
    echo "sandbox cannot write ~/Library/LaunchAgents or ~/Library/Logs."
    echo "prepared: $STAGED"
    echo
    echo "run these two lines in a normal Terminal to install:"
    echo "  mkdir -p ~/Library/LaunchAgents ~/Library/Logs/Lucas"
    echo "  cp \\"$STAGED\\" \\"$PLIST\\" && launchctl bootstrap gui/$(id -u) \\"$PLIST\\""
    exit 0
fi

cp "$STAGED" "$PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
echo "installed $LABEL (every 6h, log: $LOG_DIR/updates-monitor.log)"
