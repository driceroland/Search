import Foundation
import XCTest
@testable import Search

/// Which frames the password filling hears from (FormRelay): only a frame
/// of the page's own scheme, host and port.
@available(macOS 14, *)
final class FormRelayOriginTests: XCTestCase {
    private func same(_ scheme: String, _ host: String, _ port: Int, _ page: String) -> Bool {
        FormRelay.sameOrigin(scheme: scheme, host: host, port: port, as: URL(string: page))
    }

    func testTheSameOriginIsHeard() {
        XCTAssertTrue(same("https", "example.com", 0, "https://example.com/login"))
        XCTAssertTrue(same("https", "Example.COM", 443, "https://example.com:443/"))
        XCTAssertTrue(same("http", "127.0.0.1", 8843, "http://127.0.0.1:8843/victim"))
        XCTAssertTrue(same("http", "::1", 8080, "http://[::1]:8080/"))
    }

    func testAnotherOriginIsNot() {
        XCTAssertFalse(same("http", "localhost", 8843, "http://127.0.0.1:8843/victim"))
        XCTAssertFalse(same("http", "example.com", 0, "https://example.com/"))
        XCTAssertFalse(same("https", "evil.example.com", 0, "https://example.com/"))
        XCTAssertFalse(same("https", "example.com", 8443, "https://example.com/"))
        XCTAssertFalse(same("https", "example.com", 0, "https://example.com:8443/"))
        XCTAssertFalse(same("", "", 0, "https://example.com/"))
        XCTAssertFalse(FormRelay.sameOrigin(scheme: "https", host: "example.com", port: 0, as: nil))
        XCTAssertFalse(same("about", "", 0, "about:blank"))
    }
}
