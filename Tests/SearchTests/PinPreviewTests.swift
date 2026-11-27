import XCTest
@testable import Search

/// A pin's glance (PinPreview.swift): the unread count a mailbox's title
/// says, the card refused where it has no business, and on by default.
@available(macOS 14, *)
@MainActor
final class PinPreviewTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testUnreadFromTitles() {
        XCTAssertEqual(Glance.unread(title: "Inbox (3) - someone@example.com - Gmail", host: "mail.google.com"), "3")
        XCTAssertEqual(Glance.unread(title: "Boîte de réception (1 204) - someone@example.com - Gmail", host: "mail.google.com"), "99+")
        XCTAssertEqual(Glance.unread(title: "Inbox (1,204) - someone@example.com - Gmail", host: "mail.google.com"), "99+")
        XCTAssertNil(Glance.unread(title: "Inbox - someone@example.com - Gmail", host: "mail.google.com"))
        // The front count, anywhere: WhatsApp, Outlook.
        XCTAssertEqual(Glance.unread(title: "(12) WhatsApp", host: "web.whatsapp.com"), "12")
        XCTAssertEqual(Glance.unread(title: "(2) Mail - Someone - Outlook", host: "outlook.office.com"), "2")
        // Not a mailbox: a number in brackets is as likely a year.
        XCTAssertNil(Glance.unread(title: "Dune (2021) - IMDb", host: "www.imdb.com"))
        XCTAssertNil(Glance.unread(title: "Notes (3) - Docs", host: "docs.google.com"))
        // A mailbox's own subject line further along isn't its count.
        XCTAssertNil(Glance.unread(title: "Inbox - Meeting (2) - Gmail", host: "mail.google.com"))
    }

    func testOnByDefault() {
        let store = Store.settings
        let saved = store.object(forKey: "pins.preview")
        defer { if let saved { store.set(saved, forKey: "pins.preview") } else { store.removeObject(forKey: "pins.preview") } }
        store.removeObject(forKey: "pins.preview")
        XCTAssertTrue(Preferences().pinPreviews)
        store.set(false, forKey: "pins.preview")
        XCTAssertFalse(Preferences().pinPreviews)
        XCTAssertNotNil(SettingsIndex.items.first { $0.id == "pins.preview" })
        // Screenshots in Downloads stays off.
        XCTAssertFalse(Preferences().screenshotsInDownloads)
    }

    func testRefusedOffAndForAPlainTab() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let tab = Tab()
        let prefs = browser.prefs
        let was = prefs.pinPreviews
        defer { prefs.pinPreviews = was }
        prefs.pinPreviews = true
        XCTAssertEqual(PinPreview.refusal(tab, in: browser), "not a pin")
        prefs.pinPreviews = false
        XCTAssertEqual(PinPreview.refusal(tab, in: browser), "off")
    }
}
