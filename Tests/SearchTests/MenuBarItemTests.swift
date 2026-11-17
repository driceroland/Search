import XCTest
@testable import Search

@MainActor
final class MenuBarItemTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "menubar-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws { Store.settings.removeObject(forKey: "menubar.icon") }
    override func tearDown() async throws { Store.settings.removeObject(forKey: "menubar.icon") }

    func testOffUntilAskedForAndKept() {
        XCTAssertFalse(Preferences().menuBarIcon)
        Preferences().menuBarIcon = true
        XCTAssertTrue(Preferences().menuBarIcon)
    }

    func testTheFieldsLineOnlyWithTheLauncherOnAndAKey() {
        let rest: [MenuBarItem.Line] = [.newWindow, .settings, .separator, .quit]
        let key = LauncherKey.suggested.combo
        XCTAssertEqual(MenuBarItem.lines(launcher: true, key: key), [.field(key), .separator] + rest)
        XCTAssertEqual(MenuBarItem.lines(launcher: true, key: nil), rest)
        XCTAssertEqual(MenuBarItem.lines(launcher: false, key: key), rest)
    }
}
