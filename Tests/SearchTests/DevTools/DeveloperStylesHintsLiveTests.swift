import AppKit
import WebKit
import XCTest
@testable import Search

/// Elements › Styles' hints and the Elements preferences against a real page.
@MainActor
final class DeveloperStylesHintsLiveTests: XCTestCase {
    func testFlexWrapOnABlockElementIsMarkedInactive() async throws {
        try await withElements("""
            <!doctype html><title>Styles hints fixture</title>
            <style>#box { display: block; flex-wrap: wrap; color: red; }</style>
            <div id="box">Box</div>
            """) { session in
            let node = try await find("#box", in: session)
            session.selectNode(node)
            try await DeveloperTestSupport.wait("styles and layout", in: "DeveloperStylesHintsLiveTests") {
                session.layoutContext != nil && session.matchedStyles.contains { rule in
                    rule.properties.contains { $0.name == "flex-wrap" }
                }
            }
            let context = try XCTUnwrap(session.layoutContext)
            let rule = try XCTUnwrap(session.matchedStyles.first { rule in rule.properties.contains { $0.name == "flex-wrap" } })
            let wrap = try XCTUnwrap(rule.properties.first { $0.name == "flex-wrap" })
            let reason = DeveloperInactiveCSS.reason(property: wrap.name, value: wrap.value, in: context)
            XCTAssertEqual(reason, "The display: block property prevents flex-wrap from having an effect. Try setting display to flex.")
            let color = try XCTUnwrap(rule.properties.first { $0.name == "color" })
            XCTAssertNil(DeveloperInactiveCSS.reason(property: color.name, value: color.value, in: context))
        }
    }

    /// Chrome lists an element's user agent rules under its own, marked
    /// "user agent stylesheet": an h1's display, font-size and margins.
    func testAnH1ShowsItsUserAgentRule() async throws {
        try await withElements("""
            <!doctype html><title>Styles hints fixture</title>
            <style>h1 { color: red; }</style>
            <h1 id="title">Title</h1>
            """) { session in
            let node = try await find("#title", in: session)
            session.selectNode(node)
            try await DeveloperTestSupport.wait("styles", in: "DeveloperStylesHintsLiveTests") {
                session.matchedStyles.contains { $0.properties.contains { $0.name == "color" } }
            }
            try await Task.sleep(for: .milliseconds(300))
            // WebKit's own sheet writes them as :heading(1) and :heading.
            let size = try XCTUnwrap(session.matchedStyles.first { $0.origin == "user-agent" && $0.selector == ":heading(1)" },
                                     "no user agent rule for h1")
            XCTAssertTrue(size.properties.contains { $0.name == "font-size" })
            let heading = try XCTUnwrap(session.matchedStyles.first { $0.origin == "user-agent" && $0.selector == ":heading" })
            XCTAssertTrue(heading.properties.contains { $0.name == "display" })
            // body's margin as its sheet writes it, as Chrome shows it.
            let body = try XCTUnwrap(session.matchedStyles.first { $0.origin == "user-agent" && $0.selector == "body" })
            XCTAssertTrue(body.properties.contains { $0.name == "margin" && $0.value == "8px" })
        }
    }

    func testARangeInputHasAUserAgentShadowRootWithTheSettingOn() async throws {
        let key = DeveloperElementsSettings.userAgentShadowDOMKey
        let before = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let before { UserDefaults.standard.set(before, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await withElements("""
            <!doctype html><title>Styles hints fixture</title>
            <input id="range" type="range" min="0" max="10" value="4">
            """) { session in
            let node = try await find("#range", in: session)
            session.selectNode(node)
            try await DeveloperTestSupport.wait("the input in the tree", in: "DeveloperStylesHintsLiveTests") {
                session.nodes[node] != nil
            }
            if let input = session.nodes[node], !session.expanded.contains(node) { session.expand(input) }
            try await DeveloperTestSupport.wait("a user agent shadow root", in: "DeveloperStylesHintsLiveTests", state: {
                let children = session.nodes[node]?.children ?? []
                return "children: " + children.map { session.nodes[$0]?.display ?? "?" }.joined(separator: ", ")
            }) {
                session.nodes[node]?.children.contains { session.nodes[$0]?.shadowRootType == "user-agent" } ?? false
            }
        }
    }

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
        try await DeveloperTestSupport.wait("page to load", in: "DeveloperStylesHintsLiveTests") {
            page.title == "Styles hints fixture"
        }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        do {
            try await DeveloperTestSupport.wait("inspector and document", in: "DeveloperStylesHintsLiveTests") {
                session.ready && session.root != nil
            }
            try await check(session)
        } catch {
            await DeveloperTestSupport.finish(session, page: page, keeping: server, tab)
            throw error
        }
        await DeveloperTestSupport.finish(session, page: page, keeping: server, tab)
    }
}
