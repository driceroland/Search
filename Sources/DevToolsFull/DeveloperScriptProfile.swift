import Foundation

/// Converts WebKit's sampled stacks to time ranges that the existing flame chart
/// and trace exporter can display alongside instrumented timeline events.
enum DeveloperScriptProfile {
    private struct Frame: Equatable {
        let data: [String: String]

        init(_ raw: [String: Any]) {
            let name = raw["name"] as? String ?? ""
            var data = ["name": name.isEmpty ? "(anonymous)" : name]
            if let url = raw["url"] as? String, !url.isEmpty { data["url"] = url }
            if let line = raw["line"] as? Int, line > 0 { data["lineNumber"] = String(line) }
            if let column = raw["column"] as? Int, column > 0 { data["columnNumber"] = String(column) }
            self.data = data
        }
    }

    private struct Sample {
        let time: Double
        let frames: [Frame]
    }

    private struct Range {
        let frame: Frame
        let start: Double
        var end: Double
        let depth: Int
    }

    static let rangeLimit = 8_000

    static func timings(_ traces: [[String: Any]], within timeline: [DeveloperToolsSession.Timing]) -> [DeveloperToolsSession.Timing] {
        let samples = traces.compactMap { trace -> Sample? in
            guard let time = trace["timestamp"] as? Double, time.isFinite,
                  let frames = trace["stackFrames"] as? [[String: Any]], !frames.isEmpty else { return nil }
            // WebKit supplies the currently executing frame first.
            return Sample(time: time, frames: frames.reversed().map(Frame.init))
        }.sorted { $0.time < $1.time }
        let scripts = timeline.filter { $0.type == "FunctionCall" || $0.type == "EvaluateScript" }
            .sorted { $0.start < $1.start }
        var nextScript = 0
        var activeScripts: [DeveloperToolsSession.Timing] = []
        var previousScript: UUID?
        var openRanges: [Int] = []
        var ranges: [Range] = []

        for (index, sample) in samples.enumerated() {
            while nextScript < scripts.count, scripts[nextScript].start <= sample.time {
                activeScripts.append(scripts[nextScript])
                nextScript += 1
            }
            activeScripts.removeAll { $0.end <= sample.time }
            let parent = activeScripts.max { lhs, rhs in
                lhs.depth == rhs.depth ? lhs.start < rhs.start : lhs.depth < rhs.depth
            }
            // Split the time between adjacent samples, clipping at the script
            // record and leaving gaps when the profiler did not sample any work.
            let before = index == 0 ? 0.001 : sample.time - samples[index - 1].time
            let after = index + 1 == samples.count ? 0.001 : samples[index + 1].time - sample.time
            let start = max(parent?.start ?? 0, sample.time - min(0.010, before / 2))
            let end = min(parent?.end ?? .infinity, sample.time + min(0.010, after / 2))
            guard end > start else { continue }

            var common = 0
            if previousScript == parent?.id {
                while common < min(openRanges.count, sample.frames.count) {
                    let open = openRanges[common]
                    guard ranges[open].frame == sample.frames[common], ranges[open].end >= start - 0.000_001 else { break }
                    ranges[open].end = end
                    common += 1
                }
            }
            openRanges = Array(openRanges.prefix(common))
            // Past the cap, ranges already open still grow, but no new
            // (deeper) ones start, so the whole recording stays covered.
            for depth in common..<sample.frames.count where ranges.count < Self.rangeLimit {
                openRanges.append(ranges.count)
                ranges.append(Range(frame: sample.frames[depth], start: start, end: end,
                                    depth: (parent?.depth ?? -1) + 1 + depth))
            }
            previousScript = parent?.id
        }

        return ranges.map {
            .init(type: "JavaScriptFrame", start: $0.start, end: $0.end, depth: $0.depth, data: $0.frame.data)
        }
    }
}

/// Chrome's line-level profile: the self time sampled at each place in each
/// script during the latest Performance recording, for Sources' gutter.
struct DeveloperLineProfile: Equatable {
    /// Milliseconds by script url, then by place (1-based line, 0-based column).
    private(set) var times: [String: [SourceBreakpoint: Double]] = [:]

    var isEmpty: Bool { times.isEmpty }

    init() {}

    /// Each sample's time (halfway to its neighbours, at most 10 ms each
    /// way, as the flame chart splits it) goes to its innermost frame with
    /// a script place, so a built-in's time lands on the line calling it.
    init(_ traces: [[String: Any]], within timeline: [DeveloperToolsSession.Timing]) {
        let recording = timeline.last { $0.type == "RecordingBounds" }
        let start = recording?.start ?? 0
        let end = recording?.end ?? .infinity
        let samples = traces.compactMap { trace -> (time: Double, top: [String: Any])? in
            guard let time = trace["timestamp"] as? Double, time.isFinite,
                  let top = (trace["stackFrames"] as? [[String: Any]])?.first(where: {
                      !(($0["url"] as? String) ?? "").isEmpty && (($0["line"] as? Int) ?? 0) > 0
                  }) else { return nil }
            return (time, top)
        }.sorted { $0.time < $1.time }
        for (index, sample) in samples.enumerated() {
            guard let url = sample.top["url"] as? String, let line = sample.top["line"] as? Int else { continue }
            let before = index == 0 ? 0.001 : sample.time - samples[index - 1].time
            let after = index + 1 == samples.count ? 0.001 : samples[index + 1].time - sample.time
            let lower = max(start, sample.time - min(0.010, before / 2))
            let upper = min(end, sample.time + min(0.010, after / 2))
            guard sample.time >= start, sample.time <= end, upper > lower else { continue }
            let place = SourceBreakpoint(line: line, column: max(0, ((sample.top["column"] as? Int) ?? 1) - 1))
            times[url, default: [:]][place, default: 0] += (upper - lower) * 1000
        }
    }

    /// Milliseconds by shown line (1-based) of the file at `url`: its own
    /// samples, and for an authored file those its compiled scripts map to
    /// it through `original` (0-based lines and columns in and out).
    /// `shown` places an original line (1-based) and column (0-based) in
    /// the lines shown, a pretty-printed file's.
    func lines(of url: String, original: ((String, Int, Int) -> DeveloperSourceMap.Original?)?,
               shown: (Int, Int) -> Int) -> [Int: Double] {
        var lines: [Int: Double] = [:]
        for (script, places) in times {
            let own = DeveloperSourceMaps.key(script) == DeveloperSourceMaps.key(url)
            guard own || original != nil else { continue }
            for (place, ms) in places {
                var at = place
                if !own {
                    guard let mapped = original?(script, place.line - 1, place.column), mapped.url == url else { continue }
                    at = SourceBreakpoint(line: mapped.line + 1, column: mapped.column)
                }
                lines[shown(at.line, at.column), default: 0] += ms
            }
        }
        return lines
    }

    /// A line's timing as Chrome's gutter reads it.
    static func label(_ ms: Double) -> String { String(format: "%.1f ms", ms) }
}
