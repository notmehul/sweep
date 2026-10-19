#!/bin/zsh
# Builds Sweep.app into build/. Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
root=${0:A:h:h}
config=${1:-debug}

swift build --package-path "$root" -c "$config" --product Sweep
bin=$(swift build --package-path "$root" -c "$config" --show-bin-path)

app="$root/build/Sweep.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Sweep" "$app/Contents/MacOS/Sweep"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
for b in "$bin"/*.bundle(N); do cp -R "$b" "$app/Contents/Resources/"; done

# A stable identity keeps the Full Disk Access grant across rebuilds; ad-hoc loses it.
identity=${SWEEP_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}
if [[ -z $identity ]]; then
  echo "warning: no signing identity found, signing ad-hoc (Full Disk Access resets each build)" >&2
  identity=-
fi
codesign --force --options runtime --timestamp=none --sign "$identity" "$app"
echo "$app"
