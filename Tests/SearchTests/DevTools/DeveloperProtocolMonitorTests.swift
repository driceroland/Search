import XCTest
@testable import Search

/// The Protocol monitor's log: capped, answered in place, filtered as
/// Chrome's filter reads, and idle while no monitor is shown.
@MainActor
final class DeveloperProtocolMonitorTests: XCTestCase {
    func testIdleUntilShownAndRecording() {
        let monitor = DeveloperProtocolMonitor()
        XCTAssertFalse(monitor.isActive)
        monitor.viewerOpened()
        XCTAssertTrue(monitor.isActive)
        monitor.recording = false
        XCTAssertFalse(monitor.isActive)
        monitor.recording = true
        monitor.viewerClosed()
        XCTAssertFalse(monitor.isActive)
    }

    func testCapsRowsDroppingTheOldest() {
        let monitor = DeveloperProtocolMonitor(limit: 5)
        var ids: [Int] = []
        for index in 0..<8 { ids.append(monitor.sent("Runtime.evaluate", params: ["n": index], target: nil)) }
        XCTAssertEqual(monitor.entries.count, 5)
        XCTAssertEqual(monitor.entries.first?.params, "{\"n\":3}")
        // An answer to a dropped command changes nothing; a kept one is answered in place.
        monitor.answered(ids[0], response: ["x": 1])
        monitor.answered(ids[6], response: ["result": ["type": "number"]])
        XCTAssertEqual(monitor.entries.first { $0.id == ids[6] }?.response, "{\"result\":{\"type\":\"number\"}}")
        XCTAssertNotNil(monitor.entries.first { $0.id == ids[6] }?.elapsed)
        XCTAssertNil(monitor.entries.first { $0.id == ids[7] }?.elapsed)

        monitor.received((0..<9).map { ["method": "Console.messageAdded", "params": ["i": $0], "targetId": "page-1"] })
        XCTAssertEqual(monitor.entries.count, 5)
        XCTAssertTrue(monitor.entries.allSatisfy { $0.direction == .received })
        XCTAssertEqual(monitor.entries.last?.params, "{\"i\":8}")
        XCTAssertEqual(monitor.entries.last?.target, "page-1")
        monitor.failed(ids[7], error: "gone")
        XCTAssertFalse(monitor.entries.contains { $0.error != nil })

        monitor.clear()
        XCTAssertTrue(monitor.entries.isEmpty)
    }

    func testFailureIsRecorded() {
        let monitor = DeveloperProtocolMonitor()
        let id = monitor.sent("DOM.getDocument", params: [:], target: "frame-2")
        monitor.failed(id, error: "WebKit does not support DOM.getDocument on this target.")
        XCTAssertEqual(monitor.entries.first?.error, "WebKit does not support DOM.getDocument on this target.")
        XCTAssertEqual(monitor.entries.first?.params, "{}")
    }

    func testFilter() {
        let monitor = DeveloperProtocolMonitor()
        _ = monitor.sent("Runtime.evaluate", params: ["expression": "1 + 1"], target: nil)
        _ = monitor.sent("DOM.getDocument", params: [:], target: "frame-2")
        monitor.received([["method": "DOM.childNodeInserted", "params": ["parentNodeId": 4]]])
        let all = monitor.entries
        XCTAssertEqual(DeveloperProtocolMonitor.filter(all, "").count, 3)
        XCTAssertEqual(DeveloperProtocolMonitor.filter(all, "dom").map(\.method), ["DOM.getDocument", "DOM.childNodeInserted"])
        XCTAssertEqual(DeveloperProtocolMonitor.filter(all, "dom type:sent").map(\.method), ["DOM.getDocument"])
        XCTAssertEqual(DeveloperProtocolMonitor.filter(all, "type:received").map(\.method), ["DOM.childNodeInserted"])
        XCTAssertEqual(DeveloperProtocolMonitor.filter(all, "-dom").map(\.method), ["Runtime.evaluate"])
        XCTAssertEqual(DeveloperProtocolMonitor.filter(all, "target:main").map(\.method), ["Runtime.evaluate", "DOM.childNodeInserted"])
        XCTAssertEqual(DeveloperProtocolMonitor.filter(all, "target:frame").map(\.method), ["DOM.getDocument"])
        XCTAssertEqual(DeveloperProtocolMonitor.filter(all, "method:evaluate").count, 1)
        XCTAssertEqual(DeveloperProtocolMonitor.filter(all, "parentNodeId").map(\.method), ["DOM.childNodeInserted"])
    }

    func testRawCommandParameters() {
        XCTAssertEqual(DeveloperProtocolMonitor.parameters("  ")?.count, 0)
        XCTAssertEqual(DeveloperProtocolMonitor.parameters("{\"expression\": \"1\"}")?["expression"] as? String, "1")
        XCTAssertNil(DeveloperProtocolMonitor.parameters("[1]"))
        XCTAssertNil(DeveloperProtocolMonitor.parameters("{oops"))
    }
}

@MainActor
final class DeveloperProtocolMonitorColumnTests: XCTestCase {
    /// Timestamp goes first, then Elapsed time, as the table narrows; at
    /// its narrowest (260) Method keeps its room.
    func testColumnsGiveWayInANarrowTable() {
        typealias Column = DeveloperProtocolMonitorView.Column
        XCTAssertTrue(Column.shown(900).elapsed)
        XCTAssertTrue(Column.shown(900).time)
        XCTAssertFalse(Column.shown(260).time)
        XCTAssertFalse(Column.shown(260).elapsed)
        let middle = (1...900).map(CGFloat.init).first { Column.shown($0).elapsed && !Column.shown($0).time }
        XCTAssertNotNil(middle, "Elapsed time stays a while after Timestamp goes")
    }
}
