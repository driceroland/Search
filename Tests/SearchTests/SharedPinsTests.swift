import Combine
import XCTest
@testable import Search

/// Pins every space shows (Pins.shared): moving a pin in and out of them,
/// a row's order, and pins.json with and without them. In memory only.
final class SharedPinsTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private func def(_ letter: String, listed: Bool? = nil) -> PinDef {
        PinDef(id: UUID(), letter: letter, home: "https://\(letter.lowercased()).example/",
               title: letter, name: nil, listed: listed)
    }

    func testSharingMovesAPinToTheEndOfTheSharedOnes() {
        let a = def("A"), b = def("B"), m = def("M")
        let moved = Pins.share(a.id, own: [a, b], shared: [m])
        XCTAssertEqual(moved.own, [b])
        XCTAssertEqual(moved.shared, [m, a])
    }

    func testUnsharingMovesAPinToTheStartOfTheSpacesOwn() {
        let a = def("A"), m = def("M"), n = def("N")
        let moved = Pins.unshare(m.id, own: [a], shared: [m, n])
        XCTAssertEqual(moved.own, [m, a])
        XCTAssertEqual(moved.shared, [n])
    }

    func testAnUnknownPinChangesNothing() {
        let a = def("A"), m = def("M")
        XCTAssertEqual(Pins.share(UUID(), own: [a], shared: [m]).own, [a])
        XCTAssertEqual(Pins.share(UUID(), own: [a], shared: [m]).shared, [m])
        XCTAssertEqual(Pins.unshare(UUID(), own: [a], shared: [m]).own, [a])
        XCTAssertEqual(Pins.unshare(UUID(), own: [a], shared: [m]).shared, [m])
    }

    func testSplittingARowKeepsEachListInRowOrder() {
        // A shared pin dragged among the space's own is still a shared one,
        // in the order the shared ones had in the row.
        let a = def("A"), m = def("M"), b = def("B"), n = def("N")
        let parts = Pins.split([a, m, b, n], shared: [m.id, n.id])
        XCTAssertEqual(parts.own, [a, b])
        XCTAssertEqual(parts.shared, [m, n])
    }

    func testARowIsTheSharedPinsThenTheSpacesOwn() {
        let a = def("A"), m = def("M")
        XCTAssertEqual(Pins.row(own: [a], shared: [m], showing: true), [m, a])
    }

    func testWithSharedPinsHiddenARowIsTheSpacesOwn() {
        let a = def("A"), m = def("M")
        XCTAssertEqual(Pins.row(own: [a], shared: [m], showing: false), [a])
    }

    func testARowWithItsSharedPinsSaysWhatTheyAre() {
        let m = def("M"), n = def("N")
        XCTAssertEqual(Pins.sharedToWrite([n, m], showing: true), [n, m])
    }

    func testARowNotYetGivenTheSharedPinsCannotWipeThem() {
        // The switch just turned on, the row not rebuilt yet: it holds no
        // shared pin, and must not write an empty list over the real one.
        XCTAssertNil(Pins.sharedToWrite([], showing: true))
    }

    func testWithSharedPinsHiddenARowSaysNothingAboutThem() {
        XCTAssertNil(Pins.sharedToWrite([def("M")], showing: false))
    }

    func testAFileWithSharedPinsReadsBothLists() throws {
        let space = UUID()
        let json = """
        {"\(space.uuidString)": [{"id": "\(UUID().uuidString)", "letter": "A", "home": "https://a.example/", "title": "A"}],
         "shared": [{"id": "\(UUID().uuidString)", "letter": "M", "home": "https://m.example/", "title": "M"}]}
        """
        let read = try XCTUnwrap(Pins.decode(Data(json.utf8)))
        XCTAssertEqual(read.bySpace[space]?.map(\.letter), ["A"])
        XCTAssertEqual(read.shared.map(\.letter), ["M"])
        XCTAssertEqual(read.bySpace.count, 1)
    }

    func testAFileFromBeforeHasNoSharedPins() throws {
        let space = UUID()
        let json = #"{"\#(space.uuidString)": [{"id": "\#(UUID().uuidString)", "letter": "A", "home": "https://a.example/", "title": "A"}]}"#
        let read = try XCTUnwrap(Pins.decode(Data(json.utf8)))
        XCTAssertEqual(read.shared, [])
        XCTAssertEqual(read.bySpace[space]?.count, 1)
    }

    func testWritingAndReadingBackKeepsBothLists() throws {
        let space = UUID(), a = def("A", listed: true), m = def("M")
        let data = try XCTUnwrap(Pins.encode(bySpace: [space: [a]], shared: [m]))
        let read = try XCTUnwrap(Pins.decode(data))
        XCTAssertEqual(read.bySpace[space], [a])
        XCTAssertEqual(read.shared, [m])
    }

    func testNoSharedPinsWritesNoSharedKey() throws {
        // Someone who never turns the switch on keeps the file they had.
        let data = try XCTUnwrap(Pins.encode(bySpace: [UUID(): [def("A")]], shared: []))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertFalse(keys.contains("shared"))
    }
}

/// Settings › Spaces & Pins › Advanced › Use the same tab across spaces,
/// without a window: which space's tab holds a shared pin's page, what a row
/// keeps in front when a tab of it is exchanged, which tab a space is drawn
/// with on its way in, and where a space with no session of its own opens
/// with the setting off and on. A page playing through a switch, in a window,
/// is SharedPinReuseTests'.
@MainActor
final class SharedPinLandingTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "shared-pin-landing-\(getpid())", 1)
        super.setUp()
    }

    private let home = URL(string: "about:blank#shared")!

    func testSeparateSpaceKeepsItsTabEvenWithAnIdenticalWebKitStore() async throws {
        try await withSharedPin(reuse: true) { browser, source in
            let first = browser.spaceID
            let separate = addSpace("Separate", to: browser, sharesSignIns: false)
            _ = source.web

            // An extension can supply the same WebKit store in either space.
            let other = Tab(configuration: Web.configuration(store: source.store))
            browser.prepare(other)
            other.setAddressOptimistically(home)
            other.pin = source.pin
            other.pinID = source.pinID
            other.home = home
            other.everywhere = true
            XCTAssertTrue(source.store === other.store)
            browser.parked[separate.id] = Parked(tabs: [other], active: other.id)
            browser.showAhead(separate.id)
            XCTAssertTrue(browser.pageAhead === other)
            browser.switchSpace(to: separate.id)
            XCTAssertTrue(browser.active === other)
            browser.switchSpace(to: first)
            XCTAssertTrue(browser.active === source)
        }
    }

    /// A page of the pin opened in a parked row while the space that holds
    /// the pin has it asleep — an extension's tabs.update, a script — is the
    /// one kept: the page that is running isn't put down for one that isn't.
    func testOpenPageIsNotGivenUpForASleepingOne() async throws {
        try await withSharedPin(reuse: true) { browser, pin in
            let first = browser.spaceID
            let second = addSpace("Second", to: browser)
            pin.rest()
            XCTAssertNil(pin.built)

            browser.parked[second.id] = browser.loadRow(second.id)
            let theirs = try XCTUnwrap(browser.parked[second.id]?.tabs.first { $0.pinID == pin.pinID })
            XCTAssertFalse(theirs === pin)
            theirs.wake()
            XCTAssertNotNil(theirs.built)

            browser.switchSpace(to: second.id)
            let there = try XCTUnwrap(browser.tabs.first { $0.pinID == pin.pinID })
            XCTAssertTrue(there === theirs, "The second space keeps the page it has open")
            XCTAssertNotNil(theirs.built, "…still open")
            XCTAssertNil(pin.built)

            // That page is the pin's from here on, and goes back with you.
            browser.switchSpace(to: first)
            let back = try XCTUnwrap(browser.tabs.first { $0.pinID == pin.pinID })
            XCTAssertTrue(back === theirs, "The open page follows to the first space")
            XCTAssertNotNil(theirs.built)
        }
    }

    /// A space passing during a swipe is drawn before it is taken, from its
    /// parked row: the pin there is the page that will come in with it, in
    /// front if the row's own tab for it was. Drawn as parked, it was the
    /// tab standing in for it, asleep, which a pin's square draws dimmed and
    /// with no count (Tab.unread), until the space landed.
    func testARowPassingIsDrawnWithThePageThatComesWithIt() async throws {
        try await withSharedPin(reuse: true) { browser, pin in
            let first = browser.spaceID
            let second = addSpace("Second", to: browser)
            _ = pin.web
            XCTAssertNotNil(pin.built)
            browser.parked[second.id] = browser.loadRow(second.id)
            let theirs = try XCTUnwrap(browser.parked[second.id]?.tabs.first { $0.pinID == pin.pinID })
            XCTAssertFalse(theirs === pin)
            XCTAssertTrue(theirs.asleep, "The second space's own tab for the pin holds no page")
            XCTAssertFalse(pin.asleep)
            browser.parked[second.id]?.active = theirs.id
            let owner = browser.sharedPinOwner

            let drawn = browser.arrivingRow(second.id)
            let square = try XCTUnwrap(drawn.tabs.first { $0.pinID == pin.pinID })
            XCTAssertTrue(square === pin, "The open page is the one drawn")
            XCTAssertFalse(square.asleep, "…awake, so at full strength and with its count")
            XCTAssertFalse(drawn.tabs.contains { $0 === theirs }, "…and not the tab standing in for it")
            XCTAssertEqual(drawn.active, pin.id, "…in front, as the row's own tab for the pin was")

            // Only drawn: the rows keep their tabs until the space is taken.
            XCTAssertEqual(browser.parked[second.id]?.tabs.contains { $0 === theirs }, true, "The row still has its own tab")
            XCTAssertEqual(browser.parked[second.id]?.active, theirs.id)
            XCTAssertTrue(theirs.asleep, "Nothing is woken for the drawing")
            XCTAssertTrue(browser.tabs.contains { $0 === pin }, "The page stays with the space on screen")
            XCTAssertEqual(browser.sharedPinOwner, owner)

            // Taken, the space left behind is drawn the same way.
            browser.switchSpace(to: second.id)
            XCTAssertTrue(browser.active === pin)
            XCTAssertEqual(browser.parked[first]?.tabs.contains { $0 === theirs }, true, "The tabs changed rows")
            let behind = browser.arrivingRow(first)
            XCTAssertTrue(behind.tabs.contains { $0 === pin }, "The first space is drawn with the open page too")
            XCTAssertFalse(behind.tabs.contains { $0 === theirs })
            XCTAssertEqual(behind.active, pin.id, "…in front there as it was left")
        }
    }

    func testARowPassingIsDrawnAsParkedWithTheSettingOff() async throws {
        try await withSharedPin(reuse: false) { browser, pin in
            let second = addSpace("Second", to: browser)
            _ = pin.web
            browser.parked[second.id] = browser.loadRow(second.id)
            let theirs = try XCTUnwrap(browser.parked[second.id]?.tabs.first { $0.pinID == pin.pinID })
            let drawn = browser.arrivingRow(second.id)
            XCTAssertTrue(drawn.tabs.contains { $0 === theirs }, "Each space keeps its own tab for the pin")
            XCTAssertFalse(drawn.tabs.contains { $0 === pin }, "…and is drawn with it")
        }
    }

    func testASpaceWithItsOwnSignInsIsDrawnWithItsOwnTab() async throws {
        try await withSharedPin(reuse: true) { browser, pin in
            let separate = addSpace("Separate", to: browser, sharesSignIns: false)
            _ = pin.web
            browser.parked[separate.id] = browser.loadRow(separate.id)
            let theirs = try XCTUnwrap(browser.parked[separate.id]?.tabs.first { $0.pinID == pin.pinID })
            let drawn = browser.arrivingRow(separate.id)
            XCTAssertTrue(drawn.tabs.contains { $0 === theirs }, "A space with its own sign-ins has its own page")
            XCTAssertFalse(drawn.tabs.contains { $0 === pin }, "…and another space's is not drawn in it")
        }
    }

    /// From a space with its own sign-ins, the pages are in a parked row. In
    /// memory, its page is the one drawn; not in memory, it has none open,
    /// and drawing never reads a row from its file.
    func testDrawingARowReadsNoOtherRowFromItsFile() async throws {
        try await withSharedPin(reuse: true) { browser, pin in
            let first = browser.spaceID
            let separate = addSpace("Separate", to: browser, sharesSignIns: false)
            let second = addSpace("Second", to: browser)
            _ = pin.web
            browser.switchSpace(to: separate.id)
            XCTAssertEqual(browser.sharedPinOwner, first)
            browser.parked[second.id] = browser.loadRow(second.id)
            let theirs = try XCTUnwrap(browser.parked[second.id]?.tabs.first { $0.pinID == pin.pinID })
            XCTAssertTrue(browser.arrivingRow(second.id).tabs.contains { $0 === pin }, "From the parked row that holds it")

            let kept = browser.parked.removeValue(forKey: first)
            defer { browser.parked[first] = kept }
            XCTAssertTrue(browser.arrivingRow(second.id).tabs.contains { $0 === theirs }, "With that row in its file, as parked")
            XCTAssertNil(browser.parked[first], "The row that holds the pages stays in its file")
        }
    }

    func testReplacingARowsTabKeepsItsSelectionAndItsPair() {
        let (pin, loose, live) = (Tab(), Tab(), Tab())
        defer { [pin, loose, live].forEach { $0.close() } }

        // In front, and in a pair: the tab taking its place is both.
        var row = Parked(tabs: [pin, loose], active: pin.id, splits: [TabSplit(left: pin.id, right: loose.id)])
        row.replaceTab(at: 0, with: live)
        XCTAssertTrue(row.tabs[0] === live)
        XCTAssertTrue(row.tabs[1] === loose)
        XCTAssertEqual(row.active, live.id)
        XCTAssertEqual(row.splits.first?.tabs, [live.id, loose.id])
        XCTAssertFalse(row.inferredSelection)

        // Another tab in front stays in front.
        var behind = Parked(tabs: [pin, loose], active: loose.id)
        behind.replaceTab(at: 0, with: live)
        XCTAssertEqual(behind.active, loose.id)
        XCTAssertTrue(behind.splits.isEmpty)

        // A selection nobody made is still nobody's after the exchange,
        // until somebody makes one.
        var unvisited = Parked(tabs: [pin], active: nil)
        unvisited.setEmptySessionSelection(reusingPins: false)
        XCTAssertEqual(unvisited.active, pin.id)
        unvisited.replaceTab(at: 0, with: live)
        XCTAssertEqual(unvisited.active, live.id)
        XCTAssertTrue(unvisited.inferredSelection)
        unvisited.active = live.id
        XCTAssertFalse(unvisited.inferredSelection)
    }

    // A space with no session of its own, only the pins every space shows.
    // Before the setting, one whose row was read ahead of the visit opened
    // on its first pin, and one entered cold on a blank tab: both stay so
    // with the setting off. With it on, a blank tab either way.

    func testAnEmptySpaceEnteredColdOpensOnABlankTab() async throws {
        for reuse in [false, true] {
            try await withSharedPin(reuse: reuse) { browser, _ in
                let front = await landing(in: browser)
                XCTAssertEqual(front?.isBlank, true, "with the setting \(reuse ? "on" : "off")")
            }
        }
    }

    func testAPreloadedEmptySpaceOpensOnItsFirstPinWithTheSettingOff() async throws {
        try await withSharedPin(reuse: false) { browser, pin in
            let front = await landing(in: browser, preloadedWith: false)
            XCTAssertNotNil(pin.pinID)
            XCTAssertEqual(front?.pinID, pin.pinID)
        }
    }

    func testAPreloadedEmptySpaceOpensOnABlankTabWithTheSettingOn() async throws {
        try await withSharedPin(reuse: true) { browser, _ in
            let front = await landing(in: browser, preloadedWith: true)
            XCTAssertEqual(front?.isBlank, true)
        }
    }

    func testAnEmptySpacePreloadedBeforeTheSettingChangedFollowsIt() async throws {
        try await withSharedPin(reuse: false) { browser, pin in
            let front = await landing(in: browser, preloadedWith: true)
            XCTAssertNotNil(pin.pinID)
            XCTAssertEqual(front?.pinID, pin.pinID, "read with the setting on, entered with it off")
        }
        try await withSharedPin(reuse: true) { browser, _ in
            let front = await landing(in: browser, preloadedWith: false)
            XCTAssertEqual(front?.isBlank, true, "read with the setting off, entered with it on")
        }
    }

    /// A window with Spaces on and, in front in its first space, a pin every
    /// space shows, for `body`. `reuse` is the setting. Its rows are written
    /// nowhere, and its pin and the spaces added to it are gone afterwards.
    private func withSharedPin(reuse: Bool, _ body: (Browser, Tab) async throws -> Void) async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let prefs = browser.prefs
        let saved = (prefs.usesSpaces, prefs.pinsSameTab)
        prefs.usesSpaces = true
        prefs.pinsSameTab = reuse
        let first = browser.spaceID
        let spaces = Set(browser.spaces.map(\.id))
        let pin = try XCTUnwrap(browser.active)
        pin.setAddressOptimistically(home)
        browser.pin(pin)
        browser.shareEverywhere(pin)
        defer {
            browser.switchSpace(to: first)
            for tab in browser.tabs where tab.everywhere { browser.unpin(tab) }
            browser.closeAll()
            for space in browser.spaces where !spaces.contains(space.id) { Spaces.known[space.id] = nil }
            (prefs.usesSpaces, prefs.pinsSameTab) = saved
        }
        try await body(browser, pin)
    }

    /// One more space for the window, signed in with its first unless told
    /// otherwise (withSharedPin forgets it again).
    private func addSpace(_ name: String, to browser: Browser, sharesSignIns: Bool = true) -> Space {
        let space = Space(id: UUID(), name: name, colour: 1, sharesSignIns: sharesSignIns)
        Spaces.known[space.id] = space
        browser.spaces.append(space)
        return space
    }

    /// The tab in front at the first visit to a space with no session of its
    /// own. `preloadedWith`: its row read ahead of the visit, as the window
    /// reads the rows of spaces not yet gone to, with the setting as given at
    /// that moment and as withSharedPin has it by the time of the visit.
    private func landing(in browser: Browser, preloadedWith setting: Bool? = nil) async -> Tab? {
        let prefs = browser.prefs
        let reuse = prefs.pinsSameTab
        let first = browser.spaceID
        let space = addSpace("Empty", to: browser)
        if let setting {
            prefs.pinsSameTab = setting
            browser.parked[space.id] = browser.loadRow(space.id)
            if setting != reuse {
                // The window hears of the change on the run loop's next
                // turn, and this, which began listening after it, right
                // behind: once this has heard, it has.
                let heard = expectation(description: "the setting's change reached the window")
                let listening = prefs.$pinsSameTab.dropFirst().receive(on: RunLoop.main)
                    .sink { _ in heard.fulfill() }
                prefs.pinsSameTab = reuse
                await fulfillment(of: [heard], timeout: 5)
                listening.cancel()
            }
        }
        browser.switchSpace(to: space.id)
        let front = browser.active
        browser.switchSpace(to: first)
        return front
    }
}
