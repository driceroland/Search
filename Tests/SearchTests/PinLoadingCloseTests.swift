import AppKit
import Network
import WebKit
import XCTest
@testable import Search

/// A pin put down while its page is still loading stops saying it loads:
/// its row's spinner went on for good, since the view's own "done" went
/// unheard once it was torn down. A local address that takes the request
/// and never answers keeps the page loading. Nothing is shown.
@MainActor
final class PinLoadingCloseTests: XCTestCase {
    private var listener: NWListener?
    private var held: [NWConnection] = []

    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("pin-loading-close-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.officecommun.search.test.\(world)")
        }
        super.tearDown()
    }

    override func tearDown() {
        listener?.cancel()
        for connection in held { connection.cancel() }
        held = []
    }

    /// An address that takes a connection and says nothing.
    private func silent() async throws -> URL {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            MainActor.assumeIsolated { self?.held.append(connection) }
        }
        listener.start(queue: .main)
        for _ in 0..<50 where listener.port == nil { try await Task.sleep(for: .milliseconds(20)) }
        let port = try XCTUnwrap(listener.port?.rawValue)
        return URL(string: "http://127.0.0.1:\(port)/slow")!
    }

    private func loadingTab(_ url: URL) async throws -> Tab {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(configuration: configuration)
        tab.pin = "P"
        tab.go(to: url)
        for _ in 0..<100 where !tab.loading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(tab.loading, "the page is loading")
        return tab
    }

    func testAPinPutDownMidLoadStopsLoading() async throws {
        let tab = try await loadingTab(try await silent())
        tab.rest()
        XCTAssertFalse(tab.loading, "put down: not loading")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(tab.loading)
    }

    func testAPinPutToSleepMidLoadStopsLoading() async throws {
        let tab = try await loadingTab(try await silent())
        tab.sleep(picture: nil)
        XCTAssertFalse(tab.loading, "asleep: not loading")
    }

    func testClosingAPinnedTabMidLoadStopsItsSpinner() async throws {
        _ = NSApplication.shared
        let url = try await silent()
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.newTab()
        let tab = try XCTUnwrap(browser.tabs.last)
        browser.pin(tab, listed: true)
        browser.newTab()
        tab.go(to: url)
        for _ in 0..<100 where !tab.loading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(tab.loading)
        browser.close(tab)
        XCTAssertNotNil(tab.pin, "a pin is put down, not closed")
        XCTAssertFalse(tab.loading, "its row stops spinning")
    }
}
