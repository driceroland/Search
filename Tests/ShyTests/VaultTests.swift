import XCTest
@testable import Shy

/// The pure parts of the password vault: which host a login belongs to, the
/// site above it, and how an export is read.
/// Nothing here touches the keychain: every CSV row below is one that is
/// skipped, so nothing is ever saved.
final class VaultTests: XCTestCase {
    func testHostIsTheSiteWithoutWWW() {
        XCTAssertEqual(Vault.host(of: "https://www.example.com/login?next=/"), "example.com")
        XCTAssertEqual(Vault.host(of: "  Example.COM  "), "example.com")
        XCTAssertEqual(Vault.host(of: "http://accounts.example.com"), "accounts.example.com")
    }

    func testHostIsEmptyForAnythingButAWebsite() {
        XCTAssertEqual(Vault.host(of: "android://hash@com.vendor.app/"), "")
        XCTAssertEqual(Vault.host(of: "ftp://example.com"), "")
        XCTAssertEqual(Vault.host(of: ""), "")
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

    func testExportWithoutAPasswordColumnIsSkippedWhole() {
        let result = Vault.take(csv: "url,username\nhttps://example.com,me\nhttps://example.org,you\n", in: Profile.personalID)
        XCTAssertEqual(result.kept, 0)
        XCTAssertEqual(result.skipped, 2)
    }

    func testEmptyExportKeepsAndSkipsNothing() {
        let result = Vault.take(csv: "", in: Profile.personalID)
        XCTAssertEqual(result.kept, 0)
        XCTAssertEqual(result.skipped, 0)
    }

    func testRowsThatCannotBeKeptAreCountedAsSkipped() {
        let csv = """
        name,url,username,password,note
        no password,https://example.com,me,,
        no site,,me,secret,
        an app,android://hash@com.vendor.app/,me,secret,
        too short,https://example.com
        """
        let result = Vault.take(csv: csv, in: Profile.personalID)
        XCTAssertEqual(result.kept, 0)
        XCTAssertEqual(result.skipped, 4)
    }

    func testQuotedFieldsWithNewlinesAndQuotesStayOneRow() {
        // If the newline inside the quotes split the row, this would count
        // two skipped, not one.
        let csv = "url,username,password\nandroid://hash@com.vendor.app/,\"a \"\"quoted\"\"\nname\",secret\n"
        let result = Vault.take(csv: csv, in: Profile.personalID)
        XCTAssertEqual(result.kept, 0)
        XCTAssertEqual(result.skipped, 1)
    }

    func testWindowsLineEndingsAndBlankLinesDoNotAddRows() {
        let csv = "url,username,password\r\nandroid://x@com.app/,me,secret\r\n\r\n"
        XCTAssertEqual(Vault.take(csv: csv, in: Profile.personalID).skipped, 1)
    }
}
