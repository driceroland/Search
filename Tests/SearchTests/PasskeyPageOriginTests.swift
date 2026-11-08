import XCTest
@testable import Search

final class PasskeyPageOriginTests: XCTestCase {
    private func page(_ text: String) -> URL? { URL(string: text) }

    func testThePagesOwnOrigin() {
        XCTAssertTrue(Passkeys.isPage(scheme: "https", host: "example.com", port: 0, of: page("https://example.com/login")))
        XCTAssertTrue(Passkeys.isPage(scheme: "https", host: "Example.COM", port: 0, of: page("https://example.com/")))
        XCTAssertTrue(Passkeys.isPage(scheme: "http", host: "localhost", port: 3000, of: page("http://localhost:3000/")))
    }

    func testThePortLeftOutIsTheSchemesOwn() {
        XCTAssertTrue(Passkeys.isPage(scheme: "https", host: "example.com", port: 443, of: page("https://example.com/")))
        XCTAssertTrue(Passkeys.isPage(scheme: "https", host: "example.com", port: 0, of: page("https://example.com:443/")))
        XCTAssertFalse(Passkeys.isPage(scheme: "https", host: "example.com", port: 8443, of: page("https://example.com/")))
    }

    func testAnotherOriginIsNot() {
        XCTAssertFalse(Passkeys.isPage(scheme: "https", host: "bank.example", port: 0, of: page("https://example.com/")))
        XCTAssertFalse(Passkeys.isPage(scheme: "https", host: "login.example.com", port: 0, of: page("https://example.com/")))
        XCTAssertFalse(Passkeys.isPage(scheme: "http", host: "localhost", port: 0, of: page("https://localhost/")))
    }

    func testAnAddressLiteral() {
        XCTAssertTrue(Passkeys.isPage(scheme: "http", host: "::1", port: 8080, of: page("http://[::1]:8080/")))
    }

    func testNoPageOrNoHostIsNot() {
        XCTAssertFalse(Passkeys.isPage(scheme: "https", host: "example.com", port: 0, of: nil))
        XCTAssertFalse(Passkeys.isPage(scheme: "https", host: "example.com", port: 0, of: page("about:blank")))
    }
}
