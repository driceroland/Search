import XCTest
@testable import Search

/// Settings › Extensions › From Safari apps: an extension already added from
/// the Chrome Web Store (or another app) is told apart by the name it goes
/// by, and not offered again (SafariApps.twin); the other way round, adding
/// it from the store says it is there already (SafariApps.twinLine).
final class SafariAppTwinTests: XCTestCase {
    private func store(_ name: String, id: String = String(repeating: "a", count: 32)) -> Installed {
        Installed(id: id, name: name, version: "1", enabled: true, fromStore: true, permissions: [])
    }

    func testTheStoresNamesForOneExtension() {
        let pairs = [
            ("Grammarly for Safari", "Grammarly: AI Writing Assistant and Grammar Checker App"),
            ("Grammarly", "Grammarly: AI Writing and Grammar Checker App"),
            ("1Password – Password Manager", "1Password – Password Manager"),
            ("1Password for Safari", "1Password – Password Manager"),
            ("Bitwarden", "Bitwarden Password Manager"),
            ("Dark Reader for Safari", "Dark Reader"),
            ("Notion Web Clipper", "Notion Web Clipper"),
            ("Todoist for Safari", "Todoist for Chrome"),
            ("Raindrop.io", "Raindrop.io"),
            ("Proton Pass: Free Password Manager", "Proton Pass"),
        ]
        for (safari, chrome) in pairs {
            XCTAssertTrue(SafariApps.same(safari, chrome), "\(safari) / \(chrome)")
            XCTAssertTrue(SafariApps.same(chrome, safari), "\(chrome) / \(safari)")
        }
    }

    func testDifferentExtensionsAreNotTwins() {
        let pairs = [
            ("Dark Reader", "Dark Mode"),
            ("Google Translate", "Google Docs Offline"),
            ("Grammarly", "LanguageTool"),
            ("1Password", "Bitwarden"),
            ("AdGuard", "AdBlock"),
            ("Web", "Web Developer"),
            ("", "Grammarly"),
        ]
        for (a, b) in pairs { XCTAssertFalse(SafariApps.same(a, b), "\(a) / \(b)") }
    }

    func testBrandLeavesOffWhatOnlyOneStoreSays() {
        XCTAssertEqual(SafariApps.brand("Grammarly for Safari"), ["grammarly"])
        XCTAssertEqual(SafariApps.brand("Grammarly: AI Writing Assistant"), ["grammarly"])
        XCTAssertEqual(SafariApps.brand("Dark Reader - Safari Extension"), ["dark", "reader"])
        XCTAssertEqual(SafariApps.brand("Ghostery – Privacy Ad Blocker"), ["ghostery"])
        XCTAssertEqual(SafariApps.brand("Café (beta)"), ["cafe"])
        XCTAssertEqual(SafariApps.brand("Safari"), ["safari"], "a name that is only filler keeps its one word")
    }

    func testTwinFoundAmongInstalled() {
        let grammarly = store("Grammarly: AI Writing Assistant and Grammar Checker App")
        let installed = [store("uBlock Origin Lite", id: String(repeating: "b", count: 32)), grammarly]
        XCTAssertEqual(SafariApps.twin(of: "Grammarly for Safari", id: "local-x", among: installed)?.id, grammarly.id)
        XCTAssertNil(SafariApps.twin(of: "Wipr", id: "local-y", among: installed))
        // An extension isn't its own twin (an update, a reload).
        XCTAssertNil(SafariApps.twin(of: grammarly.name, id: grammarly.id, among: [grammarly]))
    }

    func testTheOtherWayRoundSaysWhereItCameFrom() {
        var fromApp = store("Grammarly for Safari", id: "local-g")
        fromApp.fromStore = false
        fromApp.fromApp = "Grammarly for Safari"
        let twin = SafariApps.twin(of: "Grammarly: AI Writing Assistant", id: String(repeating: "c", count: 32), among: [fromApp])
        XCTAssertEqual(twin?.id, "local-g")
        XCTAssertEqual(twin.map(SafariApps.twinLine),
                       "“Grammarly for Safari” is added from the Safari extension in “Grammarly for Safari”: with this one too, both would run.")
        XCTAssertEqual(SafariApps.twinLine(store("Grammarly")),
                       "“Grammarly” is added from the Chrome Web Store: with this one too, both would run.")
    }
}
