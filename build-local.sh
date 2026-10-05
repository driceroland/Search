#!/bin/bash
# A personal, ad-hoc-signed bundle, with its own data and no upstream auto-update.
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-debug}"
SEARCH_SIGN_IDENTITY=- ./build.sh "$CONFIG"
case "${SEARCH_ARCH:-$(uname -m)}" in
  arm64) LOCAL_OUT="build" ;;
  x86_64) LOCAL_OUT="build/intel" ;;
  *) echo "Unsupported SEARCH_ARCH" >&2; exit 1 ;;
esac
APP="$LOCAL_OUT/local/Search.app"
mkdir -p "$LOCAL_OUT/local"
if [ -e "$APP" ]; then
  # Only a bundle created by this script may be replaced.
  PROFILE=$(/usr/libexec/PlistBuddy -c 'Print SearchLocalProfile' "$APP/Contents/Info.plist" 2>/dev/null || true)
  [ "$PROFILE" = 'local' ] || { echo 'Refusing to replace an unrelated bundle' >&2; exit 1; }
  rm -rf "$APP"
fi
cp -R "$LOCAL_OUT/Search.app" "$APP"
/usr/bin/python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f: info = plistlib.load(f)
info.update(CFBundleIdentifier='local.searchbrowser', SearchLocalProfile='local',
            CFBundleDevelopmentRegion='en', CFBundleLocalizations=['en','fr'])
with open(path, 'wb') as f: plistlib.dump(info, f)
PY
codesign --force --deep --sign - "$APP"
echo "Ready: $PWD/$APP"
