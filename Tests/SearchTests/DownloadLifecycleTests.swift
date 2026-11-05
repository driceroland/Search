import AppKit
import Darwin
import Foundation
import SwiftUI
import WebKit
import XCTest
@testable import Search

private typealias BrowserTab = Search.Tab

@MainActor
final class DownloadLifecycleTests: XCTestCase {
    private var browser: Browser!
    private var fixture: LocalDownloadServer!
    private var downloadFolder: URL!
    private var window: NSWindow!
    private var page: BrowserTab?

    override class func setUp() {
        // Browser settings, history, WebKit data, and files live in this
        // process-specific test world, never in the user's Search profile.
        setenv("SEARCH_PROBE", "download-ui-\(getpid())", 1)
        super.setUp()
    }

    override class func tearDown() {
        Disk.drain()
        if let world = Store.world {
            let suite = "com.officecommun.search.test.\(world)"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: Store.folder)
        }
        super.tearDown()
    }

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        fixture = try LocalDownloadServer()
        browser = Browser(record: WindowRecord())
        browser.history.forget()
        browser.loot.forgetAll()

        downloadFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Search-download-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
        browser.prefs.downloads = downloadFolder
        browser.prefs.asksWhereToSave = false

        window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 680),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        browser.window = window
    }

    override func tearDown() async throws {
        try? nothingShown()
        if let browser {
            for entry in browser.fetches.entries { browser.cancelDownload(entry) }
            try? await waitUntil {
                browser.fetches.entries.isEmpty && browser.downloading.isEmpty
            }
            if let page { browser.close(page) }
            browser.loot.forgetAll()
            browser.history.forget()
        }
        fixture?.stop()
        try? nothingShown()
        window?.orderOut(nil)
        window?.close()
        if let downloadFolder { try? FileManager.default.removeItem(at: downloadFolder) }
        try await super.tearDown()
    }

    func testWebKitFailureWithResumeDataResumesSameEntryAndDestination() async throws {
        let tab = try await openFixturePage()
        let entry = try await startDownload("/failure.bin", in: tab)
        try await waitUntil { entry.state == .failed }

        let originalID = entry.id
        let reason = try XCTUnwrap(entry.errorDescription)
        let destination = try XCTUnwrap(entry.destination)
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(entry.canResume, "WebKit should return resume data for the ranged fixture")
        XCTAssertTrue(entry.canRetry)

        if let snapshotPath = ProcessInfo.processInfo.environment["SEARCH_DOWNLOAD_SNAPSHOT"], !snapshotPath.isEmpty {
            let paused = try await startDownload("/range.bin", in: tab)
            try await waitUntil { paused.completedBytes >= 64 * 1024 && paused.destination != nil }
            browser.pauseDownload(paused)
            try await waitUntil { paused.state == .paused }
            XCTAssertTrue(paused.canResume)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(paused.destination).path))

            let active = try await startDownload("/range.bin", in: tab)
            try await waitUntil { active.completedBytes >= 32 * 1024 }
            try writePanelSnapshot(to: URL(fileURLWithPath: snapshotPath))
        }

        browser.resumeDownload(entry)
        // A repeated click while WebKit is creating the resumed download must
        // not start a second attempt or replace the row.
        browser.resumeDownload(entry)
        try await waitUntil { entry.state == .downloading }
        XCTAssertEqual(entry.id, originalID)
        XCTAssertEqual(entry.destination, destination)

        try await waitUntil {
            browser.loot.kept.contains { $0.path == destination.path }
        }
        XCTAssertFalse(browser.fetches.entries.contains { $0.id == originalID })
        XCTAssertEqual(try Data(contentsOf: destination), fixture.expectedBytes())
        XCTAssertTrue(fixture.ranges("/failure.bin").contains { Self.rangeOffset($0) > 0 })
        XCTAssertTrue(fixture.cookies("/failure.bin").allSatisfy { $0?.contains("download-session=fixture-cookie") == true })
    }

    func testPauseResumeKeepsBytesAndDestination() async throws {
        let tab = try await openFixturePage()
        let entry = try await startDownload("/range.bin", in: tab)
        try await waitUntil { entry.completedBytes >= 64 * 1024 && entry.destination != nil }

        let originalID = entry.id
        let destination = try XCTUnwrap(entry.destination)
        browser.pauseDownload(entry)
        // The second request arrives while the first cancellation is pending.
        // It must not ask WebKit to stop twice.
        browser.pauseDownload(entry)
        try await waitUntil { entry.state == .paused }
        let pausedBytes = entry.completedBytes
        XCTAssertTrue(entry.canResume)
        XCTAssertEqual(entry.id, originalID)
        XCTAssertEqual(entry.destination, destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        browser.resumeDownload(entry)
        browser.resumeDownload(entry)
        try await waitUntil { entry.state == .downloading }
        // The row, the ring and Finder's bar go on from what had come in,
        // not from nothing: the first measure after the resume already
        // counts the bytes on disk.
        var ring: Double?
        let watching = browser.fetches.$fraction.sink { if let value = $0, ring == nil { ring = value } }
        try await waitUntil { entry.completedBytes > 0 && ring != nil || browser.loot.kept.contains { $0.path == destination.path } }
        watching.cancel()
        XCTAssertGreaterThanOrEqual(entry.completedBytes, pausedBytes, "the row started over after the resume")
        if let ring, entry.totalBytes > 0 {
            XCTAssertGreaterThanOrEqual(ring, Double(pausedBytes) / Double(entry.totalBytes) - 0.02, "the ring started over after the resume")
        }
        XCTAssertEqual(entry.id, originalID)
        XCTAssertEqual(entry.destination, destination)
        try await waitUntil { browser.loot.kept.contains { $0.path == destination.path } }

        XCTAssertFalse(browser.fetches.entries.contains { $0.id == originalID })
        XCTAssertEqual(try Data(contentsOf: destination), fixture.expectedBytes())
        XCTAssertTrue(fixture.ranges("/range.bin").contains { Self.rangeOffset($0) > 0 })
        XCTAssertTrue(fixture.cookies("/range.bin").allSatisfy { $0?.contains("download-session=fixture-cookie") == true })
    }

    func testFailureWithoutResumeDataKeepsReasonAndCanRetryFromStart() async throws {
        let tab = try await openFixturePage()
        let entry = try await startDownload("/retry.bin", in: tab)
        try await waitUntil { entry.state == .failed }

        let originalID = entry.id
        let reason = try XCTUnwrap(entry.errorDescription)
        XCTAssertFalse(reason.isEmpty)
        XCTAssertFalse(entry.canResume)
        XCTAssertTrue(entry.canRetry)

        browser.retryDownload(entry)
        XCTAssertEqual(entry.id, originalID)
        try await waitUntil { entry.state == .downloading }
        XCTAssertNil(entry.errorDescription)
        try await waitUntil { browser.loot.kept.contains { $0.name.hasPrefix("fixture") } }

        let keep = try XCTUnwrap(browser.loot.kept.first { $0.name.hasPrefix("fixture") })
        XCTAssertEqual(try Data(contentsOf: keep.url), fixture.expectedBytes())
        XCTAssertEqual(fixture.count("/retry.bin"), 2)
        XCTAssertTrue(fixture.ranges("/retry.bin").allSatisfy { $0 == nil })
        XCTAssertTrue(fixture.cookies("/retry.bin").allSatisfy { $0?.contains("download-session=fixture-cookie") == true })
    }

    func testDeletedSpaceTakesItsRunningDownloadWithIt() async throws {
        let tab = try await openFixturePage()
        let entry = try await startDownload("/cancel.bin", in: tab)
        try await waitUntil { entry.completedBytes >= 64 * 1024 && entry.destination != nil }
        let destination = try XCTUnwrap(entry.destination)
        let store = try XCTUnwrap(entry.store)
        let id = entry.id

        browser.forgetDownloads(of: store)
        try await waitUntil {
            !browser.fetches.entries.contains { $0.id == id } && browser.downloading.isEmpty
        }

        XCTAssertNil(entry.store, "a forgotten store is still kept by its row")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCancelRemovesEntryAndPartialFile() async throws {
        let tab = try await openFixturePage()
        let entry = try await startDownload("/cancel.bin", in: tab)
        try await waitUntil { entry.completedBytes >= 64 * 1024 && entry.destination != nil }
        let destination = try XCTUnwrap(entry.destination)
        let id = entry.id

        browser.cancelDownload(entry)
        browser.cancelDownload(entry)
        try await waitUntil {
            !browser.fetches.entries.contains { $0.id == id } && browser.downloading.isEmpty
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(browser.loot.kept.isEmpty)
    }

    func testANewDownloadIsCountedOnceAndItsResumeIsNot() async throws {
        let tab = try await openFixturePage()
        // Every window shares one Fetches, so earlier tests have counted too.
        let before = browser.fetches.started
        let entry = try await startDownload("/range.bin", in: tab)
        XCTAssertEqual(browser.fetches.started, before + 1, "a new download should be counted once")

        try await waitUntil { entry.completedBytes >= 64 * 1024 && entry.destination != nil }
        browser.pauseDownload(entry)
        try await waitUntil { entry.state == .paused }
        browser.resumeDownload(entry)
        try await waitUntil { entry.state == .downloading }
        XCTAssertEqual(browser.fetches.started, before + 1, "a resume is the same download going on")
    }

    func testARetryIsNotCountedAsANewDownload() async throws {
        let tab = try await openFixturePage()
        let before = browser.fetches.started
        let entry = try await startDownload("/retry.bin", in: tab)
        try await waitUntil { entry.state == .failed }
        XCTAssertEqual(browser.fetches.started, before + 1)

        browser.retryDownload(entry)
        try await waitUntil { entry.state == .downloading && fixture.count("/retry.bin") == 2 }
        XCTAssertEqual(browser.fetches.started, before + 1, "a retry is the same download going on")
    }

    func testAPrivateDownloadIsCountedThoughItHasNoRow() async throws {
        let privateSource = Tab(shy: true)
        let tab = browser.open(URL(string: "about:blank")!, foreground: true, from: privateSource)
        page = tab
        window.contentView = tab.web
        tab.go(to: fixture.url("/page"))
        try await waitUntil { tab.committed == fixture.url("/page") && !tab.loading }
        try await waitUntil { fixture.completed("/page") == 1 }

        let before = browser.fetches.started
        _ = try await requestDownload("/private.bin", from: tab.web)
        XCTAssertEqual(browser.fetches.started, before + 1, "a private download puts up the ring, so it pulses too")
        XCTAssertTrue(browser.fetches.entries.isEmpty)
        try await waitUntil { fixture.completed("/private.bin") == 1 && browser.downloading.isEmpty }
    }

    func testThePulseHoldsStillUnderReduceMotionAndNeverHasNoLength() {
        for light in [false, true] {
            let still = FetchDoor.pulse(reduced: true, light: light)
            let moving = FetchDoor.pulse(reduced: false, light: light)
            XCTAssertEqual(still.peak, 1, "Reduce Motion should leave the icon at its size (light: \(light))")
            XCTAssertGreaterThan(moving.peak, 1, "without Reduce Motion the icon should swell (light: \(light))")
            // A keyframe of no length makes a scale that is not a number, and AppKit stops the app.
            for pulse in [still, moving] {
                XCTAssertGreaterThan(pulse.up, 0, "light: \(light)")
                XCTAssertGreaterThan(pulse.down, 0, "light: \(light)")
            }
        }
    }

    func testRemovingPausedDownloadPreservesAReplacementFile() async throws {
        let tab = try await openFixturePage()
        let entry = try await startDownload("/range.bin", in: tab)
        try await waitUntil { entry.completedBytes >= 64 * 1024 && entry.destination != nil }
        let destination = try XCTUnwrap(entry.destination)

        browser.pauseDownload(entry)
        try await waitUntil { entry.state == .paused }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        let replacement = Data("a file placed here after the pause".utf8)
        try replacement.write(to: destination, options: .atomic)
        browser.cancelDownload(entry)
        try await waitUntil { !browser.fetches.entries.contains { $0.id == entry.id } }

        XCTAssertEqual(try Data(contentsOf: destination), replacement)
    }

    func testPrivateDownloadNeverEntersSharedEntriesHistoryOrCompletedList() async throws {
        let privateSource = Tab(shy: true)
        let tab = browser.open(URL(string: "about:blank")!, foreground: true, from: privateSource)
        page = tab
        window.contentView = tab.web
        tab.go(to: fixture.url("/page"))
        try await waitUntil { tab.committed == fixture.url("/page") && !tab.loading }
        try await waitUntil { fixture.completed("/page") == 1 }

        _ = try await requestDownload("/private.bin", from: tab.web)
        XCTAssertTrue(browser.fetches.entries.isEmpty)

        try await waitUntil {
            fixture.completed("/private.bin") == 1 && browser.downloading.isEmpty
        }
        XCTAssertTrue(browser.fetches.entries.isEmpty)
        XCTAssertTrue(browser.loot.kept.isEmpty)
        XCTAssertFalse(browser.history.everything(matching: "127.0.0.1").contains { $0.url == fixture.url("/page") })
        XCTAssertTrue(fixture.cookies("/private.bin").contains { $0?.contains("download-session=fixture-cookie") == true })
    }

    func testPDFSavedFromPrivatePageIsAnnouncedButNeverListed() async throws {
        let address = URL(string: "https://example.test/paper.pdf")
        let pdf = Data("%PDF".utf8)

        // The list is what these two stay out of, so an ordinary tab must still reach it.
        let ordinary = try await openFixturePage()
        browser.webView(ordinary.web, saveDataToFile: pdf, suggestedFilename: "kept.pdf",
                        mimeType: "application/pdf", originatingURL: address)
        XCTAssertEqual(browser.loot.kept.map(\.name), ["kept.pdf"])
        browser.loot.forgetAll()

        let shy = browser.open(URL(string: "about:blank")!, foreground: true, from: Tab(shy: true))
        browser.webView(shy.web, saveDataToFile: pdf, suggestedFilename: "shy.pdf",
                        mimeType: "application/pdf", originatingURL: address)
        XCTAssertEqual(browser.announcement, "Saved shy.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadFolder.appendingPathComponent("shy.pdf").path))
        XCTAssertTrue(browser.loot.kept.isEmpty, "a private tab's PDF left its name and host in downloads.json")
        browser.close(shy)
        browser.loot.forgetAll()

        // A page in a store that isn't kept, though no private tab holds it.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        browser.webView(WKWebView(frame: .zero, configuration: configuration), saveDataToFile: pdf,
                        suggestedFilename: "unkept.pdf", mimeType: "application/pdf", originatingURL: address)
        XCTAssertEqual(browser.announcement, "Saved unkept.pdf")
        XCTAssertTrue(browser.loot.kept.isEmpty, "a PDF from a store that isn't kept was listed")
    }

    func testRowAndFinishedFileHaveTheirAddressUntilHistoryIsCleared() async throws {
        let tab = try await openFixturePage()
        let source = fixture.url("/address.bin").absoluteString
        let entry = try await startDownload("/address.bin", in: tab)
        XCTAssertEqual(entry.address, source)

        try await waitUntil { browser.loot.kept.contains { $0.address == source } }

        browser.clearHistory()
        XCTAssertEqual(browser.loot.kept.count, 1, "the file stays listed")
        XCTAssertNil(browser.loot.kept.first?.address)

        // Gone from the file too, or the next launch would offer it again.
        Disk.drain()
        let written = try JSONDecoder().decode([Keep].self, from: Data(contentsOf: Store.file("downloads.json")))
        XCTAssertEqual(written.count, 1)
        XCTAssertNil(written.first?.address)
    }

    func testADownloadPausedAcrossClearHistoryKeepsNoAddress() async throws {
        let tab = try await openFixturePage()
        let entry = try await startDownload("/range.bin", in: tab)
        try await waitUntil { entry.completedBytes >= 64 * 1024 && entry.destination != nil }
        let destination = try XCTUnwrap(entry.destination)
        browser.pauseDownload(entry)
        try await waitUntil { entry.state == .paused }

        browser.clearHistory()
        XCTAssertNil(entry.address)

        browser.resumeDownload(entry)
        try await waitUntil { browser.loot.kept.contains { $0.path == destination.path } }
        XCTAssertNil(browser.loot.kept.first { $0.path == destination.path }?.address)
    }

    func testRightClickOnARowOffersItsAddressWhenItHasOne() async throws {
        let tab = try await openFixturePage()
        let host = NSHostingView(rootView: DownloadsPanel(browser: browser, loot: browser.loot))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 680)
        let offscreen = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 560, height: 680),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        offscreen.isReleasedWhenClosed = false
        offscreen.contentView = host
        defer { offscreen.close() }

        let old = Keep(name: "old.zip", from: "example.test", path: "/tmp/old.zip", date: Date())
        let done = Keep(name: "done.zip", from: "example.test", path: "/tmp/done.zip", date: Date(),
                        address: "https://example.test/done.zip")
        browser.loot.add(old)
        browser.loot.add(done)
        try await waitUntil { rowMenus(in: host) == [["Copy Address"]] }

        // Only the file listed before addresses were noted is left: no menu.
        browser.loot.forget(done)
        try await waitUntil { rowMenus(in: host).isEmpty }

        let running = try await startDownload("/cancel.bin", in: tab)
        try await waitUntil { rowMenus(in: host) == [["Copy Address"]] }
        browser.cancelDownload(running)
    }

    /// A private tab's PDF isn't listed at all (see the test above), so
    /// its address can't be either.
    func testSavedPDFKeepsItsAddress() async throws {
        let address = URL(string: "https://example.test/paper.pdf")
        let tab = try await openFixturePage()
        browser.webView(tab.web, saveDataToFile: Data("%PDF".utf8), suggestedFilename: "paper.pdf",
                        mimeType: "application/pdf", originatingURL: address)
        XCTAssertEqual(browser.loot.kept.first?.address, address?.absoluteString)
    }

    private func openFixturePage() async throws -> BrowserTab {
        let tab = browser.open(URL(string: "about:blank")!, foreground: true)
        page = tab
        window.contentView = tab.web
        tab.go(to: fixture.url("/page"))
        try await waitUntil { tab.committed == fixture.url("/page") && !tab.loading }
        try await waitUntil { fixture.completed("/page") == 1 }
        return tab
    }

    private func startDownload(_ path: String, in tab: BrowserTab) async throws -> FetchEntry {
        let download = try await requestDownload(path, from: tab.web)
        return try XCTUnwrap(browser.fetches.entry(for: download))
    }

    private func requestDownload(_ path: String, from webView: WKWebView) async throws -> WKDownload {
        let request = URLRequest(url: fixture.url(path))
        return await withCheckedContinuation { continuation in
            webView.startDownload(using: request) { download in
                // WebKit requires the delegate before this callback returns.
                // Attaching after await leaves a scheduling gap in which the
                // destination or failure callback can be lost on a cold runner.
                self.browser.keep(download, from: webView)
                continuation.resume(returning: download)
            }
        }
    }

    /// What a right-click offers anywhere down the panel: the question AppKit
    /// asks when the button goes down, without a menu coming up.
    private func rowMenus(in host: NSView) -> Set<[String]> {
        host.layoutSubtreeIfNeeded()
        return Set(stride(from: 0, to: host.bounds.height, by: 10).compactMap { y -> [String]? in
            let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: host.bounds.midX, y: y), modifierFlags: [], timestamp: 0,
                windowNumber: host.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            return event.flatMap { host.menu(for: $0) }?.items.map(\.title)
        })
    }

    private func writePanelSnapshot(to destination: URL) throws {
        let host = NSHostingView(rootView: DownloadsPanel(browser: browser, loot: browser.loot))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 680)
        let snapshotWindow = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 560, height: 680),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        snapshotWindow.isReleasedWhenClosed = false
        snapshotWindow.contentView = host
        snapshotWindow.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw SnapshotError.couldNotRender
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.couldNotEncode
        }
        try data.write(to: destination, options: .atomic)
        snapshotWindow.close()
    }

    /// These tests never put a window in, nor bring the app forward: one
    /// that did would be on someone's screen. It fails the test, and
    /// everything is put away at once.
    private func nothingShown(file: StaticString = #filePath, line: UInt = #line) throws {
        let shown = NSApp.windows.filter(\.isVisible)
        guard !shown.isEmpty || NSApp.isActive else { return }
        for window in NSApp.windows { window.orderOut(nil); window.close() }
        NSApp.hide(nil)
        XCTFail("a window was shown or the app came forward: \(shown)", file: file, line: line)
        throw WaitError.timedOut
    }

    // Hosted runners initialize WebKit services from a clean image.
    // Preserve the state assertions with a larger bounded CI deadline.
    private func waitUntil(
        timeout: TimeInterval = ProcessInfo.processInfo.environment["CI"] == "true" ? 60 : 15,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try nothingShown(file: file, line: line)
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let entries = browser.fetches.entries.map { "\($0.name): \($0.state), \($0.completedBytes) bytes" }
        XCTFail("Timed out waiting for the download state; entries: \(entries); completed: \(browser.loot.kept.map(\.name))", file: file, line: line)
        throw WaitError.timedOut
    }

    private static func rangeOffset(_ header: String?) -> Int {
        guard let header, let equals = header.firstIndex(of: "="), let dash = header.firstIndex(of: "-") else { return 0 }
        return Int(header[header.index(after: equals)..<dash]) ?? 0
    }

    private enum WaitError: Error { case timedOut }
    private enum SnapshotError: Error { case couldNotRender, couldNotEncode }
}
