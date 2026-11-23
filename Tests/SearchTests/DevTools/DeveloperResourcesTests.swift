import XCTest
@testable import Search

/// Developer resources' pure logic: a load's record from pending to
/// success or failure, the list's limit, the summary and the URL filter.
final class DeveloperResourcesTests: XCTestCase {
    private typealias Record = DeveloperResourceRecord

    func testALoadStartsPendingAndEndsInSuccessWithItsSize() {
        var list = DeveloperResourceList()
        let id = list.begin(url: "https://example.com/app.js.map", initiator: "https://example.com/app.js", kind: .sourceMap)
        XCTAssertEqual(list.records.count, 1)
        XCTAssertEqual(list.records[0].status, .pending)
        XCTAssertNil(list.records[0].bytes)
        XCTAssertEqual(DeveloperResourceFilter.bytesText(list.records[0]), "")
        list.finish(id, bytes: 12_345)
        XCTAssertEqual(list.records[0].status, .success)
        XCTAssertEqual(list.records[0].bytes, 12_345)
        XCTAssertNil(list.records[0].error)
        XCTAssertEqual(DeveloperResourceFilter.bytesText(list.records[0]), "12,345")
        XCTAssertEqual(list.records[0].initiator, "https://example.com/app.js")
        XCTAssertEqual(list.records[0].kind, .sourceMap)
    }

    func testAFailedLoadKeepsWhyAndWhatItRead() {
        var list = DeveloperResourceList()
        let missing = list.begin(url: "https://example.com/gone.map", initiator: "https://example.com/a.js", kind: .sourceMap)
        let broken = list.begin(url: "https://example.com/bad.map", initiator: "https://example.com/b.js", kind: .sourceMap)
        list.fail(missing, error: "The server answered 404.")
        list.fail(broken, error: "", bytes: 20)
        XCTAssertEqual(list.records[0].status, .failure)
        XCTAssertEqual(list.records[0].error, "The server answered 404.")
        XCTAssertNil(list.records[0].bytes)
        XCTAssertEqual(list.records[1].error, "Failed to load.", "a failure always says something")
        XCTAssertEqual(list.records[1].bytes, 20)
    }

    func testALoadEndingAfterTheListWasClearedChangesNothing() {
        var list = DeveloperResourceList()
        let old = list.begin(url: "https://a.test/old.map", initiator: "", kind: .sourceMap)
        list.removeAll()
        let new = list.begin(url: "https://a.test/new.map", initiator: "", kind: .authored)
        XCTAssertNotEqual(old, new, "ids aren't reused after a clear")
        list.finish(old, bytes: 1)
        list.fail(old, error: "x")
        XCTAssertEqual(list.records.map(\.status), [.pending])
    }

    func testTheListKeepsTheNewestRecordsAndCutsLongDataURLs() {
        var list = DeveloperResourceList()
        for index in 0..<(DeveloperResourceList.limit + 5) {
            list.begin(url: "https://a.test/\(index).map", initiator: "", kind: .sourceMap)
        }
        XCTAssertEqual(list.records.count, DeveloperResourceList.limit)
        XCTAssertEqual(list.records.first?.url, "https://a.test/5.map")

        let data = "data:application/json;base64," + String(repeating: "A", count: 10_000)
        var short = DeveloperResourceList()
        short.begin(url: data, initiator: "https://a.test/x.js", kind: .sourceMap)
        XCTAssertEqual(short.records[0].url.count, Record.urlLimit)
        XCTAssertTrue(short.records[0].displayURL.hasSuffix("…"))
        XCTAssertEqual(short.records[0].displayURL.count, 81)
        XCTAssertEqual(Record.display("https://a.test/" + String(repeating: "b", count: 200) + ".map").count, 219,
                       "only data: URLs are cut")
        XCTAssertEqual(Record.display("data:,{}"), "data:,{}")
    }

    func testTheSummaryCountsFailuresPendingAndBytesLoaded() {
        var list = DeveloperResourceList()
        let a = list.begin(url: "https://a.test/a.map", initiator: "", kind: .sourceMap)
        let b = list.begin(url: "https://a.test/b.map", initiator: "", kind: .sourceMap)
        list.begin(url: "https://a.test/c.map", initiator: "", kind: .sourceMap)
        list.finish(a, bytes: 2_500)
        list.fail(b, error: "nope", bytes: 99)
        XCTAssertEqual(DeveloperResourceList.summary(list.records), "3 resources, 1 failed, 1 pending, 2.5 kB loaded")
        XCTAssertEqual(DeveloperResourceList.summary([]), "0 resources, 0 B loaded")
        XCTAssertEqual(DeveloperResourceList.summary(Array(list.records.prefix(1))), "1 resource, 2.5 kB loaded")
    }

    func testTheFilterMatchesEveryWordInTheURLInAnyCase() {
        var list = DeveloperResourceList()
        list.begin(url: "https://cdn.example.com/js/App.js.map", initiator: "", kind: .sourceMap)
        list.begin(url: "https://cdn.example.com/css/site.css.map", initiator: "", kind: .sourceMap)
        list.begin(url: "webpack:///src/App.tsx", initiator: "", kind: .authored)
        let records = list.records
        func urls(_ query: String) -> [String] { DeveloperResourceFilter.filter(records, query: query).map(\.url) }
        XCTAssertEqual(urls("").count, 3)
        XCTAssertEqual(urls("   ").count, 3)
        XCTAssertEqual(urls("app"), ["https://cdn.example.com/js/App.js.map", "webpack:///src/App.tsx"])
        XCTAssertEqual(urls("CDN map"), ["https://cdn.example.com/js/App.js.map", "https://cdn.example.com/css/site.css.map"])
        XCTAssertEqual(urls("app -webpack"), ["https://cdn.example.com/js/App.js.map"])
        XCTAssertEqual(urls("-"), [], "a lone dash is plain text, in none of these addresses")
        XCTAssertEqual(urls("nothing"), [])
    }

    func testSourceMapFallbackOmitsCookiesOutsideTheirScope() throws {
        let base: [HTTPCookiePropertyKey: Any] = [
            .name: "session", .value: "test", .domain: "example.test", .path: "/app", .secure: "TRUE",
        ]
        let cookie = try XCTUnwrap(HTTPCookie(properties: base))
        let partitioned = try XCTUnwrap(HTTPCookie(properties: base.merging([
            .name: "partitioned", HTTPCookiePropertyKey("StoragePartition"): "another.test",
        ]) { _, extra in extra }))
        func headers(_ address: String, throughWebsite: Bool = true) throws -> [String: String] {
            let url = try XCTUnwrap(URL(string: address))
            return DeveloperResourceLoading.headers(for: url, cookies: [cookie, partitioned], throughWebsite: throughWebsite)
        }
        XCTAssertEqual(try headers("https://example.test/app/bundle.js.map")["Cookie"], "session=test")
        XCTAssertTrue(try headers("https://example.test/application/bundle.js.map").isEmpty)
        XCTAssertTrue(try headers("http://example.test/app/bundle.js.map").isEmpty)
        XCTAssertTrue(try headers("https://another.test/app/bundle.js.map").isEmpty)
        XCTAssertTrue(try headers("https://example.test/app/bundle.js.map", throughWebsite: false).isEmpty)
    }
}

/// Sources › Page lists the page's stylesheets, which WebKit's resource
/// tree types "StyleSheet".
@MainActor
final class DeveloperResourceTreeTypesTests: XCTestCase {
    func testWebKitStyleSheetsAreListed() {
        let tree: [String: Any] = [
            "frame": ["id": "main", "url": "https://example.com/"],
            "resources": [
                ["url": "https://example.com/site.css", "type": "StyleSheet"],
                ["url": "https://example.com/app.js", "type": "Script"],
                ["url": "https://example.com/logo.png", "type": "Image"],
            ],
        ]
        var list = [DeveloperToolsSession.Resource]()
        DeveloperToolsSession.addResources(tree, to: &list)
        XCTAssertEqual(list.map(\.url), ["https://example.com/", "https://example.com/site.css", "https://example.com/app.js"])
        XCTAssertEqual(list.first { $0.url.hasSuffix(".css") }?.type, "Stylesheet")
    }
}
