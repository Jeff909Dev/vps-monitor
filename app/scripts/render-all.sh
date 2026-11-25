#!/usr/bin/env bash
# Draws every state the popover and Settings can be in, in English and Spanish, light and dark, into build/render/.
# Usage: scripts/render-all.sh [path/to/vpsmon-mac]
set -euo pipefail
cd "$(dirname "$0")/.."

CLI="${1:-.build/debug/vpsmon-mac}"
OUT=../build/render
mkdir -p "$OUT"
rm -f "$OUT"/*.png

for lang in en es; do
  fixture=../fixtures/status.json
  [[ $lang == es ]] && fixture=../fixtures/status.es.json
  for theme in light dark; do
    look=(--lang "$lang")
    [[ $theme == dark ]] && look+=(--dark)
    flags=("${look[@]}" --fixture "$fixture")
    at() { echo "$OUT/$1-$lang-$theme.png"; }
    "$CLI" render "$(at popover)" "${flags[@]}"
    # RAM open on chrome, with End confirming its headless browser (16 child processes).
    "$CLI" render "$(at ram-end)" "${flags[@]}" --open-ram chrome --confirm proc:58840:326860000
    # Temporary files open, with its Free buttons; one confirming in the map.
    "$CLI" render "$(at temp-free)" "${flags[@]}" --open temp
    "$CLI" render "$(at temp-confirm)" "${flags[@]}" --open temp --confirm tmp-stale
    "$CLI" render "$(at welcome)" "${look[@]}" --welcome
    "$CLI" render "$(at outdated)" "${flags[@]}" --outdated
    "$CLI" render "$(at schema-error)" "${flags[@]}" --schema-error
    "$CLI" render "$(at offline)" "${flags[@]}" --stale
    "$CLI" render "$(at unreachable)" "${flags[@]}" --unreachable
    "$CLI" render "$(at free-failed)" "${flags[@]}" --fail docker-images
    "$CLI" render "$(at bulk-confirm)" "${flags[@]}" --confirm bulk-close
    for state in idle testing missing outdated installing password connected failed; do
      "$CLI" render "$(at "settings-$state")" "${flags[@]}" --settings "$state"
    done
  done
done > /dev/null
ls "$OUT" | wc -l | xargs echo "PNGs in $OUT:"
