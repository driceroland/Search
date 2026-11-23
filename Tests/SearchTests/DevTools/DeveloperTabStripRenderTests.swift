import XCTest
import WebKit
import SwiftUI
@testable import Search

/// Tab rows in a narrow room scroll sideways instead of truncating their
/// labels ("Sty…"), as the Sources navigator's tabs do.
@MainActor
final class DeveloperTabStripRenderTests: XCTestCase {
    func testANarrowTabRowKeepsItsLabelsWhole() throws {
        let labels = ["Styles", "Computed", "Layout", "Event Listeners", "DOM Breakpoints", "Properties", "Accessibility"]
        let strip = HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            ForEach(labels, id: \.self) { Text($0).padding(.horizontal, 5) }
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .developerTabStrip()
        .frame(width: 220, height: DeveloperToolsStyle.toolbarHeight)
        let host = NSHostingView(rootView: strip)
        host.frame.size = CGSize(width: 220, height: DeveloperToolsStyle.toolbarHeight)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: host.frame.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        if let dir = ProcessInfo.processInfo.environment["PERCH_RENDER_DIR"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("tab-strip.png"))
        }
        // The row scrolls: an NSScrollView whose document is wider than the room.
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        let scroll = try XCTUnwrap(scrollViews(host).first)
        XCTAssertGreaterThan(scroll.documentView?.frame.width ?? 0, 500, "the labels were squeezed instead of scrolling")
    }
}
