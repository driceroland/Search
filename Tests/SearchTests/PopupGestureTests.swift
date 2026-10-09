import JavaScriptCore
import XCTest
@testable import Search

final class PopupGestureTests: XCTestCase {
    func testLongLivedMenuPreservesFrameAndOneWindowLimit() {
        var permission = PopupGesture()
        permission.record(origin: "iframe", kind: "menu", now: 10)
        XCTAssertFalse(permission.take(origin: "iframe", now: 20))
        permission.menuClosed(now: 20)
        XCTAssertFalse(permission.take(origin: "sibling", now: 20.1))
        XCTAssertTrue(permission.take(origin: "iframe", now: 20.2))
        permission.menuClosed(now: 21)
        XCTAssertFalse(permission.take(origin: "iframe", now: 21.1))
    }

    func testMenuCannotCreateOrRearmAGesture() {
        var permission = PopupGesture()
        permission.menuClosed(now: 10)
        XCTAssertFalse(permission.take(origin: "same", now: 10.1))
        permission.record(origin: "same", kind: "input", now: 10)
        permission.menuClosed(now: 20)
        XCTAssertFalse(permission.take(origin: "same", now: 20.1))
        permission.record(origin: "same", kind: "input", now: 11)
        XCTAssertTrue(permission.take(origin: "same", now: 11.1))
        permission.record(origin: "same", kind: "menu", now: 11.2)
        permission.menuClosed(now: 20)
        XCTAssertFalse(permission.take(origin: "same", now: 20.1))
        permission.record(origin: "same", kind: "menu", now: 21)
        permission.clear()
        permission.menuClosed(now: 22)
        XCTAssertFalse(permission.take(origin: "same", now: 22.1))
    }

    func testAsyncRequestCanOpenOnceWithinActivationWindow() {
        var permission = PopupGesture()
        XCTAssertFalse(permission.take(origin: "https://example.com:443", now: 10))
        permission.record(origin: "https://example.com:443", kind: "input", now: 10)
        XCTAssertTrue(permission.take(origin: "https://example.com:443", now: 12))
        XCTAssertFalse(permission.take(origin: "https://example.com:443", now: 12.1))
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

    func testOpaqueOriginsCannotAuthorizeEachOther() {
        var permission = PopupGesture()
        permission.record(origin: nil, kind: "input", now: 10)
        XCTAssertFalse(permission.take(origin: nil, now: 11), "another opaque frame has no matching origin")
        XCTAssertFalse(permission.take(origin: "https://ads.example:443", now: 11))
        XCTAssertTrue(permission.take(origin: "https://parent.example:443", mainFrame: true, now: 12))
        XCTAssertFalse(permission.take(origin: nil, mainFrame: true, now: 12.1))
    }

    func testOpaqueMainFrameCanUseItsOwnGestureOnce() {
        var permission = PopupGesture()
        permission.record(origin: nil, kind: "click", now: 10)
        XCTAssertTrue(permission.take(origin: nil, mainFrame: true, now: 12))
        XCTAssertFalse(permission.take(origin: nil, mainFrame: true, now: 12.1))
    }

    func testEmptyOriginComponentsNeverMakeASharedKey() {
        XCTAssertNil(PopupGesture.originKey(scheme: "", host: "", port: 0))
        XCTAssertNil(PopupGesture.originKey(scheme: "data", host: "", port: 0))
        XCTAssertNil(PopupGesture.originKey(scheme: "file", host: "", port: 0))
        XCTAssertEqual(PopupGesture.originKey(scheme: "https", host: "example.com", port: 443), "https://example.com:443")
        XCTAssertNotEqual(PopupGesture.originKey(scheme: "http", host: "example.com", port: 80),
                          PopupGesture.originKey(scheme: "http", host: "example.com", port: 8080))
    }

    func testDelayedClickDoesNotRearmConsumedMousedown() {
        for delay in [1.01, 2, 4.99, 5] {
            var permission = PopupGesture()
            permission.record(origin: "same", kind: "input", now: 10)
            XCTAssertTrue(permission.take(origin: "same", now: 10.01))
            permission.record(origin: "same", kind: "click", now: 10 + delay)
            XCTAssertFalse(permission.take(origin: "same", now: 10 + delay))
        }
    }

    func testDelayedClickDoesNotExtendUnusedMousedown() {
        var permission = PopupGesture()
        permission.record(origin: "same", kind: "input", now: 10)
        permission.record(origin: "same", kind: "click", now: 14.9)
        XCTAssertFalse(permission.take(origin: "same", now: 15.01))
        permission.record(origin: "same", kind: "click", now: 15.1)
        XCTAssertTrue(permission.take(origin: "same", now: 15.2), "a later assistive click is still supported")
    }

    func testRepeatedAdRequestsCannotStealOrRearmPageGesture() {
        var permission = PopupGesture()
        permission.record(origin: "page", kind: "input", now: 10)
        for offset in 1...20 {
            XCTAssertFalse(permission.take(origin: "ad", now: 10 + Double(offset) / 10))
        }
        XCTAssertTrue(permission.take(origin: "page", mainFrame: true, now: 12))
        XCTAssertFalse(permission.take(origin: "page", mainFrame: true, now: 12.1))
    }

    func testNavigationRevokesGestureBeforeUnloadAndMenuClose() {
        var permission = PopupGesture()
        permission.record(origin: "same", kind: "menu", now: 10)
        permission.clear() // The main-frame policy clears before answering .allow.
        XCTAssertFalse(permission.take(origin: "same", mainFrame: true, now: 10.1))
        permission.menuClosed(now: 20)
        XCTAssertFalse(permission.take(origin: "same", mainFrame: true, now: 20.1))
    }

    func testRelayIgnoresRepeatedKeysAndSyntheticEvents() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var sent = [], listeners = {};
        var window = { webkit: { messageHandlers: { officePopupGesture: {
          postMessage: function (kind) { sent.push(kind); }
        } } } };
        function addEventListener(type, callback) { listeners[type] = callback; }
        function key(name, repeat, trusted) {
          listeners.keydown({ type: 'keydown', key: name, repeat: repeat, isTrusted: trusted });
        }
        """)
        context.evaluateScript(PopupGestureRelay.script)
        context.evaluateScript("""
        key('Enter', false, true); key('Enter', true, true); key('Enter', true, true);
        listeners.click({ type: 'click', isTrusted: true, detail: 0 });
        """)
        XCTAssertEqual(context.evaluateScript("JSON.stringify(sent)")?.toString(), "[\"input\"]")
        context.evaluateScript("""
        key('Escape', false, true); key('Shift', false, true); key('Enter', false, false);
        listeners.click({ type: 'click', isTrusted: false });
        listeners.mousedown({ type: 'mousedown', isTrusted: false });
        listeners.contextmenu({ type: 'contextmenu', isTrusted: false });
        """)
        XCTAssertEqual(context.evaluateScript("sent.length")?.toInt32(), 1)
        context.evaluateScript("""
        listeners.keyup({ type: 'keyup', key: 'Enter', isTrusted: true });
        listeners.click({ type: 'click', isTrusted: true, detail: 0 });
        """)
        XCTAssertEqual(context.evaluateScript("JSON.stringify(sent)")?.toString(), "[\"input\",\"click\"]")
        XCTAssertNil(context.exception)
    }

}
