import Foundation

/// Run the package's Performance models and live observer through the
/// same test bridge as the installed panels.
@MainActor
enum DeveloperPerformanceAutomation {
    static func perform(_ command: String, _ arguments: [String: Any], session: DeveloperToolsSession) async -> [String: Any] {
        switch command {
        case "performance.parity":
            return modelChecks()
        case "performance.liveMetrics", "performance.clearLogs":
            guard let web = session.web, !session.paused else { return ["error": "the page cannot be observed"] }
            session.select(.performance)
            if command == "performance.clearLogs" {
                return ["cleared": await DeveloperLiveMetricsModel.call(web, "api.clearLogs()") as? Bool ?? false]
            }
            guard let metrics = DeveloperLiveMetrics(raw: await DeveloperLiveMetricsModel.call(web, "api.read()")) else {
                return ["error": "no local metrics"]
            }
            return ["layoutShifts": metrics.shiftLog.map(\.elements),
                    "interactions": metrics.interactionLog.count, "cls": metrics.cls ?? 0]

        case "sources.globalListeners":
            do {
                let rows = try await DeveloperGlobalListeners.read(session)
                return ["types": rows.map(\.type), "handlers": rows.map(\.handler)]
            } catch {
                return ["error": error.localizedDescription]
            }

        case "memory.total":
            session.select(.memory)
            session.setHeapPreview(true)
            defer { session.setHeapPreview(false) }
            for _ in 0..<50 {
                if session.heapTotal != nil { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return ["bytes": session.heapTotal ?? 0]

        default: return ["error": "unknown Performance command"]
        }
    }

    private static func modelChecks() -> [String: Any] {
        let source = "https://example.test/main.js"
        let timings: [DeveloperToolsSession.Timing] = [
            .init(type: "RecordingBounds", start: 2, end: 2.02),
            .init(type: "FunctionCall", start: 1.99, end: 2.01),
        ]
        let traces: [[String: Any]] = [
            ["timestamp": 1.995, "stackFrames": [["url": source, "line": 7]]],
            ["timestamp": 2.003, "stackFrames": [["name": "native"], ["url": source, "line": 12, "column": 2]]],
            ["timestamp": 2.010, "stackFrames": [["url": source, "line": 12, "column": 4]]],
        ]
        let lines = DeveloperLineProfile(traces, within: timings).lines(of: source, original: nil) { line, _ in line }
        let script = DeveloperPerformanceScript(url: source, text: "const value = 42;",
                                                 mapText: #"{"version":3,"sources":["original.js"],"mappings":"AAAA"}"#,
                                                 mapURL: "https://example.test/main.js.map")
        var roundTrip = false
        var scriptsExcluded = false
        do {
            let data = try DeveloperPerformanceTrace.export(timings, scripts: [script])
            let loaded = try DeveloperPerformanceTrace.recording(from: data)
            let first = loaded.scripts?.first
            let decodedMap = first?.mapText.flatMap(DeveloperSourceMap.json)
            roundTrip = first?.url == script.url && first?.text == script.text && first?.mapURL == script.mapURL
                && decodedMap?["sources"] as? [String] == ["original.js"] && loaded.timings.count == timings.count
            let plain = try DeveloperPerformanceTrace.export(timings)
            scriptsExcluded = try DeveloperPerformanceTrace.recording(from: plain).scripts == nil
        } catch {
            return ["error": error.localizedDescription]
        }
        let early = SpeedIndex.histogram(rgba: [255, 0, 0, 255])
        let final = SpeedIndex.histogram(rgba: [255, 0, 0, 255, 0, 0, 255, 255])
        let film: [(ms: Double, histogram: [Int])] = [(20, early), (100, final)]
        return [
            "line12Milliseconds": lines[12] ?? 0,
            "line7Excluded": lines[7] == nil,
            "roundTrip": roundTrip,
            "scriptsExcluded": scriptsExcluded,
            "startsAtRecord": DeveloperToolsSession.withinRecording(timings, from: 2).allSatisfy { $0.start >= 2 },
            "speedIndex": SpeedIndex.speedIndex(film, fcp: 50, end: 120) ?? -1,
            "beforeFirstPaint": SpeedIndex.speedIndex(film, fcp: 121, end: 120) == nil,
        ]
    }
}
