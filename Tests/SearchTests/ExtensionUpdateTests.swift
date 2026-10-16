import AppKit
import Foundation
import XCTest
@testable import Search

@available(macOS 15.4, *)
@MainActor
final class ExtensionUpdateTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "extension-updates-\(getpid())", 1)
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
        let key = "extensions.checked"
        let previous = Store.settings.object(forKey: key)
        defer {
            if let previous { Store.settings.set(previous, forKey: key) }
            else { Store.settings.removeObject(forKey: key) }
        }
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

    func testPendingUpdateIsNotStartedTwiceAndFailureAllowsRetry() async {
        _ = NSApplication.shared
        let extensions = Extensions.shared
        let item = Installed(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", name: "Synthetic update",
                             version: "1", enabled: false, fromStore: true, permissions: [])
        let started = expectation(description: "First update requested")
        let response = UpdateResponse()
        URLProtocol.registerClass(UpdateProtocol.self)
        UpdateProtocol.response = response
        defer {
            URLProtocol.unregisterClass(UpdateProtocol.self)
            UpdateProtocol.response = nil
        }
        response.started = started
        let first = Task { await extensions.update(item) }
        await fulfillment(of: [started], timeout: 5)
        await extensions.update(item)
        XCTAssertEqual(response.count, 1, "A pending request must not be duplicated")
        response.fail()
        await first.value

        let retried = expectation(description: "Failed update can be retried")
        response.started = retried
        let retry = Task { await extensions.update(item) }
        await fulfillment(of: [retried], timeout: 5)
        XCTAssertEqual(response.count, 2)
        await retry.value
    }
}

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

private final class UpdateProtocol: URLProtocol {
    static var response: UpdateResponse?
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "clients2.google.com"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.response?.receive(self) }
    override func stopLoading() {}
}
