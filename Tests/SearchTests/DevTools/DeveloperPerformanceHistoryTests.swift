import XCTest
@testable import Search

/// Performance's recording history and entries links: the session's last
/// recordings, and an arrow between two entries kept in a saved trace.
final class DeveloperPerformanceHistoryTests: XCTestCase {
    private typealias Timing = DeveloperToolsSession.Timing
    private typealias Annotation = DeveloperPerformanceAnnotation

    private func recording(_ length: Double = 0.01) -> [Timing] {
        [Timing(type: "TimerFire", start: 1, end: 1 + length), Timing(type: "Layout", start: 1.001, end: 1.002, depth: 1)]
    }

    func testRecordingsGoNewestFirstUpToChromesLimit() {
        var history = DeveloperPerformanceRecordings()
        let recordings = (0..<7).map { _ in recording() }
        for timings in recordings { history.add(timings, annotations: [], url: "https://example.com/") }
        XCTAssertEqual(history.entries.count, DeveloperPerformanceRecordings.limit)
        XCTAssertEqual(history.entries.first?.id, DeveloperPerformanceRecordings.key(recordings[6]))
        XCTAssertFalse(history.contains(DeveloperPerformanceRecordings.key(recordings[0])), "the oldest went")
    }

    func testARecordingShownAgainIsntAddedTwice() {
        var history = DeveloperPerformanceRecordings()
        let first = recording(), second = recording()
        history.add(first, annotations: [], url: nil)
        history.add(second, annotations: [], url: nil)
        history.add(first, annotations: [], url: nil)
        XCTAssertEqual(history.entries.map(\.id), [second, first].map(DeveloperPerformanceRecordings.key))
        history.add([], annotations: [], url: nil)
        XCTAssertEqual(history.entries.count, 2, "nothing recorded, nothing kept")
    }

    func testEachRecordingKeepsItsAnnotations() {
        var history = DeveloperPerformanceRecordings()
        let timings = recording()
        history.add(timings, annotations: [], url: nil)
        let label = Annotation(label: "Slow", range: 0...5)
        history.update(DeveloperPerformanceRecordings.key(timings), annotations: [label])
        XCTAssertEqual(history.entries.first?.annotations, [label])
        XCTAssertEqual(history.entries.first?.duration ?? 0, 10, accuracy: 1e-6)
        history.clear()
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testALinkSpansBothEntriesAndFindsThemAgain() throws {
        let profile = DeveloperPerformanceProfile(recording())
        let timer = try XCTUnwrap(profile.shown.first { $0.type == "TimerFire" })
        let layout = try XCTUnwrap(profile.shown.first { $0.type == "Layout" })
        let link = Annotation.linking(.init(name: layout.title, range: layout.start...layout.end),
                                      to: .init(name: timer.title, range: timer.start...timer.end))
        XCTAssertEqual(link.label, "Layout → Timer fired")
        XCTAssertEqual(link.range.lowerBound, timer.start, accuracy: 1e-9)
        XCTAssertEqual(link.range.upperBound, timer.end, accuracy: 1e-9)
        let ends = try XCTUnwrap(link.link)
        XCTAssertEqual(Annotation.find(ends.from, in: profile.shown)?.id, layout.id)
        XCTAssertEqual(Annotation.find(ends.to, in: profile.shown)?.id, timer.id)
        XCTAssertNil(Annotation.find(.init(name: "Paint", range: timer.start...timer.end), in: profile.shown))
    }

    func testALinkRoundTripsThroughASavedTrace() throws {
        let timings = recording()
        let link = Annotation.linking(.init(name: "Timer fired", range: 0...10), to: .init(name: "Layout", range: 1...2))
        let label = Annotation(label: "Plain", range: 3...4)
        let loaded = try DeveloperPerformanceTrace.recording(from: DeveloperPerformanceTrace.export(timings, annotations: [link, label]))
        XCTAssertEqual(loaded.annotations.count, 2)
        let back = try XCTUnwrap(loaded.annotations.first { $0.id == link.id })
        let ends = try XCTUnwrap(back.link)
        XCTAssertEqual(ends.from.name, "Timer fired")
        XCTAssertEqual(ends.to.name, "Layout")
        XCTAssertEqual(ends.to.range.lowerBound, 1, accuracy: 1e-9)
        XCTAssertEqual(ends.to.range.upperBound, 2, accuracy: 1e-9)
        XCTAssertNil(loaded.annotations.first { $0.id == label.id }?.link)
    }
}
