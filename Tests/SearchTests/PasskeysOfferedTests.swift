import XCTest
@testable import Search

@MainActor
final class PasskeysOfferedTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "passkeys-offered-\(getpid())", 1)
        super.setUp()
    }

    func testAnotherCopyWritingTheStoreLeavesTheSwitchInCharge() {
        let keys = ["passkeys", "passkeys.for", "passkeys.entitled"]
        let saved = keys.map { Store.settings.object(forKey: $0) }
        let offered = FormRelay.passkeysOffered
        defer {
            zip(keys, saved).forEach { Store.settings.set($1, forKey: $0) }
            FormRelay.passkeysOffered = offered
        }
        // Switched on under an unentitled build, as this test build is.
        Store.settings.set(true, forKey: "passkeys")
        Store.settings.set(false, forKey: "passkeys.for")
        _ = Preferences()
        Store.settings.set(false, forKey: "passkeys")
        XCTAssertTrue(FormRelay.passkeysOffered)
    }
}
