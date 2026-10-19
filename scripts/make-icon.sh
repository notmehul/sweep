#!/bin/zsh
# Renders the app icon from scripts/make-icon.swift into Resources/AppIcon.icns.
set -euo pipefail
root=${0:A:h:h}
work=$(mktemp -d)
swiftc -O -o "$work/make-icon" "$root/scripts/make-icon.swift"
"$work/make-icon" "$work/icon-1024.png"
set=$work/AppIcon.iconset
mkdir -p "$set"
for size in 16 32 128 256 512; do
  sips -z $size $size "$work/icon-1024.png" --out "$set/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$work/icon-1024.png" --out "$set/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$set" -o "$root/Resources/AppIcon.icns"
cp "$work/icon-1024.png" "$root/Resources/AppIcon-1024.png"
rm -rf "$work"
echo "$root/Resources/AppIcon.icns"
