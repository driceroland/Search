import AppKit
import AuthenticationServices
import SwiftUI
import WebKit

#if DEBUG
// Records a test run keeps: frames as they come, and a clock for the run loop.

/// The pages' frames as they change, for the bench's `layouts`: one entry per
/// change, the first being where they were.
@MainActor
final class LayoutRecord {
    weak var browser: Browser?
    private(set) var seen: [[String: Any]] = []
    private var last: [String: [Int]]?
    private let began = CACurrentMediaTime()
    private var timer: Timer?
    private var observer: CFRunLoopObserver?

    init(browser: Browser) { self.browser = browser }

    func look() {
        guard let browser, let window = browser.window else { return }
        var now: [String: [Int]] = [:]
        for tab in browser.tabs {
            guard let web = tab.built, web.window === window, !web.isHiddenOrHasHiddenAncestor else { continue }
            let r = web.convert(web.bounds, to: nil)
            now[Bench.short(tab)] = [Int(r.minX.rounded()), Int((window.frame.height - r.maxY).rounded()),
                                     Int(r.width.rounded()), Int(r.height.rounded())]
        }
        guard now != last else { return }
        last = now
        seen.append(["ms": Int((CACurrentMediaTime() - began) * 1000), "pages": now])
    }

    func start() {
        let timer = Timer(timeInterval: 0.004, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // After everything else in the turn, Core Animation's commit included.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.look() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func stop() {
        look()
        timer?.invalidate()
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    }
}

/// Each pass of the main run loop, from waking to going back to sleep, in
/// milliseconds: the ones that carried a pointer move ("hoversweep") apart
/// from the rest (timers, animation, anything else).
final class LoopClock: @unchecked Sendable {
    private(set) var marked: [Double] = []
    private(set) var unmarked: [Double] = []
    private var woke: CFAbsoluteTime = 0
    private var carrying = false
    private var observers: [CFRunLoopObserver] = []

    func mark() { carrying = true }

    func start() {
        // First to hear the loop wake, last to hear it sleep: after Core
        // Animation's commit, which is where SwiftUI's update lands.
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [unowned self] _, _ in
            woke = CFAbsoluteTimeGetCurrent()
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [unowned self] _, _ in
            guard woke > 0 else { return }
            let ms = (CFAbsoluteTimeGetCurrent() - woke) * 1000
            if carrying { marked.append(ms) } else { unmarked.append(ms) }
            carrying = false
            woke = 0
        }
        for observer in [wake, sleep].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    func stop() {
        for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observers = []
    }

    static func summary(_ values: [Double]) -> [String: Double] {
        guard !values.isEmpty else { return ["count": 0] }
        let sorted = values.sorted()
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(q * Double(sorted.count)))] }
        return ["count": Double(sorted.count), "p50": at(0.5), "p95": at(0.95), "max": sorted.last!,
                "total": sorted.reduce(0, +)]
    }
}
#endif
