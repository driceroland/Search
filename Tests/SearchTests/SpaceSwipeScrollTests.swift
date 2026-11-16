import AppKit
import SwiftUI
import XCTest
@testable import Search

@MainActor
final class SpaceSwipeScrollTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "space-swipe-scroll-\(getpid())", 1)
        super.setUp()
    }

    func testOutgoingColumnKeepsItsScrollPositionDuringSwipe() async throws {
        try await checkSwipe(roomy: false, count: 60)
    }

    func testRoomyFolderRowsKeepTheirSpacingOnLanding() async throws {
        try await checkSwipe(roomy: true, count: 60)
    }

    func testShortFolderListKeepsItsSpacingOnLanding() async throws {
        try await checkSwipe(roomy: false, count: 12)
    }

    func testCollapsedFoldersKeepTheirSpacingOnLanding() async throws {
        try await checkSwipe(roomy: false, count: 60, folded: true)
    }

    private func checkSwipe(roomy: Bool, count: Int, folded: Bool = false) async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        defer { NSApp.setActivationPolicy(policy) }
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let old = (prefs.sidebar, prefs.usesSpaces, prefs.sideHides, prefs.usesTabGroups, prefs.roomyTabs)
        defer { (prefs.sidebar, prefs.usesSpaces, prefs.sideHides, prefs.usesTabGroups, prefs.roomyTabs) = old }
        prefs.sidebar = true
        prefs.usesSpaces = true
        prefs.sideHides = false
        prefs.usesTabGroups = true
        prefs.roomyTabs = roomy
        browser.folded = false
        browser.welcoming = false
        let first = Space.first()
        let second = Space(id: UUID(), name: "Two", colour: 0)
        browser.spaces = [first, second]
        browser.spaceID = first.id
        for index in 0..<60 {
            browser.newTab()
            let tab = try XCTUnwrap(browser.tabs.last)
            tab.restore(url: URL(string: "about:blank#outgoing-\(index)")!, title: "Tab \(index)")
        }
        browser.activeID = browser.tabs.first?.id
        let incoming = (0..<count).map { index in
            let tab = Search.Tab()
            tab.restore(url: URL(string: "about:blank#incoming-\(index)")!, title: "Incoming \(index)")
            return tab
        }
        let groups = (0..<(folded ? 6 : 4)).map { index in
            TabGroup(id: UUID(), name: "Folder \(index)", collapsed: folded || index % 2 == 0)
        }
        for index in 0..<(groups.count * 3) { incoming[index].groupID = groups[index / 3].id }
        browser.parked[second.id] = Parked(tabs: incoming, active: incoming.last?.id, groups: groups)
        let host = NSHostingView(rootView: ContentView(browser: browser))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        browser.window = window
        defer { window.contentView = nil; window.close(); browser.closeAll() }
        func settle() async throws {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
        }
        func scroll(in view: NSView) -> NSScrollView? {
            if let found = view as? NSScrollView, found.frame.width <= prefs.columnWidth + 1,
               found.frame.height > 60 { return found }
            return view.subviews.lazy.compactMap { scroll(in: $0) }.first
        }
        try await settle()
        let initial = try XCTUnwrap(scroll(in: host))
        let document = try XCTUnwrap(initial.documentView)
        let bottom = document.bounds.height - initial.contentView.bounds.height
        XCTAssertGreaterThan(bottom, 500)
        initial.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        initial.reflectScrolledClipView(initial.contentView)
        try await settle()
        let held = initial.contentView.bounds.minY
        XCTAssertGreaterThan(held, 500)
        for distance: CGFloat in [-15, -45, -90, -30, 0, 15, 0] {
            browser.spaceSwipe = distance
            try await settle()
            let current = try XCTUnwrap(scroll(in: host))
            XCTAssertTrue(current === initial, "The outgoing scroll view was replaced")
            if distance != 0 {
                // Model the native clip adjustment during a live trackpad
                // gesture, which moving the SwiftUI view alone doesn't cause.
                current.contentView.scroll(to: .zero)
                current.reflectScrolledClipView(current.contentView)
                try await settle()
            }
            XCTAssertEqual(current.contentView.bounds.minY, held, accuracy: 1,
                           "The outgoing list moved vertically at swipe offset \(distance)")
        }
        initial.contentView.scroll(to: .zero)
        initial.reflectScrolledClipView(initial.contentView)
        try await settle()
        XCTAssertEqual(initial.contentView.bounds.minY, 0, accuracy: 1,
                       "Normal scrolling must resume after a cancelled swipe")

        browser.spaceSwipe = -prefs.columnWidth
        try await settle()
        let previewFrames = SideBar.groupRowFrames[true] ?? [:]
        let expanded = incoming.filter { tab in
            groups.contains { !$0.collapsed && $0.id == tab.groupID }
        }
        XCTAssertEqual(expanded.count, folded ? 0 : 6)
        for tab in expanded { XCTAssertNotNil(previewFrames[tab.id]) }
        SpaceSwipe.shared.slide(browser, to: 1, from: 0)
        try await Task.sleep(for: .milliseconds(900))
        try await settle()
        XCTAssertEqual(browser.spaceID, second.id)
        XCTAssertEqual(browser.activeID, incoming.last?.id, "The selected tab is unchanged")
        if count > 12 {
            let landed = try XCTUnwrap(scroll(in: host))
            XCTAssertEqual(landed.contentView.bounds.minY, 0, accuracy: 1,
                           "Landing must keep the preview's top instead of jumping to the selected tab")
        }
        let liveFrames = SideBar.groupRowFrames[false] ?? [:]
        for id in expanded.map(\.id) + groups.map(\.id) {
            let preview = try XCTUnwrap(previewFrames[id])
            let live = try XCTUnwrap(liveFrames[id])
            XCTAssertEqual(live.minY, preview.minY, accuracy: 0.5, "Folder tab moved on landing")
            XCTAssertEqual(live.height, preview.height, accuracy: 0.5, "Folder row height changed on landing")
            for frame in SideBar.groupRowSamples[id] ?? [] {
                XCTAssertEqual(frame.minY, preview.minY, accuracy: 0.5, "Folder moved during handoff")
                XCTAssertEqual(frame.height, preview.height, accuracy: 0.5, "Folder changed height during handoff")
            }
        }
        browser.select(incoming[incoming.count - 2])
        try await settle()
        if count > 12 {
            XCTAssertGreaterThan(try XCTUnwrap(scroll(in: host)).contentView.bounds.minY, 500,
                                 "Selecting a tab within the landed space must still reveal it")
        }
    }
}
