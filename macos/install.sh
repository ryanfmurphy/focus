#!/bin/bash
# Build the focus app and install it as a login LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")"

PLIST="$HOME/Library/LaunchAgents/com.murftown.focus.plist"
BIN="$PWD/focus"   # absolute path to the built binary on THIS machine

echo "Building..."
swiftc main.swift FocusCore.swift -o focus

echo "Installing LaunchAgent -> $PLIST"
# Fill the plist template's __FOCUS_BIN__ with this machine's binary path (launchd
# needs an absolute path, so it's generated here rather than hardcoded in the repo).
sed "s|__FOCUS_BIN__|$BIN|g" com.murftown.focus.plist > "$PLIST"

# Reload cleanly. bootout is async, so wait for the old instance to fully
# unload before bootstrapping — otherwise bootstrap races with an I/O error.
pkill -f "$BIN" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.murftown.focus" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Done. The focus prompt should appear now (launch counts as a return),"
echo "and thereafter on every login / wake / screen unlock."
echo
echo "Data: ~/focus/focus.db   |   stderr: /tmp/focus.err.log"
echo "Uninstall: ./uninstall.sh"
