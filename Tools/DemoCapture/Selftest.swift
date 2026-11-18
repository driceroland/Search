import AppKit
import ObjectiveC
import QuartzCore
import CoreImage
import ScreenCaptureKit

// `demo-capture selftest`: what ScreenCaptureKit gives for a window that
// nobody can see, tried on a window of this helper's own (never Search's,
// never anyone else's). Each placement is recorded for a moment and judged:
// did frames come, did what AppKit draws on the main thread move, did what
// Core Animation animates move, are the traffic lights in colour. Nothing is
// ever put where a person would see it: a placement that turns out to be
// visible is taken away at once and reported as such.

/// The same two tricks Search's `stage` verb plays (Bench.swift): the window
/// left where it is put, off every screen, and drawn as a key window's.
enum StageTricks {
    nonisolated(unsafe) static weak var window: NSWindow?
    nonisolated(unsafe) static var active = false
    private nonisolated(unsafe) static var done: Set<String> = []

    static func install(on window: NSWindow) {
        self.window = window
        guard let cls = object_getClass(window) else { return }
        let key = NSStringFromClass(cls)
        guard !done.contains(key) else { return }
        done.insert(key)
        let constrain = NSSelectorFromString("constrainFrameRect:toScreen:")
        if let m = class_getInstanceMethod(cls, constrain) {
            typealias F = @convention(c) (AnyObject, Selector, NSRect, NSScreen?) -> NSRect
            let original = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (AnyObject, NSRect, NSScreen?) -> NSRect = { me, rect, screen in
                me === StageTricks.window ? rect : original(me, constrain, rect, screen)
            }
            replace(cls, constrain, m, imp_implementationWithBlock(block))
        }
        for name in ["_hasActiveAppearance", "_hasActiveAppearanceIgnoringKeyFocus", "hasKeyAppearance", "hasMainAppearance"] {
            let sel = NSSelectorFromString(name)
            guard let m = class_getInstanceMethod(cls, sel) else { continue }
            typealias F = @convention(c) (AnyObject, Selector) -> Bool
            let original = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (AnyObject) -> Bool = { me in
                (StageTricks.active && me === StageTricks.window) ? true : original(me, sel)
            }
            replace(cls, sel, m, imp_implementationWithBlock(block))
        }
    }

    /// macOS 26 lays a "this window is being shared" capsule over the
    /// traffic lights of a window ScreenCaptureKit records — a view of
    /// AppKit's in the window's own title bar. The demo hides it.
    @MainActor static func hideSharingBadge(in window: NSWindow) {
        func walk(_ view: NSView) {
            if NSStringFromClass(type(of: view)).contains("SharingSessionRecipientIndicator") {
                if !view.isHidden { view.isHidden = true }
                return
            }
            view.subviews.forEach(walk)
        }
        if let frame = window.contentView?.superview { walk(frame) }
    }

    private static func replace(_ cls: AnyClass, _ sel: Selector, _ m: Method, _ imp: IMP) {
        // An override on this class only, so other windows' classes keep theirs.
        if !class_addMethod(cls, sel, imp, method_getTypeEncoding(m)) {
            if let own = class_getInstanceMethod(cls, sel) { method_setImplementation(own, imp) }
        }
    }
}

@MainActor
final class Ticker: NSView {
    var n = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        // A colour that changes every frame AppKit draws on the main thread.
        let hue = CGFloat(n % 60) / 60
        NSColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
        bounds.fill()
    }
}

@MainActor
func runSelftest(only: String?, recordTo dir: String? = nil) async {
    print("Screen Recording allowed for this process: \(CGPreflightScreenCaptureAccess())")
    guard CGPreflightScreenCaptureAccess() else {
        print("""
        Not allowed. macOS asks for the permission for the app that started this helper
        (the terminal, or Claude). Allow it in System Settings › Privacy & Security ›
        Screen & System Audio Recording, then run again. Nothing was asked here.
        """)
        return
    }
    let screens = NSScreen.screens.map { NSStringFromRect($0.frame) }
    print("screens: \(screens)")
    var results: [[String: Any]] = []
    // Only placements nobody can see. Behind other windows, or below the
    // desktop picture, a window shows the moment what covers it moves; on
    // another Space it would have to be put there by hand (no public API).
    let placements = ["offscreen", "offscreen-active"].filter { only == nil || $0 == only! }
    for placement in placements {
        results.append(await trial(placement, recordTo: dir))
    }
    if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text) }
}

@MainActor
func trial(_ placement: String, recordTo dir: String? = nil) async -> [String: Any] {
    var out: [String: Any] = ["placement": placement]
    let size = NSSize(width: 480, height: 300)
    let main = NSScreen.screens.first?.frame ?? .zero
    _ = main
    let rect = NSRect(x: -30000, y: -30000, width: size.width, height: size.height)
    let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "demo-capture selftest"
    window.collectionBehavior = [.transient, .ignoresCycle]
    StageTricks.install(on: window)
    StageTricks.active = placement == "offscreen-active"
    let content = NSView(frame: NSRect(origin: .zero, size: size))
    content.wantsLayer = true
    content.layer?.backgroundColor = NSColor(white: 0.5, alpha: 1).cgColor
    let ticker = Ticker(frame: NSRect(x: 20, y: 20, width: 120, height: 120))
    content.addSubview(ticker)
    // Core Animation's own, run by the render server.
    let spinner = CALayer()
    spinner.frame = CGRect(x: 300, y: 60, width: 120, height: 120)
    spinner.backgroundColor = NSColor.systemBlue.cgColor
    content.layer?.addSublayer(spinner)
    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
    spin.fromValue = 0; spin.toValue = Double.pi * 2; spin.duration = 1; spin.repeatCount = .infinity
    spinner.add(spin, forKey: "spin")
    window.contentView = content
    let quiet = placement == "offscreen-active"
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
        MainActor.assumeIsolated {
            ticker.n += 1; ticker.needsDisplay = true
            if quiet { StageTricks.hideSharingBadge(in: window) }
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    defer { timer.invalidate(); window.orderOut(nil); StageTricks.window = nil }

    window.setFrame(rect, display: false)
    window.orderFront(nil)
    window.setFrame(rect, display: true)
    try? await Task.sleep(nanoseconds: 300_000_000)
    let onScreen = NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    out["frameAfterOrderIn"] = NSStringFromRect(window.frame)
    out["onAnyScreen"] = onScreen
    out["occlusionVisible"] = window.occlusionState.contains(.visible)
    out["backingScale"] = window.backingScaleFactor
    out["hasScreen"] = window.screen != nil
    if onScreen {
        out["error"] = "AppKit put the window back on a screen; taken away at once"
        return out
    }
    do {
        let sc = try await shareableWindow(CGWindowID(window.windowNumber))
        out["listedOnScreen"] = sc.isOnScreen
        let recorder = WindowRecorder(window: sc, scale: 2)
        let offset = hostToWall()
        if let dir { try recorder.record(to: URL(fileURLWithPath: "\(dir)/capture.mov"), codec: "hevc") }
        var tickerColours = Set<String>()
        var spinnerSamples = Set<String>()
        var light = ""
        var frameCount = 0
        let closeFrame = window.standardWindowButton(.closeButton).map { $0.convert($0.bounds, to: nil) } ?? .zero
        let wh = window.frame.height
        recorder.onFrame = { buffer, _ in
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
            let row = CVPixelBufferGetBytesPerRow(buffer)
            let pw = CVPixelBufferGetWidth(buffer), ph = CVPixelBufferGetHeight(buffer)
            let sx = Double(pw) / Double(window.frame.width), sy = Double(ph) / Double(wh)
            func px(_ x: Double, _ yTop: Double) -> String {
                let ix = min(pw - 1, max(0, Int(x * sx))), iy = min(ph - 1, max(0, Int(yTop * sy)))
                let p = base.advanced(by: iy * row + ix * 4).assumingMemoryBound(to: UInt8.self)
                return "\(p[2]),\(p[1]),\(p[0])"
            }
            // The content view is not flipped: its points count from the window's bottom.
            tickerColours.insert(px(80, wh - 80))
            spinnerSamples.insert(px(310, wh - 70))
            light = px(Double(closeFrame.midX), Double(wh - closeFrame.midY))
            frameCount += 1
            if let dump = ProcessInfo.processInfo.environment["DEMO_SELFTEST_DUMP"], frameCount % 20 == 1 {
                let image = CIImage(cvPixelBuffer: buffer)
                let rep = NSBitmapImageRep(ciImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dump)/\(placement)-\(frameCount).png"))
            }
        }
        try await recorder.start(fps: 60)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if ProcessInfo.processInfo.environment["DEMO_SELFTEST_TREE"] != nil, let frame = window.contentView?.superview {
            func walk(_ v: NSView, _ depth: Int) {
                let r = v.convert(v.bounds, to: nil)
                print(String(repeating: "  ", count: depth) + "\(type(of: v)) hidden=\(v.isHidden) alpha=\(v.alphaValue) \(NSStringFromRect(r))")
                for sub in v.subviews where depth < 6 { walk(sub, depth + 1) }
            }
            walk(frame, 0)
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(b) { print("button \(b.rawValue) hidden=\(button.isHidden) alpha=\(button.alphaValue) super=\(type(of: button.superview!))") }
            }
        }
        await recorder.stop()
        if let dir {
            let stamps: [String: Any] = ["hostToWall": offset, "stamps": recorder.stamps, "size": [Int(recorder.size.width), Int(recorder.size.height)]]
            try JSONSerialization.data(withJSONObject: stamps).write(to: URL(fileURLWithPath: "\(dir)/stamps.json"))
            out["written"] = recorder.stamps.count
            out["wallStart"] = (recorder.stamps.first ?? 0) + offset
        }
        out["completeFrames"] = recorder.complete
        out["idleFrames"] = recorder.idle
        out["size"] = [Int(recorder.size.width), Int(recorder.size.height)]
        out["mainThreadDrawingMoved"] = tickerColours.count > 1
        out["distinctTickerColours"] = tickerColours.count
        out["coreAnimationMoved"] = spinnerSamples.count > 1
        out["closeButtonRGB"] = light
        if let error = recorder.stopError { out["streamError"] = error }
    } catch {
        out["error"] = "\(error)"
    }
    return out
}
