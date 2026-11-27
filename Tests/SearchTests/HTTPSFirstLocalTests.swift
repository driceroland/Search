import XCTest
@testable import Search

/// Try HTTPS first leaves the home network as asked (umbrel.local, 27 Nov).
final class HTTPSFirstLocalTests: XCTestCase {
    func testLocalNamesAreLeftAsAsked() {
        for address in ["http://umbrel.local", "http://Umbrel.LOCAL/x", "http://umbrel.lan", "http://nas.home:5000",
                        "http://router.home.arpa", "http://pi.localdomain", "http://umbrel", "http://192.168.1.5",
                        "http://[::1]:3000", "http://localhost:3000", "http://app.localhost", "http://x.test"] {
            XCTAssertTrue(HTTPSFirst.local(URL(string: address)!), address)
        }
    }

    func testWebsitesAreUpgraded() {
        for address in ["http://example.com", "http://lan.example.com", "http://homework.com", "http://local.dev"] {
            XCTAssertFalse(HTTPSFirst.local(URL(string: address)!), address)
        }
    }

    func testTypedLANNamesGetHTTP() {
        XCTAssertEqual(Address.url(from: "Umbrel.local")?.absoluteString, "http://Umbrel.local")
        XCTAssertEqual(Address.url(from: "umbrel.lan")?.absoluteString, "http://umbrel.lan")
        XCTAssertEqual(Address.url(from: "nas.home:5000")?.absoluteString, "http://nas.home:5000")
        XCTAssertEqual(Address.url(from: "router.home.arpa")?.absoluteString, "http://router.home.arpa")
        XCTAssertEqual(Address.url(from: "homework.com")?.absoluteString, "https://homework.com")
        XCTAssertEqual(Address.url(from: "lan.example.com")?.absoluteString, "https://lan.example.com")
    }
}
