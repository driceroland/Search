import XCTest
@testable import Search

/// The Application panel's pure logic: table sorting and resizing, the
/// manifest checks, the frame tree and in-place cookie edits.
final class DeveloperApplicationPanelTests: XCTestCase {
    // MARK: Tables

    func testClickingAHeaderSortsAscendingThenTurnsTheOrderRound() {
        let first = DeveloperTableLayout.toggled(nil, column: 2)
        XCTAssertEqual(first, .init(column: 2, ascending: true))
        XCTAssertEqual(DeveloperTableLayout.toggled(first, column: 2), .init(column: 2, ascending: false))
        XCTAssertEqual(DeveloperTableLayout.toggled(.init(column: 2, ascending: false), column: 0),
                       .init(column: 0, ascending: true))
    }

    func testSortingComparesNumbersAsFinderDoesAndKeepsTiesInOrder() {
        let rows = [["b", "10"], ["a", "9"], ["c", "10"], ["d", "1"]]
        let ascending = DeveloperTableLayout.sorted(rows, by: .init(column: 1, ascending: true)) { $0 }
        XCTAssertEqual(ascending.map { $0[0] }, ["d", "a", "b", "c"])
        let descending = DeveloperTableLayout.sorted(rows, by: .init(column: 1, ascending: false)) { $0 }
        XCTAssertEqual(descending.map { $0[0] }, ["b", "c", "a", "d"])
        XCTAssertEqual(DeveloperTableLayout.sorted(rows, by: nil) { $0 }, rows)
        // A column a row lacks sorts as empty text, first.
        let ragged = DeveloperTableLayout.sorted([["x", "2"], ["y"]], by: .init(column: 1, ascending: true)) { $0 }
        XCTAssertEqual(ragged.map { $0[0] }, ["y", "x"])
    }

    func testResizingAColumnChangesOnlyThatColumnAndStopsAtTheMinimum() {
        let widths: [CGFloat] = [100, 200, 80]
        XCTAssertEqual(DeveloperTableLayout.resized(widths, column: 1, by: 40), [100, 240, 80])
        XCTAssertEqual(DeveloperTableLayout.resized(widths, column: 2, by: -500), [100, 200, 30])
        XCTAssertEqual(DeveloperTableLayout.resized(widths, column: 5, by: 10), widths)
    }

    func testUpAndDownMoveTheSelectionAndStopAtTheEnds() {
        let ids = [4, 7, 9]
        XCTAssertEqual(DeveloperTableLayout.moved(nil, in: ids, by: 1), 4)
        XCTAssertEqual(DeveloperTableLayout.moved(nil, in: ids, by: -1), 9)
        XCTAssertEqual(DeveloperTableLayout.moved(4, in: ids, by: 1), 7)
        XCTAssertEqual(DeveloperTableLayout.moved(9, in: ids, by: 1), 9)
        XCTAssertEqual(DeveloperTableLayout.moved(4, in: ids, by: -1), 4)
        XCTAssertNil(DeveloperTableLayout.moved(4, in: [], by: 1))
    }

    // MARK: Manifest

    private func manifest(_ extra: [String: Any] = [:]) -> [String: Any] {
        var raw: [String: Any] = [
            "name": "Fixture", "display": "standalone",
            "start_url": "https://example.com/app/index.html", "scope": "https://example.com/app/",
            "manifestURL": "https://example.com/app/manifest.json", "documentURL": "https://example.com/app/",
            "secure": true, "controlled": true, "workers": 1,
            "icons": [["src": "https://example.com/app/icon.png", "sizes": "192x192", "type": "image/png",
                       "width": 192, "height": 192]] as [[String: Any]],
            "types": [String: String](),
        ]
        for (key, value) in extra { raw[key] = value }
        return raw
    }

    func testAGoodManifestHasNoErrorsAndCanBeInstalled() {
        let report = DeveloperManifestReport.validate(manifest())
        XCTAssertEqual(report.errors, [])
        XCTAssertEqual(report.installability, [])
        XCTAssertEqual(report.icons.count, 1)
    }

    func testInstallabilityNamesWhatIsMissing() {
        let report = DeveloperManifestReport.validate(manifest([
            "name": "", "display": "browser", "secure": false, "icons": [[String: Any]](),
        ]))
        XCTAssertTrue(report.installability.contains("Page is not served from a secure origin"))
        XCTAssertTrue(report.installability.contains("Manifest does not contain a 'name' or 'short_name' field"))
        XCTAssertTrue(report.installability.contains { $0.hasPrefix("Manifest 'display' property must be one of") })
        XCTAssertTrue(report.installability.contains { $0.hasPrefix("Manifest does not contain a suitable icon") })
    }

    func testDisplayOverrideCanMakeABrowserDisplayInstallable() {
        let report = DeveloperManifestReport.validate(manifest(["display": "browser",
                                                                 "display_override": ["window-controls-overlay"]]))
        XCTAssertFalse(report.installability.contains { $0.hasPrefix("Manifest 'display'") })
    }

    func testErrorsForWrongTypesOriginsScopeAndIconSizes() {
        let report = DeveloperManifestReport.validate(manifest([
            "types": ["name": "number", "icons": "object"],
            "display": "kiosk",
            "start_url": "https://example.com/elsewhere/",
            "icons": [["src": "https://example.com/app/icon.png", "sizes": "512x512", "type": "image/png",
                       "width": 192, "height": 192],
                      ["src": "https://example.com/app/broken.png", "sizes": "192x192", "failed": true]] as [[String: Any]],
            "controlled": false, "workers": 0,
        ]))
        XCTAssertTrue(report.errors.contains("Manifest: property 'name' ignored, type string expected."))
        XCTAssertTrue(report.errors.contains("Manifest: property 'icons' ignored, type array expected."))
        XCTAssertTrue(report.errors.contains("Manifest: unknown 'display' value 'kiosk' ignored."))
        XCTAssertTrue(report.errors.contains("Manifest: property 'scope' ignored. Start url should be within scope of scope URL."))
        XCTAssertTrue(report.errors.contains { $0.hasPrefix("Actual size (192×192)px of icon https://example.com/app/icon.png") })
        XCTAssertTrue(report.errors.contains { $0.hasPrefix("Error while trying to use the following icon") })
        XCTAssertTrue(report.errors.contains { $0.hasPrefix("No service worker is registered.") })
    }

    func testAStartURLOnAnotherOriginIsIgnored() {
        let report = DeveloperManifestReport.validate(manifest(["start_url": "https://other.example/app/"]))
        XCTAssertTrue(report.errors.contains("Manifest: property 'start_url' ignored, should be same origin as document."))
        XCTAssertTrue(report.installability.contains("Manifest start URL is not valid"))
    }

    func testSuitableIconsAreLargeSquareSupportedAndForAnyPurpose() {
        XCTAssertTrue(DeveloperManifestReport.suitable(.init(url: "https://e.com/a.png", sizes: "144x144")))
        XCTAssertTrue(DeveloperManifestReport.suitable(.init(url: "https://e.com/a.svg", sizes: "any")))
        XCTAssertTrue(DeveloperManifestReport.suitable(.init(url: "https://e.com/a", sizes: "48x48 512x512",
                                                             purpose: "maskable any", type: "image/webp")))
        XCTAssertFalse(DeveloperManifestReport.suitable(.init(url: "https://e.com/a.png", sizes: "96x96")))
        XCTAssertFalse(DeveloperManifestReport.suitable(.init(url: "https://e.com/a.png", sizes: "192x144")))
        XCTAssertFalse(DeveloperManifestReport.suitable(.init(url: "https://e.com/a.png", sizes: "")))
        XCTAssertFalse(DeveloperManifestReport.suitable(.init(url: "https://e.com/a.ico", sizes: "256x256")))
        XCTAssertFalse(DeveloperManifestReport.suitable(.init(url: "https://e.com/a.png", sizes: "192x192",
                                                              purpose: "maskable")))
        XCTAssertFalse(DeveloperManifestReport.suitable(.init(url: "https://e.com/a.png", sizes: "192x192", failed: true)))
    }

    func testWithinScopeComparesOriginAndPathPrefix() throws {
        let scope = try XCTUnwrap(URL(string: "https://example.com/app/"))
        XCTAssertTrue(DeveloperManifestReport.within(try XCTUnwrap(URL(string: "https://example.com/app/a.html")), scope: scope))
        XCTAssertTrue(DeveloperManifestReport.within(try XCTUnwrap(URL(string: "https://example.com/app")), scope: scope))
        XCTAssertFalse(DeveloperManifestReport.within(try XCTUnwrap(URL(string: "https://example.com/apple")), scope: scope))
        XCTAssertFalse(DeveloperManifestReport.within(try XCTUnwrap(URL(string: "https://other.com/app/")), scope: scope))
    }

    // MARK: Frames

    func testTheFrameTreeKeepsSubframesResourcesAndSecureContexts() throws {
        let tree: [String: Any] = [
            "frame": ["id": "top", "url": "https://example.com/", "securityOrigin": "https://example.com",
                      "mimeType": "text/html"],
            "resources": [["url": "https://example.com/b.js", "type": "Script"],
                          ["url": "https://example.com/a.js", "type": "Script"],
                          ["url": "https://example.com/logo.png", "type": "Image"],
                          ["url": "https://example.com/data", "type": "Fetch"]],
            "childFrames": [["frame": ["id": "child", "url": "http://ads.example/", "securityOrigin": "http://ads.example",
                                       "name": "ad"]]],
        ]
        let top = try XCTUnwrap(DeveloperFrameNode.parse(tree))
        XCTAssertEqual(top.title, "top")
        XCTAssertTrue(top.secure)
        XCTAssertEqual(top.children.count, 1)
        let child = try XCTUnwrap(top.find("child"))
        XCTAssertEqual(child.title, "ad")
        XCTAssertEqual(child.depth, 1)
        XCTAssertFalse(child.secure)
        XCTAssertEqual(top.groups.map(\.title), ["Fetch and XHR", "Images", "Scripts"])
        XCTAssertEqual(top.groups.last?.resources.map(\.name), ["a.js", "b.js"])
        XCTAssertNil(top.find("missing"))
        let properties = top.properties(crossOriginIsolated: false)
        XCTAssertTrue(properties.contains(["Secure context", "Yes"]))
        XCTAssertTrue(properties.contains(["Cross-origin isolated", "No"]))
        XCTAssertFalse(child.properties(crossOriginIsolated: true).contains { $0.first == "Cross-origin isolated" })
    }

    func testAFrameWithoutAnIdIsNotParsed() {
        XCTAssertNil(DeveloperFrameNode.parse(["frame": ["url": "https://example.com/"]]))
    }

    // MARK: Cookies edited in place

    @MainActor
    func testCookieCellsEditTheDraft() throws {
        var draft = DeveloperCookieDraft(name: "a", value: "1", domain: "", path: "/")
        try DeveloperApplicationView.apply([0: " session ", 1: " spaced ", 2: "example.com", 3: "", 4: "2027-01-31T12:00:00Z",
                                            6: "true", 7: "", 8: "lax"],
                                           to: &draft, host: "example.com")
        XCTAssertEqual(draft.name, "session")
        XCTAssertEqual(draft.value, " spaced ")
        XCTAssertEqual(draft.domain, "")
        XCTAssertEqual(draft.path, "/")
        XCTAssertEqual(draft.expires, DeveloperApplicationView.date("2027-01-31T12:00:00Z"))
        XCTAssertTrue(draft.httpOnly)
        XCTAssertFalse(draft.secure)
        XCTAssertEqual(draft.sameSite, "Lax")
        try DeveloperApplicationView.apply([4: "Session", 2: ".example.com"], to: &draft, host: "example.com")
        XCTAssertNil(draft.expires)
        XCTAssertEqual(draft.domain, ".example.com")
        XCTAssertThrowsError(try DeveloperApplicationView.apply([4: "next week"], to: &draft, host: nil))
        XCTAssertThrowsError(try DeveloperApplicationView.apply([8: "sometimes"], to: &draft, host: nil))
    }

    @MainActor
    func testCookieDatesReadWithOrWithoutFractions() {
        XCTAssertNotNil(DeveloperApplicationView.date("2027-01-31T12:00:00Z"))
        XCTAssertNotNil(DeveloperApplicationView.date("2027-01-31T12:00:00.250Z"))
        XCTAssertNotNil(DeveloperApplicationView.date("2027-01-31"))
        XCTAssertNil(DeveloperApplicationView.date("tomorrow"))
    }
}
