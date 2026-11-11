import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Search

/// Measures, not checks: how much each everyday change costs the window.
/// Runs only when SPEED_OUT names a file, and writes what it measured there
/// as JSON, so the same file can be run against two builds and compared.
/// Hosted as RowCarryTests does, in a borderless window far off every screen.
@MainActor
final class SpeedBenchTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private static var results: [String: [String: Double]] = [:]

    override class func setUp() {
        setenv("SEARCH_PROBE", "speed-bench-\(getpid())", 1)
        super.setUp()
    }

    override class func tearDown() {
        if let out = ProcessInfo.processInfo.environment["SPEED_OUT"],
           let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: out))
        }
        if let world = Store.world, world.hasPrefix("speed-bench-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.officecommun.search.test.\(world)")
        }
        super.tearDown()
    }

    override func setUp() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SPEED_OUT"] == nil, "SPEED_OUT not set")
        try await super.setUp()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers { browser.closeAll() }
        windows.removeAll()
        browsers.removeAll()
        try await Task.sleep(for: .milliseconds(200))
        try await super.tearDown()
    }

    // MARK: - what is measured

    /// A word typed into the field, a key at a time, over a column of 60
    /// tabs and a history of 3000 pages.
    func testTyping() async throws {
        let browser = makeBrowser(tabs: 60)
        seedHistory(browser, pages: 3000)
        let window = host(browser)
        try await settle()
        browser.launch()
        try await settle()
        let words = Array("github pull requests")
        let cost = try await measure(browser, steps: words.count, label: "typing") { i in
            browser.typed = String(words[0...i])
        }
        record("typing", cost)
        _ = window
    }

    /// A word typed into Find on Page, a key at a time, over a column of 60
    /// tabs, with the page answering each letter as it does.
    func testFinding() async throws {
        let browser = makeBrowser(tabs: 60)
        let window = host(browser)
        let bar = NSWindow(contentRect: NSRect(x: -20_000, y: -16_000, width: 600, height: 120),
                           styleMask: .borderless, backing: .buffered, defer: false)
        bar.isReleasedWhenClosed = false
        bar.contentView = NSHostingView(rootView: FindBar(browser: browser))
        bar.orderFrontRegardless()
        windows.append(bar)
        try await settle()
        browser.finding = true
        try await settle()
        let words = Array("github pull requests")
        let cost = try await measure(browser, steps: words.count, label: "finding") { i in
            browser.needle = String(words[0...i])
        }
        record("finding", cost)
        _ = window
    }

    /// Two fingers carrying the column to the next space, an event a frame.
    func testSpaceSwipe() async throws {
        let browser = makeBrowser(tabs: 60)
        let window = host(browser)
        try await settle()
        let cost = try await measure(browser, steps: 120, label: "swipe") { i in
            browser.spaceSwipe = -CGFloat(i) * 2
        }
        browser.spaceSwipe = 0
        record("spaceSwipe", cost)
        _ = window
    }

    /// A sideways swipe on the page, to go back: the disc follows each event.
    func testBackSwipe() async throws {
        let browser = makeBrowser(tabs: 60)
        let window = host(browser)
        try await settle()
        let tab = try XCTUnwrap(browser.active)
        let cost = try await measure(browser, steps: 120, label: "pull") { i in
            tab.pull = Pull(back: true, travel: CGFloat(i), armed: i > 60, going: false)
        }
        tab.pull = nil
        record("backSwipe", cost)
        _ = window
    }

    /// A tab in the background whose title counts its unread mail.
    func testBackgroundTitles() async throws {
        let browser = makeBrowser(tabs: 60)
        seedHistory(browser, pages: 3000)
        let window = host(browser)
        try await settle()
        // An old page, far from the History menu's last few.
        let old = URL(string: "https://site2900.example/page")!
        let cost = try await measure(browser, steps: 60, label: "retitle") { i in
            browser.history.retitle(old, "(\(i + 1)) Inbox")
        }
        record("backgroundTitle", cost)
        _ = window
    }

    /// Something in the window that no tab's row shows: the downloads card
    /// hung and taken down, over a column of 60 tabs.
    func testUnrelatedChange() async throws {
        let browser = makeBrowser(tabs: 60)
        let window = host(browser)
        try await settle()
        let cost = try await measure(browser, steps: 60, label: "unrelated") { i in
            browser.downloadsHanging = i.isMultiple(of: 2)
        }
        browser.downloadsHanging = false
        record("unrelatedChange", cost)
        _ = window
    }

    /// A tab picked with ⌘ and let go again: what the rows do show.
    func testPicking() async throws {
        let browser = makeBrowser(tabs: 60)
        let window = host(browser)
        try await settle()
        let tab = browser.tabs[30]
        let cost = try await measure(browser, steps: 60, label: "picking") { _ in
            browser.extendTabSelection(to: tab, modifiers: .command)
        }
        browser.clearTabSelection()
        record("picking", cost)
        _ = window
    }

    /// The column's edge pulled out and back in one of two whole windows of
    /// 60 tabs each, a mouse event a frame. Counted: the settings published
    /// and written while it is held, and the rows of both windows built.
    /// Timed: each main run-loop pass that carried a step (LoopClock).
    func testColumnEdge() async throws {
        let prefs = Shared.prefs
        prefs.sideIcons = false
        prefs.sideHides = false
        prefs.sideWidth = Metrics.side
        var edgeWindows: [NSWindow] = []
        for n in 0..<2 {
            let browser = makeBrowser(tabs: 60)
            browser.folded = false
            browser.welcoming = false
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000 + CGFloat(n) * 1000, width: 1200, height: 800),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ContentView(browser: browser))
            browser.window = window
            window.orderFrontRegardless()
            windows.append(window)
            edgeWindows.append(window)
        }
        try await settle()

        var published = 0
        var written = 0
        let watch = prefs.objectWillChange.sink { published += 1 }
        let writes = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { _ in written += 1 }
        defer { watch.cancel(); writes.cancel() }
        Bench.bodies = [:]
        let clock = LoopClock()
        clock.start()

        let window = edgeWindows[0]
        let y = window.frame.height / 2
        let grab = NSPoint(x: prefs.sideWidth - 3, y: y)
        let steps = 60
        send(.leftMouseDown, at: grab, in: window)
        try await Task.sleep(for: .milliseconds(16))
        for step in 1...steps {
            // Out 2 points a step for the first half, back in for the second.
            let out = CGFloat(step <= steps / 2 ? step : steps - step) * 2
            clock.mark()
            send(.leftMouseDragged, at: NSPoint(x: grab.x + out + 2, y: y), in: window)
            try await Task.sleep(for: .milliseconds(16))
        }
        let publishedHeld = published
        let writtenHeld = written
        send(.leftMouseUp, at: NSPoint(x: grab.x + 2, y: y), in: window)
        try await settle()
        clock.stop()

        var values = Dictionary(uniqueKeysWithValues: LoopClock.summary(clock.marked).map { ("stepMs." + $0, $1) })
        values["publishedWhileHeld"] = Double(publishedHeld)
        values["writtenWhileHeld"] = Double(writtenHeld)
        values["written"] = Double(written)
        values["rowsPerStep"] = Double(Bench.bodies["row"] ?? 0) / Double(steps)
        record("columnEdge", values)
        prefs.sideWidth = Metrics.side
    }

    /// What the field asks the history for on each key, alone.
    func testRanking() throws {
        let browser = makeBrowser(tabs: 1)
        seedHistory(browser, pages: 3000)
        let typed = ["g", "gi", "git", "gith", "githu", "github", "github p", "github pu", "github pul", "github pull",
                     "zq", "zqx", "zqxw", "issu", "issue", "issues", "isuses", "documnet", "docum", "documen"]
        var times: [Double] = []
        for _ in 0..<5 {
            for text in typed {
                let start = CACurrentMediaTime()
                _ = browser.history.suggestions(for: text, limit: 3)
                times.append((CACurrentMediaTime() - start) * 1000)
            }
        }
        record("ranking", ["ms": median(times)])
    }

    /// Working out the row: 200 tabs in 10 groups, 10 of them pairs.
    func testRowOrder() throws {
        let browser = makeBrowser(tabs: 200)
        browser.prefs.usesTabGroups = true
        browser.prefs.splitView = true
        let tabs = browser.tabs
        for g in 0..<10 {
            let group = browser.addTabGroup(containing: tabs[g * 20])
            for k in 1..<15 { tabs[g * 20 + k].groupID = group }
        }
        for p in 0..<10 { browser.pair(tabs[p * 20 + 16], with: tabs[p * 20 + 17], onLeft: false) }
        var times: [Double] = []
        for _ in 0..<40 {
            let start = CACurrentMediaTime()
            _ = browser.shownTabs
            _ = browser.tabShortcutTargets
            _ = browser.displayedTabs
            for group in browser.tabGroups { _ = browser.visibleTabs(in: group) }
            times.append((CACurrentMediaTime() - start) * 1000)
        }
        browser.prefs.usesTabGroups = false
        browser.prefs.splitView = false
        record("rowOrder", ["ms": median(times)])
    }

    /// The scripts a page is given at each link followed.
    func testArming() async throws {
        let browser = makeBrowser(tabs: 1)
        let tab = try XCTUnwrap(browser.active)
        _ = tab.web
        try await settle()
        let url = URL(string: "https://example.com/")!
        var times: [Double] = []
        for _ in 0..<200 {
            let start = CACurrentMediaTime()
            tab.arm(hiding: "", to: url)
            times.append((CACurrentMediaTime() - start) * 1000)
        }
        record("arming", ["ms": median(times)])
    }

    /// A write at once on the main thread, while the history is being written
    /// in the background.
    func testWriteBehindBackground() throws {
        let big = Store.file("speed-big.json")
        let small = Store.file("speed-small.json")
        let blob = Data(repeating: 0x61, count: 40_000_000)
        var times: [Double] = []
        for _ in 0..<10 {
            Disk.write(big) { blob }
            // Let the background write begin.
            Thread.sleep(forTimeInterval: 0.005)
            let start = CACurrentMediaTime()
            Disk.write(small, now: true) { Data("{}".utf8) }
            times.append((CACurrentMediaTime() - start) * 1000)
            Disk.drain()
        }
        record("writeBehindBackground", ["ms": median(times)])
    }

    /// A window opened with five spaces of 30 tabs each: what it costs
    /// before it can draw.
    func testOpeningWithSpaces() async throws {
        let first = makeBrowser(tabs: 30, record: nil)
        first.prefs.usesSpaces = true
        let home = first.spaceID
        for n in 0..<4 {
            first.addSpace(named: "Space \(n)")
            for i in 0..<30 {
                if first.tabs.last?.isBlank == false { first.newTab() }
                first.tabs.last?.restore(url: URL(string: "https://s\(n)t\(i).example/")!, title: "s\(n) \(i)")
            }
        }
        first.switchSpace(to: home)
        first.flushSession()
        Disk.drain()
        var times: [Double] = []
        for _ in 0..<5 {
            let start = CACurrentMediaTime()
            let opened = Browser(record: nil)
            times.append((CACurrentMediaTime() - start) * 1000)
            browsers.append(opened)
        }
        first.prefs.usesSpaces = false
        record("openingWithSpaces", ["ms": median(times)])
    }

    // MARK: - helpers

    private func record(_ name: String, _ values: [String: Double]) {
        Self.results[name] = values
        print("SPEED \(name) \(values)")
    }

    /// Each step, then the window brought up to date and drawn. Counted:
    /// the window's own changes sent, and the column's rows made again.
    private func measure(_ browser: Browser, steps: Int, label: String, _ step: (Int) -> Void) async throws -> [String: Double] {
        var sends = 0
        let watch = browser.objectWillChange.sink { _ in sends += 1 }
        defer { watch.cancel() }
        Bench.bodies = [:]
        var times: [Double] = []
        for i in 0..<steps {
            let start = CACurrentMediaTime()
            step(i)
            drain()
            times.append((CACurrentMediaTime() - start) * 1000)
        }
        let rows = Double(Bench.bodies["row"] ?? 0)
        return [
            "ms": median(times),
            "totalMs": times.reduce(0, +),
            "windowChangesPerStep": Double(sends) / Double(steps),
            "rowsPerStep": rows / Double(steps),
        ]
    }

    /// One turn of the run loop and a drawing of every window.
    private func drain() {
        RunLoop.current.run(mode: .default, before: Date())
        for window in windows {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    private func makeBrowser(tabs count: Int, record: WindowRecord? = WindowRecord()) -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: record)
        browsers.append(browser)
        browser.prefs.sidebar = true
        browser.prefs.usesTabGroups = false
        browser.prefs.splitView = false
        for i in 0..<count {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://tab\(i).example/")!, title: "Tab \(i)")
        }
        return browser
    }

    private func seedHistory(_ browser: Browser, pages: Int) {
        let words = ["github", "issues", "pull", "requests", "docs", "document", "search", "mail", "news", "maps"]
        for i in 0..<pages {
            let url = URL(string: "https://site\(i).example/page")!
            browser.history.record(url, title: "\(words[i % words.count]) \(words[(i / 10) % words.count]) page \(i)")
        }
    }

    private func host(_ browser: Browser) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 1400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SideBar(browser: browser, prefs: browser.prefs))
        window.orderFrontRegardless()
        windows.append(window)
        let field = NSWindow(contentRect: NSRect(x: -20_000, y: -18_000, width: 800, height: 600),
                             styleMask: .borderless, backing: .buffered, defer: false)
        field.isReleasedWhenClosed = false
        field.contentView = NSHostingView(rootView: Omnibox(browser: browser, over: false))
        field.orderFrontRegardless()
        windows.append(field)
        return window
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else { return XCTFail("no \(type) event") }
        window.sendEvent(event)
    }

    private func settle() async throws {
        drain()
        try await Task.sleep(for: .milliseconds(300))
        drain()
    }
}
