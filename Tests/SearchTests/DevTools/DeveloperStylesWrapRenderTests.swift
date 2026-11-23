import XCTest
import WebKit
import class SwiftUI.NSHostingView
import struct SwiftUI.VStack
import struct SwiftUI.ForEach
@testable import Search

/// The Styles pane in a narrow sidebar, where values of several var()
/// references wrap: each declaration must keep to its own rows, its name
/// on the value's first line, not rise over the declaration before it.
@MainActor
final class DeveloperStylesWrapRenderTests: XCTestCase {
    typealias Detail = DeveloperToolsSession.Detail

    func testWrappedValuesStayInTheirRows() throws {
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let session = DeveloperToolsSession(tab: Tab(shy: true), web: page, after: nil)
        let elements = DeveloperElementsState()
        let rules = [
            DeveloperToolsSession.StyleRule(id: 1, selector: ".product-single__media-ijewel .cta--line:hover", origin: "52ff338d.css:41", properties: [
                Detail(name: "box-shadow", value: "inset 0 0 0 var(--hairline) var(--ink)"),
            ]),
            DeveloperToolsSession.StyleRule(id: 2, selector: ".cta", origin: "52ff338d.css:30", properties: [
                Detail(name: "display", value: "inline-flex"),
                Detail(name: "padding", value: "var(--space-0) var(--space-6)"),
                Detail(name: "border-radius", value: "var(--radius-full)"),
                Detail(name: "font", value: "var(--weight-medium) var(--text-md) / var(--leading-none) var(--font-sans)"),
                Detail(name: "text-decoration", value: "none"),
            ]),
        ]
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) {
            ForEach(rules, id: \.id) { rule in
                DeveloperStyleRuleView(session: session, elements: elements, rule: rule, shown: Array(rule.properties.indices))
            }
        }.frame(width: 250).font(DeveloperToolsStyle.code))
        host.frame.size = CGSize(width: 250, height: host.fittingSize.height)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: host.frame.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let dir = ProcessInfo.processInfo.environment["PERCH_RENDER_DIR"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("styles-wrap.png"))
        }
        XCTAssertGreaterThan(host.fittingSize.height, 120)
    }
}
