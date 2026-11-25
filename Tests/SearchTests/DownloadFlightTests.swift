import XCTest
@testable import Search

final class DownloadFlightTests: XCTestCase {
    private let click = CGPoint(x: 600, y: 300)
    /// The downloads button at the column's foot.
    private let foot = CGPoint(x: 80, y: 760)
    /// The downloads button in the strip across the top.
    private let strip = CGPoint(x: 1180, y: 26)

    func testTheFlightStartsAtTheClickAndEndsAtTheButton() {
        let start = DownloadFlight.point(from: click, to: foot, at: 0)
        let end = DownloadFlight.point(from: click, to: foot, at: 1)
        XCTAssertEqual(start.x, click.x, accuracy: 0.001)
        XCTAssertEqual(start.y, click.y, accuracy: 0.001)
        XCTAssertEqual(end.x, foot.x, accuracy: 0.001)
        XCTAssertEqual(end.y, foot.y, accuracy: 0.001)
    }

    func testItRisesTheLiftAboveTheHigherEndAndNoFurther() {
        let highest = stride(from: 0.0, through: 1.0, by: 0.001)
            .map { DownloadFlight.point(from: click, to: foot, at: CGFloat($0)).y }
            .min() ?? .infinity
        XCTAssertEqual(highest, click.y - DownloadFlight.lift, accuracy: 0.5)
    }

    func testToTheStripItNeverLeavesTheWindowsTop() {
        let highest = stride(from: 0.0, through: 1.0, by: 0.001)
            .map { DownloadFlight.point(from: click, to: strip, at: CGFloat($0)).y }
            .min() ?? -.infinity
        XCTAssertGreaterThanOrEqual(highest, DownloadFlight.roof - 0.5)
    }

    func testItSwellsMidFlightAndLandsAtHalfItsSize() {
        XCTAssertEqual(DownloadFlight.scale(at: 0), 1, accuracy: 0.001)
        XCTAssertGreaterThan(DownloadFlight.scale(at: 0.4), 1.2)
        XCTAssertEqual(DownloadFlight.scale(at: 1), DownloadFlight.landing, accuracy: 0.001)
    }

    func testItFadesInAsItLiftsOffAndOutAsItLands() {
        XCTAssertEqual(DownloadFlight.opacity(at: 0), 0, accuracy: 0.001)
        XCTAssertEqual(DownloadFlight.opacity(at: DownloadFlight.fadeIn), 1, accuracy: 0.001)
        XCTAssertEqual(DownloadFlight.opacity(at: 0.5), 1, accuracy: 0.001)
        XCTAssertEqual(DownloadFlight.opacity(at: 1), 0, accuracy: 0.001)
    }

    func testItsOffUnlessTurnedOn() {
        let suite = "DownloadFlightTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        XCTAssertFalse(store.bool(forKey: "motion.downloads"))
    }
}
