import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class DeveloperStorageEditingTests: XCTestCase {
    func testAddsDeletesAndClearsStorageAndSiteData() async throws {
        let (server, page, tab, session) = try await fixture()
        defer { _ = session.disconnect(); withExtendedLifetime((server, tab)) {} }
        let address = try XCTUnwrap(page.url)

        try await DeveloperApplication.setStorageItem(key: "added", value: "first", replacing: nil, persistent: true,
                                                      in: session, address: address)
        try await DeveloperApplication.setStorageItem(key: "kept", value: "second", replacing: nil, persistent: true,
                                                      in: session, address: address)
        var local = try await DeveloperApplication.read(.init(section: .local), in: session, address: address)
        XCTAssertTrue(local.rows.contains { $0.values == ["added", "first"] })
        let added = try XCTUnwrap(local.rows.first { $0.values.first == "added" }?.item)
        try await DeveloperApplication.delete([added], in: session)
        local = try await DeveloperApplication.read(.init(section: .local), in: session, address: address)
        XCTAssertFalse(local.rows.contains { $0.values.first == "added" })
        XCTAssertTrue(local.rows.contains { $0.values == ["kept", "second"] })
        let stored = try await page.evaluateJavaScript("localStorage.getItem('added')")
        XCTAssertTrue(stored == nil || stored is NSNull)

        let overview = try await DeveloperApplication.overview(in: session, address: address)
        XCTAssertEqual(overview.counts.first { $0.0 == "Local storage" }?.1, 1)
        let failed = try await DeveloperApplication.clearSiteData([.storage], in: session, address: address)
        XCTAssertEqual(failed, [])
        let length = try await page.evaluateJavaScript("localStorage.length") as? Int
        XCTAssertEqual(length, 0)
    }

    func testSavesANewCookie() async throws {
        let (server, page, tab, session) = try await fixture()
        defer { _ = session.disconnect(); withExtendedLifetime((server, tab)) {} }
        let address = try XCTUnwrap(page.url)
        guard #available(macOS 27, *) else { return }
        var draft = DeveloperCookieDraft()
        draft.name = "added_cookie"
        draft.value = "fresh"
        draft.sameSite = "Lax"
        try await DeveloperApplication.saveCookie(draft, replacing: nil, in: session, address: address)
        let cookies = try await DeveloperApplication.read(.init(section: .cookies), in: session, address: address)
        let row = try XCTUnwrap(cookies.rows.first { $0.values.first == "added_cookie" })
        XCTAssertEqual(row.values.count, DeveloperApplication.cookieColumns.count)
        XCTAssertEqual(row.values[1], "fresh")
        let item = try XCTUnwrap(row.item)
        var edited = try await DeveloperApplication.cookieDraft(for: item, in: session)
        XCTAssertEqual(edited.value, "fresh")
        edited.value = "edited"
        try await DeveloperApplication.saveCookie(edited, replacing: item, in: session, address: address)
        let visible = try await page.evaluateJavaScript("document.cookie") as? String
        XCTAssertTrue(visible?.contains("added_cookie=edited") == true)
    }

    func testPagesDeletesAndClearsIndexedDBRecords() async throws {
        let (server, page, tab, session) = try await fixture()
        defer { _ = session.disconnect(); withExtendedLifetime((server, tab)) {} }
        let address = try XCTUnwrap(page.url)
        _ = try await page.callAsyncJavaScript("""
            await new Promise((resolve, reject) => {
              const open = indexedDB.open('paging fixture', 1);
              open.onupgradeneeded = () => open.result.createObjectStore('items');
              open.onsuccess = () => {
                const tx = open.result.transaction('items', 'readwrite');
                for (let i = 0; i < 60; i++) tx.objectStore('items').put({n: i}, i);
                tx.oncomplete = () => { open.result.close(); resolve(); };
                tx.onerror = () => reject(tx.error);
              };
              open.onerror = () => reject(open.error);
            });
            """, in: nil, contentWorld: .page)
        func records(skip: Int = 0) async throws -> DeveloperApplicationSnapshot {
            try await DeveloperApplication.read(.init(section: .indexedDB, database: "paging fixture",
                                                      store: "items", skip: skip), in: session, address: address)
        }
        let first = try await records()
        XCTAssertEqual(first.rows.count, DeveloperApplicationQuery.pageSize)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.total, 60)
        let second = try await records(skip: 50)
        XCTAssertEqual(second.rows.count, 10)
        XCTAssertEqual(second.rows.first?.values[1], "50")
        try await DeveloperApplication.delete([XCTUnwrap(second.rows.first?.item)], in: session)
        let afterDelete = try await records()
        XCTAssertEqual(afterDelete.total, 59)
        try await DeveloperApplication.delete([XCTUnwrap(afterDelete.container)], in: session)
        let cleared = try await records()
        XCTAssertEqual(cleared.rows.count, 0)
    }

    func testListsAndDeletesCacheStorageEntries() async throws {
        let (server, page, tab, session) = try await fixture()
        defer { _ = session.disconnect(); withExtendedLifetime((server, tab)) {} }
        let address = try XCTUnwrap(page.url)
        _ = try await page.callAsyncJavaScript("""
            const cache = await caches.open('fixture cache');
            await cache.put('/one', new Response('one', {headers: {'Content-Type': 'text/plain'}}));
            await cache.put('/two', new Response('two'));
            """, in: nil, contentWorld: .page)
        let caches = try await DeveloperApplication.read(.init(section: .caches), in: session, address: address)
        XCTAssertTrue(caches.rows.contains { $0.values.first == "fixture cache" })
        let entries = try await DeveloperApplication.read(.init(section: .caches, cache: "fixture cache"),
                                                          in: session, address: address)
        XCTAssertEqual(entries.rows.count, 2)
        let one = try XCTUnwrap(entries.rows.first { $0.values[1].hasSuffix("/one") })
        XCTAssertEqual(one.values[3], "text/plain")
        try await DeveloperApplication.delete([XCTUnwrap(one.item)], in: session)
        let remaining = try await DeveloperApplication.read(.init(section: .caches, cache: "fixture cache"),
                                                            in: session, address: address)
        XCTAssertEqual(remaining.rows.map { $0.values[1].hasSuffix("/two") }, [true])
    }

    func testLocationPresetAppliesItsTimezoneAndLocale() async throws {
        let (server, page, tab, session) = try await fixture()
        defer { _ = session.disconnect(); withExtendedLifetime((server, tab)) {} }
        let tokyo = try XCTUnwrap(DeveloperLocations.presets.first { $0.title == "Tokyo" })
        XCTAssertEqual(DeveloperLocations.presets.map(\.title), ["Berlin", "London", "Moscow", "Mountain View", "Mumbai",
                                                                 "San Francisco", "Shanghai", "São Paulo", "Tokyo"])
        var state = DeveloperToolsSensors.State()
        state.location = .coordinates(latitude: tokyo.latitude, longitude: tokyo.longitude, accuracy: tokyo.accuracy)
        state.timezone = tokyo.timezone
        state.locale = tokyo.locale
        session.applySensors(state)
        func zone() async -> [String]? {
            try? await page.evaluateJavaScript(
                "[Intl.DateTimeFormat().resolvedOptions().timeZone, navigator.language, String(new Date(0).getTimezoneOffset())]"
            ) as? [String]
        }
        try await waitFor("the Tokyo zone") { await zone() == ["Asia/Tokyo", "ja-JP", "-540"] }
        session.resetSensors()
        try await waitFor("the real zone again") { await zone()?.first == TimeZone.current.identifier }
    }

    private func fixture() async throws -> (LocalPageServer, WKWebView, Tab, DeveloperToolsSession) {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: "<!doctype html><title>Storage editing fixture</title>"),
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 440), configuration: configuration)
        page.load(URLRequest(url: server.url("/")))
        try await waitFor("the fixture") { page.title == "Storage editing fixture" && !page.isLoading }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        try await waitFor("the inspector") { session.ready }
        return (server, page, tab, session)
    }

    private func waitFor(_ action: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<80 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Timed out waiting for \(action)")
        throw CancellationError()
    }
}
