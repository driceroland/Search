import AppKit
import WebKit
import XCTest
@testable import Search

/// A finished download dragged out of the Downloads list (idea 566): the row
/// carries its file, as a Finder file's drag does, and a page takes that
/// file as one dropped from the Finder: on a drop zone's dataTransfer.files
/// and on an <input type=file>. A row whose file has gone carries nothing.
/// The drag itself (SwiftUI's) can't be made without a pointer, so the page
/// is handed the same pasteboard the row's NSURL writes, through WebKit's
/// own dragging-destination calls. No window is ever shown.
@MainActor
final class DownloadDragOutTests: XCTestCase {
    private var folder: URL!
    private var server: LocalPageServer!

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("drag-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        server = try LocalPageServer(["/": .init(type: "text/html; charset=utf-8", body: Self.page)])
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: folder)
        holding.compactMap { $0 as? NSPasteboard }.forEach { $0.releaseGlobally() }
        holding.compactMap { $0 as? NSWindow }.forEach { $0.close() }
        holding = []
        XCTAssertTrue(NSApp.windows.allSatisfy { $0.alphaValue == 0 || !$0.isVisible }, "a window was shown")
    }

    private func finished(_ name: String, text: String = "downloaded words") throws -> Keep {
        let file = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: file)
        return Keep(name: name, from: "example.com", path: file.path, date: Date())
    }

    func testAFinishedDownloadCarriesItsFile() async throws {
        let keep = try finished("report.txt")
        let provider = try XCTUnwrap(keep.dragged)
        XCTAssertTrue(provider.registeredTypeIdentifiers.contains("public.file-url"), "\(provider.registeredTypeIdentifiers)")
        XCTAssertEqual(provider.suggestedName, "report.txt")
        let carried: URL? = try await withCheckedThrowingContinuation { done in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let error { done.resume(throwing: error) } else { done.resume(returning: url) }
            }
        }
        XCTAssertEqual(carried?.standardizedFileURL, keep.url.standardizedFileURL)
        XCTAssertTrue(carried?.isFileURL == true)
    }

    func testOneWhoseFileHasGoneCarriesNothing() throws {
        let keep = try finished("gone.txt")
        try FileManager.default.removeItem(at: keep.url)
        XCTAssertNil(keep.dragged)
    }

    /// The NSURL a row writes on the drag pasteboard is a file URL, read back
    /// as the Finder's own drags are.
    func testThePasteboardHoldsAFileURL() throws {
        let keep = try finished("notes.txt")
        let board = NSPasteboard(name: .init("search.drag-out.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        XCTAssertTrue(board.writeObjects([keep.url as NSURL]))
        XCTAssertTrue(board.types?.contains(.fileURL) == true)
        let read = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(read?.map(\.standardizedFileURL), [keep.url.standardizedFileURL])
    }

    func testAPageTakesItOnADropZone() async throws {
        let keep = try finished("drop-zone.txt", text: "zone words")
        let web = try await page()
        try await drop(keep, on: web, at: NSPoint(x: 500, y: 650))
        let got = try await waitFor(web, "return window.dropped || null;")
        XCTAssertEqual(got as? String, "drop-zone.txt:zone words")
    }

    func testAPageTakesItOnAFileInput() async throws {
        let keep = try finished("input.txt", text: "input words")
        let web = try await page()
        try await drop(keep, on: web, at: NSPoint(x: 500, y: 150))
        let got = try await waitFor(web, "return window.picked || null;")
        XCTAssertEqual(got as? String, "input.txt:input words")
    }

    // MARK: - plumbing

    private static let page = """
    <!doctype html><html><head><style>
    html, body { margin: 0; height: 800px; }
    #zone { position: absolute; top: 0; left: 0; width: 1000px; height: 400px; }
    #pick { position: absolute; top: 500px; left: 0; width: 1000px; height: 300px; }
    </style></head><body>
    <div id="zone"></div><input id="pick" type="file">
    <script>
    const zone = document.getElementById('zone');
    zone.addEventListener('dragover', e => e.preventDefault());
    zone.addEventListener('drop', async e => {
      e.preventDefault();
      const f = e.dataTransfer.files[0];
      window.dropped = f ? f.name + ':' + await f.text() : 'empty';
    });
    document.getElementById('pick').addEventListener('change', async e => {
      const f = e.target.files[0];
      window.picked = f ? f.name + ':' + await f.text() : 'empty';
    });
    </script></body></html>
    """

    private var holding: [AnyObject] = []

    private func page() async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
        // Far off every screen, and transparent besides (Tests/NoWindows).
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderBack(nil)
        holding.append(window)
        let loaded = Loaded()
        holding.append(loaded)
        web.navigationDelegate = loaded
        web.load(URLRequest(url: server.url("/")))
        try await loaded.wait()
        return web
    }

    private func drop(_ keep: Keep, on web: WKWebView, at point: NSPoint) async throws {
        // Its own pasteboard, not the system's drag one: WebKit reads the
        // drop's by name, and nothing else on the Mac sees this one.
        let board = NSPasteboard(name: .init("search.drag-out.\(UUID().uuidString)"))
        holding.append(board)
        board.clearContents()
        XCTAssertTrue(board.writeObjects([keep.url as NSURL]))
        let info = FakeDrag(board: board, window: web.window, at: point)
        holding.append(info)
        _ = web.draggingEntered(info)
        for _ in 0..<20 {
            if web.draggingUpdated(info) != [] { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotEqual(web.draggingUpdated(info), [], "the page refused the file")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(web.performDragOperation(info))
        web.concludeDragOperation(info)
    }

    private func waitFor(_ web: WKWebView, _ body: String) async throws -> Any? {
        for _ in 0..<60 {
            if let value = try await call(web, body) { return value }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    private func call(_ web: WKWebView, _ body: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { (result: Result<Any, Error>) in
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
    }

    /// What AppKit hands a view a drag lands on, for a file from elsewhere.
    private final class FakeDrag: NSObject, NSDraggingInfo {
        let board: NSPasteboard
        weak var window: NSWindow?
        let point: NSPoint

        init(board: NSPasteboard, window: NSWindow?, at point: NSPoint) {
            self.board = board
            self.window = window
            self.point = point
        }

        var draggingDestinationWindow: NSWindow? { window }
        var draggingSourceOperationMask: NSDragOperation { [.copy, .generic, .link] }
        var draggingLocation: NSPoint { point }
        var draggedImageLocation: NSPoint { point }
        var draggedImage: NSImage? { nil }
        var draggingPasteboard: NSPasteboard { board }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 4242 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }
}
