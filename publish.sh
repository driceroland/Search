#!/bin/bash
# Puts the three files the site serves into the site: the disk image for
# people, the ZIP for the updater, and the appcast that names them both.
#
#   ./publish.sh "../Office Commun Website/public/search"
#   SEARCH_ARCH=x86_64 ./publish.sh "../Office Commun Website/public/search"
#
# ./build.sh release ship makes them first (release dmg makes them too, but
# unnotarised — fine for trying, not for anyone else's Mac). The names never
# change, so the site's links never have to. The Intel build (build/intel/)
# goes into the folder's intel/, where Intel builds of Search look.
set -euo pipefail

cd "$(dirname "$0")"
[ $# -eq 1 ] || { echo "usage: ./publish.sh <folder>" >&2; exit 1; }
ARCH="${SEARCH_ARCH:-arm64}"
case "$ARCH" in
  arm64) FROM="build"; FOLDER="$1" ;;
  x86_64) FROM="build/intel"; FOLDER="${1%/}/intel" ;;
  *) echo "SEARCH_ARCH is arm64 or x86_64, not “$ARCH”" >&2; exit 1 ;;
esac
FILES=(Search.dmg Search.zip appcast.json appcast.json.zip)

for FILE in "${FILES[@]}"; do
  [ -f "$FROM/$FILE" ] || { echo "$FROM/$FILE is missing — ./build.sh release dmg makes it" >&2; exit 1; }
done
# This version's files, for this chip — not ones left from an earlier build.
VERSION="$(tr -d '[:space:]' < VERSION)"
grep -q "\"version\": \"$VERSION\"" "$FROM/appcast.json" \
  || { echo "$FROM/appcast.json isn't $VERSION — build it again first" >&2; exit 1; }
CHIP="$(mktemp -d)"
ditto -x -k "$FROM/Search.zip" "$CHIP"
[ "$(lipo -archs "$CHIP/Search.app/Contents/MacOS/Search")" = "$ARCH" ] \
  || { rm -rf "$CHIP"; echo "$FROM/Search.zip doesn't hold a $ARCH app — not publishing" >&2; exit 1; }
rm -rf "$CHIP"
# The signed feed has to hold up before it goes anywhere: builds from 1.0.4
# read only it, and a broken one would stop every update without a word.
CHECK="$(mktemp -d)"
ditto -x -k "$FROM/appcast.json.zip" "$CHECK"
codesign --verify -R='anchor apple generic and identifier "com.officecommun.search.appcast" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "7BYKA895MC"' "$CHECK/appcast.json" \
  || { rm -rf "$CHECK"; echo "$FROM/appcast.json.zip doesn't verify — not publishing" >&2; exit 1; }
cmp -s "$CHECK/appcast.json" "$FROM/appcast.json" || { rm -rf "$CHECK"; echo "the signed appcast isn't $FROM/appcast.json — not publishing" >&2; exit 1; }
rm -rf "$CHECK"
xcrun stapler validate -q "$FROM/Search.dmg" >/dev/null 2>&1 \
  || echo "note: $FROM/Search.dmg is not notarised — ./build.sh release ship does that" >&2

mkdir -p "$FOLDER"
# The AI engine the feed names, when it names one (build.sh, write_engine):
# only a file whose hash is the one in the feed.
ENGINEURL="$(python3 -c 'import json,sys; e=json.load(open(sys.argv[1])).get("ai",{}).get("engine"); print(e["url"] if e else "")' "$FROM/appcast.json")"
if [ -n "$ENGINEURL" ]; then
  ENGINEFILE="$FROM/ai/$(basename "$ENGINEURL")"
  WANT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ai"]["engine"]["sha256"])' "$FROM/appcast.json")"
  [ -f "$ENGINEFILE" ] && [ "$(shasum -a 256 "$ENGINEFILE" | cut -d' ' -f1)" = "$WANT" ] \
    || { echo "the engine the feed names isn't $ENGINEFILE with its hash — not publishing" >&2; exit 1; }
  mkdir -p "$FOLDER/ai"
  cp "$ENGINEFILE" "$FOLDER/ai/"
  echo "copied: $ENGINEFILE → $FOLDER/ai/"
fi
# The developer tools packages the feed names (build.sh, write_devtools),
# into devtools/ beside the app, where their addresses point: each a ZIP of
# this chip whose size and hash are the feed's, and whose package inside
# is signed with the Developer ID for its own identifier. All checked
# before any is copied.
DEVTOOLS="$(python3 -c '
import json, sys
for e in json.load(open(sys.argv[1])).get("devtools", []):
    print(e["url"].rsplit("/", 1)[1], e["sha256"], e["size"], e["id"])' "$FROM/appcast.json")"
if [ -n "$DEVTOOLS" ]; then
  while read -r NAME WANT SIZE ID; do
    PACKAGE="$FROM/devtools/$NAME"
    [ -f "$PACKAGE" ] && [ "$(shasum -a 256 "$PACKAGE" | cut -d' ' -f1)" = "$WANT" ] && [ "$(stat -f%z "$PACKAGE")" = "$SIZE" ] \
      || { echo "the package the feed names isn't $PACKAGE with its hash and size — not publishing" >&2; exit 1; }
    case "$NAME" in *-"$ARCH"-*.zip) ;; *) echo "$NAME isn't a $ARCH package — not publishing" >&2; exit 1 ;; esac
    UNPACKED="$(mktemp -d)"
    ditto -x -k "$PACKAGE" "$UNPACKED"
    codesign --verify --strict -R="anchor apple generic and identifier \"com.officecommun.search.devtools.$ID\" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"7BYKA895MC\"" "$UNPACKED"/*.bundle \
      || { rm -rf "$UNPACKED"; echo "$PACKAGE isn't signed with the Developer ID as com.officecommun.search.devtools.$ID — not publishing" >&2; exit 1; }
    rm -rf "$UNPACKED"
  done <<< "$DEVTOOLS"
  mkdir -p "$FOLDER/devtools"
  while read -r NAME _; do
    cp "$FROM/devtools/$NAME" "$FOLDER/devtools/"
    echo "copied: $FROM/devtools/$NAME → $FOLDER/devtools/"
  done <<< "$DEVTOOLS"
fi
for FILE in "${FILES[@]}"; do
  cp "$FROM/$FILE" "$FOLDER/$FILE"
  echo "copied: $FROM/$FILE → $FOLDER/$FILE"
done
