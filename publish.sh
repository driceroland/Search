#!/bin/bash
# Puts the three files the site serves into the site: the disk image for
# people, the ZIP for the updater, and the appcast that names them both.
#
#   ./publish.sh "../Office Commun Website/public/search"
#
# ./build.sh release ship makes them first (release dmg makes them too, but
# unnotarised — fine for trying, not for anyone else's Mac). The names never
# change, so the site's links never have to.
set -euo pipefail

cd "$(dirname "$0")"
[ $# -eq 1 ] || { echo "usage: ./publish.sh <folder>" >&2; exit 1; }
FOLDER="$1"
FILES=(Search.dmg Search.zip appcast.json appcast.json.zip)

for FILE in "${FILES[@]}"; do
  [ -f "build/$FILE" ] || { echo "build/$FILE is missing — ./build.sh release dmg makes it" >&2; exit 1; }
done
# The signed feed has to hold up before it goes anywhere: builds from 1.0.4
# read only it, and a broken one would stop every update without a word.
CHECK="$(mktemp -d)"
ditto -x -k build/appcast.json.zip "$CHECK"
codesign --verify -R='anchor apple generic and identifier "com.officecommun.search.appcast" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "7BYKA895MC"' "$CHECK/appcast.json" \
  || { rm -rf "$CHECK"; echo "build/appcast.json.zip doesn't verify — not publishing" >&2; exit 1; }
cmp -s "$CHECK/appcast.json" build/appcast.json || { rm -rf "$CHECK"; echo "the signed appcast isn't build/appcast.json — not publishing" >&2; exit 1; }
rm -rf "$CHECK"
xcrun stapler validate -q "build/Search.dmg" >/dev/null 2>&1 \
  || echo "note: build/Search.dmg is not notarised — ./build.sh release ship does that" >&2

mkdir -p "$FOLDER"
for FILE in "${FILES[@]}"; do
  cp "build/$FILE" "$FOLDER/$FILE"
  echo "copied: build/$FILE → $FOLDER/$FILE"
done
