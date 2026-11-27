import AppKit
import XCTest
@testable import Search

/// The switches on for everyone who never touched them (Drice, 25 Nov 2026):
/// on with no line in the settings, off with a line saying off, and the
/// reads outside Preferences agreeing.
@MainActor
final class DefaultsOnTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    static let keys = ["privacy.httpsFirst", "tabs.undoReopens", "video.keys", "tabs.popupWindows", "tabs.frontBeside",
                       "tabs.swipeBackCloses", "wheel.smooth", "reader.follows", "pages.capture", "sites.styles",
                       "home.grid", Motion.lightKey, "float.minimize", "pins.folders", "commandbar",
                       "sidebar.player", "tabs.pinCounts", "tabs.newAfterLast"]
    /// Still off unless turned on.
    static let offKeys = ["search.suggest", "pages.bounce", "passwords.fill.prove", "tabs.lazy", "links.little.tabs"]

    private func read(_ prefs: Preferences) -> [String: Bool] {
        ["privacy.httpsFirst": prefs.triesHTTPSFirst && HTTPSFirst.on,
         "tabs.undoReopens": prefs.undoReopensTab,
         "video.keys": prefs.videoKeys && VideoKeys.on,
         "tabs.popupWindows": prefs.popupWindows,
         "tabs.frontBeside": prefs.frontLinksBeside,
         "tabs.swipeBackCloses": prefs.swipeBackCloses,
         "wheel.smooth": prefs.wheelGlides && WheelGlide.on,
         "reader.follows": prefs.readerFollowsLook,
         "pages.capture": prefs.capturesPages,
         "sites.styles": prefs.sitesStyles && SiteStyles.shared.on,
         "home.grid": prefs.homeGrid,
         Motion.lightKey: prefs.lightMotion,
         "float.minimize": prefs.floatMinimizes && Float.minimizes,
         "pins.folders": prefs.pinFolders,
         "commandbar": prefs.commandBar,
         "sidebar.player": prefs.showsPlayer,
         "tabs.pinCounts": prefs.showsPinCounts,
         "tabs.newAfterLast": prefs.newTabAfterLast]
    }

    func testOnWithNoLineOffWithALineSayingOff() {
        let store = Store.settings
        let all = Self.keys + Self.offKeys
        let saved = Dictionary(uniqueKeysWithValues: all.map { ($0, store.object(forKey: $0)) })
        let savedLowPower = Motion.testLowPower
        defer {
            for (key, value) in saved {
                if let value { store.set(value, forKey: key) } else { store.removeObject(forKey: key) }
            }
            Motion.testLowPower = savedLowPower
            _ = Preferences()
        }

        all.forEach(store.removeObject(forKey:))
        let fresh = Preferences()
        XCTAssertEqual(read(fresh), Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, true) }))
        XCTAssertFalse(fresh.engineSuggests)
        XCTAssertFalse(fresh.bounces)
        XCTAssertFalse(fresh.asksBeforeFilling)
        XCTAssertFalse(fresh.lazyTabs)
        XCTAssertFalse(fresh.linksFindTabs)
        // Read where they are used, outside Preferences, the same way.
        Motion.testLowPower = true
        XCTAssertTrue(Motion.savingPower, "Save power in Low Power Mode, on")
        store.set("dark", forKey: "reader.look")
        XCTAssertEqual(Reader.look, .dark, "reading mode follows the look chosen")
        store.removeObject(forKey: "reader.look")
        // Nothing is written for a default.
        XCTAssertTrue(Self.keys.allSatisfy { store.object(forKey: $0) == nil })

        Self.keys.forEach { store.set(false, forKey: $0) }
        let off = Preferences()
        XCTAssertEqual(read(off), Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, false) }))
        XCTAssertFalse(Motion.savingPower, "turned off, it stays off")
        XCTAssertEqual(Reader.look, .light, "turned off, the article is light")
    }

    func testInlinePredictionsFollowTheMacUntilChosen() {
        let store = Store.settings
        let saved = store.object(forKey: "inlinePredictions")
        let kept = UserDefaults.standard.object(forKey: Preferences.inlinePredictionsKey)
        defer {
            if let saved { store.set(saved, forKey: "inlinePredictions") } else { store.removeObject(forKey: "inlinePredictions") }
            if let kept { UserDefaults.standard.set(kept, forKey: Preferences.inlinePredictionsKey) }
            else { UserDefaults.standard.removeObject(forKey: Preferences.inlinePredictionsKey) }
        }
        store.removeObject(forKey: "inlinePredictions")
        // An earlier build's false, written with no choice made, goes.
        UserDefaults.standard.set(false, forKey: Preferences.inlinePredictionsKey)
        let fresh = Preferences()
        XCTAssertEqual(fresh.inlinePredictions, Preferences.macPredicts)
        XCTAssertNil(UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[Preferences.inlinePredictionsKey])
        XCTAssertNil(store.object(forKey: "inlinePredictions"))

        store.set(false, forKey: "inlinePredictions")
        let chosen = Preferences()
        XCTAssertFalse(chosen.inlinePredictions)
        XCTAssertEqual(UserDefaults.standard.object(forKey: Preferences.inlinePredictionsKey) as? Bool, false)
    }
}
