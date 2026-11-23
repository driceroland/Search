import AppKit
import WebKit
import XCTest
@testable import Search

/// Custom formatters on a real page: with the setting on, a logged
/// object's header comes from window.devtoolsFormatters, its body opens
/// with the nested objects it names, and objects no formatter takes keep
/// the usual preview.
@MainActor
final class DeveloperConsoleFormattersLiveTests: XCTestCase {
    private static let script = """
        window.devtoolsFormatters = [{
            header(value, config) {
                if (config && config.child) return ["span", {style: "color: blue"}, "child"];
                if (!value || !value.__point) return null;
                return ["div", {style: "color: red; font-weight: bold"}, "Point(",
                        ["span", {}, String(value.x)], ", ", ["span", {}, String(value.y)], ")"];
            },
            hasBody(value, config) { return !(config && config.child); },
            body(value) {
                return ["div", {},
                    ["div", {style: "margin-left: 10px"}, "x: ", ["object", {object: value.x}]],
                    ["div", {}, "inner: ", ["object", {object: value.inner, config: {child: true}}]]];
            },
        }, {
            header() { throw new Error("a broken formatter is skipped"); },
        }];
        """

    func testFormatterHeaderAndBody() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Formatter fixture</title>
                <script src="/app.js"></script>
                """),
            "/app.js": .init(type: "text/javascript", body: Self.script),
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        page.load(URLRequest(url: server.url("/")))
        let domain = "DeveloperConsoleFormattersLiveTests"
        try await DeveloperTestSupport.wait("page to load", in: domain) { page.title == "Formatter fixture" }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        let store = session.consoleStore
        let saved = store.settings
        defer { store.settings = saved }
        do {
            try await DeveloperTestSupport.wait("inspector", in: domain) { session.ready }
            store.settings.customFormatters = true
            _ = try await page.evaluateJavaScript("console.log({__point: true, x: 3, y: 4, inner: {}}); console.log({plain: 1}); 0")
            try await DeveloperTestSupport.wait("logged objects", in: domain) {
                session.console.filter { $0.details?.parameters.first?.type == "object" }.count >= 2
            }
            let logged = session.console.compactMap { $0.details?.parameters.first }.filter { $0.type == "object" }
            let point = try XCTUnwrap(logged.first)
            let plain = try XCTUnwrap(logged.dropFirst().first)
            let targetID = session.console.first { $0.details?.parameters.first == point }?.details?.targetID

            session.loadConsoleCustomHeader(point, targetID: targetID)
            session.loadConsoleCustomHeader(plain, targetID: targetID)
            let pointKey = ConsoleCustomFormatting.key(point, config: nil)
            let plainKey = ConsoleCustomFormatting.key(plain, config: nil)
            try await DeveloperTestSupport.wait("formatter headers", in: domain,
                                                state: { "\(String(describing: store.customHeaders))" }) {
                store.customHeaders[pointKey] != .loading && store.customHeaders[plainKey] != .loading
            }
            XCTAssertEqual(store.customHeaders[plainKey], ConsoleCustomPreviewState.none)
            let preview = try XCTUnwrap(store.customHeader(point))
            XCTAssertEqual(preview.formatter, 0)
            XCTAssertTrue(preview.hasBody)
            let header = ConsoleJsonMLLayout.inline(preview.header)
            XCTAssertEqual(ConsoleJsonMLLayout.plain(header), "Point(3, 4)")
            guard case .text(_, let style)? = header.first else { return XCTFail("header starts with text") }
            XCTAssertTrue(style.bold)
            XCTAssertNotNil(style.color)

            session.loadConsoleCustomBody(preview, targetID: targetID)
            try await DeveloperTestSupport.wait("formatter body", in: domain) { store.customBodies[pointKey] != nil }
            let body = try XCTUnwrap(store.customBodies[pointKey])
            let lines = ConsoleJsonMLLayout.lines(body.body)
            XCTAssertEqual(lines.count, 2)
            XCTAssertEqual(lines.first?.indent, 10)
            XCTAssertEqual(ConsoleJsonMLLayout.plain(lines[0].runs), "x: {object 0}")
            XCTAssertEqual(body.objects[0]?.value, .number(3))
            // The nested object goes back to the formatters with its config.
            let inner = try XCTUnwrap(body.objects[1])
            let config = try XCTUnwrap(body.objects[2])
            session.loadConsoleCustomHeader(inner, config: config, targetID: targetID)
            let innerKey = ConsoleCustomFormatting.key(inner, config: config)
            try await DeveloperTestSupport.wait("nested header", in: domain) {
                store.customHeaders[innerKey] != nil && store.customHeaders[innerKey] != .loading
            }
            let child = try XCTUnwrap(store.customHeader(inner, config: config))
            XCTAssertEqual(ConsoleJsonMLLayout.plain(ConsoleJsonMLLayout.inline(child.header)), "child")
            XCTAssertFalse(child.hasBody)
            await DeveloperTestSupport.finish(session, page: page, keeping: tab, server)
        } catch {
            await DeveloperTestSupport.finish(session, page: page, keeping: tab, server)
            throw error
        }
    }
}
