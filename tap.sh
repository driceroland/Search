#!/bin/bash
# Points Homebrew at the version just released: the cask in
# github.com/driceroland/homebrew-tap gets this version and the checksums of
# the two disk images on its GitHub release, so that
#
#   brew install --cask driceroland/tap/search
#
# installs the one for the Mac it runs on, and brew upgrade brings it. Run it
# once the release is on GitHub (tag vX.Y.Z, Search.dmg for Apple Silicon and
# Search-Intel.dmg for Intel attached); it reads the version from VERSION.
set -euo pipefail

cd "$(dirname "$0")"
VERSION="$(tr -d '[:space:]' < VERSION)"
BASE="https://github.com/driceroland/Search/releases/download/v$VERSION"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for DMG in Search.dmg Search-Intel.dmg; do
  curl -fsSL -o "$WORK/$DMG" "$BASE/$DMG" \
    || { echo "no $DMG on the v$VERSION release yet — publish the release first" >&2; exit 1; }
done
ARM="$(shasum -a 256 "$WORK/Search.dmg" | cut -d' ' -f1)"
INTEL="$(shasum -a 256 "$WORK/Search-Intel.dmg" | cut -d' ' -f1)"

git clone -q https://github.com/driceroland/homebrew-tap.git "$WORK/tap"
CASK="$WORK/tap/Casks/search.rb"
# Everything above the name — the chip, the version, both checksums and the
# address they fill in — is written afresh; the rest of the cask stays as
# the tap has it. Up to 1.0.4 the cask was Apple Silicon only.
python3 - "$CASK" "$VERSION" "$ARM" "$INTEL" <<'PY'
import re, sys
path, version, arm, intel = sys.argv[1:]
text = open(path).read()
head = f'''  arch arm: "", intel: "-Intel"

  version "{version}"
  sha256 arm:   "{arm}",
         intel: "{intel}"

  url "https://github.com/driceroland/Search/releases/download/v#{{version}}/Search#{{arch}}.dmg"
'''
text, found = re.subn(r'(cask "search" do\n)(.*?)(  name )', lambda m: m.group(1) + head + m.group(3), text, count=1, flags=re.S)
if not found:
    sys.exit("the cask doesn't have the shape tap.sh knows — look at it by hand")
text = text.replace("  depends_on arch: :arm64\n", "")
open(path, "w").write(text)
PY
if git -C "$WORK/tap" diff --quiet; then
  echo "the tap already has Search $VERSION"
  exit 0
fi
git -C "$WORK/tap" commit -qam "Search $VERSION"
git -C "$WORK/tap" push -q
echo "tap: Search $VERSION, sha256 $ARM (Apple Silicon), $INTEL (Intel)"
