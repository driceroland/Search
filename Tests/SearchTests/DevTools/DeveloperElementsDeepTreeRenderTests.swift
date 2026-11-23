import AppKit
import WebKit
import XCTest
import class SwiftUI.NSHostingView
@testable import Search

/// A tree nested 30 deep in a narrow panel: with Wrap lines, deep rows keep
/// a readable width and the tree scrolls sideways to them; without, long
/// lines run on, untruncated, and the tree scrolls sideways too.
@MainActor
final class DeveloperElementsDeepTreeRenderTests: XCTestCase {
    private typealias Node = DeveloperToolsSession.DOMNode
    private var window: NSWindow?

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "developerTools.elements.wrapLines")
        window?.contentView = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    func testDeepRowsKeepTheirWidthAndScrollSideways() async throws {
        _ = NSApplication.shared
        var nodes: [Int: Node] = [:]
        nodes[1] = Node(id: 1, parent: nil, type: 9, name: "#document", text: "", attributes: [], children: [2], count: 1)
        var parent = 1, ids: [Int] = []
        for depth in 0..<30 {
            let id = 2 + depth
            nodes[id] = Node(id: id, parent: parent, type: 1, name: depth == 0 ? "html" : "div", text: "",
                             attributes: ["class", "product-media-gallery level-\(depth) row full-width-row-full", "id", "MediaGallery-template--\(depth)"],
                             children: [], count: 1)
            nodes[parent]?.children = [id]
            ids.append(id)
            parent = id
        }
        nodes[parent]?.count = 0
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        await session.disconnect().value
        session.loadTreeForTesting(nodes, root: 1, expanded: Set([1] + ids))

        for wraps in [true, false] {
            UserDefaults.standard.set(wraps, forKey: "developerTools.elements.wrapLines")
            let hosting = NSHostingView(rootView: DeveloperDOMTreeView(session: session, elements: session.elements))
            hosting.frame = NSRect(x: 0, y: 0, width: 330, height: 640)
            let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 330, height: 640),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderFront(nil)
            self.window = window
            for _ in 0..<6 {
                hosting.layoutSubtreeIfNeeded()
                hosting.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            let scroll = try XCTUnwrap(Self.scrollView(in: hosting))
            let content = scroll.documentView?.frame.width ?? 0
            XCTAssertGreaterThan(content, 330 + 100, "wraps \(wraps): the deep rows make the tree wider than the panel")
            if let dir = ProcessInfo.processInfo.environment["PERCH_RENDER_DIR"],
               let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("deep-tree-\(wraps ? "wrap" : "nowrap").png"))
            }
            window.contentView = nil
            window.close()
        }
        withExtendedLifetime((page, tab, session)) {}
    }

    private static func dump(_ view: NSView, _ wraps: Bool) {
        if let scroll = view as? NSScrollView {
            print("[deep] wraps \(wraps) scroll \(scroll.frame.size) doc \(scroll.documentView.map { "\(type(of: $0)) \($0.frame.size)" } ?? "none") h \(scroll.hasHorizontalScroller)")
        }
        for child in view.subviews { dump(child, wraps) }
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView != nil { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }
}
