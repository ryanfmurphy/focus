#!/bin/bash
# Compile and run the headless FocusCore data-layer tests (no AppKit, no app launch).
# Just the data core + the test file; a nonzero exit means something failed.
set -euo pipefail
cd "$(dirname "$0")"

BIN="$(mktemp -t focus-tests)"
trap 'rm -f "$BIN"' EXIT
swiftc FocusCore.swift tests/main.swift -o "$BIN"
"$BIN"
