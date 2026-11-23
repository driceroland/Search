import JavaScriptCore
import XCTest
@testable import Search

/// Performance's local metrics: Chrome's thresholds and wording, readings
/// from the page's script, and the scripts built around the layout-shift
/// estimator Lighthouse shares.
@MainActor
final class DeveloperLiveMetricsTests: XCTestCase {
    func testChromeThresholdsRateEachVital() {
        XCTAssertEqual(DeveloperWebVital.lcp.rating(2_500), .good)
        XCTAssertEqual(DeveloperWebVital.lcp.rating(2_501), .needsImprovement)
        XCTAssertEqual(DeveloperWebVital.lcp.rating(4_000), .needsImprovement)
        XCTAssertEqual(DeveloperWebVital.lcp.rating(4_001), .poor)
        XCTAssertEqual(DeveloperWebVital.cls.rating(0.1), .good)
        XCTAssertEqual(DeveloperWebVital.cls.rating(0.2), .needsImprovement)
        XCTAssertEqual(DeveloperWebVital.cls.rating(0.26), .poor)
        XCTAssertEqual(DeveloperWebVital.inp.rating(200), .good)
        XCTAssertEqual(DeveloperWebVital.inp.rating(300), .needsImprovement)
        XCTAssertEqual(DeveloperWebVital.inp.rating(501), .poor)
    }

    func testValuesAreWordedAsChromeWordsThem() {
        XCTAssertEqual(DeveloperWebVital.lcp.format(1_234), "1.23 s")
        XCTAssertEqual(DeveloperWebVital.lcp.format(850), "850 ms")
        XCTAssertEqual(DeveloperWebVital.cls.format(0.054), "0.05")
        XCTAssertEqual(DeveloperWebVital.inp.format(120.4), "120 ms")
        XCTAssertEqual(DeveloperWebVital.lcp.title, "Largest Contentful Paint (LCP)")
        XCTAssertEqual(DeveloperVitalRating.needsImprovement.rawValue, "Needs improvement")
    }

    func testUnsupportedEntryTypesReadAsNotAvailable() throws {
        let bare = try XCTUnwrap(DeveloperLiveMetrics(raw: [
            "lcpSupported": false, "lcp": NSNull(), "inpSupported": true, "inp": NSNull(),
            "cls": 0.02, "clsEstimated": true,
        ] as [String: Any]))
        XCTAssertEqual(bare.reading(.lcp), .unavailable)
        XCTAssertEqual(bare.reading(.inp), .waiting)
        XCTAssertEqual(bare.reading(.cls), .value(0.02))
        XCTAssertTrue(bare.clsEstimated)

        let measured = try XCTUnwrap(DeveloperLiveMetrics(raw: [
            "lcpSupported": true, "lcp": 1_800, "lcpElement": "img#hero", "inpSupported": true,
            "inp": ["value": 240, "name": "click", "target": "button#go"], "interactions": 3, "cls": 0,
        ] as [String: Any]))
        XCTAssertEqual(measured.reading(.lcp), .value(1_800))
        XCTAssertEqual(measured.lcpElement, "img#hero")
        XCTAssertEqual(measured.reading(.inp), .value(240))
        XCTAssertEqual(measured.inpEvent, "click")
        XCTAssertEqual(measured.inpTarget, "button#go")
        XCTAssertEqual(measured.interactions, 3)
        XCTAssertEqual(DeveloperLiveMetrics(raw: ["inpSupported": false] as [String: Any])?.reading(.inp), .unavailable)

        XCTAssertNil(DeveloperLiveMetrics(raw: nil))
        XCTAssertNil(DeveloperLiveMetrics(raw: "not a reading"))
    }

    /// Both scripts call the one estimator, and compile as they're sent.
    func testScriptsShareTheLayoutShiftEstimator() {
        let estimator = DeveloperLayoutShiftEstimator.source
        XCTAssertFalse(estimator.isEmpty)
        for script in [DeveloperLiveMetricsModel.script, DeveloperLighthouseModel.observeScript] {
            XCTAssertTrue(script.contains(estimator))
            let context = JSContext()!
            context.setObject(script, forKeyedSubscript: "source" as NSString)
            _ = context.evaluateScript("new Function(source)")
            XCTAssertNil(context.exception, "\(context.exception?.toString() ?? "")")
        }
    }
}
