#!/bin/bash
# Checks the packaged app before anyone downloads it: signed ad-hoc as the
# right bundle ID, both slices present, the version from VERSION, menu bar only,
# and the bundled server installer valid and of the same version.
#
#   scripts/verify-dist.sh [path/to/VPS Monitor.app]
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
app=${1:-$root/build/VPS Monitor.app}
plist=$app/Contents/Info.plist
installer=$app/Contents/Resources/vpsmon-install.sh
dist_installer=$root/build/dist/vpsmon-install.sh
bundle_id=com.jeff909dev.VPSMonitor
version=$(tr -d '[:space:]' <"$root/VERSION")
failed=0

# check <description> <command...>: prints ok or FAIL with the command's output.
check() {
  local desc=$1 out line
  shift
  if out=$("$@" 2>&1); then
    echo "ok    $desc"
  else
    echo "FAIL  $desc"
    [ -n "$out" ] && while IFS= read -r line; do echo "      $line"; done <<<"$out"
    failed=1
  fi
}

adhoc_as() {
  local info
  info=$(codesign -dv "$1" 2>&1)
  if grep -qx 'Signature=adhoc' <<<"$info" && grep -qxF "Identifier=$2" <<<"$info"; then return 0; fi
  echo "$info"
  return 1
}

universal() {
  local archs
  archs=$(lipo -archs "$1") || return 1
  [ "$(tr ' ' '\n' <<<"$archs" | sort | xargs)" = "arm64 x86_64" ] || { echo "slices: $archs"; return 1; }
}

# plist_is <key> <expected>: the Info.plist value of key equals expected.
plist_is() {
  local value
  value=$(/usr/libexec/PlistBuddy -c "Print :$1" "$plist") || return 1
  [ "$value" = "$2" ] || { echo "$1 is '$value'"; return 1; }
}

# The installer carries vpsmon as text, so its VERSION = line must say $version.
embedded_version() {
  local found
  found=$(sed -n 's/^VERSION = "\([^"]*\)"$/\1/p' "$installer" | sort -u)
  [ "$found" = "$version" ] || { echo "VERSION = lines: ${found:-none}"; return 1; }
}

[ -d "$app" ] || { echo "verify-dist: no app at $app (run make dist)"; exit 1; }
exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")

check "app is signed ad-hoc as $bundle_id" adhoc_as "$app" "$bundle_id"
check "app signature verifies (--deep --strict)" codesign --verify --deep --strict "$app"
check "$exe is universal" universal "$app/Contents/MacOS/$exe"
check "CFBundleIdentifier is $bundle_id" plist_is CFBundleIdentifier "$bundle_id"
check "CFBundleShortVersionString is $version (VERSION)" plist_is CFBundleShortVersionString "$version"
check "LSUIElement is true" plist_is LSUIElement true
check "Resources/vpsmon-install.sh is present" test -f "$installer"
check "Resources/vpsmon-install.sh passes sh -n" sh -n "$installer"
check "Resources/vpsmon-install.sh embeds vpsmon $version" embedded_version
if [ -f "$dist_installer" ]; then
  check "the bundled installer is the release asset build/dist/vpsmon-install.sh" cmp "$installer" "$dist_installer"
fi

if [ "$failed" = 0 ]; then
  echo "verify-dist: all checks passed"
else
  echo "verify-dist: FAILED"
  exit 1
fi
