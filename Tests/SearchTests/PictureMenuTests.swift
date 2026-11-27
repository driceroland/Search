import AppKit
import XCTest
@testable import Search

/// The right-click menu over a picture (idea 1208): WebKit's own hit test
/// says whether the picture is also a link, and a link's items are never
/// given up for the picture menu. Menus here are only described, never
/// shown: WebKit's items as identifiers, as WebKit hands them over.
@available(macOS 14, *)
@MainActor
final class PictureMenuTests: XCTestCase {
    private let picture = URL(string: "https://example.com/p.png")!
    private let link = ["WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow",
                        "WKMenuItemIdentifierDownloadLinkedFile", "WKMenuItemIdentifierCopyLink"]
    private let image = ["WKMenuItemIdentifierOpenImageInNewWindow", "WKMenuItemIdentifierDownloadImage",
                         "WKMenuItemIdentifierCopyImage", "WKMenuItemIdentifierShareMenu"]

    private func menu(_ ids: [String]) -> NSMenu {
        let menu = NSMenu()
        for id in ids {
            let item = NSMenuItem(title: id, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            menu.addItem(item)
        }
        return menu
    }

    private func own(_ url: URL) -> [NSMenuItem] {
        ["Open Image in New Tab", "Copy Image", "Download Image", "Copy Image Address"].map {
            NSMenuItem(title: $0, action: nil, keyEquivalent: "")
        }
    }

    func testAPictureInALinkKeepsTheLinksItems() {
        XCTAssertFalse(PictureMenu.replaces(link + image, keep: false))
        let shown = menu(link + image)
        var retargeted: [String] = []
        let replaced = PictureMenu.shape(shown, picture: picture, keep: false, items: own, retarget: { retargeted.append($0.title) })
        XCTAssertFalse(replaced)
        XCTAssertEqual(shown.items.map(\.title), link + image, "Open Link in New Tab and the rest stay")
        XCTAssertEqual(Set(retargeted), ["WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierCopyImage"])
    }

    /// The case the page's script got wrong: a link it can't see (inside a
    /// closed shadow root) is still WebKit's link, and its items stay.
    func testWebKitsLinkWinsWhateverThePageScriptThought() {
        let shown = menu(["WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierCopyLink"] + image)
        XCTAssertFalse(PictureMenu.shape(shown, picture: picture, keep: false, items: own, retarget: { _ in }))
        XCTAssertTrue(shown.items.contains { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" })
    }

    func testAPictureAloneGetsThisAppsMenu() {
        XCTAssertTrue(PictureMenu.replaces(image, keep: false))
        let shown = menu(image)
        XCTAssertTrue(PictureMenu.shape(shown, picture: picture, keep: false, items: own, retarget: { _ in }))
        XCTAssertEqual(shown.items.map(\.title), ["Open Image in New Tab", "Copy Image", "Download Image", "Copy Image Address"])
    }

    func testAnExtensionsItemsKeepWebKitsMenu() {
        XCTAssertFalse(PictureMenu.replaces(image, keep: true))
        let shown = menu(image)
        XCTAssertFalse(PictureMenu.shape(shown, picture: picture, keep: true, items: own, retarget: { _ in }))
        XCTAssertEqual(shown.items.map(\.title), image)
    }

    func testNoPictureOrNoPictureItemsLeavesWebKitsMenu() {
        XCTAssertFalse(PictureMenu.replaces(link, keep: false))
        XCTAssertFalse(PictureMenu.replaces(["WKMenuItemIdentifierReload"], keep: false))
        let shown = menu(image)
        var retargeted = 0
        XCTAssertFalse(PictureMenu.shape(shown, picture: nil, keep: false, items: own, retarget: { _ in retargeted += 1 }))
        XCTAssertEqual(shown.items.map(\.title), image)
        XCTAssertEqual(retargeted, 0)
    }
}
