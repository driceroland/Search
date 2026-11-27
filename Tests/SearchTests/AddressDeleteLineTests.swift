import AppKit
import XCTest
@testable import Search

/// ⌘⌫ in the address field while it offers the rest of an address (idea
/// 1334): the line goes at once, not only the offered ending, which the
/// field put straight back.
@MainActor
final class AddressDeleteLineTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private var browser: Browser!
    private var coordinator: AddressField.Coordinator!
    private let field = NSTextField()
    private let editor = NSTextView()

    override func setUp() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        coordinator = AddressField.Coordinator(browser: browser)
        editor.isFieldEditor = true
    }

    override func tearDown() {
        browser.closeAll()
        browser = nil
    }

    /// "goo" typed, "gle.com" offered after it and selected, as the field
    /// shows a completion.
    private func typeWithEnding() {
        browser.typing.ending = "gle.com"
        editor.string = "google.com"
        editor.setSelectedRange(NSRange(location: 3, length: 7))
        field.stringValue = editor.string
    }

    /// A key's command as AppKit runs it: the delegate first, then the text
    /// view, then the field told its text changed.
    private func press(_ command: Selector) {
        if !coordinator.control(field, textView: editor, doCommandBy: command) {
            editor.doCommand(by: command)
        }
        field.stringValue = editor.string
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    func testCommandDeleteTakesTheLineAtOnce() {
        typeWithEnding()
        press(#selector(NSResponder.deleteToBeginningOfLine(_:)))
        XCTAssertEqual(field.stringValue, "", "⌘⌫ took the line, not only the offered ending")
        XCTAssertNil(browser.typing.ending, "Nothing offered any more")
    }

    func testCommandDeleteWithNothingOffered() {
        browser.typing.ending = nil
        editor.string = "hello world"
        editor.setSelectedRange(NSRange(location: 11, length: 0))
        field.stringValue = editor.string
        press(#selector(NSResponder.deleteToBeginningOfLine(_:)))
        XCTAssertEqual(field.stringValue, "")
    }

    func testOptionDeleteStillTakesTheLastWord() {
        browser.typing.ending = "ple.com"
        editor.string = "open app"
        editor.string = "open apple.com"
        editor.setSelectedRange(NSRange(location: 8, length: 6))
        field.stringValue = editor.string
        press(#selector(NSResponder.deleteWordBackward(_:)))
        XCTAssertEqual(field.stringValue, "open ")
    }
}
