import XCTest
@testable import Search

@MainActor
final class BenchAuthorizationTests: XCTestCase {
    func testCommandsNeedTheCurrentToken() throws {
        let token = try XCTUnwrap(Bench.makeToken())
        let next = try XCTUnwrap(Bench.makeToken())

        XCTAssertEqual(token.count, 64)
        XCTAssertNotEqual(token, next)
        XCTAssertFalse(Bench.authorized([:], token: token, testing: false))
        XCTAssertFalse(Bench.authorized(["token": 1], token: token, testing: false))
        XCTAssertFalse(Bench.authorized(["token": token], token: next, testing: false))
        XCTAssertFalse(Bench.authorized(["token": token], token: nil, testing: false))
        XCTAssertTrue(Bench.authorized(["token": token], token: token, testing: false))
    }

    func testTestWorldsNeedNoToken() {
        XCTAssertTrue(Bench.authorized([:], token: nil, testing: true))
    }
}
