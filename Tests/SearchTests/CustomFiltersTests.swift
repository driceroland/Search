import CryptoKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class CustomFiltersTests: XCTestCase {
    func testOnlyAcceptsHTTPSSubscriptionURLs() {
        XCTAssertEqual(CustomFilters.subscriptionURL(" HTTPS://EXAMPLE.COM:443/a?b=1#part ")?.absoluteString,
                       "https://example.com/a?b=1")
        for value in ["http://example.com/", "file:///filters", "https:///file",
                      "https://name:pass@example.com/", "example.com"] {
            XCTAssertNil(CustomFilters.subscriptionURL(value), value)
        }
    }

    func testCachedRulesSurviveFailedRefreshAndRefreshIsOffByDefault() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "shield-custom-\(UUID())"
        let settings = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: directory))
        let shield = Shield(store: store, settings: settings)
        let cache = directory.appendingPathComponent("filters")
        let url = try XCTUnwrap(URL(string: "https://example.invalid/filters.txt"))
        var downloads: [URL] = []
        var fail = false
        let filters = CustomFilters(settings: settings, cache: cache, store: store, shield: shield) { url in
            downloads.append(url)
            if fail { throw URLError(.badServerResponse) }
            return Data("subscription-pixel.js".utf8)
        }
        defer { filters.setEnabled(false) }

        filters.add(url)
        filters.save("my-pixel.js")
        filters.start()
        filters.updateNow()
        XCTAssertFalse(filters.enabled)
        XCTAssertFalse(filters.refreshing)
        XCTAssertTrue(downloads.isEmpty)

        filters.setEnabled(true)
        try await wait { filters.ruleCount == 2 && !filters.refreshing }
        XCTAssertEqual(downloads, [url])
        let updated = try XCTUnwrap(filters.lastUpdated[url.absoluteString])
        let names = await store.availableIdentifiers() ?? []
        XCTAssertEqual(names.filter { $0.hasPrefix(CustomFilters.identifierPrefix) }.count, 1)

        filters.setEnabled(false)
        filters.setEnabled(true)
        XCTAssertFalse(filters.refreshing)
        XCTAssertEqual(downloads, [url])
        fail = true
        filters.updateNow()
        try await wait { !filters.refreshing }
        XCTAssertEqual(downloads, [url, url])
        XCTAssertNotNil(filters.listTrouble[url.absoluteString])
        XCTAssertEqual(filters.lastUpdated[url.absoluteString], updated)
        XCTAssertEqual(filters.ruleCount, 2)

        filters.remove(url.absoluteString)
        try await wait { filters.ruleCount == 1 }
        XCTAssertTrue(filters.lists.isEmpty)
        XCTAssertTrue(filters.lastUpdated.isEmpty)
        XCTAssertTrue(filters.listTrouble.isEmpty)
    }

    func testStartupRestoresTheManifestWithoutPreparingAndRebuildsAfterChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = directory.appendingPathComponent("filters")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "shield-manifest-\(UUID())"
        let settings = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let url = "https://example.invalid/filters.txt"
        settings.set(true, forKey: "shield.custom")
        settings.set([url], forKey: "shield.lists")
        settings.set([url: Date().timeIntervalSince1970], forKey: "shield.listAttempts")
        settings.set("my-pixel.js\nignored$redirect=noop", forKey: "shield.myFilters")
        let name = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = cache.appendingPathComponent(name)
        try Data("subscription-one.js".utf8).write(to: file, options: .atomic)

        let store = try XCTUnwrap(WKContentRuleListStore(url: directory))
        var preparations = 0
        func makeFilters(shield: Shield) -> CustomFilters {
            CustomFilters(settings: settings, cache: cache, store: store, shield: shield, onPrepare: {
                preparations += 1
            }, fetch: { _ in
                XCTFail("The cached fixture should not need downloading")
                throw URLError(.badServerResponse)
            })
        }
        let first = makeFilters(shield: Shield(store: store, settings: settings))
        let secondShield = Shield(store: store, settings: settings)
        let second = makeFilters(shield: secondShield)
        let third = makeFilters(shield: Shield(store: store, settings: settings))
        // Each new instance reads the enabled preference, like a new launch.
        defer {
            first.setEnabled(false)
            second.setEnabled(false)
            third.setEnabled(false)
        }

        first.start()
        try await wait { first.ruleCount == 2 }
        XCTAssertEqual(preparations, 1)
        let firstNames = await store.availableIdentifiers() ?? []
        let oldIdentifier = try XCTUnwrap(firstNames.first)

        second.start()
        var released = false
        secondShield.whenReady {
            XCTAssertEqual(second.ruleCount, 2)
            XCTAssertEqual(second.skippedCount, 1)
            released = true
        }
        XCTAssertFalse(released)
        try await wait { released }
        XCTAssertEqual(preparations, 1)

        // Even the same-size replacement invalidates the manifest.
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        try Data("subscription-two.js".utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        third.start()
        try await wait { third.ruleCount == 2 }
        XCTAssertEqual(preparations, 2)
        let modifiedNames = await store.availableIdentifiers() ?? []
        let newIdentifier = try XCTUnwrap(modifiedNames.first { $0 != oldIdentifier })

        let fourth = makeFilters(shield: Shield(store: store, settings: settings))
        defer { fourth.setEnabled(false) }
        try await store.removeContentRuleList(forIdentifier: newIdentifier)
        fourth.start()
        try await wait { fourth.ruleCount == 2 }
        XCTAssertEqual(preparations, 3)
        let rebuiltNames = await store.availableIdentifiers() ?? []
        XCTAssertTrue(rebuiltNames.contains(newIdentifier))
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for custom filters")
    }
}
