#!/bin/bash
# Assembles a double-clickable .app around the SwiftPM binary — and, when
# asked, the disk image people install it from.
#
#   ./build.sh                 debug-free release build, ad-hoc signed: runs here
#   SEARCH_DEV=1 ./build.sh    the same as a dev build: yellow icon, named for
#                              the branch (Search-split-view from
#                              claude/split-view-4a6927)
#   SEARCH_DEV=1 SEARCH_FEATURE=name ./build.sh
#                              the same, named Search-name
#   ./build.sh release dmg     + build/Search.dmg, signed with Developer ID
#                                if there is one in the keychain
#   ./build.sh release ship    + both notarised, the DMG stapled
#
#   SEARCH_ARCH=x86_64 ./build.sh release ship
#                              the same for Intel Macs, into build/intel/
#
# Same shape as the one next door: SwiftPM builds the executable, and a macOS
# app bundle is just a folder with a plist and the binary in the right place.
#
# Two builds, each for one kind of Mac: Apple Silicon, in build/, and Intel,
# in build/intel/. A single universal app would have weighed twice as much
# for everyone (10.9 MB of binary instead of 5.4). SEARCH_ARCH picks the
# chip; without it, the Mac's own.
#
# "dmg" lays the disk image's window out with dmgbuild, installed into .build
# on first use (Python 3 and a network, once).
#
# What "ship" needs, once:
#   - a Developer ID Application certificate in the login keychain
#     (SEARCH_SIGN_IDENTITY names it; otherwise the first one found is used)
#   - a notarytool profile: xcrun notarytool store-credentials "search"
#     (SEARCH_NOTARY_PROFILE names it; default "search")
#
# NOTES.md, next to this script, is what's new: newest release first, one
# paragraph each; the app shows it under What's New.
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"
STEP="${2:-app}"
ARCH="${SEARCH_ARCH:-$(uname -m)}"
case "$ARCH" in
  arm64) OUT="build"; SUBFOLDER="" ;;
  x86_64) OUT="build/intel"; SUBFOLDER="/intel" ;;
  *) echo "SEARCH_ARCH is arm64 or x86_64, not “$ARCH”" >&2; exit 1 ;;
esac
APP="$OUT/Search.app"
NAME="Search"
# Asked for with SEARCH_DEV=1, a dev build, on a yellow plate and named for
# the feature it's built from: "Search-split-view" in the menu bar, the Dock
# and ⌘Tab, so it's never taken for the installed app beside it, or for the
# dev build from another worktree. Only the name people see changes. The
# bundle id stays, so it shares the real app's settings, and so does the
# folder, build/Search.app, which fresh.sh and the tests open. Not by
# default: a plain ./build.sh is also the Search people here use every day
# and the release candidates. What goes in a DMG or a ZIP is never one.
case "${SEARCH_DEV:-}" in
  0|1) DEV="$SEARCH_DEV" ;;
  "") DEV=0 ;;
  *) echo "SEARCH_DEV is 0 or 1, not “$SEARCH_DEV”" >&2; exit 1 ;;
esac
[ "$STEP" != "app" ] && [ "$DEV" = 1 ] && { echo "a dev build doesn't go in a DMG" >&2; exit 1; }
SHOWN="$NAME"
if [ "$DEV" = 1 ]; then
  # The feature: SEARCH_FEATURE, or the branch's last part, without the
  # six-character hash a worktree's name ends in (claude/split-view-4a6927
  # is split-view). A hash has a digit in it; a word like "decade" doesn't.
  FEATURE="${SEARCH_FEATURE:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)}"
  FEATURE="${FEATURE##*/}"
  if [[ "$FEATURE" =~ ^(.+)-([0-9a-f]{6})$ ]]; then
    STEM="${BASH_REMATCH[1]}" HASH="${BASH_REMATCH[2]}"
    [[ "$HASH" =~ [0-9] ]] && FEATURE="$STEM"
  fi
  # Only what's safe in a name and in InfoPlist.strings.
  FEATURE="$(printf '%s' "$FEATURE" | tr -cd 'A-Za-z0-9._-')"
  case "$FEATURE" in
    ""|HEAD) SHOWN="$NAME Dev" ;;   # no branch to name it for
    *) SHOWN="$NAME-$FEATURE" ;;
  esac
fi
VERSION="$(tr -d '[:space:]' < VERSION)"
# A build number that only ever goes up, so the updater can tell newer from
# older without parsing version strings.
BUILD="$(date +%Y%m%d%H%M)"
# The oldest macOS this runs on — in the plist, and in the appcast so an
# older Mac is not handed a build it can't open.
MINIMUM="14.0"

# -Osize for a release: 14% less binary (5.39 → 4.65 MB) at the same speed —
# launch 337 against 338 ms, a scroll frame 0.26 against 0.25 ms, a key typed
# 0.41 ms either way, measured interleaved on 1.0.4 (27 Sep 2026).
SWIFTFLAGS=(-c "$CONFIG" --arch "$ARCH")
[ "$CONFIG" = "release" ] && SWIFTFLAGS+=(-Xswiftc -Osize)
swift build "${SWIFTFLAGS[@]}"
BINARY="$(swift build "${SWIFTFLAGS[@]}" --show-bin-path)/Search"
[ "$(lipo -archs "$BINARY")" = "$ARCH" ] || { echo "$BINARY is not a $ARCH binary" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$NAME"
# The binary says which SDK it was built with, and AppKit draws the app the
# way that SDK's macOS drew it: built with the macOS 27 SDK, a Mac on 27 gets
# 27's window buttons and controls; said to be built with an older one, it
# gets that one's. Swift Build, SwiftPM's default since Xcode 27, writes the
# oldest macOS the app runs on in both places (minos 14.0, sdk 14.0 — the
# native build system wrote sdk 27.0 from the same sources), and the app came
# out in macOS 14's looks on every Mac. The SDK it really was built with is
# put back; the oldest macOS stays as it is.
SDK="$(xcrun --sdk macosx --show-sdk-version)"
vtool -set-build-version macos "$MINIMUM" "$SDK" -replace \
  -output "$APP/Contents/MacOS/$NAME.sdk" "$APP/Contents/MacOS/$NAME"
mv "$APP/Contents/MacOS/$NAME.sdk" "$APP/Contents/MacOS/$NAME"
# The AppleScript dictionary (Scripting.swift): read-only, tabs' addresses
# and titles. The plist below points to it.
cp Search.sdef "$APP/Contents/Resources/"

# Symbols stay out of the app. The linker leaves every function's name and a
# map back to the source in the binary — 15,000 entries, more than half of
# what the app weighed (6.5 MB of binary, 2.7 without them), and nothing the
# app reads while it runs. They are kept beside the build instead, as a dSYM
# that turns the addresses in a crash report back into names (Console, or
# atos -o build/Search.app.dSYM/Contents/Resources/DWARF/Search).
if [ "$CONFIG" = "release" ]; then
  rm -rf "$APP.dSYM"
  dsymutil "$BINARY" -o "$APP.dSYM" 2>/dev/null || echo "no dSYM this time" >&2
  strip -x "$APP/Contents/MacOS/$NAME"
fi

# The icon, drawn fresh each time — it is thirty lines of Swift, not an asset
# to keep in step with anything.
ICONSET="build/AppIcon.iconset"
ICONDOC="build/AppIcon.icon"
rm -rf "$ICONSET" "$ICONDOC"
SEARCH_DEV="$DEV" swift Icon/icon.swift "$ICONSET" "$ICONDOC" > /dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
# macOS 26's Dark, Clear and Tinted Dock styles read the icon from an asset
# catalog compiled from the Icon Composer document; without one the Dock
# darkens the flat image and the mark goes black on black (#337). actool
# comes with Xcode 26 — with anything older, or only the command-line tools,
# the app keeps the .icns alone, as before. Only Assets.car is kept, not
# actool's own .icns: the one above goes on being the disk image's icon and
# the fallback. (macOS 14 and 15 show the flat pictures actool puts in
# Assets.car, drawn from the same document: the same mark, to within a
# pixel, on a plate with Apple's own corners.) --optimization space keeps
# those pictures zipped rather than lzfse'd: 666 KB of catalog instead of
# 800, every style still in it.
ICONNAME=""
ICONCAR="build/AppIcon.car"
rm -rf "$ICONCAR"
mkdir -p "$ICONCAR"
# Full paths: actool hands the document to a helper that runs elsewhere, and
# with "build/…" it finds nothing ("Icon export exited with status 255").
if xcrun actool "$PWD/$ICONDOC" --compile "$PWD/$ICONCAR" --platform macosx \
     --minimum-deployment-target "$MINIMUM" --app-icon AppIcon --optimization space \
     --output-partial-info-plist "$PWD/$ICONCAR/partial.plist" > /dev/null 2>&1 \
   && [ -f "$ICONCAR/Assets.car" ]; then
  cp "$ICONCAR/Assets.car" "$APP/Contents/Resources/Assets.car"
  ICONNAME="<key>CFBundleIconName</key><string>AppIcon</string>"
else
  echo "note: actool from Xcode 26 didn't compile the icon — no Dark or Tinted style this time" >&2
fi
rm -rf "$ICONCAR" "$ICONDOC"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>com.officecommun.search</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  $ICONNAME
  <key>LSMinimumSystemVersion</key><string>$MINIMUM</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>© Office Commun · Search</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleScriptEnabled</key><true/>
  <key>OSAScriptingDefinition</key><string>Search.sdef</string>
  <!-- Handoff of web pages (Handoff.swift): a page picked up from another
       device opens here when Search is the default browser. -->
  <key>NSUserActivityTypes</key>
  <array><string>NSUserActivityTypeBrowsingWeb</string></array>
  <!-- Owning http and https is what sends a link clicked in Mail here.
       Appearing in Desktop & Dock → Default web browser also needs the
       XHTML document type below. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web address</string>
      <key>CFBundleURLSchemes</key>
      <array><string>http</string><string>https</string></array>
    </dict>
    <!-- mailto, so Search can be the Mac's email app: an email link then
         opens the webmail chosen in Settings › General › Email links open
         in (Webmail.swift). Only ever made the default from that page's
         button; with no webmail chosen, a link that comes anyway goes on to
         the next mail app. -->
    <dict>
      <key>CFBundleURLName</key><string>Email address</string>
      <key>CFBundleURLSchemes</key>
      <array><string>mailto</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Web page</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>public.html</string><string>com.apple.web-internet-location</string></array>
    </dict>
    <!-- macOS only lists an app under Desktop & Dock → Default web browser
         when it claims public.xhtml as well as public.html. http and https
         alone, which Search already had, are not enough. -->
    <dict>
      <key>CFBundleTypeName</key><string>XHTML page</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>public.xhtml</string></array>
    </dict>
    <!-- What a browser shows besides pages, listed under the Finder's Open
         With (#524): a PDF, a picture, plain text (code and logs conform to
         it), JSON. Alternate, so Search is offered there and never becomes
         what opens them on a double-click. Pictures by name rather than
         public.image, which takes in SVG: an SVG can carry a script, and
         opened from the Finder it would run with its folder to read. -->
    <dict>
      <key>CFBundleTypeName</key><string>Document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>com.adobe.pdf</string><string>public.png</string><string>public.jpeg</string><string>com.compuserve.gif</string><string>public.heic</string><string>org.webmproject.webp</string><string>public.tiff</string><string>public.plain-text</string><string>public.json</string></array>
    </dict>
  </array>
  <!-- A browser goes wherever it is pointed, including at http sites and at
       whatever is running on localhost. -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <!-- Since macOS 15, reaching a device on the local network (a .local
       name, a router's or a printer's address) needs the user's yes, and
       an app without this sentence is refused without being asked (#1348).
       No NSBonjourServices: a page at printer.local is looked up by name,
       not browsed for, and that list is only for browsing. Chrome lists
       one, _googlecast._tcp, for casting; Safari, part of macOS, needs none. -->
  <key>NSLocalNetworkUsageDescription</key>
  <string>Search uses the local network to open pages on devices and servers in your home or office, such as .local addresses.</string>
  <!-- A browser is asked for these by the pages it shows, not by itself. macOS
       still wants a sentence to put in its own prompt, and touching the APIs
       without one is a crash rather than a refusal. -->
  <key>NSCameraUsageDescription</key>
  <string>Websites you visit can ask to use your camera. Search asks you the first time each site does and keeps your answer; Settings › Privacy forgets them.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Websites you visit can ask to use your microphone. Search asks you the first time each site does and keeps your answer; Settings › Privacy forgets them.</string>
  <!-- Location: the first key is the one macOS has always read; the second
       is the one CoreLocation's requestWhenInUseAuthorization documents.
       Same sentence in both. -->
  <key>NSLocationUsageDescription</key>
  <string>Websites you visit can ask for your location. Search asks you each time a site does, unless you choose Always allow for it; Settings › Privacy forgets those choices.</string>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>Websites you visit can ask for your location. Search asks you each time a site does, unless you choose Always allow for it; Settings › Privacy forgets those choices.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Files you download are saved to your Downloads folder.</string>
  <!-- Only once you turn on Settings › Passwords › Fill in your contact
       details: your own card, never anyone else's (MeCard.swift). -->
  <key>NSContactsUsageDescription</key>
  <string>Search fills in forms with the details on your own card in Contacts, once you pick them under a box. It reads no one else's card and saves no copy of yours.</string>
</dict>
</plist>
PLIST
# A dev build's name, as a localised one: under the icon in the Dock, in
# ⌘Tab and in Finder, macOS shows the bundle's folder name otherwise. The
# plain names above stay "Search", matching the folder, since a folder named
# otherwise reads to macOS as renamed by hand, and then the folder wins.
if [ "$DEV" = 1 ]; then
  mkdir -p "$APP/Contents/Resources/en.lproj"
  printf '"CFBundleDisplayName" = "%s";\n"CFBundleName" = "%s";\n' "$SHOWN" "$SHOWN" \
    > "$APP/Contents/Resources/en.lproj/InfoPlist.strings"
  /usr/libexec/PlistBuddy -c "Add :LSHasLocalizedDisplayName bool true" "$APP/Contents/Info.plist"
fi

# Signing. A Developer ID certificate, when there is one, with the hardened
# runtime Gatekeeper insists on for anything notarised; otherwise ad-hoc,
# which is enough for the app to run on the machine that built it — and
# which the updater refuses to swap anything in under.
IDENTITY="${SEARCH_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"
# Passkeys need an entitlement Apple grants to browsers on request, and a
# Developer ID provisioning profile that carries it. With the profile next to
# this script, both go in; without it, the app is signed as before, because
# a restricted entitlement with no profile behind it is an app that won't open.
ENTITLEMENTS="Search.entitlements"
# A release that ships without it loses passkeys and the keychain items the
# entitled builds saved (1.0.6, build 202610241534, went out that way from a
# worktree the git-ignored profile hadn't been copied into): ship refuses.
if [ "$STEP" = "ship" ] && [ ! -f "Search.provisionprofile" ] && [ -z "${SEARCH_ALLOW_NO_PASSKEYS:-}" ]; then
  echo "ship: Search.provisionprofile is missing here (it's git-ignored: copy it from the main checkout)" >&2
  exit 1
fi
if [ -f "Search.provisionprofile" ]; then
  cp "Search.provisionprofile" "$APP/Contents/embedded.provisionprofile"
  ENTITLEMENTS="Search.passkeys.entitlements"
  echo "passkeys: profile embedded"
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"
  echo "signed as: $IDENTITY"
else
  # A build that cannot sign at all is not a build: `|| true` here let one
  # through as though it had finished, leaving a bundle that would not open.
  # set -e stops it now, with codesign's own words above.
  codesign --force --deep --sign - "$APP"
  [ "$STEP" != "app" ] && echo "no Developer ID certificate found — the DMG will only open on this Mac" >&2
fi

echo "built: $APP as $SHOWN ($VERSION, $ARCH, build $BUILD)"
[ "$STEP" = "app" ] && exit 0

# The disk image: the app beside a shortcut to Applications, on a white
# window with an arrow between them — drawn by Installer/background.swift and
# laid out by Installer/dmg.py through dmgbuild, which writes the Finder's
# layout file itself, so no Finder is scripted and no window opens mid-build.
# dmgbuild is installed into .build the first time, and needs Python 3 and a
# network then; without it the image is the plain one it always was.
DMG="$OUT/$NAME.dmg"
ART="build/installer"
rm -rf "$ART" "$DMG"
DMGBUILD=".build/dmgbuild/bin/dmgbuild"
if [ ! -x "$DMGBUILD" ]; then
  { python3 -m venv .build/dmgbuild && .build/dmgbuild/bin/pip install --quiet "dmgbuild==1.6.7"; } >/dev/null 2>&1 || true
fi
if [ -x "$DMGBUILD" ] \
  && swift Installer/background.swift "$ART" >/dev/null \
  && tiffutil -cathidpicheck "$ART/background.png" "$ART/background@2x.png" -out "$ART/background.tiff" >/dev/null 2>&1
then
  "$DMGBUILD" -s Installer/dmg.py \
    -D app="$APP" -D background="$ART/background.tiff" -D icon="$APP/Contents/Resources/AppIcon.icns" \
    "$NAME" "$DMG" >/dev/null
else
  echo "note: no dmgbuild — a plain disk image, without its window laid out" >&2
  STAGE="build/dmg"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
  rm -rf "$STAGE"
fi
rm -rf "$ART"
[ -n "$IDENTITY" ] && codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "packed: $DMG"

if [ "$STEP" = "dmg" ]; then exit 0; fi

# Notarisation: Apple looks the image over. The ticket is stapled to it, so
# it opens on a Mac that has never seen this app and is offline.
[ -z "$IDENTITY" ] && { echo "can't ship without a Developer ID certificate" >&2; exit 1; }
xcrun notarytool submit "$DMG" --keychain-profile "${SEARCH_NOTARY_PROFILE:-search}" --wait
xcrun stapler staple "$DMG"
echo "shipped: $DMG"
