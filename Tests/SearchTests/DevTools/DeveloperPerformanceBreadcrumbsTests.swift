import XCTest
@testable import Search

/// Performance's breadcrumbs: zooming in adds one, clicking returns to
/// it, and a new recording clears them.
final class DeveloperPerformanceBreadcrumbsTests: XCTestCase {
    private func window(_ lower: Double, _ upper: Double) -> DeveloperFlameWindow {
        DeveloperFlameWindow(lower: lower, upper: upper)
    }

    func testZoomingInPushesABreadcrumbLabelledWithItsSpan() {
        var crumbs = DeveloperPerformanceBreadcrumbs(0...1_200)
        XCTAssertEqual(crumbs.crumbs.count, 1)
        XCTAssertEqual(crumbs.label(0), "Full range (1.2 s)")
        crumbs.push(window(100, 480))
        crumbs.push(window(200, 300))
        XCTAssertEqual(crumbs.crumbs.count, 3)
        XCTAssertEqual(crumbs.active, 2)
        XCTAssertEqual((0..<3).map { crumbs.label($0) }, ["Full range (1.2 s)", "380 ms", "100 ms"])
    }

    func testTheSameOrTheFullRangeAddsNothing() {
        var crumbs = DeveloperPerformanceBreadcrumbs(0...1_000)
        crumbs.push(window(0, 1_000))
        XCTAssertEqual(crumbs.crumbs.count, 1)
        crumbs.push(window(10, 20))
        crumbs.push(window(10, 20))
        XCTAssertEqual(crumbs.crumbs.count, 2)
    }

    func testClickingABreadcrumbReturnsToItsRangeAndANewZoomReplacesWhatFollowed() {
        var crumbs = DeveloperPerformanceBreadcrumbs(0...1_000)
        crumbs.push(window(100, 500))
        crumbs.push(window(200, 300))
        XCTAssertEqual(crumbs.select(1), window(100, 500))
        XCTAssertEqual(crumbs.active, 1)
        XCTAssertEqual(crumbs.crumbs.count, 3, "the later breadcrumb stays until another zoom")
        crumbs.push(window(400, 450))
        XCTAssertEqual(crumbs.crumbs, [window(0, 1_000), window(100, 500), window(400, 450)])
        XCTAssertEqual(crumbs.select(9), window(400, 450), "an unknown breadcrumb keeps the one shown")
    }

    func testARangeOutsideTheBreadcrumbShownGoesUnderTheOneAroundIt() {
        var crumbs = DeveloperPerformanceBreadcrumbs(0...1_000)
        crumbs.push(window(100, 200))
        crumbs.push(window(150, 160))
        crumbs.push(window(600, 900))
        XCTAssertEqual(crumbs.crumbs, [window(0, 1_000), window(600, 900)])
        XCTAssertEqual(crumbs.active, 1)
    }

    func testANewRecordingClearsThem() {
        var crumbs = DeveloperPerformanceBreadcrumbs(0...1_000)
        crumbs.push(window(100, 200))
        crumbs.reset(0...500)
        XCTAssertEqual(crumbs.crumbs, [window(0, 500)])
        XCTAssertEqual(crumbs.active, 0)
        XCTAssertEqual(crumbs.label(0), "Full range (500 ms)")
    }
}
