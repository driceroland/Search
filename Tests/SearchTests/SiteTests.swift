import XCTest
@testable import Search

/// The pure parts of the site helpers: which host an address names and which
/// site a host belongs to.
final class SiteTests: XCTestCase {
    func testHostIsTheSiteWithoutWWW() {
        XCTAssertEqual(Registrable.host(of: "https://www.example.com/login?next=/"), "example.com")
        XCTAssertEqual(Registrable.host(of: "  Example.COM  "), "example.com")
        XCTAssertEqual(Registrable.host(of: "http://accounts.example.com"), "accounts.example.com")
    }

    func testHostIsEmptyForAnythingButAWebsite() {
        XCTAssertEqual(Registrable.host(of: "android://hash@com.vendor.app/"), "")
        XCTAssertEqual(Registrable.host(of: "ftp://example.com"), "")
        XCTAssertEqual(Registrable.host(of: ""), "")
    }

    private let suffixes: Set<String> = ["com", "uk", "co.uk", "github.io"]

    private func domain(_ host: String) -> String {
        Registrable.domain(of: host, isSuffix: { self.suffixes.contains($0) })
    }

    func testRegistrableDomainIsTheSiteAboveASuffix() {
        XCTAssertEqual(domain("accounts.example.com"), "example.com")
        XCTAssertEqual(domain("www.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(domain("bbc.co.uk"), "bbc.co.uk")
    }

    func testRegistrableDomainNeverSpansTenantsOfASuffix() {
        XCTAssertEqual(domain("alice.github.io"), "alice.github.io")
        XCTAssertNotEqual(domain("alice.github.io"), domain("bob.github.io"))
        XCTAssertEqual(domain("github.io"), "github.io")
    }

    func testRegistrableDomainLeavesAddressesWhole() {
        XCTAssertEqual(domain("192.168.1.10"), "192.168.1.10")
        XCTAssertEqual(domain("[::1]"), "[::1]")
    }

    func testRegistrableDomainWithoutASuffixListIsTheHost() {
        XCTAssertEqual(Registrable.domain(of: "accounts.example.com", isSuffix: nil), "accounts.example.com")
    }
}
