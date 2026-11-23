import AppKit
import struct SwiftUI.AnyView
import class SwiftUI.NSHostingView
import WebKit
import XCTest
@testable import Search

@MainActor
final class DeveloperTimelineScreenshotLiveTests: XCTestCase {
    func testRecordingShowsNamedJavaScriptFrames() async throws {
        let live = try await open("""
            <!doctype html><title>CPU fixture</title><script>
            function burnCPU() {
                const until = performance.now() + 220;
                while (performance.now() < until) window.burnResult = Math.random();
                document.body.dataset.burned = 'yes';
            }
            </script><body></body>
            """, title: "CPU fixture")
        defer { live.window.close() }
        do {
            live.session.toggleTimeline()
            try await wait("recording") { live.session.recordingTimeline }
            _ = try await page(live.page, "return new Promise(resolve => setTimeout(() => { burnCPU(); resolve(true); }, 0));")
            live.session.toggleTimeline()
            try await wait("JavaScript samples") {
                !live.session.recordingTimeline && live.session.timeline.contains { $0.type == "JavaScriptFrame" && $0.data["name"] == "burnCPU" }
            }
            let profile = DeveloperPerformanceProfile(live.session.timeline)
            let frame = try XCTUnwrap(profile.events.first { $0.type == "JavaScriptFrame" && $0.title == "burnCPU" })
            XCTAssertNotNil(frame.parent)
            XCTAssertGreaterThan(frame.duration, 0)
            XCTAssertTrue(profile.bottomUp(in: profile.bounds).contains { $0.activity.contains("burnCPU") })
            await finish(live)
        } catch {
            await finish(live)
            throw error
        }
    }

    func testRecordingIncludesNetworkAndMemoryTracks() async throws {
        let live = try await open("<!doctype html><title>Track fixture</title><body></body>", title: "Track fixture",
                                  resources: ["/pixel.svg": .init(type: "image/svg+xml", body: """
                                      <svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><path d="M0 0h1v1H0z"/></svg>
                                      """)])
        defer { live.window.close() }
        let was = DeveloperPerformanceMemory.enabled
        DeveloperPerformanceMemory.enabled = true
        defer { DeveloperPerformanceMemory.enabled = was }
        do {
            live.session.toggleTimeline()
            try await wait("recording") { live.session.recordingTimeline }
            _ = try await page(live.page, """
                const image = new Image();
                image.src = '/pixel.svg';
                document.body.append(image);
                window.dataForHeapTrack = Array.from({length: 4096}, (_, number) => ({number}));
                await image.decode();
                """)
            try await wait("heap samples") { live.session.timeline.filter { $0.type == "JSHeapSample" }.count >= 2 }
            live.session.toggleTimeline()
            try await wait("network track") {
                !live.session.recordingTimeline && live.session.timeline.contains { $0.type == "NetworkRequest" }
            }
            let profile = DeveloperPerformanceProfile(live.session.timeline)
            let image = try XCTUnwrap(profile.network.first { $0.url.hasSuffix("/pixel.svg") })
            XCTAssertGreaterThanOrEqual(image.start, 0)
            XCTAssertGreaterThan(image.end, image.start)
            // The bar and the heap readings lie within the recording's own
            // bounds (Timeline.recordingStarted to recordingStopped), not
            // just within a duration they themselves stretch.
            let timeline = live.session.timeline
            let recorded = try XCTUnwrap(timeline.first { $0.type == "RecordingBounds" })
            let bar = try XCTUnwrap(timeline.first { $0.type == "NetworkRequest" && $0.data["url"]?.hasSuffix("/pixel.svg") == true })
            XCTAssertGreaterThanOrEqual(bar.start, recorded.start)
            XCTAssertLessThanOrEqual(bar.end, recorded.end)
            let readings = timeline.filter { $0.type == "JSHeapSample" }
            XCTAssertGreaterThanOrEqual(readings.count, 2)
            XCTAssertTrue(readings.allSatisfy { $0.start >= recorded.start && $0.start <= recorded.end })
            XCTAssertGreaterThanOrEqual(profile.heap.count, 2)
            XCTAssertTrue(profile.heap.allSatisfy { $0.bytes > 0 })
            await finish(live)
        } catch {
            await finish(live)
            throw error
        }
    }

    /// Performance's Screenshots: WebKit's Screenshot instrument records a
    /// frame as the page paints; they reach the profile as a filmstrip,
    /// not as flame chart records, and decode to images of the page.
    func testRecordingCarriesScreenshotsOfThePage() async throws {
        let live = try await open("""
            <!doctype html><title>Shots</title><body style='margin:0;background:#fff'>
            <div id=b style='width:100vw;height:100vh;background:rgb(255,0,0)'></div>
            <script>let i=0;setInterval(()=>{b.style.background=['rgb(255,0,0)','rgb(0,0,255)'][++i%2]},150)</script>
            """, title: "Shots")
        defer { live.window.close() }
        let was = DeveloperPerformanceScreenshots.enabled
        DeveloperPerformanceScreenshots.enabled = true
        defer { DeveloperPerformanceScreenshots.enabled = was }
        live.session.toggleTimeline()
        try await wait("recording") { live.session.recordingTimeline }
        try await Task.sleep(for: .seconds(1.5))
        live.session.toggleTimeline()
        try await wait("stopped") { !live.session.recordingTimeline }
        try await wait("screenshots") { live.session.timeline.contains { $0.type == "Screenshot" && $0.data["imageData"] != nil } }

        let profile = DeveloperPerformanceProfile(live.session.timeline)
        XCTAssertFalse(profile.events.contains { $0.type == "Screenshot" })
        XCTAssertGreaterThanOrEqual(profile.screenshots.count, 2, "\(profile.screenshots.count) screenshots")
        XCTAssertEqual(profile.screenshots.map(\.time), profile.screenshots.map(\.time).sorted())
        var colours = Set<String>()
        for shot in profile.screenshots {
            let image = try XCTUnwrap(shot.image, "a screenshot that doesn't decode")
            let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let colour = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            colours.insert(colour.redComponent > 0.6 ? "red" : colour.blueComponent > 0.6 ? "blue" : "other")
        }
        print("[DeveloperTimelineScreenshotLiveTests] sizes \(profile.screenshots.map { $0.imageData.count }) prefix \(profile.screenshots.first?.imageData.prefix(30) ?? "")")
        print("[DeveloperTimelineScreenshotLiveTests] \(profile.screenshots.count) screenshots over \(profile.bounds.upperBound) ms: \(colours.sorted())")
        XCTAssertTrue(colours.isSuperset(of: ["red", "blue"]), "\(colours)")
        XCTAssertNotNil(profile.screenshot(at: profile.bounds.upperBound))

        // With PERCH_RENDER_DIR set, a picture of the panel with its filmstrip.
        if let dir = ProcessInfo.processInfo.environment["PERCH_RENDER_DIR"] {
            let host = NSHostingView(rootView: DeveloperPerformanceView(session: live.session))
            let panel = NSWindow(contentRect: CGRect(x: -4_000, y: -3_000, width: 900, height: 560),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.contentView = host
            panel.orderFrontRegardless()
            defer { panel.close() }
            try await Task.sleep(for: .seconds(1))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("performance-filmstrip.png"))
            }
        }
        await finish(live)
    }

    private struct Live {
        let server: LocalPageServer
        let page: WKWebView
        let window: NSWindow
        let tab: Tab
        let session: DeveloperToolsSession
    }

    /// The page in an on-screen borderless window, off to the side (a page
    /// in no window now and then stops answering the inspector), loaded,
    /// with a DevTools session attached and ready.
    private func open(_ html: String, title: String, resources: [String: LocalPageServer.Page] = [:]) async throws -> Live {
        _ = NSApplication.shared
        var pages = resources
        pages["/"] = .init(type: "text/html", body: html)
        let server = try LocalPageServer(pages)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        page.load(URLRequest(url: server.url("/")))
        do {
            try await wait("page to load") { page.title == title }
        } catch {
            window.close()
            throw error
        }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        watched = session
        let live = Live(server: server, page: page, window: window, tab: tab, session: session)
        do {
            try await wait("inspector") { session.ready }
        } catch {
            await finish(live)
            window.close()
            throw error
        }
        return live
    }

    private func finish(_ live: Live) async {
        await DeveloperTestSupport.finish(live.session, page: live.page, keeping: live.tab, live.server)
    }

    private func page(_ page: WKWebView, _ body: String) async throws -> Any? {
        try await page.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }

    /// The session the waits describe when they time out.
    private weak var watched: DeveloperToolsSession?

    private func wait(_ action: String, seconds: Double = 8, state: (() -> String)? = nil,
                      until condition: () -> Bool) async throws {
        try await DeveloperTestSupport.wait(action, seconds: seconds, in: "DeveloperTimelineScreenshotLiveTests", state: { [watched] in
            var parts: [String] = []
            if let watched {
                parts.append("ready \(watched.ready), message \(watched.message ?? "none")")
            }
            if let state { parts.append(state()) }
            return parts.joined(separator: "; ")
        }, until: condition)
    }
}
