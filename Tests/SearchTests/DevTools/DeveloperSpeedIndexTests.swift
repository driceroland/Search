import XCTest
@testable import Search

final class DeveloperSpeedIndexTests: XCTestCase {
    private func rgba(_ pixels: [(UInt8, UInt8, UInt8)]) -> [UInt8] { pixels.flatMap { [$0.0, $0.1, $0.2, 255] } }

    func testHistogramLeavesOutNearWhitePixels() {
        // speedline's isWhitePixel: every channel 249 or more.
        let pixels: [(UInt8, UInt8, UInt8)] = [(255, 255, 255), (249, 249, 249), (10, 20, 30), (248, 255, 255)]
        let counts = DeveloperSpeedIndex.histogram(rgba: rgba(pixels))
        XCTAssertEqual(counts.reduce(0, +), 6)
        XCTAssertEqual(counts[10], 1)
        XCTAssertEqual(counts[256 + 20], 1)
        XCTAssertEqual(counts[512 + 30], 1)
        XCTAssertEqual(counts[248], 1)
    }

    func testProgressMatchesSpeedline() {
        let blank = [0, 0, 0, 0]
        let target = [4, 0, 2, 0]
        XCTAssertEqual(DeveloperSpeedIndex.progress(blank, initial: blank, target: target), 0)
        XCTAssertEqual(DeveloperSpeedIndex.progress(target, initial: blank, target: target), 1)
        XCTAssertEqual(DeveloperSpeedIndex.progress([2, 0, 1, 0], initial: blank, target: target), 0.5)
        // More than the target counts only up to the target.
        XCTAssertEqual(DeveloperSpeedIndex.progress([8, 0, 2, 0], initial: blank, target: target), 1)
        XCTAssertEqual(DeveloperSpeedIndex.progress(blank, initial: blank, target: blank), 1)
        // speedline floors to a whole percent: 2 of 3 is 66%, not 66.7%.
        XCTAssertEqual(DeveloperSpeedIndex.progress([2, 0, 0, 0], initial: blank, target: [3, 0, 0, 0]), 0.66, accuracy: 1e-9)
    }

    func testSpeedIndexIsTheAreaAboveTheProgressCurve() throws {
        let full = [4, 0, 2, 0], half = [2, 0, 1, 0]
        // Blank to 1000 ms, half done to 2000 ms, then complete: 1000 + 500.
        let value = try XCTUnwrap(DeveloperSpeedIndex.speedIndex([(500, full), (1_000, half), (2_000, full), (3_000, full)], fcp: 1_000))
        XCTAssertEqual(value, 1_500, accuracy: 0.001)
        // The frame at 500 ms shows the old page (it matches the target) but is before FCP: blank.
    }

    func testAFrameStillOnScreenAtFCPCountsFromFCP() {
        let full = [4, 0, 2, 0]
        // Only changed frames are kept: the frame from 100 ms was still on
        // screen at FCP (250 ms), so the page was complete then.
        XCTAssertEqual(DeveloperSpeedIndex.speedIndex([(100, full), (300, full)], fcp: 250), 250)
        XCTAssertEqual(DeveloperSpeedIndex.speedIndex([(100, full)], fcp: 250, end: 400), 250)
        // A reload that repaints the same pixels: the one frame is from before navigation.
        XCTAssertEqual(DeveloperSpeedIndex.speedIndex([(-40, full)], fcp: 120, end: 900), 120)
        XCTAssertEqual(DeveloperSpeedIndex.speedIndex([(0.1, full), (200, full)], fcp: 0.1), 0.1)
        // The filmstrip stopped before FCP: nothing to measure.
        XCTAssertNil(DeveloperSpeedIndex.speedIndex([(100, full)], fcp: 250))
        XCTAssertNil(DeveloperSpeedIndex.speedIndex([(100, full)], fcp: 250, end: 200))
        XCTAssertNil(DeveloperSpeedIndex.speedIndex([(100, full)], fcp: nil))
    }

    func testStagedPaintsMatchSpeedlineOnAFineFilmstrip() throws {
        // Four quarters painted at 10, 310, 610 and 910 ms (Perch's
        // si fixture): speedline's area is 10 + .75·300 + .5·300 + .25·300.
        let quarter = [1, 0, 0, 0], half = [2, 0, 0, 0], threeQuarters = [3, 0, 0, 0], full = [4, 0, 0, 0]
        let frames: [(ms: Double, histogram: [Int])] = [(10, quarter), (310, half), (610, threeQuarters), (910, full)]
        XCTAssertEqual(try XCTUnwrap(DeveloperSpeedIndex.speedIndex(frames, fcp: 10, end: 1_500)), 460, accuracy: 1e-9)
        // The same paints seen by 100 ms snapshots land up to 90 ms late each.
        let coarse: [(ms: Double, histogram: [Int])] = [(100, quarter), (400, half), (700, threeQuarters), (1_000, full)]
        XCTAssertEqual(try XCTUnwrap(DeveloperSpeedIndex.speedIndex(coarse, fcp: 10, end: 1_500)), 550, accuracy: 1e-9)
    }

    @MainActor
    func testTheRecorderKeepsOnlyFramesThatChanged() {
        let recorder = DeveloperFilmstripRecorder()
        let start = Date(timeIntervalSince1970: 1_000)
        recorder.record(start, [1, 0])
        recorder.record(start.addingTimeInterval(0.016), [1, 0])
        recorder.record(start.addingTimeInterval(0.032), [2, 0])
        recorder.record(start.addingTimeInterval(0.048), [2, 0])
        XCTAssertEqual(recorder.captured, 4)
        XCTAssertEqual(recorder.frames.map(\.histogram), [[1, 0], [2, 0]])
        XCTAssertEqual(recorder.lastCapture, start.addingTimeInterval(0.048))
        XCTAssertEqual(recorder.timed(from: start).map { $0.ms.rounded() }, [0, 32])
    }

    func testAuditReportsTheMeasuredValueWithItsCaveat() {
        var metrics = DeveloperLighthouseMetrics(fcp: 900, lcp: nil, lcpSupported: false, cls: nil, clsSupported: false,
                                                 tasks: [], taskSource: .eventLoopGaps)
        metrics.speedIndex = 1_200
        metrics.speedIndexFrames = 30
        let input = DeveloperLighthouseInput(mode: .navigation, formFactor: .desktop, categories: [.performance],
                                             requestedURL: "https://example.com/", page: DeveloperLighthousePage([:]), metrics: metrics)
        let audit = DeveloperLighthouseRules.metricAudit(.speedIndex, input)
        XCTAssertEqual(audit.mode, .numeric)
        XCTAssertEqual(audit.numericValue, 1_200)
        XCTAssertEqual(audit.displayValue, "1.2 s")
        XCTAssertGreaterThan(audit.score ?? 0, 0.9)
        XCTAssertTrue(audit.warnings.first?.contains("30 snapshots of the view, one per display frame") ?? false)
    }
}
