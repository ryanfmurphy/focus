#!/bin/bash
# Stop and remove the focus LaunchAgent.
set -euo pipefail
PLIST="$HOME/Library/LaunchAgents/com.murftown.focus.plist"
launchctl bootout "gui/$(id -u)/com.murftown.focus" 2>/dev/null || true
rm -f "$PLIST"
echo "focus uninstalled. Binary and logs left in place."
