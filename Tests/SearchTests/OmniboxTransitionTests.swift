import AppKit
import SwiftUI
import XCTest
@testable import Search

@MainActor
final class OmniboxTransitionTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "omnibox-transitions-\(getpid())", 1)
        super.setUp()
    }

    func testFloatingFieldReopensAndDismissesWithAndWithoutSplitView() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.welcoming = false
        browser.newsShowing = false
        let prefs = browser.prefs
        let saved = (prefs.floatingNewTab, prefs.splitView, prefs.sidebar)
        defer {
            browser.closeAll()
            prefs.floatingNewTab = saved.0
            prefs.splitView = saved.1
            prefs.sidebar = saved.2
        }
        prefs.floatingNewTab = true
        prefs.sidebar = false
        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        tab.go(to: URL(string: "about:blank")!)
        // The empty fixture has no non-empty WebKit frame to reveal it.
        tab.web.showFirstFrame()

        for splitView in [false, true] {
            prefs.splitView = splitView
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ContentView(browser: browser))
            window.orderFrontRegardless()
            defer {
                ContentView.forget(browser)
                window.contentView = nil
                window.close()
            }
            try await Task.sleep(for: .milliseconds(400))
            let count = browser.tabs.count
            for _ in 0..<2 {
                browser.launch()
                try await Task.sleep(for: .milliseconds(600))
                XCTAssertTrue(browser.launching)
                XCTAssertEqual(browser.tabs.count, count)
                XCTAssertEqual(browser.activeID, tab.id)
                let content = try XCTUnwrap(window.contentView)
                let field = try XCTUnwrap(addressField(in: content))
                let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                XCTAssertTrue(window.firstResponder === editor)

                browser.dismiss()
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertFalse(browser.launching)
                XCTAssertNil(addressField(in: content))
                XCTAssertTrue(window.firstResponder === tab.web)
                let point = tab.web.convert(NSPoint(x: tab.web.bounds.midX, y: tab.web.bounds.midY), to: content.superview)
                let hit = content.hitTest(point)
                XCTAssertTrue(hit === tab.web || hit?.isDescendant(of: tab.web) == true,
                              "The mounted, empty omnibox must not intercept page clicks (split: \(splitView))")
            }
        }
    }

    private func addressField(in view: NSView) -> AddressField.Field? {
        if let field = view as? AddressField.Field { return field }
        return view.subviews.compactMap { addressField(in: $0) }.first
    }
}
