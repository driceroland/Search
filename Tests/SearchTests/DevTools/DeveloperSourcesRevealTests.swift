import AppKit
import WebKit
import XCTest
@testable import Search

/// file:line links from Network › Initiator and the Console open Sources at
/// that line, as Chromium's do.
@MainActor
final class DeveloperSourcesRevealTests: XCTestCase {
    private var window: NSWindow?
    /// The session under test, for timeout messages.
    private var session: DeveloperToolsSession?

    override func tearDown() async throws {
        window?.contentView = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        session = nil
    }

    func testInitiatorFramesOpenSourcesAtTheirLine() async throws {
        _ = NSApplication.shared
        let script = """
            // Fixture script.
            function load() {
                return fetch("/data?from-script");
            }
            load();
            console.log("logged here");
            """
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><html><head><title>Reveal fixture</title></head>
                <body><p>Reveal</p><script src="/app.js"></script></body></html>
                """),
            "/app.js": .init(type: "text/javascript", body: script),
            "/data": .init(type: "text/plain", body: "data"),
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        page.load(URLRequest(url: server.url("/")))
        try await wait("page") { page.title == "Reveal fixture" }

        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        self.session = session
        do {
            try await wait("inspector") { session.ready && session.root != nil }
            session.select(.network)
            page.reload()
            try await wait("script request") {
                session.requests.contains { $0.url.contains("/data?from-script") }
            }
            let request = try XCTUnwrap(session.requests.first { $0.url.contains("/data?from-script") })
            let fetched = await session.requestDetails(request.id)
            let details = try XCTUnwrap(fetched)
            let frame = try XCTUnwrap(details.frames.first { $0.function == "load" }, "frames: \(details.stack)")
            XCTAssertTrue(frame.url.hasSuffix("/app.js"))
            XCTAssertEqual(frame.line, 3, "WebKit's lines are 1-based, as the link shows them")
            XCTAssertEqual(frame.location, "app.js:3")
            XCTAssertEqual(details.stack.first, "load @ \(frame.url):3")

            // The link: Sources, the script, the line.
            session.revealSource(url: frame.url, line: frame.line ?? 1, column: frame.column)
            XCTAssertEqual(session.panel, .sources)
            try await wait("script open in Sources") {
                session.sourceResource?.url.hasSuffix("/app.js") == true && session.source?.contains("function load") == true
            }
            XCTAssertEqual(session.sourceReveal?.line, 3)

            // The editor scrolls there and tints the line.
            let container = host()
            let text = try XCTUnwrap(session.source)
            container.textView.show(text, lineStarts: SourceLexing.lineStarts(text), id: 1, caret: nil)
            container.textView.go(toLine: 3, column: 5, flash: true)
            let selected = container.textView.selectedRange().location
            XCTAssertEqual(container.textView.lineIndex(of: selected), 2)
            XCTAssertEqual(container.textView.flashedLine, 3)
            XCTAssertNotNil(container.textView.lineRect(3))

            // A Console link takes the same path.
            session.select(.console)
            session.revealConsoleSource(url: frame.url, line: 6)
            XCTAssertEqual(session.panel, .sources)
            XCTAssertEqual(session.sourceReveal?.line, 6)
            session.revealedSource(session.sourceReveal?.serial ?? -1)
            XCTAssertNil(session.sourceReveal, "a shown reveal is not repeated when the file opens again")
            await DeveloperTestSupport.finish(session, page: page, keeping: server, tab)
        } catch {
            await DeveloperTestSupport.finish(session, page: page, keeping: server, tab)
            throw error
        }
    }

    func testPrettyPrintedFilesRevealTheFormattedLine() async throws {
        let document = SourceDocument(text: "function a(){b();c()}\nfunction d(){e()}", url: "https://example.com/app.js", type: "Script")
        XCTAssertEqual(document.shownLine(forOriginal: 2), 2)
        document.togglePretty()
        for _ in 0..<50 where !document.pretty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(document.pretty)
        let shown = document.shownLine(forOriginal: 2)
        XCTAssertGreaterThan(shown, 2, "line 2 starts lower once formatted")
        XCTAssertTrue(document.display.text.split(separator: "\n", omittingEmptySubsequences: false)[shown - 1].contains("function d"))
    }

    private func host() -> SourceContainerView {
        let container = SourceContainerView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 700, height: 430), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 430))
        content.addSubview(container)
        window.contentView = content
        window.layoutIfNeeded()
        self.window = window
        return container
    }

    private func wait(_ action: String, until condition: () -> Bool) async throws {
        try await DeveloperTestSupport.wait(action, in: "DeveloperSourcesRevealTests", state: {
            "ready \(session?.ready ?? false), panel \(String(describing: session?.panel)), "
                + "requests \(session?.requests.map(\.url) ?? []), source \(session?.sourceResource?.url ?? "none"), "
                + "message \(session?.message ?? "none")"
        }, until: condition)
    }
}
