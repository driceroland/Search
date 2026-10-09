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
isolation, late subscribers, and old-worker versus newly waking-port lifetime binding.

## Live WebKit fixture

After building, run `python3 Tests/ExtensionWorkerRecovery/live.py` on macOS
15.4 or newer. On Intel, copy `build/intel/Search.app` to `build/Search.app`
first, as the existing hidden bench harness expects. It creates and removes
its own disposable profile and serves only the local fixture. The suite has
an eight-minute deadline plus bounded cleanup. It prints environment/version,
per-port counts, PASS/FAIL and explicit NOT COVERED entries.

It exercises healthy wake, a bounded real worker event-loop stall, two explicit
native revives separated by the unchanged 60-second cooldown, refusal during
cooldown, fresh echoes and a 160-second silent-port idle/wake window. The
worker's per-start nonce establishes whether WebKit really replaced it within
the same context. If it did not, that branch is reported as not covered.
`--admission-only` runs just local extension admission and initial echoes for
baseline comparisons. `--direct-launch` is an explicit diagnostic route using
the exact built executable, unchanged signature/entitlements and the same probe
profile/window isolation; it records stdout, stderr and the actual child exit
status. `--lldb-launch --admission-only` instead launches that executable under
LLDB (never attaches) to capture the owned process's native admission stack.
The diagnostic leaves ASLR enabled, bounds stacks to 32 threads / 48 frames,
and reports debugger permission failures as BLOCKED without changing permissions.
The default continues to use the existing `open` launcher. OS crash reports and
symbolication are restricted to the captured test process.

Application-level withheld replies do not claim dead-worker detection, and the
brief stall is not proof of slow initial startup. Cross-origin child frames,
truly hung workers and failed-start wake recovery still require separate checks.

For manual inspection: Use a disposable
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
   Exercise `background.wake` recovery independently; a healthy no-op wake and a
   cooldown-refused revive must not generate a synthetic disconnect.
5. Pause startup briefly (below the existing worker-check deadline), open ports,
   then resume. Record no synthetic disconnect while startup is merely slow.
   Also check a content script in a cross-origin child frame and an extension
   page framed in a website. Record macOS/WebKit version, final commit and counts.

Steps 4–5 require an actual WebKit lifecycle fault and inspection, not the
application-reply toggle in step 3. Do not report them as passed from the mock
suite or from a normal Release build.

## Native notification route

Swift advances the installed-shim context generation when a successfully unloaded
`WKWebExtensionContext` will be replaced. All teardown paths complete old observers, including wake/revive,
manual reload, disable and removal. Rejected unload, healthy wake and the
revive cooldown do not advance it. Automatic recovery unloads and loads the
same context instance, following WebKit's own reload implementation: existing
API objects keep their internal context identifier. Those retirements use the
unchanged context generation, so newly loaded pages using cached prepared shim
resources do not mistake an earlier recovery for their own. Retained privileged
page APIs and event registrations still require live verification. Native host
and socket ports belonging to that extension are explicitly cleaned up, because
keeping the context alive cannot rely on its deallocation to end them.

A worker replaced inside the same context
uses a separate native background-view lifetime. Each port has one passive
subscription bound to that lifetime, with no health request, timeout or periodic
traffic. A new connection that wakes a background is bound to the new lifetime;
only ports bound to the retired background receive its notification. An incoming
port is observed once even when several extension listeners receive it.

Own extension pages use the existing native
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
cross-process delivery is checked by the live fixture, not inferred from source.

The same-context path adds two private WebKit interfaces:
`_webExtensionController:didCreateBackgroundWebView:forExtensionContext:` and
the read-only `_backgroundWebView` getter. Both exist in the
[March 2025 source](https://github.com/WebKit/WebKit/blob/8b6bee932bfd57c53cbe234e87cb820d8328cff5/Source/WebKit/UIProcess/Extensions/Cocoa/WebExtensionContextCocoa.mm#L3636-L3644)
and current WebKit. The getter is guarded with `responds(to:)`; the callback
is optional to WebKit. These are new dependencies for this recovery path,
although Search already uses guarded private getters and delegate callbacks in
ExtensionPopup, ExtensionCapture, Inspector and Tab. The callback occurs before
worker script loading. Views and contexts are held weakly; no delegate, system
setting or extension permission is changed.

This is a compatibility dependency, not a public API guarantee. If unavailable,
same-context wake notification degrades rather than guessing a restart; confirmed
whole-context teardown still works. Observation is sent after runtime.connect
selects its native backend, relying on WebKit's IPC ordering. A process crash
between those operations is a separate lifecycle interleaving that requires
additional live coverage.

Observers cancel when their port closes, is collected, or its document leaves.
BFCache keeps subscriptions. Replacing, disabling or removing the extension
removes its isolated bridge from tracked controllers; future tabs do not inherit
an inactive extension's handler. Failed loading rolls back a newly added bridge
without replacing a prior live registration. Automatic same-context recovery retains
it unless reloading fails with no loaded context. Stale registrations cannot cancel
subscriptions belonging to a replacement.
Abrupt process death without pagehide can retain a
pending native reply until that extension is next unloaded; no timer is added
to probe for that condition.
