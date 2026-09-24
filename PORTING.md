# Porting: Linux first, then Windows

Search is made of three things: the Mac's WebKit, SwiftUI and AppKit for the
window around it, and a few macOS services (the keychain, passkeys, the
share sheet, code signing). Only the first has an equivalent on other
systems. This is the plan for carrying the browser over anyway, in the order
it can actually be done. The discussion is on
[#62](https://github.com/driceroland/Search/issues/62).

## What carries over, and what doesn't

About 25,000 lines of Swift. 27 files import SwiftUI and 19 import AppKit:
everything drawn has to be drawn again. What does not have to be written
again:

- **The models**: history, the session, bookmarks, settings, what an address
  is (`Address.swift`), the search engines (`Engine.swift`).
- **Every script put into pages**: reading mode, hidden elements, forms,
  the floating video, icons, the store relay. It is JavaScript, and WebKit
  runs the same JavaScript on every system.
- **The ad blocker's rules.** WebKitGTK compiles the very same content
  blocker JSON (`WebKitUserContentFilterStore`), and the Windows port has
  the same compiler behind its C API.
- **The CRX check and the bench protocol**, both plain Foundation.

WebKitGTK also has public API for several things the Mac version reaches
through private names: the inspector, muting a page, whether it is playing
audio.

Not coming over, and worth saying up front:

| | Why |
|---|---|
| Chrome extensions (about 6,000 lines) | `WKWebExtension` exists only on Apple's platforms |
| Passkeys | No platform authenticator on Linux; no WebAuthn in WebKit's Windows port |
| Share sheet, 120 Hz pages, traffic lights | Mac-only to begin with |
| DRM video (Netflix and the like) | No Widevine in WebKitGTK or the Windows port |
| A floating video above other apps, on Wayland | GTK 4 has no "keep above"; X11 and Windows are fine |

## Shape

- **Swift stays.** Toolchains for Linux and Windows are official, the models
  and the scripts move unchanged, and GTK and WebKit are C libraries Swift
  calls directly: no binding packages, no second language.
- **Three parts:** `SearchCore` (nothing platform-specific), the Mac app as
  it is now, and a GTK shell for Linux (and Windows, if the spike below
  says so).
- **One seam, `WebPage`**: what the window actually asks of a page — load,
  back and forward, title, address and progress, run a script, user scripts
  and styles, messages with replies, content rules, find, zoom, a snapshot,
  downloads, dialogs and permissions, the connection's certificate, mute,
  the inspector, ending the web process. Three backends: `WKWebView`,
  WebKitGTK 6.0, and WebKit's C API on Windows.

## Phase 0 — groundwork (1–2 weeks)

1. Agree with the maintainer where the port lives: in this repository, or
   beside it. Until then the Linux shell is a target of its own that
   touches none of the Mac's files; the two files it shares are linked,
   not moved.
2. Split out `SearchCore` without changing the Mac app, with CI building
   the Mac app and the core on Linux.
3. Replace the Apple-only pieces in the core: CryptoKit → swift-crypto,
   Combine → Observation, SQLite through a module map, `~/Library` →
   XDG folders on Linux and `%APPDATA%` on Windows.

## Phase 1 — Linux (about 10–14 weeks)

- **1a. Spike.** A GTK 4 window with a WebKitGTK view, from Swift.
  The risk to retire: Swift's main queue has to be drained from GLib's main
  loop, and GObject signals have to reach Swift closures. *Done in this
  branch, see below.*
- **1b. The browser.** The window with its own controls; tabs across the
  top or down the side; the field; tabs made lazily and put to sleep;
  the session, history, bookmarks, settings, downloads, find, zoom;
  alert/confirm/prompt and file choosers (through the desktop portal);
  light and dark; ⌘ as Ctrl, in Linux's conventions; the ad blocker,
  hidden elements, reading mode; private tabs as an ephemeral network
  session, and Spaces as a network session each.
- **1c. The rest.** Passwords in libsecret, filling forms, importing
  from Chrome, Chromium and Brave on Linux; the floating video, the status
  line, the site card with the certificate; the inspector, autoscroll,
  touchpad gestures, the bench socket, icons.
- **1d. Shipping.** Flatpak on Flathub first. The GNOME runtime carries
  WebKitGTK, so the engine's security fixes arrive with the runtime, not
  with us. The self-updater stays off on Linux. Default browser through the
  `.desktop` file.

## Phase 2 — Windows, with WebKit bundled (about 10–16 weeks, and after)

- **2a. Go or no go (2 weeks).** Build WebKit's Windows port from a pinned
  trunk revision in CI (clang-cl, VS 2022, cached). Try YouTube, a Google
  sign-in, Docs, Figma, Twitch; measure size on disk and memory. Try content
  rules, user scripts, message replies and downloads through the C API, and
  embedding WebKit's window inside a GTK 4 window. Stop here if video or
  embedding doesn't hold up.
- **2b. The window.** The GTK shell again if it embeds, a Win32 one if
  not. WebKit's view is a window of its own on Windows, so everything that
  floats over the page — the field, find, accounts, the site card, the
  column sliding out, the swipe disc — has to become a popup of its own.
- **2c. Services.** Credential Manager, with Windows Hello before a
  password is shown; default browser through the registry; the bench over
  AF_UNIX (Windows 10 1803 and later). Importing passwords from Chrome is
  mostly closed since Chrome 127's app-bound encryption; bookmarks and
  history still come.
- **2d. Shipping.** An installer, Authenticode signing, the updater checking
  Authenticode instead of the Developer ID. And a standing commitment: the
  Windows port has no stable branches, so **every WebKit security release is
  ours to rebuild and ship**. That, more than the code, is what Windows
  costs.

## Open questions

1. Swift, as above, or something else.
2. In this repository (a `SearchCore` split) or a port beside it.
3. On Windows, GTK or Win32 around the page — decided by the spike.

## Where this branch is

`swift build` on Linux builds `SearchLinux`, the phase 1a spike, from
`Sources/SearchLinux` against GTK 4 and WebKitGTK 6.0. On macOS nothing
changes: `Package.swift` only declares the Linux targets on Linux.

What it does: one window, a row of tabs across the top, pages in
WebKitGTK; the field (Ctrl+L) takes an address, or words for the search
engine, using the Mac's own `Address` and `Engine`; Ctrl+T, Ctrl+W,
Ctrl+Tab, Ctrl+1–9, Alt+←/→, Ctrl+R; tabs are built when first shown;
the session comes back at the next launch; the ad blocker's rules, compiled
by WebKitGTK.

On Ubuntu 24.04 and its relatives:

```
sudo apt install libwebkitgtk-6.0-dev libgtk-4-dev
swift build
.build/debug/SearchLinux
```
