#!/bin/zsh
# Fails if any cloud model API is referenced. Sweep uses the on-device model only.
set -euo pipefail
root=${0:A:h:h}
if grep -rnE 'PrivateCloudCompute' "$root/Sources"; then
  echo "error: cloud model API referenced; Sweep is on-device only" >&2
  exit 1
fi
echo "ok: no cloud model APIs"
