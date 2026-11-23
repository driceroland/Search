import XCTest
@testable import Search

/// Application › Manifest's Identity, Presentation, Protocol handlers,
/// Shortcuts, Screenshots and Window Controls Overlay sections.
final class DeveloperManifestSectionsTests: XCTestCase {
    private func manifest(_ extra: [String: Any] = [:]) -> [String: Any] {
        var raw: [String: Any] = [
            "name": "Fixture", "short_name": "Fix", "description": "A test app", "display": "standalone",
            "start_url": "https://example.com/app/index.html?source=pwa#top", "scope": "https://example.com/app/",
            "manifestURL": "https://example.com/app/manifest.json", "documentURL": "https://example.com/app/",
            "secure": true, "controlled": true, "workers": 1, "types": [String: String](),
        ]
        for (key, value) in extra { raw[key] = value }
        return raw
    }

    private func url(_ text: String) throws -> URL { try XCTUnwrap(URL(string: text)) }

    // MARK: App Id

    func testAppIdFallsBackToTheStartURLWithoutItsFragment() throws {
        let start = try url("https://example.com/app/index.html?source=pwa#top")
        XCTAssertEqual(DeveloperManifestReport.appID(id: nil, start: start),
                       "https://example.com/app/index.html?source=pwa")
        XCTAssertEqual(DeveloperManifestReport.appID(id: "", start: start),
                       "https://example.com/app/index.html?source=pwa")
    }

    func testAppIdResolvesAgainstTheStartURLsOrigin() throws {
        let start = try url("https://example.com/app/index.html")
        XCTAssertEqual(DeveloperManifestReport.appID(id: "/", start: start), "https://example.com/")
        XCTAssertEqual(DeveloperManifestReport.appID(id: "mail", start: start), "https://example.com/mail")
        XCTAssertEqual(DeveloperManifestReport.appID(id: "/app/?x=1#frag", start: start), "https://example.com/app/?x=1")
    }

    func testAppIdOnAnotherOriginIsIgnored() throws {
        let start = try url("https://example.com/app/index.html")
        XCTAssertEqual(DeveloperManifestReport.appID(id: "https://other.example/app", start: start),
                       "https://example.com/app/index.html")
    }

    func testTheNoteRecommendsTheStartURLsPathOnlyWhenIdIsMissing() {
        let missing = DeveloperManifestReport.validate(manifest())
        XCTAssertEqual(missing.appID, "https://example.com/app/index.html?source=pwa")
        XCTAssertEqual(missing.recommendedID, "/app/index.html?source=pwa")
        let set = DeveloperManifestReport.validate(manifest(["id": "/app/"]))
        XCTAssertEqual(set.appID, "https://example.com/app/")
        XCTAssertNil(set.recommendedID)
    }

    // MARK: Sections

    func testIdentityAndPresentation() {
        let report = DeveloperManifestReport.validate(manifest([
            "orientation": "portrait", "theme_color": "#3367D6", "theme_colour": "#3367d6",
            "background_color": "transparent", "background_colour": "rgba(0, 0, 0, 0)",
            "display_override": ["Window-Controls-Overlay", "minimal-ui"],
        ]))
        XCTAssertEqual(report.name, "Fixture")
        XCTAssertEqual(report.shortName, "Fix")
        XCTAssertEqual(report.description, "A test app")
        XCTAssertEqual(report.startURL, "https://example.com/app/index.html?source=pwa#top")
        XCTAssertEqual(report.scope, "https://example.com/app/")
        XCTAssertEqual(report.display, "standalone")
        XCTAssertEqual(report.orientation, "portrait")
        XCTAssertEqual(report.themeColor, "#3367D6")
        XCTAssertEqual(report.themeColour, DeveloperManifestColour(canvas: "#3367d6"))
        XCTAssertEqual(report.backgroundColour?.alpha, 0)
        XCTAssertEqual(report.displayOverride, ["window-controls-overlay", "minimal-ui"])
        XCTAssertTrue(report.windowControlsOverlay)
        XCTAssertFalse(DeveloperManifestReport.validate(manifest()).windowControlsOverlay)
    }

    func testColoursAsTheCanvasGivesThem() throws {
        let hex = try XCTUnwrap(DeveloperManifestColour(canvas: "#ff8000"))
        XCTAssertEqual(hex.red, 1)
        XCTAssertEqual(hex.green, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(hex.blue, 0)
        XCTAssertEqual(hex.alpha, 1)
        let rgba = try XCTUnwrap(DeveloperManifestColour(canvas: "rgba(255, 0, 0, 0.5)"))
        XCTAssertEqual(rgba.red, 1)
        XCTAssertEqual(rgba.alpha, 0.5)
        XCTAssertNil(DeveloperManifestColour(canvas: nil))
        XCTAssertNil(DeveloperManifestColour(canvas: "papayawhip-ish"))
    }

    func testProtocolHandlersShortcutsAndScreenshots() throws {
        let report = DeveloperManifestReport.validate(manifest([
            "protocol_handlers": [["protocol": "web+coffee", "url": "https://example.com/app/?type=%s"],
                                  ["url": "https://example.com/missing-protocol"]],
            "shortcuts": [["name": "Today", "short_name": "Now", "url": "https://example.com/app/today",
                           "icons": [["src": "https://example.com/app/today.png", "sizes": "96x96"]]]],
            "screenshots": [["src": "https://example.com/app/wide.png", "sizes": "1280x720",
                             "form_factor": "wide", "label": "Home screen"]],
        ] as [String: Any]))
        XCTAssertEqual(report.protocolHandlers.map(\.protocolName), ["web+coffee"])
        let shortcut = try XCTUnwrap(report.shortcuts.first)
        XCTAssertEqual(shortcut.name, "Today")
        XCTAssertEqual(shortcut.shortName, "Now")
        XCTAssertEqual(shortcut.url, "https://example.com/app/today")
        XCTAssertEqual(shortcut.icons.map(\.sizes), ["96x96"])
        let shot = try XCTUnwrap(report.screenshots.first)
        XCTAssertEqual(shot.formFactor, "wide")
        XCTAssertEqual(shot.label, "Home screen")
        XCTAssertEqual(shot.image.url, "https://example.com/app/wide.png")
    }

    func testTestProtocolOpensTheHandlerWithTheLinkEscaped() {
        let handler = DeveloperManifestProtocolHandler(protocolName: "web+coffee", url: "https://example.com/?type=%s")
        XCTAssertEqual(handler.open("americano"), "https://example.com/?type=web%2Bcoffee%3Aamericano")
        XCTAssertEqual(handler.open("web+coffee:flat white"), "https://example.com/?type=web%2Bcoffee%3Aflat%20white")
    }

    func testRowsTheSectionsShowLeaveProperties() {
        XCTAssertTrue(DeveloperManifestView.sectioned("Start URL"))
        XCTAssertTrue(DeveloperManifestView.sectioned("Shortcut · Today"))
        XCTAssertFalse(DeveloperManifestView.sectioned("Manifest URL"))
        XCTAssertFalse(DeveloperManifestView.sectioned("Language"))
    }
}
