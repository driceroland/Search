import AppKit
import Foundation
import XCTest
@testable import Search

@available(macOS 15.4, *)
@MainActor
@available(macOS 14, *)
final class ExtensionUpdateTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testUpdatePermissionDefersWithoutWindowAndReturnCancelsRetry() async throws {
        _ = NSApplication.shared
        let extensions = Extensions.shared
        XCTAssertNil(extensions.answerForTests)
        XCTAssertFalse(NSApp.windows.contains { $0.isVisible && $0.canBecomeMain })
        let deferred = await extensions.ask(install: "Synthetic update", wants: ["Read history"], icon: nil, updating: true)
        XCTAssertFalse(deferred)

        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        defer { window.close() }
        let retry = Task { await extensions.ask(install: "Synthetic update", wants: ["Read history"], icon: nil, updating: true) }
        for _ in 0..<100 {
            if window.attachedSheet != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let sheet = try XCTUnwrap(window.attachedSheet)
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        let controls = buttons(in: try XCTUnwrap(sheet.contentView))
        let cancel = try XCTUnwrap(controls.first { $0.title == "Cancel" })
        let confirm = try XCTUnwrap(controls.first { $0.title == "Add Extension" })
        XCTAssertTrue(sheet.defaultButtonCell === cancel.cell, "Return must cancel the update")
        XCTAssertEqual(confirm.keyEquivalent, "")
        cancel.performClick(nil)
        let accepted = await retry.value
        XCTAssertFalse(accepted)
    }

    func testRecentStartupStillSchedulesLaterChecks() throws {
        _ = NSApplication.shared
        let extensions = Extensions.shared
        XCTAssertTrue(extensions.installed.isEmpty, "This test must never update real extensions")
        guard extensions.installed.isEmpty else { return }
        let key = Extensions.checkedKey
        let kept = [key, Extensions.retryKey, Extensions.failuresKey].map { ($0, Store.settings.object(forKey: $0)) }
        defer {
            for (name, value) in kept {
                if let value { Store.settings.set(value, forKey: name) } else { Store.settings.removeObject(forKey: name) }
            }
        }
        Store.settings.removeObject(forKey: Extensions.retryKey)
        Store.settings.removeObject(forKey: Extensions.failuresKey)
        let recent = Date()
        Store.settings.set(recent, forKey: key)
        extensions.checkForUpdates()
        let timer = try XCTUnwrap(extensions.updateClock)
        XCTAssertTrue(timer.isValid)
        XCTAssertEqual(timer.timeInterval, 3600)
        XCTAssertEqual(Store.settings.object(forKey: key) as? Date, recent)
        extensions.checkForUpdates()
        XCTAssertTrue(extensions.updateClock === timer)

        // Fire the real timer after a simulated day asleep, without waiting a day.
        Store.settings.set(Date().addingTimeInterval(-86400), forKey: key)
        timer.fire()
        let checked = try XCTUnwrap(Store.settings.object(forKey: key) as? Date)
        XCTAssertLessThan(abs(checked.timeIntervalSinceNow), 2)
        timer.fire()
        XCTAssertEqual(Store.settings.object(forKey: key) as? Date, checked)
        XCTAssertTrue(timer.isValid)
    }

    func testFailedCheckRetriesSoonerThenBacksOffToADay() {
        XCTAssertEqual(Extensions.retryDelay(failures: 1), 3600)
        XCTAssertEqual(Extensions.retryDelay(failures: 2), 7200)
        XCTAssertEqual(Extensions.retryDelay(failures: 3), 4 * 3600)
        XCTAssertEqual(Extensions.retryDelay(failures: 5), 16 * 3600)
        XCTAssertEqual(Extensions.retryDelay(failures: 6), Extensions.checkEvery)
        XCTAssertEqual(Extensions.retryDelay(failures: 40), Extensions.checkEvery)

        let now = Date()
        // A day after the last check that worked, and not before.
        XCTAssertTrue(Extensions.updateDue(checked: nil, retry: nil, now: now))
        XCTAssertFalse(Extensions.updateDue(checked: now.addingTimeInterval(-3600), retry: nil, now: now))
        XCTAssertTrue(Extensions.updateDue(checked: now.addingTimeInterval(-21 * 3600), retry: nil, now: now))
        // After a failure the planned retry decides, whatever the last good check:
        // an hour on, the hourly tick (up to five minutes early against it) runs it.
        let recent = now.addingTimeInterval(-60)
        XCTAssertFalse(Extensions.updateDue(checked: recent, retry: now.addingTimeInterval(3600), now: now))
        XCTAssertTrue(Extensions.updateDue(checked: recent, retry: now.addingTimeInterval(3600), now: now.addingTimeInterval(3600 - 30)))
        XCTAssertFalse(Extensions.updateDue(checked: .distantPast, retry: now.addingTimeInterval(7200), now: now.addingTimeInterval(3600)))
    }

    func testPendingUpdateIsNotStartedTwiceAndFailureAllowsRetry() async {
        _ = NSApplication.shared
        let extensions = Extensions.shared
        let item = Installed(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", name: "Synthetic update",
                             version: "1", enabled: false, fromStore: true, permissions: [])
        let started = expectation(description: "First update requested")
        let response = UpdateResponse()
        URLProtocol.registerClass(UpdateProtocol.self)
        // The update is fetched through Proxy.swift's session now, so that it
        // can go through a proxy; a session made from a configuration sees
        // only the classes that configuration names, not the registered ones.
        ProxyNetwork.testProtocols = [UpdateProtocol.self]
        UpdateProtocol.response = response
        defer {
            URLProtocol.unregisterClass(UpdateProtocol.self)
            ProxyNetwork.testProtocols = []
            UpdateProtocol.response = nil
        }
        response.started = started
        let first = Task { await extensions.update(item) }
        await fulfillment(of: [started], timeout: 5)
        await extensions.update(item)
        XCTAssertEqual(response.count, 1, "A pending request must not be duplicated")
        response.fail()
        let firstAnswered = await first.value
        XCTAssertFalse(firstAnswered, "A check with no answer is a failure, to be tried again soon")

        let retried = expectation(description: "Failed update can be retried")
        response.started = retried
        let retry = Task { await extensions.update(item) }
        await fulfillment(of: [retried], timeout: 5)
        XCTAssertEqual(response.count, 2)
        await retry.value
    }
}

@available(macOS 14, *)
private final class UpdateResponse {
    private let lock = NSLock()
    private var requests: [URLProtocol] = []
    private var nextStart: XCTestExpectation?
    var started: XCTestExpectation? {
        get { lock.withLock { nextStart } }
        set { lock.withLock { nextStart = newValue } }
    }
    var count: Int { lock.withLock { requests.count } }
    func receive(_ request: URLProtocol) {
        let (count, signal) = lock.withLock {
            requests.append(request)
            let signal = nextStart
            nextStart = nil
            return (requests.count, signal)
        }
        if count > 1 {
            request.client?.urlProtocol(request, didFailWithError: URLError(.notConnectedToInternet))
        }
        signal?.fulfill()
    }
    func fail() {
        let request = lock.withLock { requests.first }
        if let request { request.client?.urlProtocol(request, didFailWithError: URLError(.notConnectedToInternet)) }
    }
}

@available(macOS 14, *)
private final class UpdateProtocol: URLProtocol {
    static var response: UpdateResponse?
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "clients2.google.com"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.response?.receive(self) }
    override func stopLoading() {}
}
