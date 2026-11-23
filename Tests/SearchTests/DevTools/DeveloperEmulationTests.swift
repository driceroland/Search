import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Search

@MainActor
final class DeveloperEmulationTests: XCTestCase {
    func testDeviceModeSendsTheDeviceUserAgentAndRestoresTheTabs() async throws {
        _ = NSApplication.shared
        let room = CGSize(width: 1_000, height: 900)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: room),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        let original = try await web.evaluateJavaScript("navigator.userAgent") as? String

        var settings = DeveloperViewportSettings()
        let pixel = try XCTUnwrap(DeveloperDevices.builtIn.first { $0.title == "Pixel 7" })
        settings.select(pixel)
        XCTAssertEqual(settings.width, 412)
        XCTAssertEqual(settings.height, 915)
        settings.rotate()
        XCTAssertEqual(settings.width, 915)
        settings.rotate()

        let host = NSHostingView(rootView: Fixture(web: web, room: room, responsive: true, settings: settings))
        window.contentView = host
        web.loadHTMLString("<!doctype html><meta name=viewport content='width=device-width'><p>Device</p>",
                           baseURL: URL(string: "https://device.test/"))
        try await waitFor("the Pixel 7 user agent") {
            let agent = try? await web.evaluateJavaScript("navigator.userAgent") as? String
            return agent?.contains("Pixel 7") == true
        }
        XCTAssertEqual(web.customUserAgent, pixel.userAgent)
        let size = await DeveloperCSSViewport.measure(in: web)
        XCTAssertEqual(size?.width, 412)
        if DeveloperDeviceEmulation.canEmulateScaleFactor {
            try await waitFor("the Pixel 7 device pixel ratio") {
                let ratio = try? await web.evaluateJavaScript("window.devicePixelRatio") as? Double
                return ratio.map { abs($0 - 2.625) < 0.01 } ?? false
            }
        }

        // Responsive, desktop type: Perch's own user agent again.
        settings.select(nil)
        settings.responsiveType = .desktop
        host.rootView = Fixture(web: web, room: room, responsive: true, settings: settings)
        try await waitFor("the browser's own user agent in desktop Responsive") {
            let agent = try? await web.evaluateJavaScript("navigator.userAgent") as? String
            return agent == original
        }

        settings.responsiveType = .mobile
        host.rootView = Fixture(web: web, room: room, responsive: true, settings: settings)
        try await waitFor("the mobile user agent in Responsive") {
            let agent = try? await web.evaluateJavaScript("navigator.userAgent") as? String
            return agent == DeveloperDevices.responsiveMobileUserAgent
        }

        host.rootView = Fixture(web: web, room: room, responsive: false, settings: settings)
        try await waitFor("the tab's own user agent after device mode") {
            let agent = try? await web.evaluateJavaScript("navigator.userAgent") as? String
            return agent == original
        }
        XCTAssertEqual(web.customUserAgent ?? "", "")
        print("Perch device pixel ratio emulation:", DeveloperDeviceEmulation.canEmulateScaleFactor)
    }

    func testRenderingOverridesReachTheInspectedPage() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Rendering fixture</title>
                <style>@media print { p { color: rgb(1, 2, 3) } }</style><p>Rendering</p>
                """),
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 440), configuration: configuration)
        page.load(URLRequest(url: server.url("/")))
        try await waitFor("the fixture") { page.title == "Rendering fixture" && !page.isLoading }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        try await waitFor("the inspector") { session.ready }

        func query(_ media: String) async -> Bool {
            let result = try? await page.callAsyncJavaScript("return matchMedia(query).matches;",
                arguments: ["query": media], in: nil, contentWorld: .page)
            return result as? Bool == true
        }
        let rendering = session.rendering
        rendering.prepare(in: session)
        try await waitFor("Rendering support") { rendering.support != nil }
        let support = try XCTUnwrap(rendering.support)
        XCTAssertTrue(support.media)
        XCTAssertTrue(support.preferences.contains("PrefersColorScheme"))

        let systemDark = await query("(prefers-color-scheme: dark)")
        rendering.update(in: session) { $0.colorScheme = systemDark ? "Light" : "Dark" }
        try await waitFor("the emulated colour scheme") {
            await query("(prefers-color-scheme: dark)") == !systemDark
        }
        rendering.update(in: session) { $0.mediaType = "print" }
        try await waitFor("print media") {
            let color = try? await page.evaluateJavaScript("getComputedStyle(document.querySelector('p')).color") as? String
            return await query("print") && color == "rgb(1, 2, 3)"
        }
        rendering.update(in: session) { $0.reducedMotion = "Reduce" }
        try await waitFor("reduced motion") { await query("(prefers-reduced-motion: reduce)") }
        rendering.update(in: session) {
            $0.paintFlashing = true
            $0.layerBorders = true
        }
        rendering.update(in: session) {
            $0.mediaType = ""
            $0.colorScheme = nil
        }
        try await waitFor("screen media and the system colour scheme again") {
            let screen = await query("print")
            let dark = await query("(prefers-color-scheme: dark)")
            return !screen && dark == systemDark
        }
        XCTAssertNil(rendering.problem)

        await session.disconnect().value
        try await waitFor("WebKit to drop the overrides with the inspector") {
            await !query("(prefers-reduced-motion: reduce)")
        }
        withExtendedLifetime(tab) {}
    }

    private func waitFor(_ action: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<80 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Timed out waiting for \(action)")
        throw CancellationError()
    }

    private struct Fixture: View {
        let web: WKWebView
        let room: CGSize
        let responsive: Bool
        let settings: DeveloperViewportSettings

        var body: some View {
            DeveloperViewportCanvas(web: web, room: room, responsive: responsive, dock: .bottom,
                                    settings: .constant(settings)) {
                WebStage(page: web)
            }
            .frame(width: room.width, height: room.height, alignment: .topLeading)
        }
    }
}
