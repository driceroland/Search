import XCTest
@testable import Search

/// A Performance recording's records: what was over before the recording
/// started doesn't set its zero.
final class DeveloperPerformanceRecordingTests: XCTestCase {
    private typealias Timing = DeveloperToolsSession.Timing

    func testRecordsOverBeforeTheRecordingAreLeftOut() {
        let records = [
            Timing(type: "Paint", start: 100, end: 100.01),
            Timing(type: "Layout", start: 55, end: 115.2),
            Timing(type: "EvaluateScript", start: 115.3, end: 115.4),
        ]
        let kept = DeveloperToolsSession.withinRecording(records, from: 115)
        XCTAssertEqual(kept.map(\.type), ["Layout", "EvaluateScript"])
        let profile = DeveloperPerformanceProfile(kept + [Timing(type: "RecordingBounds", start: 115, end: 117)])
        // Zero is the recording's start: the Layout running across it is
        // cut there, and the Paint from 15 s before is gone.
        XCTAssertEqual(kept[0].start, 115)
        XCTAssertEqual(profile.duration, 2_000, accuracy: 0.001)
    }
}

/// Performance's own screenshots go on the timeline through the page's clock.
final class DeveloperPerformanceScreenshotTimingTests: XCTestCase {
    func testAScreenshotIsTimedThroughThePageClock() {
        let pageDate = Date(timeIntervalSince1970: 1_000)
        // The page answered 2 000 ms on its clock at pageDate; its 1 500 ms
        // was 50.0 s on the timeline.
        let images = [(time: pageDate.addingTimeInterval(-0.2), jpeg: "AAA"),
                      (time: pageDate.addingTimeInterval(-5), jpeg: "BBB")]
        let shots = DeveloperPerformancePageTimings.screenshots(images, pageNow: 2_000, pageDate: pageDate,
                                                                sync: (page: 1_500, timeline: 50), bounds: 49...52)
        XCTAssertEqual(shots.count, 1, "the one taken before the recording is left out")
        XCTAssertEqual(shots[0].start, 50.3, accuracy: 0.000_1)
        XCTAssertEqual(shots[0].data["imageData"], "data:image/jpeg;base64,AAA")
    }
}
