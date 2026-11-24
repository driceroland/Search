import AppKit
import WebKit
import XCTest
@testable import Search

/// adoptedStyleSheets read from a live page, and the tree's
/// `#adopted-style-sheets` row under the open document.
@MainActor
final class DeveloperAdoptedSheetsLiveTests: XCTestCase {
    func testTheDocumentsAdoptedSheetsAreReadAndShown() async throws {
        try await DeveloperElementsParityLiveTests().withElements("""
            <!doctype html><title>Elements parity fixture</title><div id="box">Box</div>
            <script>
            const sheet = new CSSStyleSheet();
            sheet.replaceSync("body { border-top: 4px solid teal } #box { outline: 1px dashed red }");
            document.adoptedStyleSheets = [sheet];
            </script>
            """) { session in
            let root = try XCTUnwrap(session.root)
            let sheets = try await session.adoptedSheets(of: root)
            XCTAssertEqual(sheets.count, 1)
            XCTAssertEqual(sheets.first??.count, 2)
            let model = DeveloperDOMTreeModel(session: session)
            try await DeveloperTestSupport.wait("the adopted sheets row", in: "DeveloperAdoptedSheetsLiveTests") {
                model.rows.contains { $0.sheet != nil }
            }
        }
    }

    /// The calc() hover's steps are worked out in the page, on the element.
    func testCalcStepsAreEvaluatedOnTheSelectedElement() async throws {
        try await DeveloperElementsParityLiveTests().withElements("""
            <!doctype html><title>Elements parity fixture</title>
            <style>:root { --base: 12px; --pad: var(--base); }
            #wrap { width: 400px } .box { width: calc(50% - var(--pad) * 2) }</style>
            <div id="wrap"><div class="box">Box</div></div>
            """) { session in
            let box = try await DeveloperElementsParityLiveTests().find(".box", in: session)
            session.selectNode(box)
            let value = "calc(50% - var(--pad) * 2)"
            let steps = DeveloperStyleEditing.mathSteps(value)
            XCTAssertEqual(steps.last, value)
            let results = await session.styleMathResults(of: box, property: "width", steps: steps)
            XCTAssertEqual(results.count, steps.count)
            XCTAssertEqual(results.last ?? nil, "176px")
            let lines = DeveloperStyleEditing.mathLines(steps, results: results, used: "176px")
            XCTAssertEqual(lines.last, "Used value: 176px")
        }
    }

    /// The var() hover follows a reference through each custom property
    /// to its value, with where each is declared, on a real page.
    func testVarChainFollowsTheElementsDeclarations() async throws {
        let parity = DeveloperElementsParityLiveTests()
        try await parity.withElements("""
            <!doctype html><title>Elements parity fixture</title>
            <style>:root { --base: 12px; --pad: var(--base); --gap: var(--pad) }
            .box { padding: var(--gap) }</style>
            <div class="box">Box</div>
            """) { session in
            let box = try await parity.find(".box", in: session)
            session.selectNode(box)
            try await DeveloperTestSupport.wait("the box's styles", in: "DeveloperAdoptedSheetsLiveTests") {
                session.matchedStyles.contains { $0.selector == ".box" }
                    && session.matchedStyles.contains { $0.properties.contains { $0.name == "--gap" } }
            }
            let lines = session.variableChain("var(--gap)")
            print("var chain:", lines)
            XCTAssertEqual(lines.count, 4, "\(lines)")
            XCTAssertTrue(lines[0].hasPrefix("--gap: var(--pad) — :root"), "\(lines)")
            XCTAssertTrue(lines[1].hasPrefix("  --pad: var(--base) — :root"), "\(lines)")
            XCTAssertTrue(lines[2].hasPrefix("    --base: 12px — :root"), "\(lines)")
            XCTAssertEqual(lines.last, "Value: 12px")
        }
    }

    /// Sources › Global Listeners lists the window's listeners, not the
    /// document's, and Remove takes one off the page.
    func testGlobalListenersAreTheWindowsOwn() async throws {
        try await DeveloperElementsParityLiveTests().withElements("""
            <!doctype html><title>Elements parity fixture</title><p>listeners</p>
            <script>
            window.addEventListener("resize", function onResize() {});
            window.addEventListener("message", function onMessage() {});
            document.addEventListener("click", function onClick() {});
            </script>
            """) { session in
            session.loadGlobalListeners()
            try await DeveloperTestSupport.wait("the window's listeners", in: "DeveloperAdoptedSheetsLiveTests") {
                Set(session.globalListeners.map(\.type)) == ["resize", "message"]
            }
            XCTAssertEqual(session.globalListeners.first { $0.type == "resize" }?.handler, "onResize")
            let message = try XCTUnwrap(session.globalListeners.first { $0.type == "message" })
            session.removeGlobalListener(message)
            try await DeveloperTestSupport.wait("message removed", in: "DeveloperAdoptedSheetsLiveTests") {
                session.globalListeners.map(\.type) == ["resize"]
            }
        }
    }
}
