import AppKit
import WebKit
import XCTest
@testable import Search

/// A frame that loads while hidden is drawn at the page's zoom once shown
/// (FrameZoom.swift), with the zoom above 100% and below it, and as it goes
/// up and down. A view of its own stands in for a tab's, with the script a
/// tab is given; that a tab is given it is Tests/frame_zoom.py's.
@MainActor
final class FrameZoomTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testAHiddenFrameShownAbove100PercentIsDrawnAtThePagesZoom() async throws {
        for zoom in [1.1, 1.25, 1.5] {
            let page = try await Page(zoom: zoom)
            try await page.show()
            let boxes = try await page.settled(Page.frames)
            XCTAssertTrue(Page.right(boxes, all: Page.frames), "at \(zoom): \(boxes)")
        }
    }

    func testAHiddenFrameShownBelow100PercentIsDrawnAtThePagesZoom() async throws {
        for zoom in [0.9, 0.8, 0.5] {
            let page = try await Page(zoom: zoom)
            try await page.show()
            let boxes = try await page.settled(Page.frames)
            XCTAssertTrue(Page.right(boxes, all: Page.frames), "at \(zoom): \(boxes)")
        }
    }

    /// What is drawn, not what the frame says of itself: the box's green, in
    /// points, in a picture of the page.
    func testTheBoxIsDrawnAtTheZoomedWidth() async throws {
        for zoom in [1.1, 0.9] {
            let page = try await Page(zoom: zoom)
            try await page.show()
            _ = try await page.settled(Page.frames)
            for id in Page.frames {
                let width = try await page.drawnWidth(of: id)
                XCTAssertEqual(width, Page.box * zoom, accuracy: 1.5, "\(id) at \(zoom)")
            }
        }
    }

    /// ⌘+ and ⌘− after the frame is shown, through 100% and out the other
    /// side: the frames already shown follow, and one made at each zoom is
    /// right.
    func testZoomingInAndOutKeepsEveryFrameRight() async throws {
        let page = try await Page(zoom: 1.1)
        try await page.show()
        var ids = Page.frames
        var boxes = try await page.settled(ids)
        XCTAssertTrue(Page.right(boxes, all: ids), "at the start: \(boxes)")
        var zoom = 1.1
        // Up twice, then down past 100% to under it, then back up.
        let steps: [Double] = [1.1, 1.1, 1 / 1.1, 1 / 1.1, 1 / 1.1, 1 / 1.1, 1 / 1.1, 1.1, 1.1]
        for (n, step) in steps.enumerated() {
            zoom *= step
            page.web.pageZoom = zoom
            let late = "late\(n)"
            try await page.addHidden(late)
            ids.append(late)
            boxes = try await page.settled(ids)
            XCTAssertTrue(Page.right(boxes, all: ids), "step \(n) to \(zoom): \(boxes)")
        }
        XCTAssertTrue(steps.indices.contains { steps[...$0].reduce(1.1, *) < 0.95 }, "the steps went under 100%")
    }

    /// The zoom moved while the frame was still hidden, up and down.
    func testAZoomChangedWhileTheFrameIsHidden() async throws {
        for (from, to) in [(1.0, 1.25), (1.1, 0.9), (0.8, 1.0), (1.25, 1.1), (0.9, 0.8)] {
            let page = try await Page(zoom: from)
            page.web.pageZoom = to
            try await Task.sleep(nanoseconds: 200_000_000)
            try await page.show()
            let boxes = try await page.settled(Page.frames)
            XCTAssertTrue(Page.right(boxes, all: Page.frames), "\(from) to \(to): \(boxes)")
        }
    }

    /// At 100% there is nothing to miss, and every frame is as it was.
    func testAt100PercentEveryFrameIsRight() async throws {
        let page = try await Page(zoom: 1)
        try await page.show()
        let boxes = try await page.settled(Page.frames)
        XCTAssertTrue(Page.right(boxes, all: Page.frames), "\(boxes)")
        let sheets = try await page.sheets()
        XCTAssertTrue(sheets.values.allSatisfy { $0 == 0 }, "\(sheets)")
    }

    /// Restyling a frame is that frame's own affair: the page around it is
    /// not resized, nor is a frame beside it, and the frame itself hears
    /// only the one resize of being shown.
    func testThePageAroundTheFrameHearsNothing() async throws {
        for zoom in [1.1, 0.9] {
            let page = try await Page(zoom: zoom)
            _ = try await page.boxes()
            let before = try await page.resizes()
            try await page.show()
            let boxes = try await page.settled(Page.frames)
            XCTAssertTrue(Page.right(boxes, all: Page.frames), "at \(zoom): \(boxes)")
            let after = try await page.resizes()
            let heard = after.reduce(into: [String: Int]()) { $0[$1.key] = $1.value - (before[$1.key] ?? 0) }
            XCTAssertEqual(heard, ["page": 0, "seen": 0, "hidden": 1, "inside": 1], "at \(zoom)")
        }
    }

    /// The style sheets a frame adopted itself are still its own afterwards,
    /// still at work, and none of Search's is left beside them in any frame.
    func testAFramesOwnSheetsAreKeptAndNoneIsLeftBehind() async throws {
        for zoom in [1.1, 0.9] {
            let page = try await Page(zoom: zoom)
            try await page.addHidden("own", sheet: true)
            try await page.show()
            let ids = Page.frames + ["own"]
            let boxes = try await page.settled(ids)
            XCTAssertTrue(Page.right(boxes, all: ids), "at \(zoom): \(boxes)")
            let sheets = try await page.sheets()
            XCTAssertEqual(sheets, ["seen": 0, "hidden": 0, "inside": 0, "own": 1], "at \(zoom)")
            let tall = try await page.web.evaluateJavaScript("tall.own") as? Double
            XCTAssertEqual(tall, 41, "its own sheet's rule still holds at \(zoom)")
        }
    }

    // MARK: - The page

    /// A page with a frame shown from the start (`seen`), one that loads
    /// with `display: none` (`hidden`) and one inside something hidden
    /// (`inside`), as a sign-in prompt's and a password manager's are. Each
    /// frame is another origin's (a data: address) and answers with the
    /// width it measures its box as, with how many style sheets its document
    /// has adopted, how tall the box is and how many times it has been
    /// resized. The page counts its own resizes.
    @MainActor
    private final class Page {
        let web: WKWebView
        private let window: NSWindow

        /// The frames the page starts with.
        static let frames = ["seen", "hidden", "inside"]
        /// How wide each frame's box is, in its own pixels: what a frame
        /// drawn at its page's zoom measures it as.
        static let box = 100.0
        /// How long a frame has to come right. No longer: a page nobody can
        /// see, as this one is, has its frames restyled by WebKit itself
        /// some three seconds after it loads, and a wait that long passed
        /// with nothing of ours done (a page in a window on screen never
        /// is).
        static let wait: TimeInterval = 1.5

        /// With `sheet`, the frame adopts one of its own, which makes its
        /// box a pixel taller.
        static func frame(_ id: String, sheet: Bool = false) -> String {
            let own = sheet ? "var mine = new CSSStyleSheet(); mine.replaceSync('#b{height:41px}'); document.adoptedStyleSheets = [mine];" : ""
            let doc = """
            <!doctype html><style>html,body{margin:0}#b{width:\(Int(box))px;height:40px;background:#00aa00}</style><div id=b></div><script>
            \(own)
            var resizes = 0;
            addEventListener('resize', function () { resizes++; });
            addEventListener('message', function () {
              var b = document.getElementById('b');
              parent.postMessage({id: '\(id)', box: b.getBoundingClientRect().width, tall: b.offsetHeight,
                                  sheets: document.adoptedStyleSheets.length, resizes: resizes}, '*');
            });
            </script>
            """
            return "data:text/html;base64," + Data(doc.utf8).base64EncodedString()
        }

        static let html = """
        <!doctype html><html style="color-scheme: dark"><body style="background:#111111;margin:0">
        <iframe id=seen style="display:block;width:300px;height:60px;border:0" src="\(frame("seen"))"></iframe>
        <iframe id=hidden style="width:300px;height:60px;border:0;display:none" src="\(frame("hidden"))"></iframe>
        <div id=wrap style="display:none"><iframe id=inside style="display:block;width:300px;height:60px;border:0" src="\(frame("inside"))"></iframe></div>
        <script>
        var got = {}, sheets = {}, tall = {}, resizes = {page: 0};
        addEventListener('resize', function () { resizes.page++; });
        addEventListener('message', function (e) {
          if (!e.data || !e.data.id) return;
          got[e.data.id] = e.data.box; sheets[e.data.id] = e.data.sheets; tall[e.data.id] = e.data.tall;
          resizes[e.data.id] = e.data.resizes;
        });
        function show() {
          [].forEach.call(document.querySelectorAll('iframe'), function (f) { f.style.display = 'block'; });
          document.getElementById('wrap').style.display = 'block';
        }
        function addHidden(id, src) {
          var f = document.createElement('iframe');
          f.id = id; f.src = src; f.style.cssText = 'width:300px;height:60px;border:0;display:none';
          f.onload = function () { f.dataset.loaded = '1'; };
          document.body.appendChild(f);
        }
        function ask() {
          got = {};
          [].forEach.call(document.querySelectorAll('iframe'), function (f) { f.contentWindow.postMessage('say', '*'); });
        }
        </script></body></html>
        """

        init(zoom: Double) async throws {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.userContentController.addUserScript(
                Armed.script(FrameZoom.script, .atDocumentStart, mainFrameOnly: false, in: Web.world))
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: 880, height: 900), configuration: config)
            // A window it is never shown in: a view in none lays nothing out.
            window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 880, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = web
            web.pageZoom = zoom
            web.loadHTMLString(Page.html, baseURL: URL(string: "https://frames.example/"))
            // Every frame's document is in: the hidden ones load unseen.
            try await waitFor("typeof ask === 'function' && document.readyState === 'complete'")
            try await Task.sleep(nanoseconds: 150_000_000)
        }

        /// Asked until the page says yes, five seconds at most. Asked again
        /// on an error too: a page still loading drops what it was asked.
        private func waitFor(_ js: String) async throws {
            for _ in 0..<200 {
                if (try? await web.evaluateJavaScript(js) as? Bool) == true { return }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
        }

        func show() async throws {
            _ = try await web.evaluateJavaScript("show(); true")
        }

        /// One more frame, loaded while hidden, then shown.
        func addHidden(_ id: String, sheet: Bool = false) async throws {
            _ = try await web.evaluateJavaScript("addHidden('\(id)', '\(Page.frame(id, sheet: sheet))'); true")
            try await waitFor("document.getElementById('\(id)').dataset.loaded === '1'")
            _ = try await web.evaluateJavaScript("document.getElementById('\(id)').style.display = 'block'; true")
        }

        /// How many times the page ("page") and each frame have been resized,
        /// as the frames last answered.
        func resizes() async throws -> [String: Int] {
            let text = try await web.evaluateJavaScript("JSON.stringify(resizes)") as? String ?? "{}"
            let read = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
            return read.compactMapValues { ($0 as? NSNumber)?.intValue }
        }

        /// How many style sheets each frame's document has adopted, as the
        /// frames last answered.
        func sheets() async throws -> [String: Int] {
            let text = try await web.evaluateJavaScript("JSON.stringify(sheets)") as? String ?? "{}"
            let read = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
            return read.compactMapValues { ($0 as? NSNumber)?.intValue }
        }

        /// What each frame measures its box as, asked now.
        func boxes() async throws -> [String: Double] {
            _ = try await web.evaluateJavaScript("ask(); true")
            try await Task.sleep(nanoseconds: 120_000_000)
            let text = try await web.evaluateJavaScript("JSON.stringify(got)") as? String ?? "{}"
            let read = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] ?? [:]
            return read.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        }

        /// The same once every frame in `ids` has answered and is right, or
        /// as it stands once `wait` is up. A frame missing from the answer
        /// is no answer: it comes back as it was last heard, or not at all.
        func settled(_ ids: [String]) async throws -> [String: Double] {
            var last: [String: Double] = [:]
            let until = Date().addingTimeInterval(Page.wait)
            repeat {
                last = try await boxes().filter { ids.contains($0.key) }
                if Page.right(last, all: ids) { break }
            } while Date() < until
            return last
        }

        /// Every frame in `ids` answered, and every one measures its box as
        /// `box`: drawn at its page's zoom.
        static func right(_ boxes: [String: Double], all ids: [String]) -> Bool {
            boxes.count == ids.count && boxes.values.allSatisfy { abs($0 - box) < 0.5 }
        }

        /// How wide the frame's green box is in a picture of the page, in
        /// points of the view.
        func drawnWidth(of id: String) async throws -> Double {
            let text = try await web.evaluateJavaScript(
                "(function(){var b=document.getElementById('\(id)').getBoundingClientRect();return JSON.stringify([b.left, b.top + 20])})()") as? String ?? "[]"
            let at = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Double] ?? []
            guard at.count == 2 else { throw XCTSkip("no place for \(id)") }
            let image: NSImage = try await withCheckedThrowingContinuation { done in
                web.takeSnapshot(with: nil) { image, error in
                    if let image { done.resume(returning: image) } else { done.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                }
            }
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { throw XCTSkip("no picture") }
            let zoom = Double(web.pageZoom), scale = Double(rep.pixelsWide) / Double(web.bounds.width)
            let y = min(rep.pixelsHigh - 1, Int(at[1] * zoom * scale))
            var green = 0
            for x in Int(at[0] * zoom * scale)..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      c.greenComponent > 0.5, c.redComponent < 0.25, c.blueComponent < 0.25 else { break }
                green += 1
            }
            return Double(green) / scale
        }
    }
}
