import XCTest
@testable import Search

/// Small windows for links are on for a new install and stay off for one
/// from before (Preferences.settleLittleLinks), each in a settings suite of
/// its own, removed afterwards.
@available(macOS 14, *)
final class LittleLinksDefaultTests: XCTestCase {
    private var suite = ""
    private var store: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "com.officecommun.search.test.little-default-\(getpid())-\(UUID().uuidString)"
        store = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suite)
        store = nil
        super.tearDown()
    }

    private var little: Bool? { store.object(forKey: Preferences.littleKey) as? Bool }

    func testANewInstallGetsSmallWindows() {
        Preferences.settleLittleLinks(in: store)
        XCTAssertEqual(little, true)
    }

    func testAnInstallFromBeforeKeepsThemOff() {
        for key in ["welcomed", "glyph", "passkeys.for", "passkeys.entitled"] {
            store.removePersistentDomain(forName: suite)
            store.set(key == "glyph" ? "letters" as Any : true as Any, forKey: key)
            Preferences.settleLittleLinks(in: store)
            XCTAssertEqual(little, false, "an install with \(key) written")
        }
    }

    func testAChoiceMadeStands() {
        store.set(true, forKey: "welcomed")
        store.set(true, forKey: Preferences.littleKey)
        Preferences.settleLittleLinks(in: store)
        XCTAssertEqual(little, true)

        store.removePersistentDomain(forName: suite)
        store.set(false, forKey: Preferences.littleKey)
        Preferences.settleLittleLinks(in: store)
        XCTAssertEqual(little, false)
    }

    /// The second launch of a new install finds the lines the first one
    /// wrote, and still has small windows on.
    func testSettledOnceForANewInstall() {
        Preferences.settleLittleLinks(in: store)
        store.set(true, forKey: "welcomed")
        store.set(false, forKey: "passkeys.for")
        Preferences.settleLittleLinks(in: store)
        XCTAssertEqual(little, true)
    }
}
