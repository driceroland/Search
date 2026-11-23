import AppKit
import SwiftUI
import XCTest
@testable import Search

/// Network settings › Capture screenshots: when a screenshot is taken, how
/// many are kept, and what a click on one lists.
@MainActor
final class DeveloperNetworkFilmstripTests: XCTestCase {
    private typealias Filmstrip = DeveloperNetworkFilmstrip

    private func request(_ id: String, start: Double?, end: Double? = nil, wall: Double? = nil,
                         failure: String? = nil) -> DeveloperToolsSession.Request {
        var request = DeveloperToolsSession.Request(id: id, url: "https://example.test/\(id)", method: "GET",
                                                    type: "Script", loader: nil, started: start)
        request.ended = end
        request.wallStarted = wall
        request.failure = failure
        return request
    }

    func testAScreenshotIsDueEveryTenthOfASecondWhileLoading() {
        XCTAssertTrue(Filmstrip.shouldCapture(count: 0, last: nil, now: 5, loading: true), "the first one at once")
        XCTAssertFalse(Filmstrip.shouldCapture(count: 0, last: nil, now: 5, loading: false), "nothing loading: none")
        XCTAssertFalse(Filmstrip.shouldCapture(count: 3, last: 5.0, now: 5.05, loading: true), "too soon")
        XCTAssertTrue(Filmstrip.shouldCapture(count: 3, last: 5.0, now: 5.1, loading: true))
        XCTAssertTrue(Filmstrip.shouldCapture(count: 3, last: 5.0, now: 5.095, loading: true), "a timer a little early")
    }

    func testTheRecordingStopsAtSixtyScreenshots() {
        XCTAssertEqual(Filmstrip.limit, 60)
        XCTAssertTrue(Filmstrip.shouldCapture(count: 59, last: 1, now: 2, loading: true))
        XCTAssertFalse(Filmstrip.shouldCapture(count: 60, last: 1, now: 2, loading: true))
        let filmstrip = Filmstrip()
        let image = NSImage(size: NSSize(width: 4, height: 3))
        for index in 0..<75 { filmstrip.append(image, at: Double(index) / 10) }
        XCTAssertEqual(filmstrip.frames.count, 60, "the cap holds however often they're added")
        XCTAssertEqual(filmstrip.frames.last?.time ?? 0, 5.9, accuracy: 0.0001)
        XCTAssertEqual(Set(filmstrip.frames.map(\.id)).count, 60, "each its own id")
        filmstrip.clear()
        XCTAssertTrue(filmstrip.frames.isEmpty, "Clear empties it")
        filmstrip.append(image, at: 9)
        XCTAssertEqual(filmstrip.frames.count, 1, "and it records again")
    }

    func testLoadingMeansAPendingRequestStartedRecently() {
        let done = request("1", start: 1, end: 2)
        let pending = request("2", start: 3)
        let failed = request("3", start: 3, failure: "Cancelled")
        XCTAssertTrue(Filmstrip.loading([done, pending], now: 4))
        XCTAssertFalse(Filmstrip.loading([done, failed], now: 4))
        XCTAssertFalse(Filmstrip.loading([pending], now: 3 + Filmstrip.staleAfter + 1), "an open stream doesn't keep it going")
        XCTAssertFalse(Filmstrip.loading([], now: 4))
    }

    func testScreenshotsAreTimedOnTheNetworkClock() {
        XCTAssertNil(Filmstrip.clockOffset([request("1", start: 1)]), "no wall time: no clock yet")
        XCTAssertEqual(Filmstrip.clockOffset([request("1", start: 1), request("2", start: 10, wall: 1_000_010)]),
                       1_000_000)
        var redirected = request("3", start: 50, wall: 1_000_000)
        redirected.originalURL = "https://example.test/old"
        XCTAssertEqual(Filmstrip.clockOffset([redirected, request("4", start: 2, wall: 1_000_002)]), 1_000_000,
                       "a redirect keeps its first wall time, so it isn't read")
    }

    func testAClickedScreenshotListsWhatHadFinishedByThen() {
        let rows = [
            request("1", start: 1, end: 1.2),
            request("2", start: 1, end: 1.5),
            request("3", start: 1.1, end: 2),
            request("4", start: 1.2),
        ]
        XCTAssertEqual(Filmstrip.finished(by: 1.5, rows).map(\.id), ["1", "2"], "finished at the moment counts")
        XCTAssertEqual(Filmstrip.finished(by: 1, rows).map(\.id), [])
        XCTAssertEqual(Filmstrip.finished(by: 10, rows).map(\.id), ["1", "2", "3"], "still loading isn't listed")
    }

    func testScreenshotsAreKeptSmall() {
        let image = NSImage(size: NSSize(width: 1_200, height: 800))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 1_200, height: 800).fill()
        image.unlockFocus()
        let scaled = Filmstrip.scaled(image, width: 300)
        XCTAssertEqual(scaled.size.width, 300)
        XCTAssertEqual(scaled.size.height, 200)
        let bitmap = scaled.representations.first as? NSBitmapImageRep
        XCTAssertEqual(bitmap?.pixelsWide, 300)
        XCTAssertEqual(bitmap?.pixelsHigh, 200)
    }

    func testTimeLabelsReadAsTheSummarysDo() {
        XCTAssertEqual(DeveloperNetworkFilmstripView.seconds(120), "120 ms")
        XCTAssertEqual(DeveloperNetworkFilmstripView.seconds(1_500), "1.50 s")
    }
}
