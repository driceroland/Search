import AppKit
import XCTest
@testable import Search

@MainActor
final class MutedTabRestoreTests: XCTestCase {
    override class func setUp() {
        // Store.world is read once. Start the suite in a world of its own;
        // every method below keeps its state in WindowRecord.rows.
        if ProcessInfo.processInfo.environment["SEARCH_PROBE"] == nil {
            setenv("SEARCH_PROBE", "muted-tab-restore-\(getpid())", 1)
        }
        super.setUp()
    }

    func testReopenedTabsKeepMutedAndUnmutedState() throws {
        try withBrowser { browser, tabs in
            tabs[1].toggleMute()
            browser.close(tabs[1])
            browser.reopen()
            let muted = try XCTUnwrap(browser.tabs.first { $0.address == tabs[1].address })
            XCTAssertTrue(muted.muted)

            browser.close(try XCTUnwrap(browser.tabs.first { $0.address == tabs[2].address }))
            browser.reopen()
            let unmuted = try XCTUnwrap(browser.tabs.first { $0.address == tabs[2].address })
            XCTAssertFalse(unmuted.muted)
        }
    }

    func testBatchReopenKeepsEachTabsMute() throws {
        try withBrowser { browser, tabs in
            tabs[1].toggleMute()
            tabs[3].toggleMute()
            let addresses = tabs.compactMap(\.address)
            browser.closeTabsBelow(tabs[0])
            XCTAssertTrue(browser.tabs.count == 1)

            browser.reopen()
            XCTAssertEqual(browser.tabs.compactMap(\.address), addresses)
            let byAddress = Dictionary(uniqueKeysWithValues: zip(addresses, browser.tabs))
            let muted = try XCTUnwrap(byAddress[try XCTUnwrap(tabs[1].address)])
            let unmuted = try XCTUnwrap(byAddress[try XCTUnwrap(tabs[2].address)])
            XCTAssertTrue(muted.muted)
            XCTAssertFalse(unmuted.muted)
            XCTAssertTrue(try XCTUnwrap(byAddress[try XCTUnwrap(tabs[3].address)]).muted)
            XCTAssertTrue(muted.asleep)
            XCTAssertNil(muted.built)
        }
    }

    func testClosedGroupKeepsMutedTabState() throws {
        try withBrowser { browser, tabs in
            browser.prefs.usesTabGroups = true
            tabs[2].toggleMute()
            let group = browser.addTabGroup(containing: tabs[1])
            browser.move(tabs[2], toGroup: group)
            browser.closeTabGroup(group)

            browser.reopen()
            let unmuted = try XCTUnwrap(browser.tabs.first { $0.address == tabs[1].address })
            let muted = try XCTUnwrap(browser.tabs.first { $0.address == tabs[2].address })
            XCTAssertFalse(unmuted.muted)
            XCTAssertTrue(muted.muted)
        }
    }

    func testSessionRestoresMutedTabWhileItIsStillAsleep() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let muted = "https://muted-restore.example/"
        let heard = "https://heard-restore.example/"
        let written = try sessionShape(tabs: [
            ["url": muted, "title": "Muted", "muted": true],
            ["url": heard, "title": "Heard"],
        ], active: 1)
        let browser = makeBrowser()
        defer { browser.closeAll() }
        browser.record.rows[browser.spaceID.uuidString] = written
        let restoredRow = browser.loadRow(browser.spaceID)
        let restored = try XCTUnwrap(restoredRow.tabs.first { $0.address?.absoluteString == muted })
        XCTAssertTrue(restored.muted)
        XCTAssertTrue(restored.asleep)
        XCTAssertNil(restored.built, "restoring the mute must not wake the tab")
        XCTAssertFalse(try XCTUnwrap(restoredRow.tabs.first { $0.address?.absoluteString == heard }).muted)
    }

    func testLegacySessionMuteDefaultsToFalseAndMuteRoundTrips() throws {
        let legacy = try JSONDecoder().decode(
            Session.Entry.self,
            from: JSONSerialization.data(withJSONObject: ["url": "https://legacy.example/", "title": "Legacy"])
        )
        XCTAssertFalse(try encodedMuted([legacy])[0])

        let muted = try JSONDecoder().decode(
            Session.Entry.self,
            from: JSONSerialization.data(withJSONObject: [
                "url": "https://muted-roundtrip.example/", "title": "Muted", "muted": true,
            ])
        )
        XCTAssertEqual(try encodedMuted([muted]), [true])
    }

    func testToggleSavesMuteAndUnmuteClearsItWithoutAnotherAct() throws {
        let browser = Browser(record: nil)
        defer { browser.closeAll() }
        let tab = browser.tabs.first { !$0.isBlank } ?? {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "https://mute-save.example/")!, title: "Mute save")
            return browser.tabs.last!
        }()

        tab.toggleMute()
        waitForSavedMute(browser, address: tab.address, true)
        let savedAfterMute = try savedShape(browser).tabs.map { ($0.url, $0.muted) }
        XCTAssertEqual(try savedMute(browser, address: tab.address), true, "saved row: \(savedAfterMute)")

        tab.toggleMute()
        waitForSavedMute(browser, address: tab.address, false)
        let savedAfterUnmute = try savedShape(browser).tabs.map { ($0.url, $0.muted) }
        XCTAssertEqual(try savedMute(browser, address: tab.address), false, "saved row: \(savedAfterUnmute)")
    }

    /// The mute subscription asks for the session a moment later. None of
    /// these checks after each toggle write one themselves.
    private func waitForSavedMute(_ browser: Browser, address: URL?, _ wanted: Bool) {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if (try? savedMute(browser, address: address)) == wanted { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func withBrowser(_ body: (Browser, [Tab]) throws -> Void) rethrows {
        let browser = makeBrowser()
        let groups = browser.prefs.usesTabGroups
        defer {
            browser.closeAll()
            browser.prefs.usesTabGroups = groups
        }
        browser.prefs.usesTabGroups = false
        try body(browser, browser.tabs)
    }

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.closeAll()
        browser.record.rows = [:]
        browser.parked = [:]
        browser.tabGroups = []
        for number in 1...4 {
            browser.newTab()
            browser.tabs.last?.restore(
                url: URL(string: "https://muted-\(number).example/")!,
                title: "Tab \(number)"
            )
        }
        return browser
    }

    private func savedMute(_ browser: Browser, address: URL?) throws -> Bool? {
        try savedShape(browser).tabs.first { $0.url == address?.absoluteString }?.muted
    }

    private func savedShape(_ browser: Browser) throws -> Session.Shape {
        browser.usesFiles ? Session.read(space: browser.spaceID) : browser.allRows()[browser.spaceID.uuidString]
            ?? Session.Shape(tabs: [], active: 0)
    }

    private func encodedMuted(_ entries: [Session.Entry]) throws -> [Bool] {
        let data = try JSONEncoder().encode(entries)
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return objects.map { $0["muted"] as? Bool ?? false }
    }

    private func sessionShape(tabs: [[String: Any]], active: Int) throws -> Session.Shape {
        let object: [String: Any] = ["tabs": tabs, "active": active]
        return try JSONDecoder().decode(
            Session.Shape.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}
