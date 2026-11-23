import AppKit
import XCTest
@testable import Search

/// ⌘T and ⌘K come up over the page after the address line was clicked
/// into (#1374). The click marks the field as the line's (inlineEdit), and
/// nothing put that mark away: the next ⌘T came up in the line instead of
/// floating, and with Always show the address bar turned off, nowhere.
@MainActor
final class AddressLineLaunchTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private func page() throws -> (Browser, () -> Void) {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        let before = (prefs.floatingNewTab, prefs.addressLine)
        prefs.floatingNewTab = true
        prefs.addressLine = true
        let browser = Browser(record: WindowRecord())
        browser.welcoming = false
        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        tab.go(to: URL(string: "about:blank")!)
        XCTAssertFalse(browser.fieldShowing)
        return (browser, {
            browser.closeAll()
            (prefs.floatingNewTab, prefs.addressLine) = before
        })
    }

    /// The line's field, as a click on it raises it (AddressLine).
    private func clickLine(_ browser: Browser) {
        browser.edit()
        browser.inlineEdit = true
        XCTAssertTrue(browser.editingInline)
    }

    func testCommandTFloatsAfterTheLineWasClicked() throws {
        let (browser, done) = try page()
        defer { done() }
        clickLine(browser)
        // Put away (Escape, a click on the page), then ⌘T.
        browser.editing = false
        XCTAssertFalse(browser.inlineEdit, "the field put away is no longer the line's")
        browser.launch()
        XCTAssertTrue(browser.launching)
        XCTAssertFalse(browser.editingInline, "⌘T's field floats over the page")

        // With the line turned off, ⌘T still brings its field.
        browser.launch()
        XCTAssertFalse(browser.launching)
        browser.prefs.addressLine = false
        browser.launch()
        XCTAssertTrue(browser.launching)
        XCTAssertFalse(browser.editingInline)
    }

    func testCommandTAndKFromTheLinesFieldFloat() throws {
        let (browser, done) = try page()
        defer { done() }
        clickLine(browser)
        browser.launch()
        XCTAssertTrue(browser.launching)
        XCTAssertFalse(browser.editingInline)

        browser.editing = false
        clickLine(browser)
        browser.summon()
        XCTAssertTrue(browser.editing)
        XCTAssertFalse(browser.editingInline, "⌘K's switcher floats over the page")
    }
}
