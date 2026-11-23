import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class DeveloperEventSourceLiveTests: XCTestCase {
    func testNetworkShowsDefaultAndNamedMessagesFromTheirRequest() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: "<!doctype html><title>EventSource fixture</title>"),
            "/events": .init(type: "text/event-stream",
                             body: "id: first\ndata: hello\n\nid: second\nevent: update\ndata: world\n\n"),
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = PageView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        defer { window.close() }
        page.load(URLRequest(url: server.url("/")))
        try await DeveloperTestSupport.wait("page to load", in: "DeveloperEventSourceLiveTests") { page.title == "EventSource fixture" }
        _ = try await page.evaluateJavaScript("window.nativeEventSource = window.EventSource; 0")

        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        do {
            try await DeveloperTestSupport.wait("inspector to open", in: "DeveloperEventSourceLiveTests") { session.ready }
            session.select(.network)
            let hooked = try await page.evaluateJavaScript("window.EventSource !== window.nativeEventSource")
            XCTAssertEqual(hooked as? Bool, true)
            let unnoticed = try await page.evaluateJavaScript("""
                EventSource.prototype.constructor === EventSource && !('perchEventSourceCapture' in window)
                    && /\\[native code\\]/.test(Function.prototype.toString.call(EventSource.prototype.addEventListener))
                """)
            XCTAssertEqual(unnoticed as? Bool, true)
            _ = try await page.evaluateJavaScript("""
                window.receivedEvents = [];
                window.events = new EventSource("/events?fixture=stream");
                events.onmessage = event => receivedEvents.push(event.data);
                events.addEventListener("update", event => {
                    receivedEvents.push(event.data);
                    events.close();
                });
                0;
                """)
            let address = server.url("/events?fixture=stream").absoluteString
            try await DeveloperTestSupport.wait("event stream request", in: "DeveloperEventSourceLiveTests") {
                session.requests.contains { $0.url == address && $0.mimeType == "text/event-stream" }
            }
            let request = try XCTUnwrap(session.requests.first { $0.url == address })
            XCTAssertTrue(DeveloperRequestTab.available(for: request, details: nil).contains(.messages))
            var messages: [DeveloperNetworkTools.Frame] = []
            for _ in 0..<80 {
                messages = await session.networkTools.frames(for: request.id, after: 0).frames
                if messages.count >= 2 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(messages.map(\.eventType), ["message", "update"])
            XCTAssertEqual(messages.map(\.eventID), ["first", "second"])
            XCTAssertEqual(messages.map(\.data), ["hello", "world"])
            XCTAssertTrue(messages.allSatisfy { $0.time != nil })
            let fromPage = try await page.evaluateJavaScript("receivedEvents.join(',')")
            XCTAssertEqual(fromPage as? String, "hello,world")
            XCTAssertEqual(server.requests.filter { $0 == "/events" }.count, 1)

            await session.disconnect().value
            let restored = try await page.evaluateJavaScript("window.EventSource === window.nativeEventSource && !window.perchEventSourceCapture && !window[Symbol.for('perch.eventSourceCapture')] && EventSource.prototype.constructor === EventSource")
            XCTAssertEqual(restored as? Bool, true)
            await DeveloperTestSupport.finish(session, page: page, keeping: tab)
        } catch {
            await DeveloperTestSupport.finish(session, page: page, keeping: tab)
            throw error
        }
    }
}
