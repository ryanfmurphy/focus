#!/bin/bash
# Relaunch focus after a clean quit (Cmd-Q / "Quit focus").
# The agent stays loaded after a clean exit — this just (re)starts the process.
# If it isn't loaded at all (e.g. after uninstall), fall back to installing.
set -euo pipefail

LABEL="com.murftown.focus"
TARGET="gui/$(id -u)/$LABEL"

if launchctl print "$TARGET" >/dev/null 2>&1; then
    launchctl kickstart -k "$TARGET"   # -k: restart if somehow already running
    echo "Relaunched $LABEL."
else
    echo "Agent isn't loaded — running install.sh to bootstrap it."
    exec "$(dirname "$0")/install.sh"
fi
