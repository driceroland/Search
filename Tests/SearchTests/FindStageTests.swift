import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Search

@MainActor
final class FindStageTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "find-stage-\(getpid())", 1)
        super.setUp()
    }

    func testFindBarFollowsFocusedPaneAndStageLayout() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let left = Tab(bench: true)
        let right = Tab(bench: true)
        let stage = PaneStage(frame: CGRect(x: 0, y: 0, width: 1000, height: 500))
        var pair = TabSplit(left: left.id, right: right.id)
        stage.show([left, right], split: pair, focused: right.id)
        stage.showFind(browser)
        let window = makeWindow(stage)
        defer { window.close() }
        stage.layoutSubtreeIfNeeded()
        let bar = try XCTUnwrap(stage.subviews.compactMap { $0 as? NSHostingView<FindBar> }.first)
        XCTAssertTrue(bar.superview === stage)
        XCTAssertEqual(bar.frame.maxX, 1000, accuracy: 0.1)
        XCTAssertEqual(bar.frame.minY, 0)
        try await assertControlsHit(in: bar, stage: stage)

        pair.fraction = 0.35
        stage.show([left, right], split: pair, focused: left.id)
        stage.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.frame.maxX, (1000 - PaneStage.gutter) * 0.35, accuracy: 0.1)
        try await assertControlsHit(in: bar, stage: stage)

        stage.frame.size.width = 520
        stage.layoutSubtreeIfNeeded()
        try await assertControlsHit(in: bar, stage: stage, narrow: true)

        stage.frame.size = CGSize(width: 420, height: 250)
        stage.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.frame.maxX, 420, accuracy: 0.1)
        XCTAssertFalse(bar.isHidden)
        try await assertControlsHit(in: bar, stage: stage)
        stage.showFind(nil)
        XCTAssertNil(bar.superview)
    }

    func testCloseButtonClearsFindWithoutClickingPageAfterStatusChanges() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let tab = browser.benchOpen(URL(string: "about:blank")!)
        browser.activeID = tab.id
        let stage = PaneStage(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        stage.show([tab], split: nil, focused: tab.id)
        let window = makeWindow(stage)
        defer { browser.closeFind(); window.close() }
        let web = tab.web
        web.loadHTMLString("""
            <body style="margin:0;min-height:100vh" onclick="window.pageClicks++">
            orchid orchid orchid
            <script>window.pageClicks = 0; window.findFixtureReady = true;</script>
            </body>
            """, baseURL: URL(string: "https://find-stage.invalid/"))
        try await waitUntil("the fixture page loads") {
            (try? await web.evaluateJavaScript("window.findFixtureReady")) as? Bool == true
        }
        browser.openFind()
        stage.showFind(browser)
        stage.layoutSubtreeIfNeeded()
        let bar = try XCTUnwrap(stage.subviews.compactMap { $0 as? NSHostingView<FindBar> }.first)
        try await assertControlsHit(in: bar, stage: stage)

        for query in ["orchid", "missing", "", "orchid"] {
            browser.needle = query
            try await waitUntil("find finishes searching for \(query)") {
                !browser.findBusy && (query.isEmpty || browser.findResult != nil)
            }
            XCTAssertEqual(browser.findStatus, query.isEmpty ? nil : query == "missing" ? "No matches" : "1 of 3")
            try await assertControlsHit(in: bar, stage: stage)
        }
        let highlighted = try await web.evaluateJavaScript("CSS.highlights.get('search-find-match')?.size ?? 0")
        XCTAssertEqual(highlighted as? Int, 3)

        let point = bar.convert(closePoint(in: bar), to: nil)
        let target = try XCTUnwrap(stage.hitTest(stage.superview!.convert(point, from: nil)))
        XCTAssertTrue(target === bar || target.isDescendant(of: bar), "X must receive the press before the page")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            ))
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(20))
        }
        try await waitUntil("X closes Find and clears page highlights") {
            guard !browser.finding else { return false }
            return (try await web.evaluateJavaScript("CSS.highlights.get('search-find-match')?.size ?? 0")) as? Int == 0
        }
        XCTAssertEqual(browser.needle, "")
        XCTAssertNil(browser.findResult)
        XCTAssertNil(browser.findStatus)
        let clicks = try await web.evaluateJavaScript("window.pageClicks")
        XCTAssertEqual(clicks as? Int, 0)
    }

    private func makeWindow(_ stage: PaneStage) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000,
                                                 width: stage.frame.width, height: stage.frame.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = stage
        window.orderFrontRegardless()
        return window
    }

    private func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        return view.subviews.compactMap { textField(in: $0) }.first
    }

    private func closePoint(in bar: NSHostingView<FindBar>, narrow: Bool = false) -> NSPoint {
        // The 24pt X sits inside 14pt outer and 8pt (6pt when narrow) inner trailing padding.
        NSPoint(x: bar.bounds.maxX - 14 - (narrow ? 6 : 8) - 12, y: 32)
    }

    private func assertControlsHit(in bar: NSHostingView<FindBar>, stage: PaneStage,
                                   narrow: Bool = false) async throws {
        // Let the existing 0.14s missed-result animation finish before checking the final layout.
        try await Task.sleep(for: .milliseconds(250))
        stage.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(textField(in: bar))
        let fieldPoint = field.convert(NSPoint(x: 2, y: field.bounds.midY), to: stage.superview)
        let fieldHit = stage.hitTest(fieldPoint)
        XCTAssertTrue(fieldHit === bar || fieldHit?.isDescendant(of: bar) == true, "Find field must keep its click")
        let beforeField = field.convert(NSPoint(x: -24, y: field.bounds.midY), to: stage)
        XCTAssertNil(bar.hitTest(beforeField), "empty space left of the pill must pass through after resizing")
        let close = closePoint(in: bar, narrow: narrow)
        let labels = ["Close Find on Page", "Search options"] + (narrow ? [] : ["Next match", "Previous match"])
        for (index, label) in labels.enumerated() {
            let point = bar.convert(NSPoint(x: close.x - CGFloat(index) * 30, y: close.y), to: stage.superview)
            let hit = stage.hitTest(point)
            XCTAssertTrue(hit === bar || hit?.isDescendant(of: bar) == true, "\(label) must keep its click")
        }
        for point in [NSPoint(x: 2, y: 32), NSPoint(x: bar.bounds.midX, y: 2),
                      NSPoint(x: bar.bounds.maxX - 15, y: 13), NSPoint(x: bar.bounds.maxX - 2, y: 32),
                      NSPoint(x: bar.bounds.midX, y: bar.bounds.maxY - 2)] {
            XCTAssertNil(bar.hitTest(bar.convert(point, to: stage)), "empty padding must pass through")
        }
    }

    private func waitUntil(_ message: String, _ predicate: () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for \(message)")
        throw NSError(domain: "FindStageTests", code: 1)
    }
}
