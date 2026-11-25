import AppKit

/// Where the main thread's time goes with many tabs, from the very start
/// (Tests/perf_many_tabs.py). Test runs started with SEARCH_PERF=1 only:
/// otherwise nothing is installed and every call returns at once.
///
/// Each pass of the main run loop, from waking to going back to sleep, is
/// counted; the ones over 16 ms are kept with when they came (ms since the
/// process started), so a launch, an import or a space switch shows its
/// hangs afterwards without having been watched live. `mark` notes when a
/// step of the launch was reached, once.
@MainActor
enum PerfLog {
    static let on = Store.testing && ProcessInfo.processInfo.environment["SEARCH_PERF"] != nil
    /// When the process started, as the kernel has it.
    static let started: CFAbsoluteTime = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return CFAbsoluteTimeGetCurrent() }
        let t = info.kp_proc.p_starttime
        return Double(t.tv_sec) + Double(t.tv_usec) / 1e6 - kCFAbsoluteTimeIntervalSince1970
    }()
    private(set) static var marks: [String: Double] = [:]
    /// [ms since start, ms long] of every pass over 16 ms.
    private(set) static var long: [[Double]] = []
    private(set) static var passes = 0
    private(set) static var busy = 0.0
    private static var woke: CFAbsoluteTime = 0
    private static var installed = false

    static func now() -> Double { ((CFAbsoluteTimeGetCurrent() - started) * 10000).rounded() / 10 }

    static func mark(_ name: String) {
        guard on, marks[name] == nil else { return }
        marks[name] = now()
    }

    static func install() {
        guard on, !installed else { return }
        installed = true
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { _, _ in
            woke = CFAbsoluteTimeGetCurrent()
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            guard woke > 0 else { return }
            let t = CFAbsoluteTimeGetCurrent()
            let ms = (t - woke) * 1000
            passes += 1
            busy += ms
            if ms > 16 { long.append([((woke - started) * 1000).rounded(), (ms * 10).rounded() / 10]) }
            woke = 0
        }
        for o in [wake, sleep].compactMap({ $0 }) { CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes) }
        mark("installed")
    }

    static func state() -> [String: Any] {
        ["marks": marks, "long": long, "passes": passes, "busyMs": (busy * 10).rounded() / 10, "now": now()]
    }

    /// The app's own CPU time so far, in ms.
    static func cpuMs() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let t = { (v: timeval) in Double(v.tv_sec) * 1000 + Double(v.tv_usec) / 1000 }
        return ((t(usage.ru_utime) + t(usage.ru_stime)) * 10).rounded() / 10
    }

    /// Passes as Bench.timePasses gives them, summed up.
    static func summary(_ passes: [[String: Any]]) -> [String: Any] {
        let ms = passes.compactMap { $0["ms"] as? Double }.sorted()
        let rows = passes.compactMap { $0["rows"] as? Int }.reduce(0, +)
        return ["passes": ms.count, "busyMs": (ms.reduce(0, +) * 10).rounded() / 10, "longestMs": ms.last ?? 0,
                "over16": ms.filter { $0 > 16 }.count, "over50": ms.filter { $0 > 50 }.count, "rows": rows]
    }
}
