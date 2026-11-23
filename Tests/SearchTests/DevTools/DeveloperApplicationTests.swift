import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class DeveloperApplicationTests: XCTestCase {
    func testReadsApplicationDataOnlyFromTheInspectedOrigin() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Perch Application fixture</title>
                <link rel="manifest" href="/perch.webmanifest">
                """),
            "/perch.webmanifest": .init(type: "application/manifest+json", body: """
                {"name":"Perch fixture","start_url":"/","display_override":["window-controls-overlay","standalone"]}
                """),
            "/worker.js": .init(type: "text/javascript", body: """
                self.addEventListener('install', (event) => event.waitUntil(self.skipWaiting()));
                self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));
                """),
        ])
        let address = server.url("/")
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        Web.inspector(config.preferences)
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 440), configuration: config)
        page.load(URLRequest(url: address))
        try await wait { page.title == "Perch Application fixture" && !page.isLoading }

        let fixture = try await page.callAsyncJavaScript("""
            localStorage.setItem('local fixture', 'local value');
            sessionStorage.setItem('session fixture', 'session value');
            document.cookie = 'fixture_cookie=example; Path=/';
            const db = await new Promise((resolve, reject) => {
                const open = indexedDB.open('perch application fixture', 1);
                open.onupgradeneeded = () => open.result.createObjectStore('preferences', { keyPath: 'id' })
                    .createIndex('label', 'label');
                open.onsuccess = () => resolve(open.result);
                open.onerror = () => reject(open.error);
            });
            await new Promise((resolve, reject) => {
                const transaction = db.transaction('preferences', 'readwrite');
                transaction.objectStore('preferences').put({ id: 1, label: 'fixture record' });
                transaction.oncomplete = resolve;
                transaction.onerror = () => reject(transaction.error);
            });
            db.close();
            if (!navigator.serviceWorker?.register) return false;
            try {
                await navigator.serviceWorker.register('/worker.js');
                return true;
            } catch { return false; }
            """, arguments: [:], in: nil, contentWorld: .page)
        let workerAvailable = fixture as? Bool == true
        let unrelated = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "example.test", .path: "/", .name: "other_cookie", .value: "unrelated fixture",
        ]))
        await page.configuration.websiteDataStore.httpCookieStore.setCookie(unrelated)
        let httpOnly = try XCTUnwrap(HTTPCookie.cookies(withResponseHeaderFields: [
            "Set-Cookie": "http_only_fixture=local; Path=/; HttpOnly",
        ], for: address).first)
        XCTAssertTrue(httpOnly.isHTTPOnly)
        await page.configuration.websiteDataStore.httpCookieStore.setCookie(httpOnly)

        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        defer { _ = session.disconnect() }
        try await wait { session.ready }

        func read(_ section: DeveloperApplicationSection, database: String? = nil, store: String? = nil) async throws -> [[String]] {
            try await DeveloperApplication.read(.init(section: section, database: database, store: store),
                                                in: session, address: address).rows.map(\.values)
        }
        let local = try await read(.local)
        let sessionStorage = try await read(.session)
        let cookies = try await read(.cookies)
        let manifest = try await read(.manifest)
        let databases = try await read(.indexedDB)
        let stores = try await read(.indexedDB, database: "perch application fixture")
        let records = try await read(.indexedDB, database: "perch application fixture", store: "preferences")

        XCTAssertTrue(local.contains(["local fixture", "local value"]))
        XCTAssertTrue(sessionStorage.contains(["session fixture", "session value"]))
        XCTAssertTrue(cookies.contains { $0.first == "fixture_cookie" && $0.dropFirst().first == "example" })
        XCTAssertFalse(cookies.contains { $0.first == "other_cookie" })
        let readsHTTPOnly: Bool
#if compiler(>=6.4)
        if #available(macOS 27, *) { readsHTTPOnly = true } else { readsHTTPOnly = false }
#else
        readsHTTPOnly = false
#endif
        if readsHTTPOnly {
            XCTAssertTrue(cookies.contains { $0.count == 11 && $0.first == "http_only_fixture" && $0[6] == "✓" })
        } else {
            XCTAssertFalse(cookies.contains { $0.first == "http_only_fixture" })
        }
        XCTAssertTrue(manifest.contains(["Name", "Perch fixture"]))
        XCTAssertTrue(manifest.contains(["Display override", "window-controls-overlay, standalone"]))
        XCTAssertTrue(databases.contains(["perch application fixture", "1"]))
        XCTAssertTrue(stores.contains(["preferences", "id", "—", "label"]))
        XCTAssertTrue(records.contains { $0.count == 3 && $0[1] == "1" && $0.last?.contains("fixture record") == true })

        _ = try await read(.indexedDB, database: "deleted database fixture")
        let afterMissing = try await read(.indexedDB)
        XCTAssertFalse(afterMissing.contains { $0.first == "deleted database fixture" })

        if workerAvailable {
            let workers = try await read(.workers)
            XCTAssertTrue(workers.contains { $0.contains(server.url("/worker.js").absoluteString) })
        }

        do {
            _ = try await DeveloperApplication.read(.init(section: .local), in: session, address: server.url("/elsewhere"))
            XCTFail("A stale page address must not receive storage values")
        } catch DeveloperApplication.Issue.pageChanged {}
        XCTAssertFalse(session.nativeInspectorVisible)
    }

    func testEditsExactStorageKeysAndRejectsStaleValuesAndReloads() async throws {
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: "<!doctype html><title>Storage editor fixture</title>"),
        ])
        let address = server.url("/")
        let (page, tab, session) = try await editingSession(for: address, title: "Storage editor fixture")
        defer {
            _ = session.disconnect()
            withExtendedLifetime(tab) {}
        }
        let prefix = String(repeating: "k", count: 4100)
        let key = prefix + " target"
        let sibling = prefix + " other"
        let original = String(repeating: "v", count: 5200)
        _ = try await page.callAsyncJavaScript("""
            localStorage.setItem(key, original);
            localStorage.setItem(sibling, 'sibling');
            sessionStorage.setItem(key, 'session');
            sessionStorage.setItem('oversize', 'a'.repeat(65537));
            """, arguments: ["key": key, "sibling": sibling, "original": original], in: nil, contentWorld: .page)

        let local = try await DeveloperApplication.read(.init(section: .local), in: session, address: address)
        let row = try XCTUnwrap(local.rows.first { $0.values.last?.count == 4096 })
        XCTAssertEqual(row.values.first?.count, 4096)
        let localRef = try XCTUnwrap(row.editableValue)
        let fullValue = try await DeveloperApplication.value(for: localRef, in: session)
        XCTAssertEqual(fullValue, original)
        try await DeveloperApplication.setValue("updated", replacing: fullValue, for: localRef, in: session)
        do {
            try await DeveloperApplication.setValue("stale", replacing: fullValue, for: localRef, in: session)
            XCTFail("A stale value must not be overwritten")
        } catch DeveloperApplication.Issue.valueChanged {}

        let sessionRows = try await DeveloperApplication.read(.init(section: .session), in: session, address: address)
        let sessionRef = try XCTUnwrap(sessionRows.rows.first { $0.values.last == "session" }?.editableValue)
        let sessionValue = try await DeveloperApplication.value(for: sessionRef, in: session)
        try await DeveloperApplication.setValue("updated session", replacing: sessionValue, for: sessionRef, in: session)
        let oversize = try XCTUnwrap(sessionRows.rows.first { $0.values.first == "oversize" }?.editableValue)
        do {
            _ = try await DeveloperApplication.value(for: oversize, in: session)
            XCTFail("Opening a large value must not silently return an editable prefix")
        } catch DeveloperApplication.Issue.valueTooLarge {}
        let confirmed = try await page.callAsyncJavaScript("""
            return [localStorage.getItem(key), localStorage.getItem(sibling), sessionStorage.getItem(key)];
            """, arguments: ["key": key, "sibling": sibling], in: nil, contentWorld: .page) as? [String]
        XCTAssertEqual(confirmed, ["updated", "sibling", "updated session"])
        _ = try await page.evaluateJavaScript("document.title = 'Before reload'")
        try await wait { page.title == "Before reload" }
        page.reload()
        try await wait { page.url == address && !page.isLoading && page.title == "Storage editor fixture" }
        do {
            try await DeveloperApplication.setValue("stale document", replacing: "updated", for: localRef, in: session)
            XCTFail("A reloaded document must have a new edit identity even at the same URL")
        } catch DeveloperApplication.Issue.pageChanged {}
        let afterReload = try await page.callAsyncJavaScript("return localStorage.getItem(key);",
            arguments: ["key": key], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(afterReload, "updated")
    }

    func testEditsTheSelectedCookieAndPreservesItsAttributes() async throws {
        let server = try LocalPageServer([
            "/app/index": .init(type: "text/html", body: "<!doctype html><title>Cookie editor fixture</title>"),
        ])
        let address = server.url("/app/index")
        let (page, tab, session) = try await editingSession(for: address, title: "Cookie editor fixture")
        defer {
            _ = session.disconnect()
            withExtendedLifetime(tab) {}
        }
        let jar = page.configuration.websiteDataStore.httpCookieStore
        func make(_ header: String, for url: URL) throws -> HTTPCookie {
            try XCTUnwrap(HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: url).first)
        }
        let selected = try make("example=original; Path=/app; HttpOnly; SameSite=Strict; Expires=Wed, 21 Oct 2037 07:28:00 GMT", for: address)
        let sibling = try make("example=sibling; Path=/", for: address)
        let otherOrigin = try make("example=unrelated; Path=/", for: XCTUnwrap(URL(string: "https://example.test/")))
        await jar.setCookie(selected)
        await jar.setCookie(sibling)
        await jar.setCookie(otherOrigin)

        let snapshot = try await DeveloperApplication.read(.init(section: .cookies), in: session, address: address)
#if compiler(>=6.4)
        guard #available(macOS 27, *) else {
            XCTAssertTrue(snapshot.rows.allSatisfy { $0.editableValue == nil })
            return
        }
        let row = try XCTUnwrap(snapshot.rows.first { $0.values.count == 11 && $0.values[3] == "/app" })
        let reference = try XCTUnwrap(row.editableValue)
        let original = try await DeveloperApplication.value(for: reference, in: session)
        XCTAssertEqual(original, "original")
        do {
            try await DeveloperApplication.setValue("value; Path=/", replacing: original, for: reference, in: session)
            XCTFail("Cookie values may not inject attributes")
        } catch DeveloperApplication.Issue.invalidCookieValue {}
        try await DeveloperApplication.setValue("modified=1", replacing: original, for: reference, in: session)
        do {
            try await DeveloperApplication.setValue("stale", replacing: original, for: reference, in: session)
            XCTFail("A changed cookie must not be overwritten with a stale editor")
        } catch DeveloperApplication.Issue.valueChanged {}
        let all = await jar.allCookies()
        let saved = try XCTUnwrap(all.first { $0.domain == selected.domain && $0.path == selected.path })
        XCTAssertEqual(saved.value, "modified=1")
        XCTAssertEqual(saved.name, selected.name)
        XCTAssertEqual(saved.isHTTPOnly, selected.isHTTPOnly)
        XCTAssertEqual(saved.isSecure, selected.isSecure)
        XCTAssertEqual(saved.sameSitePolicy, selected.sameSitePolicy)
        XCTAssertEqual(saved.expiresDate, selected.expiresDate)
        XCTAssertTrue(all.contains { $0.domain == sibling.domain && $0.path == sibling.path && $0.value == "sibling" })
        XCTAssertTrue(all.contains { $0.domain == otherOrigin.domain && $0.path == otherOrigin.path && $0.value == "unrelated" })
#else
        XCTAssertTrue(snapshot.rows.allSatisfy { $0.editableValue == nil })
#endif
    }

    private func editingSession(for address: URL, title: String) async throws -> (WKWebView, Tab, DeveloperToolsSession) {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        Web.inspector(config.preferences)
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 440), configuration: config)
        page.load(URLRequest(url: address))
        try await wait { page.title == title && !page.isLoading }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        try await wait { session.ready }
        return (page, tab, session)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<80 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "DeveloperApplicationTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "The local WebKit fixture did not finish attaching."])
    }
}
