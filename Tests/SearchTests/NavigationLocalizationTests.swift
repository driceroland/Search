import XCTest
@testable import Search

final class LocalizationTests: XCTestCase {
    func testSystemLanguageAndExplicitChoice() {
        XCTAssertEqual(InterfaceLanguage.system.code(preferred: ["fr-CA", "en"]), "fr")
        XCTAssertEqual(InterfaceLanguage.system.code(preferred: ["de-DE", "fr"]), "en")
        XCTAssertEqual(InterfaceLanguage.english.code(preferred: ["fr-FR"]), "en")
        XCTAssertEqual(InterfaceLanguage.french.code(preferred: ["en-US"]), "fr")
    }

    func testCatalogAndSafeInterpolation() {
        XCTAssertGreaterThan(Localization.french.count, 600)
        let phrase: LocalizedPhrase = "Save the password for \("{1} Élise") on \("example.test")?"
        XCTAssertEqual(Localization.render(phrase, language: "fr"), "Enregistrer le mot de passe de {1} Élise sur example.test ?")
        XCTAssertEqual(Localization.render(phrase, language: "en"), "Save the password for {1} Élise on example.test?")
        XCTAssertEqual(Localization.render("Missing translation", language: "fr"), "Missing translation")
    }

    func testEveryTranslationPreservesItsArguments() throws {
        let regex = try NSRegularExpression(pattern: #"\{[0-9]+\}"#)
        func placeholders(_ text: String) -> Set<String> {
            Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) })
        }
        for (key, value) in Localization.french {
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertEqual(placeholders(key), placeholders(value), key)
        }
    }

    func testCommandTitlesFollowLanguageChangesWithoutRebuildingCatalog() throws {
        let original = Localization.shared.language
        defer { Localization.shared.language = original }
        let command = try XCTUnwrap(Command.named("file.newTab"))
        Localization.shared.language = .french
        XCTAssertEqual(command.title, "Nouvel onglet")
        Localization.shared.language = .english
        XCTAssertEqual(command.title, "New Tab")
    }
}

@MainActor
final class FloatingNavigationTests: XCTestCase {
    func testRestingAddressNeverRevealsCredentials() throws {
        let url = try XCTUnwrap(URL(string: "https://alice:secret@example.test:8443/path?q=one#two"))
        let label = FloatingNavigation.displayAddress(url)
        XCTAssertFalse(label.contains("alice"))
        XCTAssertFalse(label.contains("secret"))
        XCTAssertTrue(label.contains("example.test:8443/path?q=one#two"))
    }

    func testNavigationPreferencePersistsIndependentlyOfSidebar() {
        let old = Store.settings.object(forKey: "navigation.floating")
        defer {
            if let old { Store.settings.set(old, forKey: "navigation.floating") }
            else { Store.settings.removeObject(forKey: "navigation.floating") }
        }
        Store.settings.removeObject(forKey: "navigation.floating")
        let first = Preferences()
        XCTAssertFalse(first.floatingNavigation)
        let sidebar = first.sidebar
        let hides = first.sideHides
        first.floatingNavigation = true
        let restored = Preferences()
        XCTAssertTrue(restored.floatingNavigation)
        XCTAssertEqual(restored.sidebar, sidebar)
        XCTAssertEqual(restored.sideHides, hides)
        restored.floatingNavigation = false
        XCTAssertFalse(Preferences().floatingNavigation)
    }
}
