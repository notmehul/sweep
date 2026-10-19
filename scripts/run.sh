#!/bin/zsh
# Build, bundle, sign and relaunch Sweep.app.
set -euo pipefail
app=$("${0:A:h}/bundle.sh" "$@" | tail -1)
pkill -x Sweep 2>/dev/null || true
open "$app"
