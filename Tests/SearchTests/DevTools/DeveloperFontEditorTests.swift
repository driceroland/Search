import XCTest
import SwiftUI
@testable import Search

final class DeveloperFontEditorTests: XCTestCase {
    typealias Detail = DeveloperToolsSession.Detail

    func testButtonSitsOnTheFirstEnabledFontDeclaration() {
        var off = Detail(name: "font-size", value: "12px"); off.enabled = false
        let rule = [Detail(name: "color", value: "red"), off, Detail(name: "line-height", value: "1.5"),
                    Detail(name: "font-family", value: "Inter")]
        XCTAssertFalse(DeveloperFontEditor.carriesButton(rule, at: 1))
        XCTAssertTrue(DeveloperFontEditor.carriesButton(rule, at: 2))
        XCTAssertFalse(DeveloperFontEditor.carriesButton(rule, at: 3))
        XCTAssertFalse(DeveloperFontEditor.carriesButton([Detail(name: "color", value: "red")], at: 0))
    }

    func testSplitReadsNumbersUnitsAndWeightKeywords() {
        XCTAssertEqual(DeveloperFontEditor.split("12.5px")?.number, 12.5)
        XCTAssertEqual(DeveloperFontEditor.split("12.5px")?.unit, "px")
        XCTAssertEqual(DeveloperFontEditor.split("1.4")?.unit, "")
        XCTAssertEqual(DeveloperFontEditor.split("-0.02em")?.number, -0.02)
        XCTAssertEqual(DeveloperFontEditor.split("150%")?.unit, "%")
        XCTAssertEqual(DeveloperFontEditor.split("bold")?.number, 700)
        XCTAssertNil(DeveloperFontEditor.split("var(--size)"))
        XCTAssertNil(DeveloperFontEditor.split("calc(1rem + 2px)"))
        XCTAssertNil(DeveloperFontEditor.split("larger"))
    }

    func testFamiliesRoundTripWithQuotes() {
        let families = DeveloperFontEditor.families(#""Helvetica Neue", Arial, 'Segoe UI', sans-serif"#)
        XCTAssertEqual(families, ["Helvetica Neue", "Arial", "Segoe UI", "sans-serif"])
        XCTAssertEqual(DeveloperFontEditor.familyCSS(families + [""]), #""Helvetica Neue", Arial, "Segoe UI", sans-serif"#)
    }

    func testSettingKeepsTheDeclarationInPlace() {
        let rule = [Detail(name: "font-size", value: "12px"), Detail(name: "color", value: "red")]
        let set = DeveloperFontEditor.setting("font-size", "14px", in: rule)
        XCTAssertEqual(set.map(\.name), ["font-size", "color"])
        XCTAssertEqual(set.first?.value, "14px")
        XCTAssertEqual(DeveloperFontEditor.setting("font-weight", "700", in: rule).map(\.name), ["font-size", "color", "font-weight"])
        XCTAssertEqual(DeveloperFontEditor.setting("font-size", nil, in: rule).map(\.name), ["color"])
        XCTAssertEqual(DeveloperFontEditor.css(14.004, unit: "px", step: 1), "14px")
        XCTAssertEqual(DeveloperFontEditor.css(1.456, unit: "", step: 0.1), "1.46")
        XCTAssertEqual(DeveloperFontEditor.css(644, unit: "", step: 100), "600")
    }
}

@MainActor
final class DeveloperFontEditorRenderTests: XCTestCase {
    /// Lays the popover out and, with PERCH_RENDER_DIR set, saves a picture
    /// of it to look at.
    func testEditorLaysOutItsRows() throws {
        typealias Detail = DeveloperToolsSession.Detail
        let rule = DeveloperToolsSession.StyleRule(id: 1, selector: ".brand", origin: "style.css", properties: [
            Detail(name: "font-family", value: #""Helvetica Neue", Arial, sans-serif"#),
            Detail(name: "font-size", value: "18px"), Detail(name: "line-height", value: "1.4"),
            Detail(name: "font-weight", value: "bold"), Detail(name: "letter-spacing", value: "var(--tight)"),
        ])
        let host = NSHostingView(rootView: DeveloperFontEditorView(rule: rule) { _, _ in })
        host.frame.size = host.fittingSize
        XCTAssertGreaterThan(host.fittingSize.width, 300)
        XCTAssertGreaterThan(host.fittingSize.height, 200)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: host.fittingSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let dir = ProcessInfo.processInfo.environment["PERCH_RENDER_DIR"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("font-editor.png"))
        }
    }
}
