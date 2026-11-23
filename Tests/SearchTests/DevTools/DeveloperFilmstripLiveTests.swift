import AppKit
import WebKit
import XCTest
@testable import Search

/// Speed Index's filmstrip on a real page: three quarters of the view are
/// painted 300, 600 and 900 ms in, and the recorder has to see each paint
/// within a frame or so of the page's own time for the style change, as
/// Chrome's per-frame screenshots do. At the old 100 ms cadence each was
/// seen up to 100 ms late, which put Speed Index 60–120 ms above Chrome's.
@MainActor
final class DeveloperFilmstripLiveTests: XCTestCase {
    func testEachPaintIsSeenWithinAFrame() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Filmstrip fixture</title>
                <style>body{margin:0}.b{height:25vh}</style>
                <h1 style="margin:0;height:25vh;background:#246">Staged paints</h1>
                <div id=a class=b></div><div id=b class=b></div><div id=c class=b></div>
                <script>
                window.painted = [];
                const at = (ms, id, color) => setTimeout(() => {
                    document.getElementById(id).style.background = color;
                    painted.push(performance.now());
                }, ms);
                at(300, 'a', '#c33'); at(600, 'b', '#3a3'); at(900, 'c', '#a6c');
                </script>
                """),
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        defer { window.close() }

        let recorder = DeveloperFilmstripRecorder()
        recorder.start(page)
        defer { recorder.stop() }
        page.load(URLRequest(url: server.url("/")))
        try await DeveloperTestSupport.wait("three paints", seconds: 10, in: "DeveloperFilmstripLiveTests") {
            page.title == "Filmstrip fixture" && recorder.frames.count >= 5
        }
        try await Task.sleep(for: .milliseconds(300))
        recorder.stop()

        let originValue = try await page.evaluateJavaScript("performance.timeOrigin")
        let paintedValue = try await page.evaluateJavaScript("painted")
        let origin = try XCTUnwrap(originValue as? NSNumber).doubleValue
        let painted = try XCTUnwrap(paintedValue as? [NSNumber]).map(\.doubleValue)
        XCTAssertEqual(painted.count, 3)
        let frames = recorder.timed(from: Date(timeIntervalSince1970: origin / 1_000)).filter { $0.ms > 0 }
        print("[DeveloperFilmstripLiveTests] painted \(painted.map { Int($0) }) ms; frames seen at \(frames.map { Int($0.ms) }) ms; "
              + "\(recorder.captured) snapshots")
        for time in painted {
            // The first frame showing this paint.
            let seen = try XCTUnwrap(frames.first { $0.ms >= time - 2 }?.ms, "no frame after the paint at \(Int(time)) ms")
            XCTAssertLessThan(seen - time, 40, "the paint at \(Int(time)) ms was seen at \(Int(seen)) ms")
        }
    }
}
