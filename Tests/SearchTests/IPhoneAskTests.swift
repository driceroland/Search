import XCTest
@testable import Search

/// The iPhone beta's quieter places (IPhoneAsk.swift): when they offer it,
/// that one "Not now" or one address from anywhere ends it, and that each
/// place's press says where it was made. No window, no network.
@available(macOS 14, *)
@MainActor
final class IPhoneAskTests: XCTestCase {
    private var store: UserDefaults!
    private let suite = "com.officecommun.search.iphoneask-tests-\(getpid())"

    override func setUp() {
        super.setUp()
        store = UserDefaults(suiteName: suite)
        store.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testOpenUntilJoinedOrDismissed() {
        XCTAssertTrue(IPhoneAsk.open(store))
        IPhoneAsk.dismiss(store)
        XCTAssertFalse(IPhoneAsk.open(store))
        XCTAssertFalse(IPhoneAsk.onNewTab(store))
    }

    func testOnlyTheIPhoneBetaEndsIt() {
        OptIn.remember(.news(iPhoneBeta: false), in: store)
        XCTAssertTrue(IPhoneAsk.open(store), "the Mac news list alone: still offered")
        OptIn.remember(.news(iPhoneBeta: true), in: store)
        XCTAssertFalse(IPhoneAsk.open(store), "the card with the iPhone box ticked")
        store.removePersistentDomain(forName: suite)
        OptIn.remember(.iPhoneBeta, in: store)
        XCTAssertFalse(IPhoneAsk.open(store), "asked for the beta from any place")
    }

    func testNewTabForThreeDaysFromFirstSeen() {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertTrue(IPhoneAsk.onNewTab(store, now: start))
        IPhoneAsk.seenOnNewTab(store, now: start)
        IPhoneAsk.seenOnNewTab(store, now: start.addingTimeInterval(86_400))
        XCTAssertTrue(IPhoneAsk.onNewTab(store, now: start.addingTimeInterval(2.9 * 86_400)))
        XCTAssertFalse(IPhoneAsk.onNewTab(store, now: start.addingTimeInterval(3.1 * 86_400)))
    }

    func testEachPlaceTagsItsSource() throws {
        let base = URL(string: "https://searchbrowser.app/api/")!
        let expected: [IPhoneAsk.Spot: String] = [.about: "app-about", .help: "app-help", .newTab: "app-newtab"]
        for spot in IPhoneAsk.Spot.allCases {
            let request = OptIn.request(email: "a@example.com", list: .iPhoneBeta, source: spot.source, base: base)
            XCTAssertEqual(request.url?.absoluteString, "https://searchbrowser.app/api/ios-beta")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(Set(body.keys), ["email", "source"])
            XCTAssertEqual(body["source"] as? String, expected[spot])
        }
    }
}
