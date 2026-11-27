import XCTest
@testable import Search

/// Developer Mode site by site (DevMode.swift): on by itself for a site on
/// this Mac only, a choice by hand kept per site and dropped once it says
/// what the site would do by itself, private tabs keeping nothing.
@available(macOS 14, *)
@MainActor
final class DevModeTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private func mode(local: Bool = true) -> (DevMode, UserDefaults) {
        let suite = "devmode.tests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        addTeardownBlock { store.removePersistentDomain(forName: suite) }
        let mode = DevMode(store: store)
        mode.localOverride = local
        return (mode, store)
    }

    func testLocalHosts() {
        for host in ["localhost", "LOCALHOST", "127.0.0.1", "127.1.2.3", "::1", "[::1]", "app.localhost",
                     "shop.test", "0.0.0.0", "localhost."] {
            XCTAssertTrue(DevMode.isLocal(host), host)
        }
        for host in ["example.com", "localhost.com", "mytest", "test.example.com", "127.0.0.1.example.com",
                     "128.0.0.1", "127.0.0", "127.0.0.256", "10.0.0.1", "testing", "contest"] {
            XCTAssertFalse(DevMode.isLocal(host), host)
        }
    }

    func testOnByItselfForLocalSitesOnly() {
        let (mode, _) = mode()
        XCTAssertTrue(mode.isOn(URL(string: "http://localhost:3000/"), shy: false))
        XCTAssertTrue(mode.isOn(URL(string: "http://[::1]:8080/a?b=c"), shy: false))
        XCTAssertTrue(mode.isOn(URL(string: "https://app.test/"), shy: true))
        XCTAssertFalse(mode.isOn(URL(string: "https://example.com/"), shy: false))
        // Not a web page: never.
        XCTAssertFalse(mode.isOn(URL(string: "file:///tmp/a.html"), shy: false))
        XCTAssertFalse(mode.isOn(nil, shy: false))

        let (off, _) = self.mode(local: false)
        XCTAssertFalse(off.isOn(URL(string: "http://localhost:3000/"), shy: false))
    }

    func testChoicesKeptPerSiteAndDroppedWhenDefault() {
        let (mode, store) = mode()
        let local = URL(string: "http://localhost:5173/")!
        let site = URL(string: "https://staging.example.com/x")!

        mode.set(true, for: site, shy: false)
        XCTAssertTrue(mode.isOn(site, shy: false))
        XCTAssertTrue(mode.isOn(URL(string: "https://staging.example.com/other"), shy: false))
        XCTAssertEqual(store.dictionary(forKey: DevMode.sitesKey) as? [String: Bool], ["staging.example.com": true])

        mode.set(false, for: local, shy: false)
        XCTAssertFalse(mode.isOn(local, shy: false))
        XCTAssertEqual(store.dictionary(forKey: DevMode.sitesKey)?["localhost"] as? Bool, false)

        // Back to what each does by itself: nothing kept.
        mode.set(true, for: local, shy: false)
        mode.set(false, for: site, shy: false)
        XCTAssertNil(store.object(forKey: DevMode.sitesKey))
        XCTAssertTrue(mode.isOn(local, shy: false))
        XCTAssertFalse(mode.isOn(site, shy: false))
    }

    func testPrivateTabsKeepNothing() {
        let (mode, store) = mode()
        let site = URL(string: "https://example.org/")!
        mode.set(true, for: site, shy: true)
        XCTAssertTrue(mode.isOn(site, shy: true))
        XCTAssertFalse(mode.isOn(site, shy: false))
        XCTAssertNil(store.object(forKey: DevMode.sitesKey))
    }

    func testCacheOffPerSite() {
        let (mode, _) = mode()
        let page = URL(string: "http://localhost:3000/a")!
        XCTAssertFalse(mode.skipsCache(page))
        mode.setSkipsCache(true, for: page)
        XCTAssertTrue(mode.skipsCache(URL(string: "http://localhost:3000/b")))
        XCTAssertFalse(mode.skipsCache(URL(string: "https://example.com/")))
        mode.setSkipsCache(false, for: page)
        XCTAssertFalse(mode.skipsCache(page))
    }

    func testShortcutAndSettings() {
        let command = Command.named("view.developerMode")
        XCTAssertNotNil(command)
        XCTAssertEqual(ShortcutStore.shared.display("view.developerMode"), "⌥⇧⌘I")
        XCTAssertNotNil(SettingsIndex.items.first { $0.id == "developer.local" })
    }
}
