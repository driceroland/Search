import AppKit
import SwiftUI
import XCTest
@testable import Search

@available(macOS 14, *)
@MainActor
final class PasteAndGoTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testAddressUsesItsOwnNativeFieldEditor() throws {
        let field = AddressField.Field(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        let ordinary = NSTextField(frame: NSRect(x: 0, y: 28, width: 240, height: 24))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(ordinary)
        XCTAssertTrue(window.makeFirstResponder(field))
        let addressEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(addressEditor.isFieldEditor)
        XCTAssertTrue(window.makeFirstResponder(ordinary))
        let ordinaryEditor = try XCTUnwrap(ordinary.currentEditor() as? NSTextView)
        XCTAssertFalse(addressEditor === ordinaryEditor, "Paste and Go belongs to the address editor, not the shared editor")
    }

    func testNativeMenuPreservesPasteAndOnlyNavigatesOnAction() throws {
        try withAddressField { field, board, click in
            let url = try XCTUnwrap(URL(string: "https://example.test/path?q=go#here"))
            XCTAssertTrue(board.writeObjects([url as NSURL]))
            var visited: [URL] = []
            var reads = 0
            field.pasteAndGoPasteboard = { reads += 1; return board }
            field.pasteAndGo = { visited.append($0) }
            XCTAssertEqual(reads, 0)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            let menu = try XCTUnwrap(editor.menu(for: click))
            XCTAssertTrue(menu.items.contains { $0.action == #selector(NSText.paste(_:)) })
            let item = try XCTUnwrap(menu.items.first { $0.title == "Paste and Go" })
            XCTAssertEqual(item.keyEquivalent, "")
            XCTAssertEqual(reads, 1)
            XCTAssertTrue(visited.isEmpty)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            XCTAssertEqual(visited, [url])
            XCTAssertEqual(reads, 2)
        }
    }

    func testStartTabMenuNavigatesTheExistingTabToClipboardAddress() async throws {
        let browser = Browser(record: WindowRecord())
        browser.welcoming = false
        browser.newsShowing = false
        defer { browser.closeAll() }
        browser.newTab()
        let tab = try XCTUnwrap(browser.active)
        XCTAssertTrue(browser.fieldShowing)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:1/paste-and-go"))
        XCTAssertTrue(board.setString(url.absoluteString, forType: .string))

        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(browser: browser))
        defer {
            ContentView.forget(browser)
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(400))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        let delegate: AnyObject? = editor.delegate
        let field = try XCTUnwrap(delegate as? AddressField.Field)
        field.pasteAndGoPasteboard = { board }
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
        editor.keyDown(with: key)
        XCTAssertEqual(editor.string, "q", "The field editor must accept normal keyboard input")
        XCTAssertEqual(browser.typed, "q", "Typed characters must reach the browser draft")
        let point = editor.convert(NSPoint(x: 8, y: 8), to: nil)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point,
                                                   modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(editor.menu(for: click))
        XCTAssertTrue(tab.isBlank)
        let item = try XCTUnwrap(menu.item(withTitle: "Paste and Go"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertTrue(browser.active === tab)
        XCTAssertEqual(tab.address, url)
        XCTAssertEqual(browser.typed, "")
    }

    func testNonWebClipboardDoesNotOfferPasteAndGo() throws {
        try withAddressField { field, board, click in
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            field.pasteAndGo = { _ in XCTFail("Menu request must never navigate") }
            XCTAssertNil(editor.menu(for: click)?.item(withTitle: "Paste and Go"))
            for text in ["words to look up", "todo", "1.2.3", "name@example.test", "search://settings",
                         "file:///tmp/file", "javascript:alert(1)", "about:blank", "https:///path",
                         "https://example.test\nhttps://other.test", "https://example.test and words"] {
                board.clearContents()
                XCTAssertTrue(board.setString(text, forType: .string))
                XCTAssertNil(editor.menu(for: click)?.item(withTitle: "Paste and Go"), text)
            }
        }
    }

    func testCopiedWebsiteWithoutSchemeOffersPasteAndGo() throws {
        try withAddressField { field, board, click in
            var visited: URL?
            field.pasteAndGo = { visited = $0 }
            XCTAssertTrue(board.setString("example.test/path?q=go#here", forType: .string))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            let item = try XCTUnwrap(editor.menu(for: click)?.item(withTitle: "Paste and Go"))
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            XCTAssertEqual(visited?.absoluteString, "https://example.test/path?q=go#here")
        }
    }

    func testActionRechecksClipboardAndDoesNotNavigateAfterFocusLeaves() throws {
        try withAddressField { field, board, click in
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            field.pasteAndGo = { _ in XCTFail("An invalid or stale action must not navigate") }
            XCTAssertTrue(board.setString(" \nhttps://example.test/path\n", forType: .string))
            let menu = try XCTUnwrap(editor.menu(for: click))
            let item = try XCTUnwrap(menu.item(withTitle: "Paste and Go"))
            let action = try XCTUnwrap(item.action)
            board.clearContents()
            XCTAssertTrue(board.setString("not a website", forType: .string))
            XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
            board.clearContents()
            XCTAssertTrue(board.setString("https://example.test/other", forType: .string))
            XCTAssertTrue(try XCTUnwrap(field.window).makeFirstResponder(nil))
            XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
        }
    }

    private func withAddressField(_ body: (AddressField.Field, NSPasteboard, NSEvent) throws -> Void) throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let field = AddressField.Field(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.pasteAndGoPasteboard = { board }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 8, y: 8),
                                                   modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        try body(field, board, click)
    }
}
