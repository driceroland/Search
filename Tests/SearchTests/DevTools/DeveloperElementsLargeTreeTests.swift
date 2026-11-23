import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Search

/// The Elements tree on a big document: flattening, expanding and scrolling
/// stay within a time budget, and only rows near the viewport are built.
@MainActor
final class DeveloperElementsLargeTreeTests: XCTestCase {
    private typealias Node = DeveloperToolsSession.DOMNode
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.contentView = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    /// document › html › body › `sections` sections of `items` items each,
    /// every item an element with attributes and one text child.
    private static func document(sections: Int, items: Int) -> (nodes: [Int: Node], sections: [Int]) {
        var nodes: [Int: Node] = [:]
        var next = 10
        func add(_ parent: Int?, type: Int = 1, name: String, text: String = "", attributes: [String] = [],
                 children: [Int] = [], count: Int? = nil) -> Int {
            next += 1
            nodes[next] = Node(id: next, parent: parent, type: type, name: name, text: text,
                               attributes: attributes, children: children, count: count ?? children.count)
            return next
        }
        nodes[1] = Node(id: 1, parent: nil, type: 9, name: "#document", text: "", attributes: [], children: [2], count: 1)
        nodes[2] = Node(id: 2, parent: 1, type: 1, name: "html", text: "", attributes: ["lang", "en"], children: [3], count: 1)
        nodes[3] = Node(id: 3, parent: 2, type: 1, name: "body", text: "", attributes: [], children: [], count: 0)
        var sectionIDs: [Int] = []
        for section in 0..<sections {
            let id = add(3, name: "section", attributes: ["id", "s\(section)", "class", "group"])
            var children: [Int] = []
            for item in 0..<items {
                let element = add(id, name: "div", attributes: ["class", "item item-\(item)", "data-index", "\(item)"], count: 1)
                let text = add(element, type: 3, name: "#text", text: "Item \(section).\(item)")
                nodes[element]?.children = [text]
                children.append(element)
            }
            nodes[id]?.children = children
            nodes[id]?.count = children.count
            sectionIDs.append(id)
        }
        nodes[3]?.children = sectionIDs
        nodes[3]?.count = sectionIDs.count
        return (nodes, sectionIDs)
    }

    func testFlatteningTenThousandRowsStaysWithinBudget() {
        let (nodes, sections) = Self.document(sections: 100, items: 100)
        XCTAssertGreaterThan(nodes.count, 20_000)
        let expanded: Set<Int> = Set([1, 2, 3] + sections)

        let start = Date()
        let rows = DeveloperDOMTreeModel.flatten(nodes: nodes, root: 1, expanded: expanded)
        let elapsed = Date().timeIntervalSince(start)
        // document, html, body, 100 sections, 10,000 items.
        XCTAssertEqual(rows.count, 3 + 100 + 10_000)
        XCTAssertEqual(rows.first?.node.type, 9)
        XCTAssertEqual(rows[3].node.name, "section")
        XCTAssertEqual(rows[4].depth, 4, "items sit under their section")
        XCTAssertLessThan(elapsed, 0.5, "flattening 10k rows took \(elapsed)s")

        // Collapsing a section is one more pass, as fast.
        let again = Date()
        let fewer = DeveloperDOMTreeModel.flatten(nodes: nodes, root: 1, expanded: expanded.subtracting([sections[50]]))
        XCTAssertLessThan(Date().timeIntervalSince(again), 0.5)
        XCTAssertEqual(fewer.count, rows.count - 100)
        // Each item's only child is short text: inline, nothing to expand.
        XCTAssertEqual(rows[10].inline, "Item 0.6")
        XCTAssertFalse(rows[10].expandable)

        // Row text is built once per node and reused until the node changes.
        let model = DeveloperDOMTreeModel(session: nil)
        let row = rows[10]
        let first = model.line(for: row)
        XCTAssertEqual(String(first.characters), "<div class=\"item item-6\" data-index=\"6\">Item 0.6</div>")
        let timed = Date()
        for _ in 0..<10_000 { _ = model.line(for: row) }
        XCTAssertLessThan(Date().timeIntervalSince(timed), 0.5, "cached lines are lookups")
    }

    func testTreeViewBuildsOnlyRowsNearTheViewport() async throws {
        _ = NSApplication.shared
        let (nodes, sections) = Self.document(sections: 100, items: 100)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        // No inspector: the tree is the fixture's alone.
        await session.disconnect().value
        session.loadTreeForTesting(nodes, root: 1, expanded: Set([1, 2, 3] + sections))

        DeveloperDOMRowCounter.rendered = 0
        let hosting = NSHostingView(rootView: DeveloperDOMTreeView(session: session, elements: session.elements))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        self.window = window
        let start = Date()
        try await settle(hosting)
        let firstRender = Date().timeIntervalSince(start)
        // 400pt of 16pt rows is 25; allow for the toolbar and lazy prefetch.
        XCTAssertGreaterThan(DeveloperDOMRowCounter.rendered, 0, "rows were drawn")
        XCTAssertLessThan(DeveloperDOMRowCounter.rendered, 300,
                          "rendered \(DeveloperDOMRowCounter.rendered) of 10,103 rows")
        XCTAssertLessThan(firstRender, 3, "first render of a 10k-row tree took \(firstRender)s")

        // Scrolling halfway down builds the rows there, not those between.
        if let scroll = Self.scrollView(in: hosting) {
            DeveloperDOMRowCounter.rendered = 0
            let scrolled = Date()
            let height = scroll.documentView?.bounds.height ?? 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: height / 2))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(hosting)
            XCTAssertLessThan(DeveloperDOMRowCounter.rendered, 300, "scrolling rendered \(DeveloperDOMRowCounter.rendered) rows")
            XCTAssertLessThan(Date().timeIntervalSince(scrolled), 2)
        }

        // Selecting a row far down scrolls to it without building the rest.
        DeveloperDOMRowCounter.rendered = 0
        let target = nodes[sections[97]]!.children[42]
        let selected = Date()
        session.selectForTesting(target)
        try await settle(hosting)
        XCTAssertLessThan(DeveloperDOMRowCounter.rendered, 300, "selecting rendered \(DeveloperDOMRowCounter.rendered) rows")
        XCTAssertLessThan(Date().timeIntervalSince(selected), 2)

        // Expanding a section's items again (collapse, then open) is one
        // coalesced rebuild, not one per change.
        let section = sections[20]
        DeveloperDOMRowCounter.rendered = 0
        let expandStart = Date()
        session.expanded.remove(section)
        session.expanded.insert(section)
        for item in sections.prefix(50) { session.expanded.insert(item) }
        try await settle(hosting)
        XCTAssertLessThan(Date().timeIntervalSince(expandStart), 2)
        XCTAssertLessThan(DeveloperDOMRowCounter.rendered, 300)

        withExtendedLifetime((page, tab, session)) {}
    }

    /// Lays out and lets the tree's per-frame rebuild and SwiftUI's update run.
    private func settle(_ view: NSView) async throws {
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView != nil { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }
}
