#!/bin/bash
# Packs the built app and the server installer into build/dist: the .zip, the
# .dmg with an Applications link, and SHA256SUMS.txt over every release asset.
# `make dist` builds the inputs first.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
version=$(tr -d '[:space:]' <"$root/VERSION")
app="$root/build/VPS Monitor.app"
dist="$root/build/dist"
zip="VPS-Monitor-$version-mac.zip"
dmg="VPS-Monitor-$version-mac.dmg"
installer=vpsmon-install.sh

[ -d "$app" ] || { echo "make-dist: no app at $app (run make app)"; exit 1; }
[ -f "$dist/$installer" ] || { echo "make-dist: no $dist/$installer (run make installer)"; exit 1; }

rm -f "$dist/$zip" "$dist/$dmg" "$dist/SHA256SUMS.txt"
ditto -c -k --keepParent "$app" "$dist/$zip"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/VPS Monitor.app"
ln -s /Applications "$stage/Applications"
# hdiutil sometimes fails with "Resource busy" on CI runners; a retry clears it.
for attempt in 1 2 3; do
  if hdiutil create -volname "VPS Monitor" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dist/$dmg"; then
    break
  fi
  [ "$attempt" = 3 ] && { echo "make-dist: hdiutil failed 3 times"; exit 1; }
  sleep 5
done

cd "$dist"
shasum -a 256 "$dmg" "$zip" "$installer" >SHA256SUMS.txt
cat SHA256SUMS.txt
