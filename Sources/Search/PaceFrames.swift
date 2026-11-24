import AppKit
import QuartzCore

/// A space swipe or a column scroll in a window that is drawn but never
/// seen (FoldFrames.stage), every display frame timed (Bench "paceframes",
/// idea 1051). Test runs only, in a probe started hidden.
///
/// "swipe": two fingers across the column, `steps` moves of `dx` in all, one
/// every `every` seconds, let go, and `tail` seconds more for the space to
/// be taken. "scroll": a trackpad stroke of `steps` moves of `dy` and its
/// `glide`, or with `wheel` a mouse's notches, the column's clip view moved
/// as a scroll moves it (or, with `clip` false, the events sent to the view
/// under the pointer). Answered: the gaps between display frames (late:
/// over 13 ms), each main run loop pass (busyMs, longestPass), the CPU
/// used, the rows built and where the column's scroll went.
@MainActor
enum PaceFrames {
    private final class Ticker: NSObject {
        var ticks: [CFTimeInterval] = []
        var offsets: [Double] = []
        var probe: () -> Double = { .nan }
        @objc func tick(_ link: CADisplayLink) { ticks.append(link.timestamp); offsets.append(probe()) }
    }

    static var hitNames: [String] = []
    static func run(_ browser: Browser, _ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard NSApp.isHidden else { answer(["error": "needs a hidden probe"]); return }
        guard let window = browser.window else { answer(["error": "no window"]); return }
        if request["stage"] as? Bool ?? true, !FoldFrames.stage(window) { answer(["error": "not staged"]); return }
        let kind = request["kind"] as? String ?? "swipe"
        let dx = request["dx"] as? Double ?? -240
        let steps = request["steps"] as? Int ?? 20
        let every = request["every"] as? Double ?? 1.0 / 120
        let tail = request["tail"] as? Double ?? 0.6
        later(0.4) {
            let ticker = Ticker()
            ticker.probe = { Bench.columnOffset(browser) ?? .nan }
            var passes: [Double] = []
            var woke: CFAbsoluteTime = 0
            let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { _, _ in
                woke = CFAbsoluteTimeGetCurrent()
            }
            let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
                guard woke > 0 else { return }
                passes.append((CFAbsoluteTimeGetCurrent() - woke) * 1000); woke = 0
            }
            let observers = [wake, sleep].compactMap { $0 }
            for o in observers { CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes) }
            let link = (NSScreen.main ?? NSScreen.screens[0]).displayLink(target: ticker, selector: #selector(Ticker.tick(_:)))
            // Asked for the display's full pace, as the swipe's glide asks
            // (SwipeGlide). The display can still run at 60 Hz: then every
            // gap is 16.7 ms whatever the app does, and gapMedian says so.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            Bench.bodies = [:]
            let from = browser.spaceID
            let cpu0 = cpu()
            let started = CACurrentMediaTime()
            var stepMs: [Double] = []
            @MainActor func finish() {
                later(tail) {
                    link.invalidate()
                    let cpu1 = cpu()
                    for o in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes) }
                    let ticks = ticker.ticks.filter { $0 >= started - 0.001 }
                    let gaps = zip(ticks, ticks.dropFirst()).map { ($1 - $0) * 1000 }.sorted()
                    func pct(_ xs: [Double], _ p: Double) -> Double {
                        xs.isEmpty ? 0 : (xs[min(xs.count - 1, Int(Double(xs.count - 1) * p + 0.5))] * 10).rounded() / 10
                    }
                    let s = stepMs.sorted()
                    let offs = ticker.offsets.filter { !$0.isNaN }
                    answer(["kind": kind, "ticks": ticks.count, "gapP95": pct(gaps, 0.95), "gapMax": pct(gaps, 1),
                            "gapMedian": pct(gaps, 0.5), "late": gaps.filter { $0 > 13 }.count,
                            "hz": window.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 0,
                            "stepMedianMs": pct(s, 0.5), "stepP95Ms": pct(s, 0.95), "stepMaxMs": pct(s, 1),
                            "busyMs": (passes.reduce(0, +) * 10).rounded() / 10, "longestPass": pct(passes.sorted(), 1),
                            "cpuMs": ((cpu1 - cpu0) * 10000).rounded() / 10, "rows": Bench.bodies["row", default: 0],
                            "landed": browser.spaceID != from, "tabs": browser.tabs.count,
                            "offsetFrom": offs.first ?? -1, "hit": hitNames, "offsetTo": offs.last ?? -1])
                }
            }
            if kind == "swipe" {
                let t0 = CFAbsoluteTimeGetCurrent()
                SpaceSwipe.shared.start(for: browser)
                SpaceSwipe.shared.began()
                stepMs.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                @MainActor func step(_ n: Int) {
                    let t = CFAbsoluteTimeGetCurrent()
                    guard n < steps else {
                        SpaceSwipe.shared.ended()
                        stepMs.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
                        finish(); return
                    }
                    _ = SpaceSwipe.shared.moved(along: dx / Double(steps))
                    stepMs.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
                    later(every) { step(n + 1) }
                }
                step(0)
            } else {
                // Two fingers down the column, as a trackpad sends them, then their glide.
                guard let frame = window.contentView?.superview else { answer(["error": "no frame"]); return }
                let width = Double(browser.prefs.columnWidth)
                let point = NSPoint(x: width / 2, y: Double(window.frame.height) / 2)
                guard let hit = frame.hitTest(frame.convert(point, from: nil)) else { answer(["error": "nothing under"]); return }
                func scrolls(in view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls) }
                let column = scrolls(in: frame).first { v in let r = v.convert(v.bounds, to: nil); return r.height > 60 && Double(r.maxX) <= width + 1 }
                let under: NSView = request["direct"] as? Bool == true ? (column ?? hit) : hit
                var hitChain: [String] = []
                var v: NSView? = hit
                while let at = v, hitChain.count < 12 { hitChain.append(String(describing: type(of: at))); v = at.superview }
                hitNames = hitChain
                let dy = request["dy"] as? Double ?? -14
                let glide = request["glide"] as? Int ?? 50
                let wheel = request["wheel"] as? Bool ?? false
                var events: [(Int64, Int64, Double)] = []
                if wheel {
                    events = (0..<steps).map { _ in (0, 0, dy) }
                } else {
                    events.append((128, 0, 0)); events.append((1, 0, dy))
                    for _ in 0..<steps { events.append((2, 0, dy)) }
                    events.append((4, 0, 0))
                    for g in 0..<glide { events.append((0, g == 0 ? 1 : (g == glide - 1 ? 3 : 2), dy * pow(0.95, Double(g)))) }
                }
                let clip = request["clip"] as? Bool ?? true
                @MainActor func send(_ n: Int) {
                    guard n < events.count else { finish(); return }
                    let (phase, momentum, y) = events[n]
                    let t = CFAbsoluteTimeGetCurrent()
                    if clip, let column {
                        // The clip view moved as a scroll moves it: what the rows see is the same.
                        let b = column.contentView.bounds
                        let top = max(0, (column.documentView?.frame.height ?? 0) - b.height)
                        column.contentView.scroll(to: NSPoint(x: b.minX, y: min(top, max(0, b.minY - y))))
                        column.reflectScrolledClipView(column.contentView)
                    } else if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(y), wheel2: 0, wheel3: 0) {
                        cg.location = CGPoint(x: window.frame.minX + point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - (window.frame.minY + point.y))
                        if !wheel {
                            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
                        }
                        if let event = NSEvent(cgEvent: cg) { under.scrollWheel(with: event) }
                    }
                    stepMs.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
                    later(every) { send(n + 1) }
                }
                send(0)
            }
        }
    }

    private static func later(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
    }

    private static func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let t = { (v: timeval) in Double(v.tv_sec) + Double(v.tv_usec) / 1e6 }
        return t(usage.ru_utime) + t(usage.ru_stime)
    }
}
