import XCTest
@testable import Search

/// Idea 797: what an app on the Mac says to an extension waits for the
/// extension to speak on the port, and never goes to a port that has gone.
@MainActor
final class PortRelayTests: XCTestCase {
    func testHeldUntilTheExtensionSpeaksThenInOrder() {
        var sent: [Int] = []
        let relay = PortRelay(send: { sent.append($0 as! Int) }, gone: { false })
        relay.fromApp(1)
        relay.fromApp(2)
        XCTAssertEqual(sent, [])
        XCTAssertEqual(relay.holding, 2)
        relay.heard()
        XCTAssertEqual(sent, [1, 2])
        relay.fromApp(3)
        XCTAssertEqual(sent, [1, 2, 3])
        relay.heard()
        XCTAssertEqual(sent, [1, 2, 3])
    }

    func testTheGraceOpensItWithoutAWord() {
        var sent: [Int] = []
        let relay = PortRelay(send: { sent.append($0 as! Int) }, gone: { false })
        relay.fromApp(1)
        relay.open()
        XCTAssertEqual(sent, [1])
        XCTAssertTrue(relay.isOpen)
    }

    func testNothingGoesToAPortThatHasGone() {
        var sent: [Int] = []
        var gone = false
        let relay = PortRelay(send: { sent.append($0 as! Int) }, gone: { gone })
        relay.fromApp(1)
        gone = true
        relay.heard()
        XCTAssertEqual(sent, [])
        XCTAssertTrue(relay.closed)
        gone = false
        relay.fromApp(2)
        XCTAssertEqual(sent, [])
    }

    func testGoneHalfwayStopsTheRest() {
        var sent: [Int] = []
        var gone = false
        let relay = PortRelay(send: { sent.append($0 as! Int); if sent.count == 2 { gone = true } }, gone: { gone })
        (1...4).forEach { relay.fromApp($0) }
        relay.open()
        XCTAssertEqual(sent, [1, 2])
        XCTAssertTrue(relay.closed)
    }

    func testClosedDropsWhatWaitsAndWhatComes() {
        var sent: [Int] = []
        let relay = PortRelay(send: { sent.append($0 as! Int) }, gone: { false })
        relay.fromApp(1)
        relay.close()
        relay.open()
        relay.fromApp(2)
        XCTAssertEqual(sent, [])
        XCTAssertEqual(relay.holding, 0)
    }

    func testTooMuchUnaskedGoesRatherThanPilingUp() {
        var count = 0
        let relay = PortRelay(send: { _ in count += 1 }, gone: { false })
        for i in 0..<PortRelay.cap { relay.fromApp(i) }
        XCTAssertEqual(count, PortRelay.cap)
        XCTAssertTrue(relay.isOpen)
    }
}
