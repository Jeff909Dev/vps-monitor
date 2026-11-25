#!/bin/bash
# Fails unless VERSION, the VERSION literal in server/vpsmon and the tag (when
# given) name the same release.
#
#   scripts/check-version.sh [v0.2.0]
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
semver='^[0-9]+\.[0-9]+\.[0-9]+$'

version=$(tr -d '[:space:]' <"$root/VERSION" 2>/dev/null)
if ! grep -Eq "$semver" <<<"$version"; then
  echo "check-version: VERSION must hold x.y.z, found '$version'"
  exit 1
fi

server=$(sed -n 's/^VERSION = "\([^"]*\)"$/\1/p' "$root/server/vpsmon" 2>/dev/null)
if [ -z "$server" ]; then
  echo "check-version: server/vpsmon has no line VERSION = \"x.y.z\""
  exit 1
fi
if [ "$(wc -l <<<"$server" | tr -d ' ')" != 1 ]; then
  echo "check-version: server/vpsmon has more than one VERSION = line"
  exit 1
fi

failed=0
if [ "$server" != "$version" ]; then
  echo "check-version: server/vpsmon says $server, VERSION says $version"
  failed=1
fi
if [ $# -gt 0 ]; then
  tag=${1#v}
  if [ "$tag" != "$version" ]; then
    echo "check-version: tag $1 does not match VERSION $version"
    failed=1
  fi
fi

[ "$failed" = 0 ] || exit 1
echo "check-version: $version${1:+ (tag $1)}"
