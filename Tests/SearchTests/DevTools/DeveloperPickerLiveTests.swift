import AppKit
import WebKit
import XCTest
@testable import Search

/// DevTools' element picker on a real page: a hover lights the element
/// under the pointer within a frame or two, a burst of moves doesn't
/// queue up behind itself, the page hears no hovers meanwhile, and a
/// click selects the element under it.
@MainActor
final class DeveloperPickerLiveTests: XCTestCase {
    func testHoversLightQuicklyAndAClickSelects() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Picker fixture</title>
                <body style="margin:0">
                <div id=left style="position:absolute;left:0;top:0;width:200px;height:200px;background:#c33"></div>
                <div id=right style="position:absolute;left:300px;top:0;width:200px;height:200px;background:#33c"></div>
                """),
        ])
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
        try await DeveloperTestSupport.wait("page to load", in: "DeveloperPickerLiveTests") { page.title == "Picker fixture" }

        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        do {
            try await DeveloperTestSupport.wait("inspector", in: "DeveloperPickerLiveTests") { session.ready }
            session.togglePicker()
            XCTAssertTrue(session.picking)
            XCTAssertTrue(page.pickingElement)
            XCTAssertFalse(page.hears(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                       clickCount: 0, pressure: 0)!))

            // A first hover, then a burst of 30 moves: each settles fast.
            var timings: [Double] = []
            for round in 0..<5 {
                let start = Date()
                for step in 0..<6 { session.previewPick(NSPoint(x: 20 + step * 25, y: 50 + round)) }
                while !(session.highlightedPick != nil && !session.hoverBusy) {
                    if Date().timeIntervalSince(start) > 2 { return XCTFail("hover \(round) never settled") }
                    try await Task.sleep(for: .milliseconds(2))
                }
                timings.append(Date().timeIntervalSince(start) * 1000)
                session.previewPick(NSPoint(x: 250, y: 400))   // nothing there but the body
                try await DeveloperTestSupport.wait("hover off \(round)", seconds: 2, in: "DeveloperPickerLiveTests") { !session.hoverBusy }
            }
            print("[DeveloperPickerLiveTests] hover settle ms: \(timings.map { Int($0) })")
            XCTAssertLessThan(timings.sorted()[timings.count / 2], 50, "\(timings)")

            // A click picks the element under it.
            session.togglePicker()
            XCTAssertFalse(page.pickingElement)
            session.inspect(at: NSPoint(x: 350, y: 50))
            try await DeveloperTestSupport.wait("picked node", in: "DeveloperPickerLiveTests") {
                session.selectedNode.flatMap { session.nodes[$0]?.attributes }?.contains("right") == true
            }
            await session.disconnect().value
            withExtendedLifetime(tab) {}
        } catch {
            await session.disconnect().value
            throw error
        }
    }
}
