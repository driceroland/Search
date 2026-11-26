#!/usr/bin/env python3
"""A page handed off from an iPhone keeps the window's tabs (ideas 1247, 1173).

`python3 Tests/handoff_scene.py` (no build of Search needed).

SwiftUI's own app delegate, given a Handoff activity (or a file to open),
routes it to a scene first: for Search's `Window` scene it closed the open
window and opened it again (AppWindowsController.activateWindowForExternalEvent),
before Links.application(_:continue:) was even called. Search took that close
for yours (Browsers.closing): with another window open, every tab of the
window went; alone, the window left full screen. `.handlesExternalEvents(matching: [])`
on the scene keeps SwiftUI out of it.

The real app can't be driven this way headless: SwiftUI brings the window
forward for the event. So a tiny SwiftUI app with the same scene is built
here, twice — as Search's was, and as it is — and handed the same events
through SwiftUI's delegate. Every window it makes is transparent from birth
and it may never be the active app: nothing reaches the screen. The script
also checks that App.swift's scene still carries the modifier.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

APP = r'''
import SwiftUI
import AppKit
import ObjectiveC

// Every window transparent from birth, whatever it is told later.
func invisible() {
    typealias SetAlpha = @convention(c) (NSWindow, Selector, CGFloat) -> Void
    let alpha = #selector(setter: NSWindow.alphaValue)
    let m = class_getInstanceMethod(NSWindow.self, alpha)!
    let real = unsafeBitCast(method_getImplementation(m), to: SetAlpha.self)
    let none: @convention(block) (NSWindow, CGFloat) -> Void = { w, _ in real(w, alpha, 0) }
    method_setImplementation(m, imp_implementationWithBlock(none))
    let initSel = #selector(NSWindow.init(contentRect:styleMask:backing:defer:))
    let i = class_getInstanceMethod(NSWindow.self, initSel)!
    typealias Init = @convention(c) (NSWindow, Selector, NSRect, UInt, UInt, Bool) -> NSWindow
    let realInit = unsafeBitCast(method_getImplementation(i), to: Init.self)
    let born: @convention(block) (NSWindow, NSRect, UInt, UInt, Bool) -> NSWindow = { w, r, s, b, d in
        let made = realInit(w, initSel, r, s, b, d)
        real(made, alpha, 0)
        return made
    }
    method_setImplementation(i, imp_implementationWithBlock(born))
}

func say(_ s: String) { print(s); fflush(stdout) }

/// Any window of this process the window server shows with some alpha.
func shown() -> Int {
    let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter {
        ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && (($0[kCGWindowAlpha as String] as? Double) ?? 0) > 0
    }.count
}

final class Delegate: NSObject, NSApplicationDelegate {
    var other: NSWindow?
    var closes = 0
    func applicationDidFinishLaunching(_ n: Notification) {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            self.closes += 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            // A second window, as Search's other windows are: AppKit's own.
            let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 300, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = NSView()
            w.orderBack(nil)
            self.other = w
            let d = NSApp.delegate!
            let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
            activity.webpageURL = URL(string: "https://example.com/handed")
            let taken = d.application?(NSApp, continue: activity, restorationHandler: { _ in }) ?? false
            say("continue closes=\(self.closes) taken=\(taken)")
            self.closes = 0
            d.application?(NSApp, open: [URL(fileURLWithPath: "/tmp/page.html")])
            say("open closes=\(self.closes)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                say("shown=\(shown())")
                exit(0)
            }
        }
    }
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        say("delegate continue \(userActivity.webpageURL?.absoluteString ?? "")")
        return true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        say("delegate open \(urls.count)")
    }
}

@main
struct ProbeApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    init() {
        invisible()
        NSApplication.shared.setActivationPolicy(.prohibited)
    }
    var body: some Scene {
        #if FIXED
        Window("Probe", id: "probe") { Color.clear }
            .windowStyle(.hiddenTitleBar)
            .handlesExternalEvents(matching: [])
        #else
        Window("Probe", id: "probe") { Color.clear }
            .windowStyle(.hiddenTitleBar)
        #endif
    }
}
'''

failures = 0
def ok(name, cond, detail=""):
    global failures
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"  {detail}"))
    if not cond: failures += 1

def run(fixed, folder):
    src = folder / "main.swift"
    src.write_text(APP)
    exe = folder / ("fixed" if fixed else "before")
    flags = ["-DFIXED"] if fixed else []
    subprocess.run(["swiftc", "-parse-as-library", *flags, str(src), "-o", str(exe)], check=True)
    out = subprocess.run([str(exe)], capture_output=True, text=True, timeout=30).stdout
    got = dict(re.findall(r"^(continue|open) closes=(\d+)", out, re.M))
    return out, {k: int(v) for k, v in got.items()}

app = (ROOT / "Sources/Search/App.swift").read_text()
scene = app[app.index('Window("Search", id: Browsers.sceneID)'):app.index(".commands {")]
ok("Search's scene keeps SwiftUI out of external events", ".handlesExternalEvents(matching: [])" in scene)

with tempfile.TemporaryDirectory(prefix="handoff-scene-") as tmp:
    folder = Path(tmp)
    out, before = run(False, folder)
    ok("as before: SwiftUI closed the window for a Handoff page (the bug)", before.get("continue", 0) >= 1, out)
    ok("as before: and for a file opened", before.get("open", 0) >= 1, out)
    ok("nothing on screen (before)", "shown=0" in out, out)
    out, after = run(True, folder)
    ok("now: no window closed for a Handoff page", after.get("continue") == 0, out)
    ok("now: none for a file opened", after.get("open") == 0, out)
    ok("now: Links still takes the page", "delegate continue https://example.com/handed" in out and "taken=true" in out, out)
    ok("now: and the file", "delegate open 1" in out, out)
    ok("nothing on screen (now)", "shown=0" in out, out)

print("PASS" if not failures else f"{failures} FAILED")
sys.exit(1 if failures else 0)
