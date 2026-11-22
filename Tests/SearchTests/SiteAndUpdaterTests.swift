import XCTest
@testable import Search

/// The pure parts of the site helpers and the updater: which host an address
/// names, which site a host belongs to, and that an unsigned feed is refused.
final class SiteAndUpdaterTests: XCTestCase {
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

    private func release(minimum: String?) -> Updater.Release {
        Updater.Release(
            version: "9.9", build: 9999,
            archive: URL(string: "https://officecommun.com/search/Search.zip")!,
            dmg: URL(string: "https://officecommun.com/search/Search.dmg")!,
            sha256: nil, notes: nil, minimumSystemVersion: minimum
        )
    }

    func testACheckThatFindsNothingLeavesASwapUnderWay() {
        let next = release(minimum: nil)
        XCTAssertEqual(Updater.nothingNewer(after: .fetching(next)), .fetching(next))
        XCTAssertEqual(Updater.nothingNewer(after: .ready(next)), .ready(next))
        XCTAssertEqual(Updater.nothingNewer(after: .waiting(next)), .none)
        XCTAssertEqual(Updater.nothingNewer(after: .offered(next)), .none)
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
