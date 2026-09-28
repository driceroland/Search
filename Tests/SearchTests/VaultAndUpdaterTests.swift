import XCTest
@testable import Search

/// The pure parts of the password vault and the updater: which host a login
/// belongs to, how an export is read, and that an unsigned feed is refused.
/// Nothing here touches the keychain: every CSV row below is one that is
/// skipped, so nothing is ever saved.
final class VaultAndUpdaterTests: XCTestCase {
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
        let result = Vault.take(csv: "url,username\nhttps://example.com,me\nhttps://example.org,you\n")
        XCTAssertEqual(result.kept, 0)
        XCTAssertEqual(result.skipped, 2)
    }

    func testEmptyExportKeepsAndSkipsNothing() {
        let result = Vault.take(csv: "")
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
        let result = Vault.take(csv: csv)
        XCTAssertEqual(result.kept, 0)
        XCTAssertEqual(result.skipped, 4)
    }

    func testQuotedFieldsWithNewlinesAndQuotesStayOneRow() {
        // If the newline inside the quotes split the row, this would count
        // two skipped, not one.
        let csv = "url,username,password\nandroid://hash@com.vendor.app/,\"a \"\"quoted\"\"\nname\",secret\n"
        let result = Vault.take(csv: csv)
        XCTAssertEqual(result.kept, 0)
        XCTAssertEqual(result.skipped, 1)
    }

    func testWindowsLineEndingsAndBlankLinesDoNotAddRows() {
        let csv = "url,username,password\r\nandroid://x@com.app/,me,secret\r\n\r\n"
        XCTAssertEqual(Vault.take(csv: csv).skipped, 1)
    }

    private func release(minimum: String?) -> Updater.Release {
        Updater.Release(
            version: "9.9", build: 9999,
            archive: URL(string: "https://officecommun.com/search/Search.zip")!,
            dmg: URL(string: "https://officecommun.com/search/Search.dmg")!,
            sha256: nil, notes: nil, minimumSystemVersion: minimum
        )
    }

    func testReleaseWithoutAMinimumRunsHere() {
        XCTAssertTrue(release(minimum: nil).runsHere)
    }

    func testReleaseNeedingANewerMacIsNotOffered() {
        XCTAssertFalse(release(minimum: "99").runsHere)
        XCTAssertFalse(release(minimum: "99.1.2").runsHere)
    }

    func testReleaseNeedingAnOlderMacRunsHere() {
        XCTAssertTrue(release(minimum: "10.15").runsHere)
        XCTAssertTrue(release(minimum: "14").runsHere)
    }

    func testAnUnreadableMinimumCountsAsZero() {
        XCTAssertTrue(release(minimum: "soon").runsHere)
    }

    func testGarbageIsNotAFeed() {
        XCTAssertNil(Updater.opened(Data("not a zip".utf8)))
        XCTAssertNil(Updater.opened(Data()))
    }

    func testAnUnsignedFeedInAValidZipIsRefused() throws {
        // Zipped flat, so it unpacks to appcast.json: with a parent folder the
        // feed would fail to be found, not to be signed.
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("feed-test-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        let json = folder.appendingPathComponent("appcast.json")
        try Data(#"{"version":"9.9","build":9999}"#.utf8).write(to: json)
        let zip = folder.appendingPathComponent("appcast.json.zip")

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", json.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0)

        XCTAssertNil(Updater.opened(try Data(contentsOf: zip)))
    }
}
