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
