import AppKit
import WebKit
import XCTest
@testable import Search

/// Chrome DevTools parity in Elements, against a live page: the at-rule
/// sections in Styles, the tree's container, scroll-snap, top-layer, slot
/// and subgrid badges, and the full-page accessibility tree.
@MainActor
final class DeveloperElementsParityLiveTests: XCTestCase {
    func testStylesShowTheAtRulesTheElementUses() async throws {
        try await withElements("""
            <!doctype html><title>Elements parity fixture</title>
            <style>
            @property --accent { syntax: "<color>"; inherits: false; initial-value: red; }
            @property --unused { syntax: "<length>"; inherits: false; initial-value: 0px; }
            @keyframes fade { from { opacity: 0; } to { opacity: 1; } }
            @keyframes unused { from { opacity: 0; } }
            @font-face { font-family: "Fixture Sans"; src: local("Helvetica"); }
            #box { animation: fade 10s infinite; color: var(--accent); font-family: "Fixture Sans", sans-serif; }
            </style>
            <div id="box">Box</div>
            """) { session in
            let box = try await find("#box", in: session)
            session.selectNode(box)
            try await DeveloperTestSupport.wait("at-rule sections", in: "DeveloperElementsParityLiveTests") {
                session.matchedStyles.contains { $0.section == "@keyframes fade" }
            }
            let keyframes = session.matchedStyles.filter { $0.section == "@keyframes fade" }
            XCTAssertEqual(keyframes.count, 2)
            XCTAssertEqual(keyframes.first?.properties.first?.name, "opacity")
            XCTAssertFalse(session.matchedStyles.contains { $0.section == "@keyframes unused" })
            let properties = session.matchedStyles.filter { $0.section == "@property" }
            XCTAssertEqual(properties.map(\.selector), ["--accent"], "only the registered properties the element uses")
            XCTAssertTrue(properties.first?.properties.contains { $0.name == "initial-value" } == true)
            XCTAssertTrue(session.matchedStyles.contains { $0.section == "@font-face" })
            XCTAssertTrue(session.matchedStyles.filter(\.atRule).allSatisfy { !$0.editable })
            // The element's own rule still wins its declarations.
            let own = try XCTUnwrap(session.matchedStyles.first { $0.selector == "#box" })
            XCTAssertFalse(own.properties.contains { $0.overridden })
            // At-rules come after the matched rules, as in Chrome.
            let firstAtRule = try XCTUnwrap(session.matchedStyles.firstIndex { $0.atRule })
            XCTAssertFalse(session.matchedStyles[firstAtRule...].contains { !$0.atRule })
        }
    }

    func testTreeBadgesForContainersSnapTopLayerSlotsAndSubgrids() async throws {
        try await withElements("""
            <!doctype html><title>Elements parity fixture</title>
            <div id="cq" style="container-type: inline-size">Container</div>
            <div id="snap" style="overflow: auto; height: 50px; scroll-snap-type: y mandatory">
                <div style="height: 60px; scroll-snap-align: start">A</div>
                <div style="height: 60px; scroll-snap-align: start">B</div>
            </div>
            <div id="grid" style="display: grid; grid-template-columns: 1fr 1fr">
                <div id="sub" style="display: grid; grid-column: span 2; grid-template-columns: subgrid">Subgrid</div>
            </div>
            <div id="host"><span id="slotted">Slotted</span></div>
            <div id="plain">Plain</div>
            <dialog id="modal">Modal</dialog>
            <script>
            document.getElementById("host").attachShadow({mode: "open"}).innerHTML = "<slot></slot>";
            document.getElementById("modal").showModal();
            </script>
            """) { session in
            var ids: [Int] = []
            for selector in ["#cq", "#snap", "#sub", "#slotted", "#modal", "#plain"] {
                ids.append(try await find(selector, in: session))
            }
            let raw = try await session.elementsBridge("return await perchElements.flags(ids, target);", [
                "ids": ids, "target": session.domTargetID as Any? ?? NSNull(),
            ]) as? [String: [String]] ?? [:]
            func flags(_ index: Int) -> [String] { raw[String(ids[index])] ?? [] }
            XCTAssertTrue(flags(0).contains("container"))
            XCTAssertTrue(flags(1).contains("scroll-snap"))
            XCTAssertTrue(flags(2).contains("subgrid"))
            XCTAssertTrue(flags(3).contains("slot"))
            XCTAssertTrue(flags(4).contains("top-layer"))
            XCTAssertFalse(flags(5).contains { DeveloperDOMTreeView.pageBadges.contains($0) })

            // The container badge's overlay, drawn by the page and taken
            // down again when switched off.
            let web = try XCTUnwrap(session.web)
            func shown() async throws -> Int {
                let value = try await web.evaluateJavaScript(
                    "document[Symbol.for('perch.elementsOverlay')]?.count?.() ?? 0")
                return (value as? NSNumber)?.intValue ?? 0
            }
            session.setPageOverlay(ids[0], kind: "container", on: true)
            XCTAssertTrue(session.elements.pageOverlays.contains(.init(node: ids[0], kind: "container")))
            var count = 0
            for _ in 0..<100 where count == 0 {
                count = try await shown()
                if count == 0 { try await Task.sleep(for: .milliseconds(50)) }
            }
            XCTAssertEqual(count, 1)
            session.setPageOverlay(ids[1], kind: "scroll-snap", on: true)
            for _ in 0..<100 where count == 1 {
                count = try await shown()
                if count == 1 { try await Task.sleep(for: .milliseconds(50)) }
            }
            XCTAssertEqual(count, 2)
            session.setPageOverlay(ids[0], kind: "container", on: false)
            session.setPageOverlay(ids[1], kind: "scroll-snap", on: false)
            for _ in 0..<100 where count != 0 {
                count = try await shown()
                if count != 0 { try await Task.sleep(for: .milliseconds(50)) }
            }
            XCTAssertEqual(count, 0)
            XCTAssertTrue(session.elements.pageOverlays.isEmpty)
        }
    }

    func testAccessibilityTreeOpensLevelByLevelAndSelectsTheDOMNode() async throws {
        try await withElements("""
            <!doctype html><title>Elements parity fixture</title>
            <main id="main">
                <div><div><button id="open">Open panel</button></div></div>
                <a id="link" href="#x">Read more</a>
            </main>
            <div aria-hidden="true"><button id="hidden">Hidden</button></div>
            """) { session in
            let tree = DeveloperAccessibilityTree()
            await tree.load(session)
            let root = try XCTUnwrap(tree.roots.first, "the tree has a root row")
            XCTAssertTrue(tree.expanded.contains(root.id), "the root opens, as in Chrome")
            let main = try await find("#main", in: session)
            let button = try await find("#open", in: session)
            let link = try await find("#link", in: session)
            let hidden = try await find("#hidden", in: session)

            // Open rows down to the button; ignored wrappers are skipped.
            var found: DeveloperAccessibilityTree.Row?
            for _ in 0..<8 where found == nil {
                for row in tree.rows where row.node.childCount > 0 && !tree.expanded.contains(row.id) {
                    await tree.open(row.id, session)
                }
                found = tree.rows.first { $0.id == button }
            }
            let row = try XCTUnwrap(found, "the button is in the tree")
            XCTAssertEqual(row.node.role, "button")
            XCTAssertEqual(row.node.name, "Open panel")
            XCTAssertTrue(tree.rows.contains { $0.id == main })
            XCTAssertTrue(tree.rows.contains { $0.id == link && $0.node.name == "Read more" })
            XCTAssertFalse(tree.rows.contains { $0.id == hidden }, "nodes the tree ignores aren't listed")

            session.selectNode(row.id)
            XCTAssertEqual(session.selectedNode, button)
            try await DeveloperTestSupport.wait("styles of the selected node", in: "DeveloperElementsParityLiveTests") {
                !session.matchedStyles.isEmpty
            }
        }
    }

    // MARK: Fixture

    func find(_ selector: String, in session: DeveloperToolsSession) async throws -> Int {
        let matches = await session.searchDOM(selector)
        return try XCTUnwrap(matches.first, "Expected a DOM node for \(selector).")
    }

    func withElements(_ html: String, check: (DeveloperToolsSession) async throws -> Void) async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer(["/": .init(type: "text/html", body: html)])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = PageView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        defer { window.close() }
        page.load(URLRequest(url: server.url("/")))
        try await DeveloperTestSupport.wait("page to load", in: "DeveloperElementsParityLiveTests") {
            page.title == "Elements parity fixture"
        }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        defer { withExtendedLifetime((tab, server)) {} }
        do {
            try await DeveloperTestSupport.wait("inspector and document", in: "DeveloperElementsParityLiveTests") {
                session.ready && session.root != nil
            }
            try await check(session)
        } catch {
            await session.disconnect().value
            throw error
        }
        await session.disconnect().value
    }
}
