#!/bin/zsh
# Tests, builds and publishes a GitHub release with Sweep.dmg and Sweep.zip.
# The version comes from CFBundleShortVersionString in Resources/Info.plist.
# Usage: scripts/release.sh            build and publish v<version>
#        scripts/release.sh --dry-run  build into dist/ without tagging or publishing
set -euo pipefail
root=${0:A:h:h}
cd "$root"
dry_run=${1:-}

version=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
tag="v$version"

if [[ $dry_run != --dry-run ]]; then
  [[ -z $(git status --porcelain) ]] || { echo "error: commit your changes first" >&2; exit 1; }
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "error: $tag already exists; bump CFBundleShortVersionString" >&2; exit 1
  fi
fi

swift test
scripts/check-no-cloud.sh
# The Apple Development certificate names a personal email, so public builds are signed
# ad-hoc until there's a Developer ID. Set SWEEP_SIGN_IDENTITY to override.
app=$(SWEEP_SIGN_IDENTITY=${SWEEP_SIGN_IDENTITY:--} scripts/bundle.sh release | tail -1)
codesign --verify --strict "$app"

dist="$root/dist"
rm -rf "$dist" && mkdir -p "$dist"
ditto -c -k --keepParent "$app" "$dist/Sweep.zip"

# The disk image opens to Sweep next to an Applications shortcut, ready to drag across.
staging=$(mktemp -d)
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname Sweep -srcfolder "$staging" -ov -format UDZO "$dist/Sweep.dmg"
rm -rf "$staging"

(cd "$dist" && shasum -a 256 Sweep.dmg Sweep.zip > SHA256SUMS)
echo "built $tag in $dist"
[[ $dry_run == --dry-run ]] && exit 0

git tag -a "$tag" -m "Sweep $version"
git push origin "$tag"
gh release create "$tag" "$dist/Sweep.dmg" "$dist/Sweep.zip" "$dist/SHA256SUMS" \
  --title "Sweep $version" --notes-file scripts/release-notes.md
