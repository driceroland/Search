import AppKit
import XCTest
@testable import Search

@MainActor
final class SpaceFloatTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "space-float-\(getpid())", 1)
        super.setUp()
    }

    func testOnlyOneRequestCanFinishAndOldAnswersCannotFinishANewOne() {
        var requests = SpaceFloatRequest()
        let first = requests.begin()!
        XCTAssertNil(requests.begin())
        XCTAssertFalse(requests.finish(UUID()))
        XCTAssertEqual(requests.pending, first)
        XCTAssertTrue(requests.finish(first))
        let second = requests.begin()!
        XCTAssertFalse(requests.finish(first))
        XCTAssertEqual(requests.pending, second)
        XCTAssertTrue(requests.finish(second))
        XCTAssertNil(requests.pending)
    }

    func testSpaceSwitchWithNoVideoAndDisabledFloating() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let oldUsesSpaces = browser.prefs.usesSpaces
        let oldFloatsOnLeave = browser.prefs.floatsOnLeave
        let oldSpaces = browser.spaces
        defer {
            browser.closeAll()
            browser.prefs.usesSpaces = oldUsesSpaces
            browser.prefs.floatsOnLeave = oldFloatsOnLeave
            browser.spaces = oldSpaces
        }
        browser.prefs.usesSpaces = true
        let first = browser.spaceID
        let second = UUID()
        browser.spaces = [Space(id: first, name: "First", colour: 0),
                          Space(id: second, name: "Second", colour: 1)]
        browser.closeAll()
        browser.showRow([], active: nil, blank: true)

        browser.prefs.floatsOnLeave = false
        browser.switchSpace(to: second)
        XCTAssertEqual(browser.spaceID, second)
        XCTAssertNil(browser.spaceFloat.pending)
        XCTAssertNil(browser.floating)
        XCTAssertNil(browser.pictured)

        browser.prefs.floatsOnLeave = true
        browser.switchSpace(to: first)
        XCTAssertEqual(browser.spaceID, first)
        XCTAssertNil(browser.spaceFloat.pending)
        XCTAssertNil(browser.floating)
        XCTAssertNil(browser.pictured)

        let pending = browser.spaceFloat.begin()
        browser.switchSpace(to: first)
        browser.switchSpace(to: UUID())
        XCTAssertEqual(browser.spaceID, first)
        XCTAssertEqual(browser.spaceFloat.pending, pending)
        if let pending { browser.spaceFloat.finish(pending) }
    }
}
