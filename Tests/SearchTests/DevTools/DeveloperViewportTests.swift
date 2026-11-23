import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Search

@MainActor
final class DeveloperViewportTests: XCTestCase {
    func testRedockAndResponsivePreviewResizeTheSamePage() async throws {
        _ = NSApplication.shared
        let room = CGSize(width: 1_000, height: 780)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: room),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)

        func stage(_ dock: DeveloperDockPosition, extent: CGFloat, responsive: Bool) -> Fixture {
            Fixture(web: web, room: room, dock: dock, extent: extent, responsive: responsive)
        }

        let host = NSHostingView(rootView: stage(.bottom, extent: 300, responsive: false))
        window.contentView = host
        web.loadHTMLString("""
            <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
            <style>body{margin:0;overflow:hidden}main{width:100vw}</style>
            <main>Viewport test</main><script>window.visits = 7</script>
            """, baseURL: nil)
        try await waitForViewport(web, width: 1_000, height: 479)

        host.rootView = stage(.right, extent: 315, responsive: false)
        try await waitForViewport(web, width: 684, height: 780)

        host.rootView = stage(.right, extent: 530, responsive: false)
        try await waitForViewport(web, width: 469, height: 780)

        host.rootView = stage(.left, extent: 530, responsive: true)
        try await waitForViewport(web, width: 390, height: 844)
        let css = try await web.callAsyncJavaScript(
            "return [document.querySelector('main').offsetWidth, matchMedia('(max-width: 400px)').matches ? 1 : 0, window.visits];",
            arguments: [:], in: nil, contentWorld: .page
        ) as? [Int]
        XCTAssertEqual(css, [390, 1, 7])
        XCTAssertLessThan(web.convert(web.bounds, to: nil).height, 844)

        host.rootView = stage(.left, extent: 530, responsive: false)
        try await waitForViewport(web, width: 469, height: 780)
        let visits = try await web.evaluateJavaScript("window.visits") as? Int
        XCTAssertEqual(visits, 7)
    }

    private func waitForViewport(_ web: WKWebView, width: Int, height: Int) async throws {
        for _ in 0..<70 {
            if let size = await DeveloperCSSViewport.measure(in: web),
               size.width == width, size.height == height { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        let measured = await DeveloperCSSViewport.measure(in: web)
        XCTFail("Expected \(width) × \(height), found \(measured?.text ?? "no viewport")")
    }

    private struct Fixture: View {
        let web: WKWebView
        let room: CGSize
        let dock: DeveloperDockPosition
        let extent: CGFloat
        let responsive: Bool

        var body: some View {
            let page = DeveloperDockLayout(in: room, position: dock, extent: extent).page
            ZStack(alignment: .topLeading) {
                DeveloperViewportCanvas(web: web, room: page.size, responsive: responsive,
                                        dock: dock, settings: .constant(DeveloperViewportSettings())) {
                    WebStage(page: web)
                }
                .offset(x: page.minX, y: page.minY)
            }
            .frame(width: room.width, height: room.height, alignment: .topLeading)
        }
    }
}
