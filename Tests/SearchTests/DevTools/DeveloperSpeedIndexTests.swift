import XCTest
@testable import Search

final class DeveloperSpeedIndexTests: XCTestCase {
    private func rgba(_ pixels: [(UInt8, UInt8, UInt8)]) -> [UInt8] { pixels.flatMap { [$0.0, $0.1, $0.2, 255] } }

    func testHistogramLeavesOutNearWhitePixels() {
        let pixels: [(UInt8, UInt8, UInt8)] = [(255, 255, 255), (250, 250, 250), (10, 20, 30), (249, 255, 255)]
        let counts = DeveloperSpeedIndex.histogram(rgba: rgba(pixels))
        XCTAssertEqual(counts.reduce(0, +), 6)
        XCTAssertEqual(counts[10], 1)
        XCTAssertEqual(counts[256 + 20], 1)
        XCTAssertEqual(counts[512 + 30], 1)
        XCTAssertEqual(counts[249], 1)
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
    }

    func testSpeedIndexIsTheAreaAboveTheProgressCurve() throws {
        let full = [4, 0, 2, 0], half = [2, 0, 1, 0]
        // Blank to 1000 ms, half done to 2000 ms, then complete: 1000 + 500.
        let value = try XCTUnwrap(DeveloperSpeedIndex.speedIndex([(500, full), (1_000, half), (2_000, full), (3_000, full)], fcp: 1_000))
        XCTAssertEqual(value, 1_500, accuracy: 0.001)
        // The frame at 500 ms shows the old page (it matches the target) but is before FCP: blank.
    }

    func testSpeedIndexIsNeverBelowFCPAndNeedsAFrameAfterIt() {
        let full = [4, 0, 2, 0]
        // Complete at the first frame after FCP: it counts from that frame.
        XCTAssertEqual(DeveloperSpeedIndex.speedIndex([(100, full), (300, full)], fcp: 250), 300)
        XCTAssertEqual(DeveloperSpeedIndex.speedIndex([(100, full), (250, full)], fcp: 400 - 150), 250)
        XCTAssertEqual(DeveloperSpeedIndex.speedIndex([(0.1, full), (200, full)], fcp: 0.1), 0.1)
        XCTAssertNil(DeveloperSpeedIndex.speedIndex([(100, full)], fcp: 250))
        XCTAssertNil(DeveloperSpeedIndex.speedIndex([(100, full)], fcp: nil))
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
        XCTAssertTrue(audit.warnings.first?.contains("30 snapshots") ?? false)
    }
}
