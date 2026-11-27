import AppKit
import XCTest
@testable import Search

/// Profiles in one window (OneWindow.swift): what windows.json keeps of a
/// merged window, and the switch in Settings.
@available(macOS 14, *)
@MainActor
final class OneWindowTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testRecordKeepsTheMergedWindow() throws {
        var record = WindowRecord(space: Space.firstID)
        record.merge = UUID()
        record.tucked = true
        let back = try JSONDecoder().decode(WindowRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(back.merge, record.merge)
        XCTAssertEqual(back.tucked, true)
    }

    func testOlderRecordIsAWindowOfItsOwn() throws {
        let old = #"{"id":"\#(UUID().uuidString)","space":"\#(Space.firstID.uuidString)"}"#
        let back = try JSONDecoder().decode(WindowRecord.self, from: Data(old.utf8))
        XCTAssertNil(back.merge)
        XCTAssertNil(back.tucked)
    }

    func testOffByDefaultAndFindable() {
        let saved = Store.settings.object(forKey: "profiles.oneWindow")
        defer { Store.settings.set(saved, forKey: "profiles.oneWindow") }
        Store.settings.removeObject(forKey: "profiles.oneWindow")
        XCTAssertFalse(Preferences().profilesInOneWindow)
        for words in ["profiles in one window", "one window", "single window"] {
            XCTAssertTrue(SettingsIndex.find(words).contains { $0.id == "profiles.oneWindow" }, words)
        }
        XCTAssertEqual(SettingsIndex.item("profiles.oneWindow")?.parent, "profiles")
    }

    /// A profile's window swapped in takes the desktop (macOS Space) you're
    /// on, not the one it was last on: ordered in with .moveToActiveSpace,
    /// which is put back afterwards. Only the flags are checked: nothing is
    /// ordered in here, and a desktop can't be chosen from a test.
    func testSwappedWindowJoinsTheActiveDesktop() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        var during: NSWindow.CollectionBehavior = []
        OneWindow.onActiveSpace(window, after: nil) { during = window.collectionBehavior }
        XCTAssertTrue(during.contains(.moveToActiveSpace))
        XCTAssertTrue(during.contains(.fullScreenPrimary), "full screen still allowed")
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(window.collectionBehavior, [.fullScreenPrimary], "only for the order-in")

        // A window on every desktop can't also be moved: those flags go while it does.
        let joining = OneWindow.joiningActiveSpace([.canJoinAllSpaces, .stationary, .fullScreenAuxiliary])
        XCTAssertEqual(joining, [.moveToActiveSpace, .fullScreenAuxiliary])

        // The window it replaces isn't on the desktop you're on (never shown
        // here): nothing is moved.
        let elsewhere = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                 styleMask: [.titled], backing: .buffered, defer: true)
        elsewhere.isReleasedWhenClosed = false
        XCTAssertFalse(elsewhere.isOnActiveSpace)
        OneWindow.onActiveSpace(window, after: elsewhere) { during = window.collectionBehavior }
        XCTAssertEqual(during, [.fullScreenPrimary])
    }
}
