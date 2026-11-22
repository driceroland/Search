import XCTest
@testable import Search

/// Sync with iCloud and Handoff on for a new install, left as they were for
/// one from before (SyncDefault.swift), and nothing started before the
/// welcome is left. Each case in a settings suite of its own, removed
/// afterwards; CloudKit never runs (ICloudSyncTests' stand-ins).
@MainActor
final class SyncDefaultTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private var suite = ""
    private var store: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "com.officecommun.search.test.sync-default-\(getpid())-\(UUID().uuidString)"
        store = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suite)
        store = nil
        super.tearDown()
    }

    private func sync(available: Bool = true, engine given: ICloudSyncTests.FakeEngine? = nil) -> ICloudSync {
        let engine = given ?? ICloudSyncTests.FakeEngine()
        let sync = ICloudSync(local: ICloudSyncTests.FakeMac(), defaults: store, file: nil, available: available) { owner, _ in
            engine.sync = owner
            return engine
        }
        engine.sync = sync
        return sync
    }

    /// Where the welcome's switches start at this launch.
    private func starts(ranBefore: Bool = false) -> (sync: Bool, handoff: Bool) {
        SyncDefault.settle(store, ranBefore: ranBefore)
        return SyncDefault.starts(new: SyncDefault.isNew(store), welcomed: store.bool(forKey: "welcomed"),
                                  syncOn: store.bool(forKey: ICloudSync.onKey), handoffOn: store.bool(forKey: "handoff"))
    }

    // MARK: - new or not

    func testAFreshInstallStartsWithBothOn() {
        XCTAssertTrue(starts() == (true, true))
        XCTAssertEqual(store.string(forKey: SyncDefault.key), SyncDefault.new)
        // Nothing is on yet: only the welcome's switches are.
        XCTAssertNil(store.object(forKey: ICloudSync.onKey))
        XCTAssertNil(store.object(forKey: "handoff"))
    }

    func testAFreshInstallQuitDuringTheWelcomeIsStillNewAtItsNextLaunch() {
        _ = starts()
        // What the first launch leaves behind before the welcome is left.
        store.set(true, forKey: "passkeys.for")
        store.set("{{0, 0}, {1200, 800}}", forKey: "NSWindow Frame search")
        XCTAssertTrue(starts(ranBefore: true) == (true, true))
    }

    func testOnceWelcomedTheSwitchesStartAsTheyAre() {
        _ = starts()
        store.set(true, forKey: "welcomed")
        store.set(false, forKey: "handoff")
        XCTAssertTrue(starts(ranBefore: true) == (false, false))
    }

    func testAnInstallFromBeforeIsExistingByAnyTrace() {
        for trace in SyncDefault.traces {
            store.removePersistentDomain(forName: suite)
            store.set(trace == "glyph" ? "letters" as Any : true as Any, forKey: trace)
            SyncDefault.settle(store, ranBefore: false)
            XCTAssertEqual(store.string(forKey: SyncDefault.key), SyncDefault.existing, trace)
        }
    }

    func testAnInstallFromBeforeIsExistingByItsFolderAlone() {
        SyncDefault.settle(store, ranBefore: true)
        XCTAssertFalse(SyncDefault.isNew(store))
    }

    func testSettledOnceAndForAll() {
        store.set(true, forKey: "passkeys.for")
        SyncDefault.settle(store, ranBefore: false)
        store.removeObject(forKey: "passkeys.for")
        SyncDefault.settle(store, ranBefore: false)
        XCTAssertFalse(SyncDefault.isNew(store))
    }

    // MARK: - existing users keep what they had

    func testExistingWithSyncOffStaysOff() {
        store.set(true, forKey: "welcomed")
        store.set(true, forKey: "passkeys.for")
        XCTAssertTrue(starts(ranBefore: true) == (false, false))
        let icloud = sync()
        XCTAssertFalse(icloud.on)
        XCTAssertFalse(icloud.isScheduled)
        XCTAssertNil(store.object(forKey: ICloudSync.onKey))
        // The welcome opened again from the menu and left as it started.
        let prefs = Shared.prefs
        let handoff = prefs.handoff
        defer { prefs.handoff = handoff }
        prefs.handoff = false
        SyncDefault.welcomeLeft(sync: false, handoff: false, prefs: prefs, icloud: icloud)
        XCTAssertFalse(icloud.on)
        XCTAssertFalse(prefs.handoff)
    }

    func testExistingWithSyncOnStaysOn() {
        store.set(true, forKey: "welcomed")
        store.set(true, forKey: ICloudSync.onKey)
        store.set(true, forKey: "handoff")
        XCTAssertTrue(starts(ranBefore: true) == (true, true))
        XCTAssertFalse(SyncDefault.isNew(store))
        let icloud = sync()
        XCTAssertTrue(icloud.on)
        XCTAssertEqual(store.object(forKey: ICloudSync.onKey) as? Bool, true)
    }

    // MARK: - nothing before the welcome is left

    func testNothingStartsUntilTheWelcomeIsLeft() {
        _ = starts()
        let engine = ICloudSyncTests.FakeEngine()
        let icloud = sync(engine: engine)
        // The welcome is up, its switches on: nothing runs, nothing is kept.
        XCTAssertFalse(icloud.on)
        XCTAssertFalse(icloud.isScheduled)
        XCTAssertTrue(engine.saved.isEmpty && engine.fetches == 0)

        let prefs = Shared.prefs
        let handoff = prefs.handoff
        defer { prefs.handoff = handoff; icloud.turnOff() }
        prefs.handoff = false
        SyncDefault.welcomeLeft(sync: true, handoff: true, prefs: prefs, icloud: icloud)
        XCTAssertTrue(icloud.on)
        XCTAssertTrue(icloud.isScheduled)
        XCTAssertEqual(store.object(forKey: ICloudSync.onKey) as? Bool, true)
        XCTAssertTrue(prefs.handoff)
    }

    func testBothTurnedOffInTheWelcomeStayOff() {
        _ = starts()
        let icloud = sync()
        let prefs = Shared.prefs
        let handoff = prefs.handoff
        defer { prefs.handoff = handoff }
        prefs.handoff = false
        SyncDefault.welcomeLeft(sync: false, handoff: false, prefs: prefs, icloud: icloud)
        XCTAssertFalse(icloud.on)
        XCTAssertFalse(icloud.isScheduled)
        XCTAssertNil(store.object(forKey: ICloudSync.onKey))
        XCTAssertFalse(prefs.handoff)
    }

    // MARK: - without iCloud: waits, quietly

    func testWithoutICloudInThisBuildTheChoiceWaits() {
        let icloud = sync(available: false)
        icloud.turnOnOrWait()
        XCTAssertTrue(icloud.on)
        XCTAssertFalse(icloud.isScheduled)
        XCTAssertNil(icloud.engine)
        XCTAssertNil(icloud.problem)
        XCTAssertTrue(["Needs a build of Search signed for iCloud", "Off in a test run"]
            .contains(icloud.summary(folderSyncOn: false, otherwise: "off")))
        // And it can be turned off again.
        icloud.turnOff()
        XCTAssertFalse(icloud.on)
        XCTAssertNil(store.object(forKey: ICloudSync.onKey))
    }

    func testSignedOutWaitsWithoutAnError() async {
        let engine = ICloudSyncTests.FakeEngine()
        engine.state = .signedOut
        let icloud = sync(engine: engine)
        defer { icloud.turnOff() }
        icloud.turnOnOrWait()
        await icloud.join()
        await icloud.join()
        XCTAssertFalse(icloud.joined)
        XCTAssertNil(icloud.problem)
        XCTAssertEqual(engine.fetches, 0)
        XCTAssertTrue(engine.saved.isEmpty)
        XCTAssertEqual(icloud.summary(folderSyncOn: false, otherwise: "off"), "Not signed in to iCloud: System Settings › Apple Account")
    }

    // MARK: - the What's New card

    func testTheCardOffersSyncFirstThenHandoffWhileTheyAreOff() {
        let prefs = Shared.prefs
        let handoff = prefs.handoff
        defer { prefs.handoff = handoff }
        prefs.handoff = false
        XCTAssertFalse(ICloudSync.shared.on)
        for version in ["1.0.17", "1.0.18"] {
            let rows = WhatsNew.rows(for: WhatsNew.Release(version: version), prefs: prefs)
            let first = (rows.leading + rows.own).map(\.title)
            XCTAssertEqual(Array(first.prefix(2)), ["Sync with iCloud", "Handoff to your iPhone"], version)
            XCTAssertFalse(rows.earlier.map(\.title).contains("Sync with iCloud"), version)
            XCTAssertFalse(rows.earlier.map(\.title).contains("Handoff to your iPhone"), version)
        }
        prefs.handoff = true
        let rows = WhatsNew.rows(for: WhatsNew.Release(version: "1.0.18"), prefs: prefs)
        XCTAssertEqual(rows.leading.map(\.title), ["Sync with iCloud"])
    }

    func testEachSwitchIsOnTheCardOnce() {
        let titles = WhatsNew.toggles.map(\.title)
        XCTAssertEqual(titles.filter { $0 == "Sync with iCloud" }.count, 1)
        XCTAssertEqual(titles.filter { $0 == "Handoff to your iPhone" }.count, 1)
        XCTAssertEqual(Array(WhatsNew.toggles.prefix(2)).map(\.lead), [true, true])
    }
}
