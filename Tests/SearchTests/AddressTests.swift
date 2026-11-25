import AppKit
import Darwin
import Foundation
import XCTest
@testable import Search

final class AddressTests: XCTestCase {
    func testExistingPathsKeepTheirLiteralNames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        for name in ["report.pdf", "résumé #1? 100%.html"] {
            let file = folder.appendingPathComponent(name)
            try Data("local file".utf8).write(to: file)
            let url = try XCTUnwrap(Address.file(from: " \(file.path)\n"))
            XCTAssertNil(Address.url(from: file.path), "Suggestions and text drops must not resolve paths")
            XCTAssertTrue(url.isFileURL)
            XCTAssertEqual(url.path, file.path)
            XCTAssertNil(url.query)
            XCTAssertNil(url.fragment)
            XCTAssertEqual(Address.url(from: url.absoluteString), url)
        }
        XCTAssertNil(Address.file(from: folder.path))
        XCTAssertNil(Address.file(from: folder.appendingPathComponent("missing.pdf").path))
    }

    func testHomeRelativePath() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
        let file = #filePath
        try XCTSkipUnless(file.hasPrefix(home), "Checkout is outside the home directory")
        let url = try XCTUnwrap(Address.file(from: "~/" + file.dropFirst(home.count)))
        XCTAssertEqual(url.path, file)
    }

    func testOnlyRegularFilesAreAccepted() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("regular.txt")
        try Data("text".utf8).write(to: file)
        let pipe = folder.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        for path in [folder.path, pipe.path, link.path, "/dev/zero", "/dev/random",
                     "/" + file.path, folder.appendingPathComponent("missing").path] {
            XCTAssertNil(Address.file(from: path), path)
        }
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(Address.file(from: link.path), "A broken link is not a regular file either")
    }

    func testAddressesAndSearchPhrasesKeepTheirMeaning() {
        XCTAssertEqual(Address.url(from: "example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(Address.url(from: "localhost:3000/test")?.absoluteString, "http://localhost:3000/test")
        XCTAssertEqual(Address.url(from: "https://example.com/a?q=b#c")?.absoluteString, "https://example.com/a?q=b#c")
        for text in ["", "two words", "./report.pdf", "person@example.com", "javascript:alert(1)"] {
            XCTAssertNil(Address.url(from: text), text)
            XCTAssertNil(Address.file(from: text), text)
        }
    }

    func testLocalHostnamesIgnoreCase() {
        let addresses = [
            "LOCALHOST:3000/Status?item=ABC#Top",
            "Dev.LocalHost:3000/Dashboard",
            "Printer.LOCAL:8080/Status",
        ]
        for address in addresses {
            XCTAssertEqual(Address.url(from: address)?.absoluteString, "http://" + address)
        }
        XCTAssertEqual(Address.url(from: "https://LOCALHOST:3000")?.absoluteString, "https://LOCALHOST:3000")
        XCTAssertEqual(Address.url(from: "Example.COM/Status")?.absoluteString, "https://Example.COM/Status")
    }
}

@MainActor
final class FileDestinationTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testOnlyCommittedDestinationsResolvePathsAndSiteSearchKeepsPrecedence() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).html")
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        browser.typed = file.path
        XCTAssertNil(browser.ending)
        XCTAssertFalse(browser.offers.contains { $0.url.isFileURL })
        XCTAssertEqual(browser.destination(for: file.path), file)
        XCTAssertEqual(browser.destination(for: file.absoluteString), file)
        XCTAssertEqual(browser.destination(for: "/dev/zero"), browser.searchURL(for: "/dev/zero"))

        let site = SearchSite(name: "Fixture", host: "example.test", template: "https://example.test/?q=%s")
        browser.siteChip = site
        XCTAssertEqual(browser.destination(for: file.path), site.url(for: file.path))
        browser.siteChip = nil
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(browser.destination(for: file.path), browser.searchURL(for: file.path))
    }
    /// #1473: vnc://, ssh:// and other apps' links typed in the field go to
    /// the app that opens them, not to a search; only with an app to take
    /// them, and never Search's own schemes or a script.
    func testAnotherAppsSchemeTypedGoesToThatApp() {
        let someApp = URL(fileURLWithPath: "/System/Applications/Utilities/Screen Sharing.app")
        let anApp: (URL) -> URL? = { _ in someApp }
        XCTAssertEqual(Address.otherApp(from: "vnc://192.168.1.20", opener: anApp)?.absoluteString, "vnc://192.168.1.20")
        XCTAssertEqual(Address.otherApp(from: " ssh://me@box.local ", opener: anApp)?.absoluteString, "ssh://me@box.local")
        XCTAssertNil(Address.otherApp(from: "vnc://host", opener: { _ in nil }), "no app takes it: searched, as before")
        for mine in ["https://example.com", "http://a.b", "file:///tmp", "search://settings", "javascript://x%0Aalert(1)", "about://blank"] {
            XCTAssertNil(Address.otherApp(from: mine, opener: anApp), mine)
        }
        XCTAssertNil(Address.otherApp(from: "vnc host", opener: anApp))
        XCTAssertNil(Address.otherApp(from: "what is vnc://", opener: anApp))
        XCTAssertNil(Address.otherApp(from: "1abc://x", opener: anApp))
        XCTAssertNil(Address.url(from: "vnc://192.168.1.20"), "the window itself still doesn't load it")
    }
}
