import AppKit
import XCTest
@testable import Search

/// The switches on for everyone who never touched them (Drice, 25 Nov 2026):
/// on with no line in the settings, off with a line saying off, and the
/// reads outside Preferences agreeing. Most have no switch since 27 Nov
/// 2026 (Retired): a test world still reads their line, which is what the
/// first test sees; the retired test sees them as everyone else does.
@MainActor
final class DefaultsOnTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    static let keys = ["privacy.httpsFirst", "tabs.undoReopens", "video.keys", "tabs.popupWindows", "tabs.frontBeside",
                       "tabs.swipeBackCloses", "reader.follows", "pages.capture", "sites.styles",
                       "home.grid", Motion.lightKey, "float.minimize", "pins.folders", "commandbar",
                       "sidebar.player", "tabs.pinCounts", "tabs.newAfterLast"]
    /// Still off unless turned on.
    /// "wheel.smooth" was on from 25 Nov 2026 until 27 Nov: off again, it
    /// cost about four times the CPU per notch.
    static let offKeys = ["search.suggest", "pages.bounce", "passwords.fill.prove", "tabs.lazy", "links.little.tabs", "wheel.smooth"]

    private func read(_ prefs: Preferences) -> [String: Bool] {
        ["privacy.httpsFirst": prefs.triesHTTPSFirst && HTTPSFirst.on,
         "tabs.undoReopens": prefs.undoReopensTab,
         "video.keys": prefs.videoKeys && VideoKeys.on,
         "tabs.popupWindows": prefs.popupWindows,
         "tabs.frontBeside": prefs.frontLinksBeside,
         "tabs.swipeBackCloses": prefs.swipeBackCloses,
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
        XCTAssertFalse(fresh.wheelGlides || WheelGlide.on, "smooth wheel off unless turned on")
        XCTAssertNil(store.object(forKey: "wheel.smooth"), "nothing written for the default")
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

        // Turned on by hand (while it was on for everyone, or since): it stays on.
        store.set(true, forKey: "wheel.smooth")
        let chosen = Preferences()
        XCTAssertTrue(chosen.wheelGlides && WheelGlide.on, "smooth wheel turned on stays on")
    }

    /// Settings cut in half (27 Nov 2026): the switches it took out are
    /// fixed, whatever line an earlier build left. Seen as everyone sees
    /// Search, outside a test world (Retired.honoured off).
    static let retiredOn = ["tabs.undoReopens", "video.keys", "tabs.popupWindows", "tabs.frontBeside", "tabs.swipeBackCloses",
                            "reader.follows", "pages.capture", "sites.styles", "home.grid", Motion.lightKey, "float.minimize",
                            "pins.folders", "commandbar", "sidebar.player", "tabs.pinCounts", "tabs.newAfterLast",
                            "meet.pip", "pins.preview", "swipe.history", UpdateNotice.key, "pins.home", "pins.peek",
                            // Off until 27 Nov 2026, on for everyone since.
                            "sidebar.narrowIcons", "newtab.recent"]
    static let retiredOff = ["tabs.reading", "tabs.give", "reader.twins", "field.hidesPage", "tabs.clickAddressOnly", "pages.bounce"]

    func testRetiredSwitchesAreFixedWhateverTheLineSays() {
        let store = Store.settings
        let all = Self.retiredOn + Self.retiredOff
        let saved = Dictionary(uniqueKeysWithValues: all.map { ($0, store.object(forKey: $0)) })
        let savedLowPower = Motion.testLowPower
        defer {
            Retired.honoured = true
            for (key, value) in saved {
                if let value { store.set(value, forKey: key) } else { store.removeObject(forKey: key) }
            }
            Motion.testLowPower = savedLowPower
            _ = Preferences()
        }
        Retired.honoured = false
        func check(_ prefs: Preferences, _ said: String) {
            XCTAssertTrue(prefs.undoReopensTab && prefs.videoKeys && VideoKeys.on && prefs.popupWindows
                          && prefs.frontLinksBeside && prefs.swipeBackCloses && prefs.readerFollowsLook, said)
            XCTAssertTrue(prefs.capturesPages && prefs.sitesStyles && SiteStyles.shared.on && prefs.homeGrid, said)
            XCTAssertTrue(prefs.lightMotion && prefs.floatMinimizes && Float.minimizes && prefs.pinFolders, said)
            XCTAssertTrue(prefs.commandBar && prefs.showsPlayer && prefs.showsPinCounts && prefs.newTabAfterLast, said)
            XCTAssertTrue(prefs.meetPiP && MeetPiP.on && prefs.pinPreviews && prefs.holdsHistory && PageView.holdsHistory, said)
            XCTAssertTrue(prefs.showsUpdateReady && prefs.pinsKeepSite && prefs.pinsGoHome && prefs.pinsPeek, said)
            XCTAssertTrue(prefs.narrowsToIcons && prefs.recentInNewTab, said)
            XCTAssertFalse(prefs.showsReading || prefs.tabsGive || prefs.readsTwins || prefs.fieldHidesPage
                           || prefs.tabClickAddressOnly || prefs.bounces || Swipe.bounces, said)
            Motion.testLowPower = true
            XCTAssertTrue(Motion.savingPower, said)
            store.set("dark", forKey: "reader.look")
            XCTAssertEqual(Reader.look, .dark, said)
            store.removeObject(forKey: "reader.look")
        }

        all.forEach(store.removeObject(forKey:))
        check(Preferences(), "no line")
        XCTAssertTrue(all.allSatisfy { store.object(forKey: $0) == nil }, "nothing written for a fixed switch")

        // An old choice the other way: not followed, and left where it is.
        Self.retiredOn.forEach { store.set(false, forKey: $0) }
        Self.retiredOff.forEach { store.set(true, forKey: $0) }
        let prefs = Preferences()
        check(prefs, "an old line the other way")
        prefs.reread()
        check(prefs, "read again from the file")
        XCTAssertTrue(Self.retiredOn.allSatisfy { store.object(forKey: $0) as? Bool == false }, "old lines left alone")
        XCTAssertTrue(Self.retiredOff.allSatisfy { store.object(forKey: $0) as? Bool == true }, "old lines left alone")
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
