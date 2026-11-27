import XCTest
@testable import Search

/// Settings › Appearance › Darken pages that stay light: hidden while Search
/// is set to Light, unless it is on, so whoever turned it on can always find
/// it to turn it off. On the model only.
@available(macOS 14, *)
@MainActor
final class DuskSwitchTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "dusk-switch-\(getpid())", 1)
        super.setUp()
    }

    private let keys = ["look", "pages.dusk"]
    private var saved: [(String, Any?)] = []

    override func setUp() async throws {
        saved = keys.map { ($0, Store.settings.object(forKey: $0)) }
        keys.forEach(Store.settings.removeObject(forKey:))
    }

    override func tearDown() async throws {
        for (key, value) in saved { Store.settings.set(value, forKey: key) }
        Dusk.shared.on = Store.settings.bool(forKey: "pages.dusk")
    }

    func testShownInLightOnlyWhileOn() throws {
        let prefs = Preferences()
        let item = try XCTUnwrap(SettingsIndex.item("pages.dusk"))
        prefs.look = .dark
        XCTAssertTrue(SettingsIndex.applies(item, prefs), "dark: there to turn on")
        prefs.look = .light
        XCTAssertFalse(SettingsIndex.applies(item, prefs), "light and off: nothing to turn on")
        prefs.darkensPages = true
        XCTAssertTrue(SettingsIndex.applies(item, prefs), "light and on: shown, so it can be turned off")
    }
}
