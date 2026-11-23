import AppKit
import XCTest
@testable import Search

/// The Sources panel's code view itself: shown in a window off screen.
@MainActor
final class DeveloperSourcesViewTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
    }

    private func host() -> SourceContainerView {
        _ = NSApplication.shared
        let container = SourceContainerView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 700, height: 430), styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 430))
        content.addSubview(container)
        window.contentView = content
        window.layoutIfNeeded()
        self.window = window
        return container
    }

    private func minifiedBundle(_ size: Int) -> String {
        let chunk = #"function n(e,t){var r=e.length,o=/[a-z]+\d*/gi;if(!r)return t?`${e}:${t}`:"none";for(var i=0;i<r;i++){switch(e[i]){case 1:t+=e[i]*2;break;default:t={k:"v",n:[1,2,{x:!0}]}}}return t}"#
        var text = ""
        text.reserveCapacity(size + chunk.utf16.count)
        while text.utf16.count < size { text += chunk }
        return text
    }

    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags, code: UInt16, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    func testHalfAMegabyteOnOneLineShowsAndColoursQuickly() throws {
        let container = host()
        let text = minifiedBundle(500_000)
        let tokens = SourceHighlighter.tokens(text, language: .js)
        let textView = container.textView

        var started = Date()
        textView.show(text, lineStarts: SourceLexing.lineStarts(text), id: 0, caret: nil)
        container.layoutSubtreeIfNeeded()
        textView.displayIfNeeded()
        let showTime = Date().timeIntervalSince(started)

        started = Date()
        textView.setTokens(tokens, id: 0)
        textView.displayIfNeeded()
        let paintTime = Date().timeIntervalSince(started)

        started = Date()
        textView.scroll(NSPoint(x: 0, y: textView.bounds.height / 2))
        textView.paintVisible()
        container.gutter.displayIfNeeded()
        textView.displayIfNeeded()
        let scrollTime = Date().timeIntervalSince(started)
        print("500 KB on one line: show \(Int(showTime * 1000)) ms, colour \(Int(paintTime * 1000)) ms, jump to the middle \(Int(scrollTime * 1000)) ms")

        XCTAssertLessThan(showTime, 2)
        XCTAssertLessThan(paintTime, 0.5)
        XCTAssertLessThan(scrollTime, 2)
        // Coloured where it is looking, plain far away.
        let layout = try XCTUnwrap(textView.layoutManager)
        let middle = textView.characterIndexForInsertion(at: NSPoint(x: 40, y: textView.visibleRect.midY))
        var found = false
        for offset in max(0, middle - 400)..<min(text.utf16.count, middle + 400) where layout.temporaryAttribute(.foregroundColor, atCharacterIndex: offset, effectiveRange: nil) != nil {
            found = true
            break
        }
        XCTAssertTrue(found, "nothing coloured where the view is looking")
    }

    func testFindAndGoToLineKeysBelongToTheCodeView() throws {
        let container = host()
        let window = try XCTUnwrap(self.window)
        let text = (1...200).map { "let line\($0) = \($0);" }.joined(separator: "\n")
        container.textView.show(text, lineStarts: SourceLexing.lineStarts(text), id: 0, caret: nil)
        window.makeFirstResponder(container.textView)

        XCTAssertTrue(DeveloperSourceKeys.take(key("f", .command, code: 3, in: window)))
        XCTAssertTrue(container.scrollView.isFindBarVisible)

        XCTAssertTrue(DeveloperSourceKeys.take(key("\u{1b}", [], code: 53, in: window)))
        XCTAssertFalse(container.scrollView.isFindBarVisible)

        // ⌃G: Chrome's quick-open box, on ":".
        XCTAssertTrue(DeveloperSourceKeys.take(key("g", .control, code: 5, in: window)))
        XCTAssertTrue(container.showsQuickOpen)
        XCTAssertEqual(container.quickOpenTitles, ["Current line: 1. Type a line number between 1 and 200 to navigate to."])
        XCTAssertTrue(DeveloperSourceKeys.take(key("\u{1b}", [], code: 53, in: window)))
        XCTAssertFalse(container.showsQuickOpen)

        // ⇧⌘O: the file's symbols.
        let script = "function alpha(a, b) {}\nclass Beta { gamma(x) { return x } }\nconst delta = (y) => y"
        container.textView.language = .js
        container.textView.show(script, lineStarts: SourceLexing.lineStarts(script), id: 1, caret: nil)
        window.makeFirstResponder(container.textView)
        XCTAssertTrue(DeveloperSourceKeys.take(key("o", [.command, .shift], code: 31, in: window)))
        XCTAssertEqual(container.quickOpenTitles, ["alpha(a, b)", "class Beta", "gamma(x)", "delta(y)"])
        container.chooseQuickOpen(2)
        XCTAssertFalse(container.showsQuickOpen)
        XCTAssertEqual(container.textView.lineIndex(of: container.textView.selectedRange().location), 1)

        container.textView.show(text, lineStarts: SourceLexing.lineStarts(text), id: 2, caret: nil)
        container.textView.go(toLine: 150, column: 5)
        let range = container.textView.selectedRange()
        XCTAssertEqual(container.textView.lineIndex(of: range.location), 149)
        XCTAssertEqual(range.location - container.textView.lineStarts[149], 4)

        // Keys elsewhere aren't the code view's.
        let other = NSTextField()
        window.contentView?.addSubview(other)
        window.makeFirstResponder(other)
        XCTAssertFalse(DeveloperSourceKeys.take(key("f", .command, code: 3, in: window)))
    }

    func testPrettyPrintingTogglesAndMapsBreakpoints() async throws {
        let source = "function a(){b();c()}\nfunction d(){e()}"
        let document = SourceDocument(text: source, url: "https://example.com/app.js", type: "Script")
        XCTAssertEqual(document.display.lineStarts.count, 2)
        document.togglePretty()
        for _ in 0..<200 where !document.pretty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(document.pretty)
        XCTAssertEqual(document.display.text, "function a() {\n    b();\n    c()\n}\nfunction d() {\n    e()\n}")
        // Line 3 of the formatted text, `c()`, is column 17 of line 1.
        XCTAssertEqual(document.breakpointTarget(line: 3).line, 1)
        XCTAssertEqual(document.breakpointTarget(line: 3).column, 17)
        // The first formatted line of an original line sets a breakpoint by line.
        XCTAssertNil(document.breakpointTarget(line: 5).column)
        XCTAssertEqual(document.breakpointTarget(line: 5).line, 2)
        XCTAssertEqual(document.shownBreakpoints(lines: [2], columns: [SourceBreakpoint(line: 1, column: 17)]), [3, 5])

        document.togglePretty()
        XCTAssertFalse(document.pretty)
        XCTAssertEqual(document.display.text, source)
        XCTAssertEqual(document.shownBreakpoints(lines: [2], columns: [SourceBreakpoint(line: 1, column: 17)]), [1, 2])
    }

    func testMinifiedFileIsOfferedPrettyPrinting() async throws {
        let document = SourceDocument(text: minifiedBundle(5_000), url: "https://example.com/offer.min.js", type: "Script")
        for _ in 0..<200 where !document.minified { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(document.offersPrettyPrint)
        document.dismissOffer()
        XCTAssertFalse(document.offersPrettyPrint)

        let plain = SourceDocument(text: "let a = 1;\nlet b = 2;\n", url: "https://example.com/plain.js", type: "Script")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(plain.offersPrettyPrint)
    }
}
