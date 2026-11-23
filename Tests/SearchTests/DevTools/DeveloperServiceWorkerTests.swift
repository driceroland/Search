import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class DeveloperServiceWorkerTests: XCTestCase {
    private func makeServer() throws -> LocalPageServer {
        try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Worker fixture</title>
                <script>
                window.__pushed = [];
                navigator.serviceWorker.addEventListener("message", (event) => window.__pushed.push(event.data));
                window.__ready = navigator.serviceWorker.register("/sw.js").then(() => navigator.serviceWorker.ready).then(() => "ready");
                </script>
                """),
            "/sw.js": .init(type: "text/javascript", body: """
                self.addEventListener("install", () => {});
                self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));
                self.addEventListener("push", (event) => {
                    const text = event.data ? event.data.text() : null;
                    event.waitUntil(self.clients.matchAll({includeUncontrolled: true})
                        .then((all) => all.forEach((client) => client.postMessage({push: text}))));
                });
                self.addEventListener("message", (event) => {
                    if (event.data && event.data.type === "SKIP_WAITING") self.skipWaiting();
                });
                """),
        ])
    }

    func testPushMessageReachesTheWorker() async throws {
        _ = NSApplication.shared
        let server = try makeServer()
        let configuration = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        let permissions = Permissions(origin: "http://127.0.0.1:\(server.port)")
        store.perform(NSSelectorFromString("set_delegate:"), with: permissions)
        configuration.websiteDataStore = store
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        web.load(URLRequest(url: server.url("/")))
        try await wait("page") { web.title == "Worker fixture" }
        let ready = try await web.callAsyncJavaScript("return await window.__ready;", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(ready as? String, "ready")

        let sent = await DeveloperServiceWorkers.push("hello worker", scope: server.url("/"), in: web)
        _ = sent
        var pushed: [Any] = []
        for _ in 0..<50 {
            pushed = try await web.evaluateJavaScript("window.__pushed") as? [Any] ?? []
            if !pushed.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual((pushed.first as? [String: Any])?["push"] as? String, "hello worker")

        // The listing, then a second version waiting and let in by skipWaiting.
        var listing = try await DeveloperServiceWorkers.list(in: web)
        XCTAssertEqual(listing.registrations.count, 1)
        XCTAssertEqual(listing.registrations.first?.active?.state, "activated")
        let scope = try XCTUnwrap(listing.registrations.first?.scope)
        _ = try await web.callAsyncJavaScript("""
            const registration = await navigator.serviceWorker.register("/sw.js?v=2");
            for (let i = 0; i < 50 && !registration.waiting; i++) await new Promise((r) => setTimeout(r, 100));
            return !!registration.waiting;
            """, arguments: [:], in: nil, contentWorld: .page)
        listing = try await DeveloperServiceWorkers.list(in: web)
        XCTAssertNotNil(listing.registrations.first?.waiting, "a worker waiting to activate")
        try await DeveloperServiceWorkers.perform(.skipWaiting, scope: scope, in: web)
        listing = try await DeveloperServiceWorkers.list(in: web)
        XCTAssertNil(listing.registrations.first?.waiting)
        XCTAssertTrue(listing.registrations.first?.active?.scriptURL.hasSuffix("v=2") == true)

        try await DeveloperServiceWorkers.perform(.update, scope: scope, in: web)
        try await DeveloperServiceWorkers.perform(.unregister, scope: scope, in: web)
        listing = try await DeveloperServiceWorkers.list(in: web)
        XCTAssertTrue(listing.registrations.isEmpty)
    }

    private final class Permissions: NSObject {
        let origin: String
        init(origin: String) { self.origin = origin }
        @objc(notificationPermissionsForWebsiteDataStore:)
        func permissions(_ store: WKWebsiteDataStore) -> NSDictionary { [origin: NSNumber(value: true)] }
    }

    private func wait(_ action: String, until condition: () -> Bool) async throws {
        for _ in 0..<80 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "DeveloperServiceWorkerTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(action)"])
    }
}
