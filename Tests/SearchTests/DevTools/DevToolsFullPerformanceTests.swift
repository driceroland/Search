import WebKit
import XCTest

extension DevToolsFullTests {
    /// Exercise the reconciled code through the installed Full package.
    func verifyPerformanceParity(
        web: WKWebView,
        perform: @MainActor (String, [String: Any]) async throws -> [String: Any]
    ) async throws {
        let models = try await perform("performance.parity", [:])
        XCTAssertEqual(models["line7Excluded"] as? Bool, true, "\(models)")
        XCTAssertGreaterThan(models["line12Milliseconds"] as? Double ?? 0, 0, "\(models)")
        XCTAssertEqual(models["roundTrip"] as? Bool, true, "\(models)")
        XCTAssertEqual(models["scriptsExcluded"] as? Bool, true, "\(models)")
        XCTAssertEqual(models["startsAtRecord"] as? Bool, true, "\(models)")
        XCTAssertEqual(models["speedIndex"] as? Double ?? -1, 75, accuracy: 0.001)
        XCTAssertEqual(models["beforeFirstPaint"] as? Bool, true, "\(models)")

        _ = try await web.evaluateJavaScript("""
            window.addEventListener('search-fixture-window', function globalProbe() {});
            document.addEventListener('search-fixture-document', function documentProbe() {});
            true
            """)
        let listeners = try await perform("sources.globalListeners", [:])
        XCTAssertNil(listeners["error"])
        XCTAssertTrue((listeners["types"] as? [String] ?? []).contains("search-fixture-window"), "\(listeners)")
        XCTAssertFalse((listeners["types"] as? [String] ?? []).contains("search-fixture-document"), "\(listeners)")

        let withoutSamples = try await perform("performance.record", ["disableSamples": true, "milliseconds": 150])
        XCTAssertEqual(withoutSamples["sampling"] as? Bool, false, "\(withoutSamples)")
        XCTAssertFalse((withoutSamples["types"] as? [String] ?? []).contains("JavaScriptFrame"))

        let initial = try await perform("performance.liveMetrics", [:])
        XCTAssertNil(initial["error"])
        let cleared = try await perform("performance.clearLogs", [:])
        XCTAssertEqual(cleared["cleared"] as? Bool, true)
        try await Task.sleep(for: .milliseconds(300))

        _ = try await web.evaluateJavaScript("document.getElementById('title').style.transform = 'translateX(35px)'; true")
        try await Task.sleep(for: .milliseconds(500))
        let transformed = try await perform("performance.liveMetrics", [:])
        XCTAssertEqual(transformed["layoutShifts"] as? [[String]], [], "compositing is not a layout shift")

        _ = try await web.evaluateJavaScript("document.getElementById('title').style.marginTop = '100px'; true")
        var moved: [[String]] = []
        for _ in 0..<30 {
            let log = try await perform("performance.liveMetrics", [:])
            moved = log["layoutShifts"] as? [[String]] ?? []
            if moved.contains(where: { $0.contains(where: { $0.hasPrefix("h1#title") }) }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(moved.contains { $0.contains(where: { $0.hasPrefix("h1#title") }) }, "\(moved)")
        let heap = try await perform("memory.total", [:])
        XCTAssertNil(heap["error"])
    }
}
