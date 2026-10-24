import AppKit
import Foundation
import WebKit
import XCTest
@testable import Search

/// The guess (Reader.script) on pages laid out as newsrooms lay theirs out:
/// what of an article's head, pictures and frames comes into the reading
/// page, and what doesn't (#564, #565).
@MainActor
final class ReaderGuessTests: XCTestCase {
    private var server: LocalPageServer!
    private static let html = "text/html; charset=utf-8"
    private static let prose = String(repeating: "<p>" + String(repeating: "Words to read here. ", count: 20) + "</p>", count: 4)
    private static let photo = "<svg xmlns='http://www.w3.org/2000/svg' width='800' height='450'><rect width='800' height='450' fill='#888'/></svg>"

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        server = try LocalPageServer([
            "/photo.svg": .init(type: "image/svg+xml", body: Self.photo),
            "/photo2.svg": .init(type: "image/svg+xml", body: Self.photo),
            "/ft": .init(type: Self.html, body: """
            <!doctype html><html><head><title>FT</title></head><body>
            <h1>The headline</h1>
            <div class="story">
            <div class="topper"><figure><img src="/photo.svg" width="800" height="450" alt="Opening"></figure></div>
            <article>\(Self.prose)
              <figure><iframe src="about:blank#flourish-chart" style="height:300px;border:0"></iframe></figure>
              <figure><iframe src="about:blank#an-advert"></iframe></figure>
            </article>
            <nav><a href="/a">A</a> <a href="/b">B</a></nav>
            </div>
            <footer><figure><img src="/photo.svg" width="800" height="450" alt="Footer"></figure></footer>
            </body></html>
            """),
            "/bloomberg": .init(type: Self.html, body: """
            <!doctype html><html><head><title>Bloomberg</title></head><body>
            <h1>The headline</h1>
            <div class="BasicByline_byline__VTyoS">By Someone</div>
            <ul class="Takeaways_takeaways">
              <li>One point</li> <li>Another</li>
            </ul>
            <article>\(Self.prose)
              <button><img src="/photo2.svg" width="800" height="450" alt="In a button"></button>
              <div class="video-js"><video src="blob:http://127.0.0.1/abc" autoplay poster="/photo.svg"><source src="blob:http://127.0.0.1/abc"><source src="https://example.invalid/clip.mp4"></video><div class="vjs-control-bar">Play</div></div>
              <div class="newsletter-box"><p>Sign up</p></div>
            </article>
            <nav><div class="byline">Not this one</div></nav>
            </body></html>
            """),
        ])
    }

    override func tearDown() async throws {
        server.stop()
        server = nil
        try await super.tearDown()
    }

    func testTheOpeningPhotoAndChartsComeButNotOtherFrames() async throws {
        let web = try await read("/ft")
        let found = try await call(web, """
        var reader = document.getElementById('office-reader');
        var frames = Array.prototype.map.call(reader.querySelectorAll('iframe'), function (f) {
          return f.getAttribute('src') + '|' + f.className + '|' + f.style.height; });
        var pictures = Array.prototype.map.call(reader.querySelectorAll('img'), function (i) { return i.alt; });
        return { frames: frames, pictures: pictures, topper: !!reader.querySelector('.topper') };
        """) as? [String: Any]
        XCTAssertEqual(found?["frames"] as? [String], ["about:blank#flourish-chart|office-chart|300px"],
                       "a chart maker's frame stays at its height; a frame in a figure from elsewhere goes")
        XCTAssertEqual(found?["pictures"] as? [String], ["Opening"], "the opening photo, and nothing from the footer")
        XCTAssertEqual(found?["topper"] as? Bool, false, "the topper's class goes with it")
    }

    func testTheHeadComesAndAVideoPlaysFromItsPlainSource() async throws {
        let web = try await read("/bloomberg")
        let found = try await call(web, """
        var reader = document.getElementById('office-reader');
        var video = reader.querySelector('video');
        return {
          above: Array.prototype.map.call(reader.querySelectorAll('.office-above'), function (e) { return e.textContent.trim().replace(/\\s+/g, ' '); }),
          buttons: reader.querySelectorAll('button').length,
          inButton: !!reader.querySelector('img[alt="In a button"]'),
          src: video ? video.getAttribute('src') : null,
          preload: video ? video.getAttribute('preload') : null,
          autoplay: video ? video.hasAttribute('autoplay') : null,
          controls: video ? video.hasAttribute('controls') : null,
          bar: !!reader.querySelector('.vjs-control-bar'),
          newsletter: !!reader.querySelector('.newsletter-box')
        };
        """) as? [String: Any]
        XCTAssertEqual(found?["above"] as? [String], ["By Someone", "One point Another"])
        XCTAssertEqual(found?["buttons"] as? Int, 0)
        XCTAssertEqual(found?["inButton"] as? Bool, true, "a picture in a button is the picture")
        XCTAssertEqual(found?["src"] as? String, "https://example.invalid/clip.mp4")
        XCTAssertEqual(found?["preload"] as? String, "metadata", "nothing downloads before play")
        XCTAssertEqual(found?["autoplay"] as? Bool, false)
        XCTAssertEqual(found?["controls"] as? Bool, true)
        XCTAssertEqual(found?["bar"] as? Bool, false)
        XCTAssertEqual(found?["newsletter"] as? Bool, false)
    }

    /// White unless reading mode follows the window: then dark when asked,
    /// and the article's own repeated headline goes.
    func testTheLookIsLightUnlessAskedForDark() async throws {
        let light = try await read("/ft")
        let plain = try await call(light, "return [document.documentElement.getAttribute('data-office-look'), getComputedStyle(document.body).backgroundColor];") as? [String]
        XCTAssertEqual(plain, ["light", "rgb(255, 255, 255)"])
        let dark = try await read("/ft", look: "dark")
        let shown = try await call(dark, "return [document.documentElement.getAttribute('data-office-look'), getComputedStyle(document.body).backgroundColor, document.querySelectorAll('#office-reader h1').length];") as? [Any]
        XCTAssertEqual(shown?[0] as? String, "dark")
        XCTAssertEqual(shown?[1] as? String, "rgb(28, 28, 28)")
        XCTAssertEqual(shown?[2] as? Int, 1)
    }

    // MARK: - plumbing

    private var holding: [Loaded] = []

    private func read(_ path: String, look: String? = nil) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
        let loaded = Loaded()
        holding.append(loaded)
        web.navigationDelegate = loaded
        web.load(URLRequest(url: server.url(path)))
        try await loaded.wait()
        var arguments: [String: Any] = ["sheet": Reader.sheet]
        if let look { arguments["readerLook"] = look }
        let answer = try await call(web, Reader.script, arguments, world: .page)
        XCTAssertEqual(answer as? String, "read")
        return web
    }

    private func call(_ web: WKWebView, _ body: String, _ arguments: [String: Any] = [:],
                      world: WKContentWorld = .page) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { (result: Result<Any, Error>) in
                continuation.resume(with: result.map { $0 is NSNull ? nil : $0 })
            }
        }
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var done = false

        func wait() async throws {
            if done { return }
            try await withCheckedThrowingContinuation { self.continuation = $0 }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done = true
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            done = true
            continuation?.resume(throwing: error)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            done = true
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
