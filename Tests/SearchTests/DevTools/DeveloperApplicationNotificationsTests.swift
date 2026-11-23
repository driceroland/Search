import Foundation
import JavaScriptCore
import XCTest
@testable import Search

/// Background services › Notifications: the events the page-world hooks
/// log, read into the table, and the hooks themselves, which put the
/// page's globals back when recording stops.
@MainActor
final class DeveloperApplicationNotificationsTests: XCTestCase {
    func testEventsParseWithTheirMetadataAndSkipNamelessOnes() {
        let raw: [Any] = [
            ["time": 1_700_000_000_000, "event": "Notification displayed", "origin": "https://example.com",
             "title": "Hello", "details": [["source", "new Notification()"], ["body", "World"], ["broken"]]],
            ["time": 1_700_000_001_000, "event": "Permission requested", "origin": "https://example.com", "title": "",
             "details": [["permission", "default"]]],
            ["time": 1, "origin": "https://example.com"],
            "not an event",
        ]
        let events = DeveloperNotificationEvent.parse(raw, first: 5)
        XCTAssertEqual(events.map(\.name), ["Notification displayed", "Permission requested"])
        XCTAssertEqual(events.map(\.id), [5, 6])
        XCTAssertEqual(events[0].title, "Hello")
        XCTAssertEqual(events[0].origin, "https://example.com")
        XCTAssertEqual(events[0].time, 1_700_000_000_000)
        XCTAssertEqual(events[0].details, [["source", "new Notification()"], ["body", "World"]])
        XCTAssertEqual(events[1].details, [["permission", "default"]])
    }

    func testSavedEventsAreJSON() throws {
        let events = DeveloperNotificationEvent.parse([
            ["time": 2000, "event": "Notification clicked", "origin": "https://example.com", "title": "Hi",
             "details": [["tag", "a"]]],
        ])
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: DeveloperNotificationEvent.export(events)) as? [[String: Any]])
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0]["eventName"] as? String, "Notification clicked")
        XCTAssertEqual(saved[0]["timestamp"] as? Double, 2)
        XCTAssertEqual((saved[0]["eventMetadata"] as? [[String: String]])?.first, ["key": "tag", "value": "a"])
    }

    func testTheHooksLogAndStoppingPutsThePagesGlobalsBack() throws {
        let context = try XCTUnwrap(JSContext())
        _ = context.evaluateScript("""
            var window = globalThis;
            var location = { origin: 'https://example.com' };
            // As a page's interface objects are: writable, configurable globals.
            Object.defineProperty(globalThis, 'Notification', { writable: true, configurable: true,
                value: class { constructor(title, options) { this.title = title; } } });
            Notification.permission = 'default';
            Notification.requestPermission = function () { return { then() {} }; };
            var NativeNotification = Notification;
            var nativeRequest = Notification.requestPermission;
            Object.defineProperty(globalThis, 'ServiceWorkerRegistration', { writable: true, configurable: true,
                value: class { get scope() { return 'https://example.com/'; } } });
            ServiceWorkerRegistration.prototype.showNotification = function () { return 'shown'; };
            var nativeShow = ServiceWorkerRegistration.prototype.showNotification;
            """)
        context.setObject(DeveloperNotificationRecorder.script, forKeyedSubscript: "source" as NSString)
        _ = context.evaluateScript("var hooks = eval('(' + source + '\\n)');")
        XCTAssertNil(context.exception)
        @discardableResult func run(_ script: String) -> JSValue? { context.evaluateScript(script) }

        XCTAssertEqual(run("hooks('start', 'perch.test').recording")?.toBool(), true)
        XCTAssertEqual(run("Object.getOwnPropertyDescriptor(window, Symbol.for('perch.test')).enumerable")?.toBool(), false)
        XCTAssertEqual(run("window.Notification === NativeNotification")?.toBool(), false)
        run("new Notification('Hi', { body: 'There', tag: 't1' });")
        run("Notification.requestPermission();")
        run("new ServiceWorkerRegistration().showNotification('From worker', { body: 'b' });")
        XCTAssertNil(context.exception)

        let read = try XCTUnwrap(run("JSON.stringify(hooks('read', 'perch.test').events)")?.toString())
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(read.utf8)) as? [Any])
        let events = DeveloperNotificationEvent.parse(raw)
        XCTAssertEqual(events.map(\.name), ["Notification displayed", "Permission requested", "Notification displayed"])
        XCTAssertEqual(events.map(\.title), ["Hi", "", "From worker"])
        XCTAssertEqual(events.first?.origin, "https://example.com")
        XCTAssertTrue(events[0].details.contains(["body", "There"]))
        XCTAssertTrue(events[0].details.contains(["tag", "t1"]))
        XCTAssertTrue(events[1].details.contains(["permission", "default"]))
        XCTAssertTrue(events[2].details.contains(["scope", "https://example.com/"]))

        XCTAssertEqual(run("hooks('clear', 'perch.test').events.length")?.toInt32(), 0)
        XCTAssertEqual(run("hooks('stop', 'perch.test').recording")?.toBool(), false)
        XCTAssertEqual(run("window.Notification === NativeNotification")?.toBool(), true)
        XCTAssertEqual(run("Notification.requestPermission === nativeRequest")?.toBool(), true)
        XCTAssertEqual(run("ServiceWorkerRegistration.prototype.showNotification === nativeShow")?.toBool(), true)
        XCTAssertEqual(run("Symbol.for('perch.test') in window")?.toBool(), false)
        run("new Notification('After');")
        XCTAssertEqual(run("hooks('read', 'perch.test').events.length")?.toInt32(), 0)
        XCTAssertNil(context.exception)
    }
}
