import XCTest
import SwiftUI
@testable import Search

/// The calm card after an update and Settings › What's New: each release's
/// counts match its CHANGELOG section, its settings are real rows, the
/// sentence reads right, and the dot comes with an update and goes once
/// What's New is opened.
@MainActor
final class WhatsNewTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    /// Top-level lines under each section's Added, Changed and Fixed.
    private func changelog() throws -> [String: (changes: Int, fixes: Int)] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CHANGELOG.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        var counts: [String: (changes: Int, fixes: Int)] = [:]
        var version: String?, heading = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                version = line.dropFirst(3).split(separator: " ").first.map(String.init)
                heading = ""
            } else if line.hasPrefix("### ") {
                heading = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("- "), let version {
                var count = counts[version] ?? (0, 0)
                if heading == "Added" || heading == "Changed" { count.changes += 1 }
                if heading == "Fixed" { count.fixes += 1 }
                counts[version] = count
            }
        }
        return counts
    }

    func testCountsMatchTheChangelog() throws {
        let sections = try changelog()
        XCTAssertEqual(sections["1.0.22"]?.changes, 26)
        XCTAssertEqual(sections["1.0.22"]?.fixes, 63)
        for release in WhatsNew.releases {
            guard let section = sections[release.version] else {
                XCTAssertNil(release.changes, "\(release.version) has counts but no CHANGELOG section")
                continue
            }
            // A version from 1.0.22 on that has shipped has its counts.
            if !WhatsNew.older(release.version, than: "1.0.22") {
                XCTAssertEqual(release.changes, section.changes, release.version)
                XCTAssertEqual(release.fixes, section.fixes, release.version)
            }
        }
    }

    func testSettingsAreRealRowsOnce() {
        for release in WhatsNew.releases {
            XCTAssertEqual(Set(release.settings).count, release.settings.count, release.version)
            for id in release.settings {
                XCTAssertNotNil(SettingsIndex.item(id), "\(release.version): \(id)")
            }
            XCTAssertEqual(WhatsNew.items(release).map(\.id), release.settings, release.version)
        }
        let latest = WhatsNew.releases[0]
        XCTAssertTrue(latest.settings.contains("sidebar.roomy"), "Roomier tabs now enlarges pinned squares")
        XCTAssertEqual(WhatsNew.releases.first { $0.version == "1.0.22" }?.settings.first, "meet.pip")
    }

    /// The popup stays simple: a short title, two short lines, no list. The
    /// details live in Settings › What's New, which still has its highlights.
    func testCardTextStaysShort() {
        XCTAssertLessThanOrEqual(WhatsNewCard.title.count, 24)
        XCTAssertLessThanOrEqual(WhatsNewCard.lines.count, 2)
        for line in WhatsNewCard.lines {
            XCTAssertLessThanOrEqual(line.split(separator: " ").count, 8, line)
        }
        let all = ([WhatsNewCard.title] + WhatsNewCard.lines).joined(separator: " ").lowercased()
        XCTAssertFalse(all.contains("shorten"), "not in this build")
        XCTAssertFalse(all.contains("cookie") || all.contains("signed in"), "that fix is not on main")
        XCTAssertEqual(WhatsNewCard.lines.first, "A few small improvements and fixes.")
        // The details are in Settings › What's New.
        let release = WhatsNew.releases[0]
        XCTAssertTrue((4...6).contains(release.highlights.count))
        for item in release.highlights {
            XCTAssertNotNil(NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil), item.symbol)
        }
    }

    /// The email form is in the card at once, behind no link: the block the
    /// card draws is the one with the form, and offered whenever no email
    /// has been given (the source file holds it; a picture shows it).
    func testCardShowsTheEmailForm() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: WhatsNewCard(release: WhatsNew.releases[0], close: {}, settings: {}, optInForced: true))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        func texts(_ view: NSView) -> [String] {
            var out: [String] = []
            if let label = view.accessibilityLabel() { out.append(label) }
            for sub in view.subviews { out += texts(sub) }
            return out
        }
        // Tall enough for the title, two lines and the whole email block.
        XCTAssertGreaterThan(host.fittingSize.height, 330)
        XCTAssertEqual(host.fittingSize.width, 420, accuracy: 1)
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Search/WhatsNew.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("OptInBlock(source: .whatsNew"))
        XCTAssertFalse(source.contains("Join\") { joining"), "no link in front of the form")
    }

    func testReleasesAreNewestFirst() {
        for (a, b) in zip(WhatsNew.releases, WhatsNew.releases.dropFirst()) {
            XCTAssertTrue(WhatsNew.older(b.version, than: a.version), "\(b.version) before \(a.version)")
        }
    }

    func testSummary() {
        XCTAssertEqual(WhatsNew.summary(.init(version: "1.0.22", changes: 26, fixes: 63)),
                       "26 new features and changes, 63 fixes in 1.0.22")
        XCTAssertEqual(WhatsNew.summary(.init(version: "1.0.9", changes: 1, fixes: 1)),
                       "1 new feature or change, 1 fix in 1.0.9")
        XCTAssertEqual(WhatsNew.summary(.init(version: "1.0.23")), "What's new in 1.0.23")
    }

    func testLatestIsTheNewestReleaseNotAfterTheVersion() {
        XCTAssertEqual(WhatsNew.latest(for: "1.0.22")?.version, "1.0.22")
        XCTAssertEqual(WhatsNew.latest(for: "1.0.22.1")?.version, "1.0.22")
        XCTAssertEqual(WhatsNew.latest(for: "9.0")?.version, WhatsNew.releases.first?.version)
        // A dev build falls back to the newest.
        XCTAssertEqual(WhatsNew.latest(for: "dev")?.version, WhatsNew.releases.first?.version)
    }

    func testDotUntilOpened() throws {
        let store = try XCTUnwrap(UserDefaults(suiteName: "whatsnew-dot-\(UUID().uuidString)"))
        XCTAssertFalse(WhatsNew.unopened(store), "no dot on a fresh install")
        guard let latest = WhatsNew.latest else { return XCTFail("no release") }
        store.set(latest.version, forKey: WhatsNew.dotKey)
        XCTAssertTrue(WhatsNew.unopened(store))
        WhatsNew.opened(store)
        XCTAssertFalse(WhatsNew.unopened(store))
        store.set("1.0.1", forKey: WhatsNew.dotKey)
        XCTAssertFalse(WhatsNew.unopened(store), "a dot from an older update doesn't linger")
    }

    /// Sync with iCloud and Handoff, offered as rows while off and not yet
    /// seen there; gone once seen or turned on.
    func testWorthALook() throws {
        let store = try XCTUnwrap(UserDefaults(suiteName: "whatsnew-worth-\(UUID().uuidString)"))
        let prefs = Shared.prefs
        let before = prefs.handoff
        defer { prefs.handoff = before }
        prefs.handoff = false
        let first = WhatsNew.worthALook(prefs, store)
        XCTAssertTrue(first.contains("handoff"))
        XCTAssertEqual(first.contains("icloud"), !ICloudSync.shared.on && !Sync.shared.on)
        for id in first { XCTAssertNotNil(SettingsIndex.item(id), id) }
        XCTAssertEqual(WhatsNew.toggles.filter(\.lead).compactMap(\.settingsID), ["icloud", "handoff"])
        // Turned on: not offered.
        prefs.handoff = true
        XCTAssertFalse(WhatsNew.worthALook(prefs, store).contains("handoff"))
        // Seen once: not offered again, even off.
        prefs.handoff = false
        WhatsNew.sawWorth(first, store)
        XCTAssertEqual(WhatsNew.worthALook(prefs, store), [])
        WhatsNew.sawWorth(first, store)
        XCTAssertEqual(store.stringArray(forKey: WhatsNew.worthSeenKey)?.count, first.count)
    }

    func testWhatsNewSectionTopsTheRail() {
        XCTAssertEqual(SettingsPanel.Page.blocks.first?.first, .whatsNew)
        XCTAssertEqual(SettingsPanel.Page.named("whatsnew"), .whatsNew)
        XCTAssertEqual(SettingsPanel.Page.named(SettingsPanel.Page.whatsNew.rawValue), .whatsNew)
    }

    func testURLBarFindsTheAddressBar() {
        for words in ["url bar", "address bar", "url field"] {
            XCTAssertTrue(SettingsIndex.find(words).contains { $0.id == "address.shown" }, words)
        }
    }

    func testRoomierPinSquares() {
        XCTAssertEqual(SideBar.square(roomy: false), 34)
        // As much taller as the rows: 36 for 28.
        XCTAssertEqual(SideBar.square(roomy: true), 44)
        XCTAssertEqual(SideBar.square(roomy: true) / SideBar.square(roomy: false), 36 / 28, accuracy: 0.02)
    }
}
