import AppKit
import QuartzCore
import WebKit

/// ⌘S pressed over and over in a window that is drawn but never seen, and
/// each slide timed frame by frame (Bench "foldframes", idea 847).
///
/// A hidden probe draws nothing, so its browser window is first staged far
/// off every screen and ordered in there, kept out of the app's hiding, with
/// its pages told they aren't covered: Core Animation and WebKit then draw
/// it at the display's pace as they would on a screen, and nothing shows.
/// It stays staged until the probe quits, so it never comes back on screen.
///
/// For every press, until the column rests: each display frame (a display
/// link on the window), where the column stood at it, so the frames the
/// slide moved on and the gaps between them; each pass of the main run
/// loop and how long it ran; and the window's layers half way through,
/// with those that make the window server draw apart (masks, shadows,
/// filters, rounded clips) and those laid out beyond the window.
@MainActor
enum FoldFrames {
    /// The window's frame before it was staged, kept for nothing but a check.
    private static var staged: NSWindow?

    static func run(_ browser: Browser, _ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard NSApp.isHidden else { answer(["error": "foldframes needs a probe started hidden"]); return }
        guard let window = browser.window else { answer(["error": "no window"]); return }
        // "census": the window's layers and pages as they are now, nothing pressed.
        if request["census"] as? Bool == true { answer(census(window)); return }
        let times = min(40, max(1, request["times"] as? Int ?? 10))
        let span = request["span"] as? Double ?? 0.6
        let rest = request["rest"] as? Double ?? 0.35
        if let slides = request["slides"] as? Bool { browser.prefs.slidesColumn = slides }
        guard stage(window) else { answer(["error": "the window would have shown"]); return }
        // Half a second for WebKit and the column to draw where they now are.
        later(0.5) {
            var presses: [[String: Any]] = []
            @MainActor func press(_ n: Int) {
                guard n < times else {
                    answer(["presses": presses, "slides": browser.prefs.slidesColumn,
                            "hz": window.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 0,
                            "frame": [Int(window.frame.minX), Int(window.frame.minY), Int(window.frame.width), Int(window.frame.height)],
                            "atRest": census(window)])
                    return
                }
                once(browser, window, span: span, track: request["track"] as? Bool == true) { found in
                    presses.append(found)
                    later(rest) { press(n + 1) }
                }
            }
            press(0)
        }
    }

    /// The window far off every screen, ordered in although the app is
    /// hidden, its pages drawing as if seen.
    static func stage(_ window: NSWindow) -> Bool {
        guard staged !== window else { return true }
        func shows() -> Bool { NSScreen.screens.contains { $0.frame.intersects(window.frame) } }
        let far = NSRect(x: -20000, y: -22000, width: window.frame.width, height: window.frame.height)
        // Clear until it is known to be far off: ordering a titled window in
        // can pull it back onto a screen.
        window.alphaValue = 0
        window.canHide = false
        unconstrain(window)
        window.setFrame(far, display: false)
        window.orderBack(nil)
        if shows() { window.setFrame(far, display: false) }
        guard !shows() else {
            window.orderOut(nil)
            window.canHide = true
            return false
        }
        window.alphaValue = 1
        staged = window
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        func pages(_ view: NSView) -> [WKWebView] { ((view as? WKWebView).map { [$0] } ?? []) + view.subviews.flatMap(pages) }
        for web in window.contentView.map(pages) ?? [] where web.responds(to: occlusion) {
            unsafeBitCast(web.method(for: occlusion), to: Setter.self)(web, occlusion, false)
        }
        return true
    }

    /// AppKit keeps a titled window's title bar on some screen as it is
    /// ordered in or moved: for the staged window alone, it is left where
    /// it is put.
    private static var loose: NSWindow?
    private static func unconstrain(_ window: NSWindow) {
        loose = window
        let pick = #selector(NSWindow.constrainFrameRect(_:to:))
        guard let cls = object_getClass(window), let method = class_getInstanceMethod(cls, pick) else { return }
        typealias Constrain = @convention(c) (NSWindow, Selector, NSRect, NSScreen?) -> NSRect
        let original = unsafeBitCast(method_getImplementation(method), to: Constrain.self)
        let block: @convention(block) (NSWindow, NSRect, NSScreen?) -> NSRect = { this, rect, screen in
            this === loose ? rect : original(this, pick, rect, screen)
        }
        class_replaceMethod(cls, pick, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }

    private final class Ticker: NSObject {
        var ticks: [(at: CFTimeInterval, column: Double)] = []
        var column: () -> Double = { .nan }
        var look: () -> Void = {}
        /// With "track": where things stood at each frame (see `geometry`).
        var track: (() -> [String: Any])?
        var tracked: [[String: Any]] = []
        var started: CFTimeInterval = 0
        @objc func tick(_ link: CADisplayLink) {
            ticks.append((link.timestamp, column())); look()
            if var at = track?() {
                at["t"] = ((link.timestamp - started) * 10000).rounded() / 10
                tracked.append(at)
            }
        }
    }

    /// Each layer's model state, frame to frame: what the window server is
    /// handed again. Moved (position, bounds, opacity, hidden) and redrawn
    /// (new contents), counted per frame, with who redrew.
    private final class Layers {
        struct State: Equatable { var position: CGPoint; var bounds: CGRect; var opacity: Swift.Float; var hidden: Bool; var contents: UInt }
        var last: [ObjectIdentifier: State] = [:]
        var moved = 0, redrawn = 0, added = 0, maxMoved = 0
        var redrawers: [String: Int] = [:]
        func look(_ top: CALayer) {
            var now: [ObjectIdentifier: State] = [:]
            var movedHere = 0
            func walk(_ layer: CALayer) {
                let state = State(position: layer.position, bounds: layer.bounds, opacity: layer.opacity, hidden: layer.isHidden,
                                  contents: layer.contents.map { UInt(bitPattern: Unmanaged.passUnretained($0 as AnyObject).toOpaque()) } ?? 0)
                let id = ObjectIdentifier(layer)
                now[id] = state
                if let was = last[id] {
                    if was.position != state.position || was.bounds != state.bounds || was.opacity != state.opacity || was.hidden != state.hidden {
                        movedHere += 1
                    }
                    if was.contents != state.contents, state.contents != 0 {
                        redrawn += 1
                        var owner = "-"
                        var l: CALayer? = layer
                        while let at = l { if let d = at.delegate { owner = String(describing: type(of: d)); break }; l = at.superlayer }
                        redrawers["\(owner) \(Int(layer.bounds.width))x\(Int(layer.bounds.height))", default: 0] += 1
                    }
                } else if !last.isEmpty {
                    added += 1
                }
                for sub in layer.sublayers ?? [] { walk(sub) }
            }
            walk(top)
            moved += movedHere
            maxMoved = max(maxMoved, movedHere)
            last = now
        }
    }

    /// One ⌘S, timed for `span` seconds.
    private static func once(_ browser: Browser, _ window: NSWindow, span: Double, track: Bool = false,
                             _ done: @escaping @MainActor ([String: Any]) -> Void) {
        guard let root = window.contentView?.superview else { done([:]); return }
        func catches(in view: NSView) -> [NSView] {
            (String(describing: type(of: view)) == "Catch" ? [view] : []) + view.subviews.flatMap(catches)
        }
        // One row's catcher stands for the column: it moves with it.
        weak var marker = catches(in: root).first
        let ticker = Ticker()
        ticker.column = {
            if marker?.window == nil { marker = catches(in: root).first }
            guard let marker else { return .nan }
            return Double(marker.convert(marker.bounds, to: nil).minX)
        }
        let layers = Layers()
        var pageWidths: [Int] = []
        if let top = root.layer {
            ticker.look = {
                layers.look(top)
                if let w = browser.active?.built.map({ Int($0.frame.width) }), pageWidths.last != w { pageWidths.append(w) }
            }
        }
        var passes: [Double] = []
        var woke: CFAbsoluteTime = 0
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { _, _ in
            woke = CFAbsoluteTimeGetCurrent()
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            guard woke > 0 else { return }
            passes.append((CFAbsoluteTimeGetCurrent() - woke) * 1000)
            woke = 0
        }
        let observers = [wake, sleep].compactMap { $0 }
        for observer in observers { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
        let link = (NSScreen.main ?? NSScreen.screens[0]).displayLink(target: ticker, selector: #selector(Ticker.tick(_:)))
        link.add(to: .main, forMode: .common)
        let before = browser.folded
        let started = CACurrentMediaTime()
        ticker.started = started
        if track { ticker.track = { geometry(browser, window) } }
        let cpu0 = cpu()
        browser.toggleFold()
        var middle: [String: Any] = [:]
        later(0.1) { middle = census(window) }
        later(span) {
            link.invalidate()
            let cpu1 = cpu()
            for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            let ticks = ticker.ticks.filter { $0.at >= started - 0.001 }
            // The frames the column moved on, and the time between them.
            // Not its last point: kept to whole pixels (PixelOffset), the
            // spring's tail moves a half point every few frames, which is
            // the column at rest, not a stall.
            var moves: [CFTimeInterval] = []
            let rest = ticks.last?.column ?? .nan
            for (a, b) in zip(ticks, ticks.dropFirst()) where !a.column.isNaN && !b.column.isNaN && abs(b.column - a.column) > 0.01
                && !(abs(a.column - rest) <= 1) {
                moves.append(b.at)
            }
            let gaps = zip(moves, moves.dropFirst()).map { ($1 - $0) * 1000 }.sorted()
            let tickGaps = zip(ticks, ticks.dropFirst()).map { ($1.at - $0.at) * 1000 }.sorted()
            func pct(_ xs: [Double], _ p: Double) -> Double {
                xs.isEmpty ? 0 : (xs[min(xs.count - 1, Int(Double(xs.count - 1) * p + 0.5))] * 10).rounded() / 10
            }
            let first = moves.first.map { (($0 - started) * 1000).rounded() } ?? -1
            let last = moves.last.map { (($0 - started) * 1000).rounded() } ?? -1
            done(["folded": browser.folded, "was": before,
                  "ticks": ticks.count, "tickWorst": pct(tickGaps, 1), "tickP95": pct(tickGaps, 0.95),
                  "moved": moves.count, "firstMs": first, "lastMs": last,
                  "worst": pct(gaps, 1), "p95": pct(gaps, 0.95), "median": pct(gaps, 0.5),
                  "passes": passes.count, "busyMs": (passes.reduce(0, +) * 10).rounded() / 10,
                  "longestPass": ((passes.max() ?? 0) * 10).rounded() / 10,
                  "cpuMs": ((cpu1 - cpu0) * 10000).rounded() / 10,
                  "layersMoved": layers.moved, "layersMovedMax": layers.maxMoved, "redrawn": layers.redrawn, "addedLayers": layers.added,
                  "redrawers": layers.redrawers, "pageWidths": pageWidths,
                  "middle": middle, "track": ticker.tracked])
        }
    }

    /// Where the page's card, the column and the window's buttons stand at
    /// this frame, in the window's coordinates with y down: the page as it
    /// is seen — the web view cut by every layer above it that clips, short
    /// of the window's own — the column's left edge, and the buttons'
    /// slide as Core Animation shows it.
    static func geometry(_ browser: Browser, _ window: NSWindow) -> [String: Any] {
        guard let root = window.contentView?.superview, let top = root.layer else { return [:] }
        let height = top.bounds.height
        func flip(_ r: CGRect) -> [Double] {
            [Double(r.minX), Double(height - r.maxY), Double(r.width), Double(r.height)].map { ($0 * 10).rounded() / 10 }
        }
        var out: [String: Any] = ["window": flip(top.bounds)]
        if let web = browser.active?.built, var layer = web.layer {
            var seen = layer.convert(layer.bounds, to: top)
            var radius: CGFloat = 0
            while let up = layer.superlayer, up !== top {
                if up.masksToBounds || up.mask != nil {
                    let clip = up.convert(up.mask?.frame ?? up.bounds, to: top)
                    if clip.width < 10_000 {
                        seen = seen.intersection(clip)
                        radius = max(radius, up.mask?.cornerRadius ?? up.cornerRadius)
                    }
                }
                layer = up
            }
            out["card"] = flip(seen)
            out["radius"] = Double(radius)
            out["page"] = flip(web.convert(web.bounds, to: nil).offsetBy(dx: 0, dy: 0))
            out["pageSize"] = [Double(web.frame.width), Double(web.frame.height)]
        }
        func catches(in view: NSView) -> [NSView] {
            (String(describing: type(of: view)) == "Catch" ? [view] : []) + view.subviews.flatMap(catches)
        }
        if let marker = catches(in: root).first {
            out["column"] = Double(marker.convert(marker.bounds, to: nil).minX)
        }
        if let bar = window.standardWindowButton(.closeButton)?.superview, let layer = bar.layer {
            let shown = layer.presentation() ?? layer
            out["lights"] = (shown.value(forKeyPath: "transform.translation.x") as? Double) ?? 0
            out["lightsHidden"] = bar.isHidden
        }
        return out
    }

    private static func later(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
    }

    /// This process's CPU time so far, in seconds.
    private static func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let t = { (v: timeval) in Double(v.tv_sec) + Double(v.tv_usec) / 1e6 }
        return t(usage.ru_utime) + t(usage.ru_stime)
    }

    /// The window's layers: all of them, those shown, and of those shown the
    /// ones the window server has to draw apart before putting them in, and
    /// those beyond the window's own bounds.
    static func census(_ window: NSWindow) -> [String: Any] {
        guard let top = window.contentView?.superview?.layer else { return [:] }
        let bounds = top.bounds
        var total = 0, shown = 0, masks = 0, shadows = 0, filters = 0, rounded = 0, outside = 0, big = 0
        var kinds: [String: Int] = [:]
        var apart: [String] = []
        var clearBig = 0
        func owner(_ layer: CALayer) -> String {
            var l: CALayer? = layer
            while let at = l {
                if let d = at.delegate { return String(describing: type(of: d)) }
                l = at.superlayer
            }
            return "-"
        }
        func walk(_ layer: CALayer, _ seen: Bool) {
            total += 1
            let seen = seen && !layer.isHidden && layer.opacity > 0
            if seen {
                shown += 1
                if layer.mask != nil { masks += 1; kinds["mask " + String(describing: type(of: layer)), default: 0] += 1 }
                if layer.shadowOpacity > 0, layer.shadowPath == nil { shadows += 1; kinds["shadow " + String(describing: type(of: layer)), default: 0] += 1 }
                if !(layer.filters ?? []).isEmpty || !(layer.backgroundFilters ?? []).isEmpty || layer.compositingFilter != nil {
                    filters += 1; kinds["filter " + String(describing: type(of: layer)), default: 0] += 1
                }
                if layer.masksToBounds, layer.cornerRadius > 0, !(layer.sublayers ?? []).isEmpty { rounded += 1 }
                let place = layer.convert(layer.bounds, to: top)
                if place.width > 0, place.height > 0, !place.intersects(bounds) { outside += 1 }
                if place.width * place.height > bounds.width * bounds.height * 0.5 {
                    big += 1
                    if !layer.isOpaque, layer.contents != nil || layer.backgroundColor != nil { clearBig += 1 }
                }
                let off = layer.mask != nil || (layer.shadowOpacity > 0 && layer.shadowPath == nil)
                    || !(layer.backgroundFilters ?? []).isEmpty || !(layer.filters ?? []).isEmpty
                if off {
                    let what = (layer.mask != nil ? "mask" : "") + (layer.shadowOpacity > 0 ? "shadow\(layer.shadowOpacity)r\(Int(layer.shadowRadius))a\(layer.shadowColor?.alpha ?? -1)" : "")
                        + (!(layer.filters ?? []).isEmpty || !(layer.backgroundFilters ?? []).isEmpty ? "filter" : "")
                    apart.append("\(what) \(owner(layer)) \(Int(place.minX)),\(Int(place.minY)) \(Int(place.width))x\(Int(place.height))")
                }
            }
            for sub in layer.sublayers ?? [] { walk(sub, seen) }
        }
        walk(top, true)
        // Pages drawing no ground of their own (PaneStage.backPages): clear,
        // so blended over what is under them, and painted afresh each switch.
        func pages(_ view: NSView) -> [WKWebView] { ((view as? WKWebView).map { [$0] } ?? []) + view.subviews.flatMap(pages) }
        let webs = window.contentView.map(pages) ?? []
        let clearPages = webs.filter { $0.responds(to: NSSelectorFromString("_drawsBackground")) && ($0.value(forKey: "drawsBackground") as? Bool) == false }.count
        let covers = webs.reduce(0) { $0 + $1.subviews.filter { String(describing: type(of: $0)) == "FoldCover" }.count }
        return ["clearPages": clearPages, "covers": covers,
                "webPids": webs.compactMap { $0.responds(to: NSSelectorFromString("_webProcessIdentifier")) ? ($0.value(forKey: "_webProcessIdentifier") as? Int) : nil },
                "layers": total, "shown": shown, "masks": masks, "shadows": shadows, "filters": filters,
                "roundedClips": rounded, "outside": outside, "big": big, "clearBig": clearBig, "kinds": kinds, "apart": apart]
    }
}
