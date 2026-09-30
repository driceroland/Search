import XCTest
@testable import Search

final class PopupGestureTests: XCTestCase {
    func testAsyncRequestCanOpenOnceWithinActivationWindow() {
        var permission = PopupGesture()
        XCTAssertFalse(permission.take(origin: "https://example.com:443", now: 10))
        permission.record(origin: "https://example.com:443", kind: "input", now: 10)
        XCTAssertTrue(permission.take(origin: "https://example.com:443", now: 10.421))
        XCTAssertFalse(permission.take(origin: "https://example.com:443", now: 10.422))
    }

    func testClickDoesNotRearmConsumedMousedown() {
        var permission = PopupGesture()
        permission.record(origin: "same", kind: "input", now: 10)
        XCTAssertTrue(permission.take(origin: "same", now: 10.01))
        permission.record(origin: "same", kind: "click", now: 10.1)
        XCTAssertFalse(permission.take(origin: "same", now: 10.2))
        permission.record(origin: "same", kind: "input", now: 10.3)
        XCTAssertTrue(permission.take(origin: "same", now: 10.4))
    }

    func testUnrelatedFrameExpiredGestureAndNewDocumentCannotOpen() {
        var permission = PopupGesture()
        permission.record(origin: "first", kind: "input", now: 10)
        XCTAssertFalse(permission.take(origin: "third-party", now: 11))
        XCTAssertFalse(permission.take(origin: "first", now: 15.01))
        permission.record(origin: "first", kind: "input", now: 20)
        permission.clear()
        XCTAssertFalse(permission.take(origin: "first", now: 20.1))
    }

    func testAssistiveClickCanOpenWithoutMousedown() {
        var permission = PopupGesture()
        permission.record(origin: "same", kind: "click", now: 10)
        XCTAssertTrue(permission.take(origin: "same", now: 10.1))
        permission.record(origin: "same", kind: "click", now: 10.2)
        XCTAssertTrue(permission.take(origin: "same", now: 10.3))
    }

    func testIframeInteractionAlsoActivatesItsTopLevelPage() {
        var permission = PopupGesture()
        permission.record(origin: "iframe", kind: "input", now: 10)
        XCTAssertFalse(permission.take(origin: "sibling", now: 10.1))
        XCTAssertTrue(permission.take(origin: "parent", mainFrame: true, now: 10.2))
        XCTAssertFalse(permission.take(origin: "iframe", now: 10.3))
    }
}
