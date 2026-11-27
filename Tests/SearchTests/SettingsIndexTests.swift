import XCTest
@testable import Search

/// Settings' rows (SettingsIndex): merged controls write the keys the two
/// switches did, new defaults reach only keys never touched, and an
/// explicit off on a switch that left Settings stays off.
@MainActor
final class SettingsIndexTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private let touched = ["sidebar", "sidebar.position", "tabs.sleep", SleepPace.key, "float.leave", "float.away",
                           "pins.home", "pins.peek", "links.peek", "links.peekClick", "pages.120", "pages.120.mode",
                           "swipe.history", "tabs.address", "links.show", "float.flicks", "spaces", "pins.list",
                           "newtab.floating", "search.shift", "search.shiftCustom", "tabs.swipeBackCloses"]

    private func fresh(_ body: () -> Void) {
        let saved = touched.map { ($0, Store.settings.object(forKey: $0)) }
        defer { for (key, value) in saved { Store.settings.set(value, forKey: key) } }
        touched.forEach(Store.settings.removeObject(forKey:))
        body()
    }

    func testIdsAreUniqueAndEveryGroupIsReal() {
        XCTAssertEqual(Set(SettingsIndex.items.map(\.id)).count, SettingsIndex.items.count)
        for item in SettingsIndex.items {
            XCTAssertNotNil(SettingsIndex.group(item.group), item.id)
            XCTAssertLessThanOrEqual(item.detail.count, 90, item.id)
            if let parent = item.parent { XCTAssertNotNil(SettingsIndex.item(parent), item.id) }
        }
    }

    func testOldSectionNames() {
        XCTAssertEqual(SettingsPanel.Page.named("shortcuts"), .keyboard)
        XCTAssertEqual(SettingsPanel.Page.named("downloads"), .general)
        XCTAssertEqual(SettingsPanel.Page.named("privacy"), .privacy)
    }

    func testDefaultsForUntouchedKeys() {
        fresh {
            let prefs = Preferences()
            XCTAssertTrue(prefs.pinsKeepSite)
            XCTAssertEqual(prefs.fastPages, .never)
            XCTAssertTrue(prefs.holdsHistory)
            XCTAssertTrue(prefs.showsAddress)
            XCTAssertEqual(prefs.sleepChoice, .normal)
            XCTAssertEqual(prefs.floatOwn, .tabs)
            XCTAssertEqual(prefs.peekChoice, .shift)
            // Nothing written just for reading them.
            for key in ["pins.home", "pins.peek", "pages.120.mode", "swipe.history", "tabs.address"] {
                XCTAssertNil(Store.settings.object(forKey: key), key)
            }
        }
    }

    /// The loading line (27 Nov 2026): off, however 1.0.21 or 1.0.22 left
    /// things; only a switch turned on by hand counts.
    func testLoadingLineOffUnlessTurnedOn() {
        fresh {
            XCTAssertFalse(Preferences().showsLoadingLine)
            XCTAssertNil(Store.settings.object(forKey: "fold.loadingLine"), "nothing written for the default")
            Store.settings.set(false, forKey: "fold.loadingLine")
            XCTAssertFalse(Preferences().showsLoadingLine)
            Store.settings.set(true, forKey: "fold.loadingLine")
            XCTAssertTrue(Preferences().showsLoadingLine, "turned on by hand, it stays on")
        }
    }

    func testExplicitChoicesStand() {
        fresh {
            Store.settings.set(false, forKey: "pages.120")
            Store.settings.set(false, forKey: "swipe.history")
            Store.settings.set(false, forKey: "tabs.address")
            Store.settings.set(false, forKey: "links.show")
            Store.settings.set(false, forKey: "float.flicks")
            Store.settings.set(false, forKey: "pins.home")
            let prefs = Preferences()
            XCTAssertEqual(prefs.fastPages, .never)
            XCTAssertFalse(prefs.holdsHistory)
            XCTAssertFalse(prefs.showsAddress)
            XCTAssertFalse(prefs.showsLinks)
            XCTAssertFalse(prefs.floatFlicks)
            XCTAssertFalse(prefs.pinsKeepSite, "one off, the other never set: off")
            Store.settings.set(true, forKey: "pins.peek")
            XCTAssertTrue(Preferences().pinsKeepSite, "either on: on")
            Store.settings.set(true, forKey: "pages.120")
            XCTAssertEqual(Preferences().fastPages, .always)
        }
    }

    func testMergedControlsWriteTheOldKeys() {
        fresh {
            let prefs = Preferences()
            prefs.tabsLayout = .right
            XCTAssertEqual(Store.settings.object(forKey: "sidebar") as? Bool, true)
            XCTAssertEqual(Store.settings.string(forKey: "sidebar.position"), "right")
            prefs.tabsLayout = .top
            XCTAssertEqual(Store.settings.object(forKey: "sidebar") as? Bool, false)
            prefs.sleepChoice = .never
            XCTAssertEqual(Store.settings.object(forKey: "tabs.sleep") as? Bool, false)
            prefs.sleepChoice = .sooner
            XCTAssertEqual(Store.settings.object(forKey: "tabs.sleep") as? Bool, true)
            XCTAssertEqual(Store.settings.string(forKey: SleepPace.key), "sooner")
            prefs.floatOwn = .tabsOrApps
            XCTAssertEqual(Store.settings.object(forKey: "float.leave") as? Bool, true)
            XCTAssertEqual(Store.settings.object(forKey: "float.away") as? Bool, true)
            prefs.floatOwn = .never
            XCTAssertEqual(Store.settings.object(forKey: "float.leave") as? Bool, false)
            XCTAssertEqual(Store.settings.object(forKey: "float.away") as? Bool, false)
            prefs.pinsKeepSite = false
            XCTAssertEqual(Store.settings.object(forKey: "pins.home") as? Bool, false)
            XCTAssertEqual(Store.settings.object(forKey: "pins.peek") as? Bool, false)
            prefs.peekChoice = .off
            XCTAssertEqual(Store.settings.object(forKey: "links.peek") as? Bool, false)
            prefs.peekChoice = .optionCommand
            XCTAssertEqual(Store.settings.object(forKey: "links.peek") as? Bool, true)
            XCTAssertEqual(Store.settings.string(forKey: "links.peekClick"), "optionCommand")
        }
    }

    func testSetUpLikeArcAndUndo() {
        fresh {
            let prefs = Preferences()
            prefs.pinsKeepSite = false
            // On by default since a35ea540: written off so Set Up has it
            // to turn on, and Undo to put back.
            prefs.swipeBackCloses = false
            let before = prefs.arcSnapshot
            let layout = prefs.tabsLayout
            XCTAssertFalse(prefs.looksLikeArc)
            // The five from 1.0.7, closing tabs after 12 hours and swipe
            // back closing a link's tab; float and peek are on already.
            XCTAssertEqual(prefs.setUpLikeArc().count, 7)
            XCTAssertTrue(prefs.looksLikeArc)
            prefs.restore(before)
            XCTAssertEqual(prefs.tabsLayout, layout)
            XCTAssertFalse(prefs.usesSpaces || prefs.listsPins || prefs.pinsKeepSite || prefs.floatingNewTab)
            XCTAssertEqual(prefs.tabLife, .never)
            XCTAssertFalse(prefs.swipeBackCloses)
        }
    }

    /// Shift-Return's engine (#848): off until picked, kept when picked,
    /// and Off takes the key away again rather than writing an empty one.
    func testShiftEngineOffUntilPicked() {
        fresh {
            XCTAssertNil(Preferences().shiftEngine)
            XCTAssertNil(Store.settings.object(forKey: "search.shift"), "nothing written just for reading it")
            let prefs = Preferences()
            prefs.shiftEngine = .google
            XCTAssertEqual(Store.settings.string(forKey: "search.shift"), "google")
            XCTAssertEqual(Preferences().shiftEngine, .google)
            prefs.shiftEngine = .custom
            prefs.shiftCustom = "https://example.com/?q=%s"
            let again = Preferences()
            XCTAssertEqual(again.shiftEngine, .custom)
            XCTAssertEqual(again.shiftCustom, "https://example.com/?q=%s")
            prefs.shiftEngine = nil
            XCTAssertNil(Store.settings.object(forKey: "search.shift"))
            XCTAssertNil(Preferences().shiftEngine)
            Store.settings.set("not-an-engine", forKey: "search.shift")
            XCTAssertNil(Preferences().shiftEngine, "an unknown name reads as off")
        }
    }

    /// Settings cut in half (Drice, 27 Nov 2026): 163 rows before. At most
    /// half of them on the pages, and about 110 with every page's Advanced
    /// open. A budget: a row added past it takes one out.
    func testHalfAsLong() {
        let drawn = SettingsIndex.drawn
        let shown = drawn.filter { !$0.advanced }
        XCTAssertLessThanOrEqual(shown.count, 163 / 2, "rows on the pages")
        XCTAssertLessThanOrEqual(drawn.count, 112, "rows with Advanced open")
        // Each page's Advanced holds what it says.
        for page in SettingsPanel.Page.allCases {
            XCTAssertTrue(SettingsIndex.advanced(of: page).allSatisfy { $0.advanced && $0.page == page && $0.within == nil })
            for group in SettingsIndex.groups(of: page) {
                XCTAssertTrue(SettingsIndex.items(in: group.id).allSatisfy { !$0.advanced && $0.within == nil })
            }
        }
    }

    /// A line of a row that holds several: its row is real, drawn, wide, on
    /// the same page and as advanced; and the find field still finds the line.
    func testLinesSitInARealRow() {
        let lined = SettingsIndex.items.filter { $0.within != nil }
        XCTAssertFalse(lined.isEmpty)
        for line in lined {
            let row = SettingsIndex.item(line.within!)
            XCTAssertNotNil(row, line.id)
            XCTAssertEqual(row?.kind, .wide, line.id)
            XCTAssertEqual(row?.page, line.page, line.id)
            XCTAssertEqual(row?.advanced, line.advanced, line.id)
            XCTAssertNil(row?.within, line.id)
            XCTAssertFalse(line.findOnly, line.id)
            // By the words of its title (a key's symbol alone isn't a word).
            let words = line.title.split(separator: " ").filter { $0.allSatisfy { $0.isLetter || $0 == "'" } }.joined(separator: " ")
            XCTAssertTrue(SettingsIndex.find(words).contains { $0.id == line.id }, line.id)
        }
        // Every row of lines has some.
        for row in SettingsIndex.drawn where row.keys.isEmpty && row.kind == .wide && row.advanced {
            XCTAssertFalse(SettingsIndex.lines(of: row.id).isEmpty, row.id)
        }
    }

    /// The switches taken out are gone from the pages but the find field
    /// still says they are always there, or finds them in their menu.
    func testRetiredSwitchesAreFoundAsAlwaysOn() {
        for id in ["sidebar.player", "tabs.undoReopens", "meet.pip", "video.keys", "pins.keep", "commandbar",
                   "updates.notice", "newtab.recent", "sidebar.narrowIcons"] {
            let item = SettingsIndex.item(id)
            XCTAssertEqual(item?.kind, .note, id)
            XCTAssertEqual(item?.findOnly, true, id)
            XCTAssertTrue(SettingsIndex.find(item?.title ?? "").contains { $0.id == id }, id)
        }
        for id in ["tabs.reading", "tabs.give", "reader.twins", "field.hidesPage", "tabs.clickAddressOnly", "pages.bounce"] {
            XCTAssertNil(SettingsIndex.item(id), id)
        }
        XCTAssertTrue(SettingsIndex.find("export spaces").contains { $0.id == "general.exportSpaces" })
    }

    /// Home background: Off, Solid colour, Gradient and Image. A wall or the
    /// stickers left by an earlier build reads as Off, and its line stays.
    func testRetiredHomeThemesReadAsOff() {
        XCTAssertEqual(HomeTheme.Family.allCases.map(\.title), ["Off", "Solid colour", "Gradient", "Image"])
        for name in ["openRoad", "monsoonForest", "stickers"] {
            XCTAssertEqual(HomeTheme.stored(name), .off, name)
        }
        XCTAssertEqual(HomeTheme.stored("gradient"), .gradient)
        XCTAssertNil(HomeTheme.stored("not-a-theme"))
        let keys = ["home.theme", "home.shuffle", "home.tuning"]
        let saved = keys.map { ($0, Store.settings.object(forKey: $0)) }
        defer { for (key, value) in saved { Store.settings.set(value, forKey: key) } }
        Store.settings.set("stickers", forKey: "home.theme")
        Store.settings.set(true, forKey: "home.shuffle")
        Store.settings.set(#"{"pack":"ocean","intensity":0.5}"#, forKey: "home.tuning")
        let prefs = Preferences()
        XCTAssertEqual(prefs.homeTheme, .off)
        XCTAssertFalse(HomeBackground.behind(prefs))
        prefs.reread()
        XCTAssertEqual(prefs.homeTheme, .off)
        XCTAssertEqual(Store.settings.string(forKey: "home.theme"), "stickers", "the line is left as it was")
        XCTAssertEqual(Store.settings.object(forKey: "home.shuffle") as? Bool, true)
        XCTAssertEqual(prefs.homeTuning.pack, .ocean, "the pack is still read, so it is written back with the rest")
    }

    func testFindByWords() {
        XCTAssertTrue(SettingsIndex.find("vertical tabs").contains { $0.id == "tabs.layout" })
        XCTAssertTrue(SettingsIndex.find("pip").contains { $0.id == "float.own" })
        XCTAssertTrue(SettingsIndex.find("autoplay").contains { $0.id == "media.click" })
        XCTAssertTrue(SettingsIndex.find("spelling").contains { $0.id == "autocorrect" })
        XCTAssertTrue(SettingsIndex.find("split").contains { $0.id == "note.split" })
        XCTAssertTrue(SettingsIndex.find("shift enter").contains { $0.id == "search.shift" })
        // Under Advanced, or a line of a row of several, still found.
        XCTAssertTrue(SettingsIndex.find("middle button").contains { $0.id == "autoscroll" })
        XCTAssertTrue(SettingsIndex.find("liquid glass").contains { $0.id == "tabs.liquid" })
        XCTAssertTrue(SettingsIndex.find("double click rename").contains { $0.id == "tabs.clickRenames" })
        XCTAssertTrue(SettingsIndex.find("backspace").contains { $0.id == "keys.backspaceBack" })
        XCTAssertTrue(SettingsIndex.find("smooth scrolling").contains { $0.id == "wheel.smooth" && $0.advanced && $0.within == "mouse.habits" })
        XCTAssertTrue(SettingsIndex.find("site tiles").contains { $0.id == "home.tiles" })
        // The loading line: a visible switch on Appearance, found by its words.
        for word in ["loading", "progress", "line", "loading line"] {
            XCTAssertTrue(SettingsIndex.find(word).contains { $0.id == "fold.loadingLine" }, word)
        }
        let line = SettingsIndex.items.first { $0.id == "fold.loadingLine" }
        XCTAssertEqual(line?.page, .appearance)
        XCTAssertEqual(line?.advanced, false, "not buried in Advanced")
        XCTAssertTrue(SettingsIndex.find("advanced").isEmpty == false)
        XCTAssertTrue(SettingsIndex.find("").isEmpty)
        XCTAssertTrue(SettingsIndex.find("zzzz nothing").isEmpty)
    }
}
