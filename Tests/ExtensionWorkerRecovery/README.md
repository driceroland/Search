# Worker recovery regression

## Checks that can run without macOS

Run `node Tests/ExtensionWorkerRecovery/run.js`. It executes the **whole**
installed shim, including the real content-script early return. The tests use
mock WebKit objects; they are not a live extension recovery result.

To reproduce the missing notification on upstream main:

```
git show 35aa0516fc300031733bb843f334b47baff72232:Sources/Search/ExtensionShims.swift >/tmp/upstream-shim.swift
node Tests/ExtensionWorkerRecovery/run.js /tmp/upstream-shim.swift
```

The content-script case fails with disconnect count 0 instead of 1. The
existing `ExtensionPortTests` extracted a later block past the early return;
its simulated `inContent` condition does not establish real content coverage.

On macOS 15.4+, also run `swift test --filter ExtensionWorkerPortTests` and
`swift build -c release`. The Node suite covers both entry paths, native event
deduplication and lastError, explicit disconnect, fresh/reentrant connections,
second recovery, external extensions, missing bridge, delayed ping, rejected
subscriptions and generation fanout. Swift additionally checks native generation
isolation and late subscribers.

## Live test still required

This checkout has NOT been run as a live macOS extension. Use a disposable
Search test profile, not a signed-in extension or model service. No model calls
are involved. Build with the repository's `./build.sh` instructions.

1. Serve this directory with `python3 -m http.server 8765 --bind 127.0.0.1`.
   Load the `extension` directory as an unpacked extension in the test profile.
2. Open `http://127.0.0.1:8765/site.html` and the extension's `page.html` in a tab.
   Open a **second** copy of `page.html` for the independent recovery requester.
   Each starts one port and receives an echo. Record the html attribute
   `data-search-port-fixture` in the site and the log in the first extension tab.
3. The “Withhold application replies” button stops application-level replies.
   It does NOT disable the shim's ping and is not evidence of a dead worker.
   Click “Request native recovery” in the second extension tab. Record exactly
   one disconnect for each old port. Click “Fresh content connection” and
   “Connect”, then verify fresh echoes. Repeat after the native 60-second
   cooldown; the old callbacks must stay at one.
4. Separately exercise real failure detection with the worker stopped/unresponsive
   in Web Inspector, or a controlled native startup failure. Trigger the existing
   send/connect worker check and record which native path performed recovery.
   Exercise `background.wake` recovery independently; a successful wake and a
   cooldown-refused revive must not generate a synthetic disconnect.
5. Pause startup briefly (below the existing worker-check deadline), open ports,
   then resume. Record no synthetic disconnect while startup is merely slow.
   Also check a content script in a cross-origin child frame and an extension
   page framed in a website. Record macOS/WebKit version, final commit and counts.

Steps 4–5 require an actual WebKit lifecycle fault and inspection, not the
application-reply toggle in step 3. Do not report them as passed from the mock
suite or from a normal Release build.

## Native notification route

Swift advances one generation only after `WKWebExtensionController.unload`
succeeds. All teardown paths complete old observers, including wake/revive,
manual reload, disable and removal. Rejected unload, healthy wake and the
revive cooldown do not advance it. Own extension pages use the existing native
message bridge. Content scripts use a reply-only handler in their isolated
world; websites get no new main-world handler and the bridge can only observe
or cancel a notification, never request a restart or another native API.

WebKit has no public content-script broadcast API. Its shared world name
`WebExtension-<uniqueIdentifier>` is an implementation detail. It was checked
in [the March 2025 WebKit source](https://github.com/WebKit/WebKit/blob/8b6bee932bfd57c53cbe234e87cb820d8328cff5/Source/WebKit/UIProcess/Extensions/Cocoa/WebExtensionContextCocoa.mm#L348-L350)
and current WebKit; public `WKContentWorld.world(name:)` accesses that shared
world. If that layout changes, the shim fails closed to native port behavior
rather than synthesizing recovery. No promise is made about an untested WebKit
version. A pending native reply's source path survives unload, but actual
cross-process delivery still needs the live test above.

Observers cancel when the last port closes or the document leaves. BFCache
keeps the subscription. Abrupt process death without pagehide can retain a
pending native reply until that extension is next unloaded; no timer is added
to probe for that condition.
