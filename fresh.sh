#!/bin/bash
# A first launch, without touching the browser you actually use.
#
#   ./fresh.sh          wipe this checkout's test world and open Search as a newcomer
#   ./fresh.sh again    open the test copy as it was left, no wipe
#
#   SEARCH_PROBE=NAME ./fresh.sh   the same for a named world, "Search (NAME)"
#
# A run with SEARCH_PROBE=1 keeps everything apart from the real one: its own
# folder under Application Support, its own settings suite, its own WebKit
# store for cookies and sign-ins. Wiping those three is a fresh install; the
# real session, pins, history and logins are never in reach of this script.
set -euo pipefail

cd "$(dirname "$0")"

# The world, named the way Store.world names it: the test world is this
# checkout's own, test and the first eight hex digits of a SHA-1 of its
# real path, so two checkouts testing at once never share one.
WORLD=$(printf '%s' "${SEARCH_PROBE:-test}" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')
case "$WORLD" in ""|1|test) WORLD="test-$(printf '%s' "$(pwd -P)" | shasum | cut -c1-8)" ;; esac
# Store.probeStore: FNV-1a of the name in the store's identifier.
SUITE="com.officecommun.search.test.$WORLD"; HASH=2166136261
for ((i = 0; i < ${#WORLD}; i++)); do
  HASH=$(( ((HASH ^ $(printf '%d' "'${WORLD:i:1}")) * 16777619) & 0xFFFFFFFF ))
done
STORE=$(printf '5E4C%04X-%04X-4000-8000-000000000001' $((HASH >> 16)) $((HASH & 0xFFFF)))

if [ "${1:-}" != "again" ]; then
  rm -rf "$HOME/Library/Application Support/Search ($WORLD)"
  defaults delete "$SUITE" 2>/dev/null || true
  # Store.probeStore(1), the fixed identifier of the world's website data.
  rm -rf "$HOME/Library/WebKit/com.officecommun.search/WebsiteDataStore/$STORE"
  echo "world \"$WORLD\" wiped"
fi

[ -d "build/Search.app" ] || ./build.sh release

# A world the bench is going to drive opens hidden. A test run that comes to
# the front trips the probe's own guard, which hides the app and then refuses
# every command for the rest of that run, as it should: a run that showed a
# window is one to throw away. A world with the switch off is opened to be
# looked at, so it opens as before.
HIDDEN=""
if [ "$(defaults read "$SUITE" bench 2>/dev/null || true)" = 1 ]; then
  HIDDEN="-g -j"
fi
open -n $HIDDEN --env SEARCH_PROBE="$WORLD" "build/Search.app"
