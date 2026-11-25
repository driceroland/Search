import Foundation

/// Performance's CPU track, over WebKit's Timeline "CPU" instrument: each
/// CPUProfiler.trackingUpdate (about two a second) says how busy the
/// page's process was, as a percentage of one core, and how much of that
/// was each thread. Its threads are classed as Web Inspector's own CPU
/// timeline classes them: the main thread ("main"), web workers (a
/// "webkit" thread with a worker's target), WebKit's other threads, and
/// the rest. Chrome's Threads section is the nearest it has to this.
enum DeveloperPerformanceCPU {
    typealias Timing = DeveloperToolsSession.Timing

    /// The record type the samples are kept as.
    static let type = "CPUSample"
    /// The most samples a recording keeps: over half an hour of them.
    static let limit = 4_000

    /// One reading: the process's usage and its threads' shares, in
    /// percent of a core, at `time` ms from the recording's start.
    struct Sample: Equatable {
        let time: Double
        let usage: Double
        /// Nil when WebKit didn't break the usage down by thread.
        var main: Double?
        var workers: Double?
        var webkit: Double?
        var other: Double?
        var workerCount = 0

        var hasThreads: Bool { main != nil }
    }

    /// A CPUProfiler.trackingUpdate's `event` as a record, or nil for one
    /// from before the recording began or without a reading.
    static func timing(_ event: [String: Any], since start: Double = -.infinity) -> Timing? {
        guard let time = DeveloperMeasure.finite(event["timestamp"]), time >= start,
              let usage = DeveloperMeasure.finite(event["usage"]), usage >= 0 else { return nil }
        var data = ["usage": String(usage)]
        if let threads = event["threads"] as? [[String: Any]], !threads.isEmpty {
            var main = 0.0, workers = 0.0, webkit = 0.0, other = 0.0
            var workerCount = 0
            for thread in threads {
                guard let value = DeveloperMeasure.finite(thread["usage"]), value >= 0 else { continue }
                switch thread["type"] as? String {
                case "main":
                    main += value
                case "webkit":
                    if let target = thread["targetId"] as? String, !target.isEmpty {
                        workers += value
                        workerCount += 1
                    } else {
                        webkit += value
                    }
                default:
                    other += value
                }
            }
            data["main"] = String(main)
            data["workers"] = String(workers)
            data["webkit"] = String(webkit)
            data["other"] = String(other)
            data["workerCount"] = String(workerCount)
        }
        return Timing(type: type, start: time, end: time, data: data)
    }

    /// A record read back as a sample, at `time` ms into the recording.
    static func sample(_ data: [String: String], at time: Double) -> Sample? {
        guard let usage = data["usage"].flatMap({ Double($0) }), usage.isFinite, usage >= 0 else { return nil }
        func share(_ key: String) -> Double? {
            guard let value = data[key].flatMap({ Double($0) }), value.isFinite else { return nil }
            return max(0, value)
        }
        return Sample(time: time, usage: usage, main: share("main"), workers: share("workers"), webkit: share("webkit"),
                      other: share("other"), workerCount: data["workerCount"].flatMap { Int($0) } ?? 0)
    }

    /// At most `limit` samples, thinned evenly across the recording, so a
    /// long one keeps its whole span rather than only its start.
    static func budgeted(_ samples: [Sample], limit: Int = Self.limit) -> [Sample] {
        guard limit > 0 else { return [] }
        guard samples.count > limit else { return samples }
        let step = Double(samples.count) / Double(limit)
        return (0..<limit).map { samples[min(samples.count - 1, Int(Double($0) * step))] }
    }

    /// The sample covering `time`: WebKit's reading covers the half second
    /// before it, so the first one at or after `time`.
    static func sample(at time: Double, in samples: [Sample]) -> Sample? {
        guard let last = samples.last, time <= last.time else { return nil }
        return samples.first { $0.time >= time }
    }

    /// "12.5%", as Web Inspector labels usage.
    static func percent(_ value: Double) -> String {
        value >= 10 || value == 0 ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value)
    }
}
