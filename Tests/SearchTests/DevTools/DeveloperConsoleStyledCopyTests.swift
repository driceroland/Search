import AppKit
import SwiftUI
import XCTest
@testable import Search

final class DeveloperConsoleStyledCopyTests: XCTestCase {
    private typealias Line = DeveloperToolsSession.ConsoleLine

    private func styledLine() -> Line {
        Line(level: "log", text: "Hello world 42", details: ConsoleMessageDetails(source: "console-api", type: "log", parameters: [
            ConsoleRemoteObject(type: "string", value: .string("%cHello %cworld")),
            ConsoleRemoteObject(type: "string", value: .string("color: red; font-weight: bold")),
            ConsoleRemoteObject(type: "string", value: .string("font-style: italic; background: blue")),
            ConsoleRemoteObject(type: "number", value: .number(42)),
        ]))
    }

    private func rgb(_ value: Any?) -> (Double, Double, Double)? {
        guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else { return nil }
        return (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
    }

    func testStyledCopyKeepsPercentCStyles() throws {
        let row = ConsoleRow(line: styledLine(), depth: 0, opensGroup: false, collapsed: false)
        let text = ConsoleStyledCopy.attributed([row])
        XCTAssertEqual(text.string, "Hello world 42")

        // "Hello ": red and bold.
        let hello = text.attributes(at: 0, effectiveRange: nil)
        let red = try XCTUnwrap(rgb(hello[.foregroundColor]))
        XCTAssertEqual(red.0, 1, accuracy: 0.01)
        XCTAssertEqual(red.1, 0, accuracy: 0.01)
        XCTAssertEqual(red.2, 0, accuracy: 0.01)
        let bold = try XCTUnwrap(hello[.font] as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        XCTAssertNil(hello[.backgroundColor])

        // "world": italic on blue, in the destination's own text colour.
        let world = text.attributes(at: 6, effectiveRange: nil)
        let italic = try XCTUnwrap(world[.font] as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
        XCTAssertFalse(NSFontManager.shared.traits(of: italic).contains(.boldFontMask))
        let blue = try XCTUnwrap(rgb(world[.backgroundColor]))
        XCTAssertEqual(blue.2, 1, accuracy: 0.01)
        XCTAssertNil(world[.foregroundColor])

        // The number argument keeps the console's value colour.
        let number = text.attributes(at: 12, effectiveRange: nil)
        XCTAssertNotNil(number[.foregroundColor])
    }

    func testStyledCopyJoinsMessagesAndWritesRTF() throws {
        let plain = Line(level: "error", text: "broken")
        let rows = [ConsoleRow(line: styledLine(), depth: 0, opensGroup: false, collapsed: false),
                    ConsoleRow(line: plain, depth: 0, opensGroup: false, collapsed: false)]
        let text = ConsoleStyledCopy.attributed(rows)
        XCTAssertEqual(text.string, "Hello world 42\nbroken")
        // An error keeps its red.
        XCTAssertNotNil(text.attributes(at: text.length - 1, effectiveRange: nil)[.foregroundColor])

        let rtf = try XCTUnwrap(ConsoleStyledCopy.rtf(text))
        let source = try XCTUnwrap(String(data: rtf, encoding: .ascii))
        XCTAssertTrue(source.hasPrefix("{\\rtf"))
        XCTAssertTrue(source.contains("Hello"))
        let back = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                          documentAttributes: nil)
        XCTAssertEqual(back.string, "Hello world 42\nbroken")
        let red = try XCTUnwrap(rgb(back.attributes(at: 0, effectiveRange: nil)[.foregroundColor]))
        XCTAssertEqual(red.0, 1, accuracy: 0.05)
        XCTAssertEqual(red.2, 0, accuracy: 0.05)
    }

    func testStyleAttributesFromCSS() {
        let style = ConsoleStyle(css: "color: #00ff00; text-decoration: underline line-through; font-size: 20px; font-family: Helvetica")
        let attributes = ConsoleStyledCopy.attributes(style, color: nil)
        XCTAssertEqual((attributes[.font] as? NSFont)?.pointSize, 20)
        XCTAssertFalse((attributes[.font] as? NSFont)?.isFixedPitch ?? true)
        XCTAssertEqual(attributes[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(attributes[.strikethroughStyle] as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(rgb(attributes[.foregroundColor])?.1 ?? 0, 1, accuracy: 0.01)
    }
}
