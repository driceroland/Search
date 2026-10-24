import AppKit
import XCTest
@testable import Search

/// Two pages side by side as cards: each card's shadow is given its outline,
/// so Core Animation never has to find it from the pixels underneath.
@MainActor
final class SplitCardShadowTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "split-card-shadow-\(getpid())", 1)
        super.setUp()
    }

    func testEachCardShadowHasTheCardsOutline() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        for word in ["one", "two"] {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(word)")!, title: word)
        }
        let tabs = Array(browser.tabs.prefix(2))
        XCTAssertEqual(tabs.count, 2)

        let stage = PaneStage(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        stage.corner = Metrics.cardRadius
        stage.show(tabs, split: nil, focused: nil)
        stage.layoutSubtreeIfNeeded()

        let shadows = try XCTUnwrap(stage.layer?.sublayers).filter { $0.shadowOpacity > 0 && !$0.isHidden }
        XCTAssertEqual(shadows.count, 2, "A shadow under each card")
        for shadow in shadows {
            let path = try XCTUnwrap(shadow.shadowPath, "The shadow is given its shape")
            XCTAssertEqual(path.boundingBox.size, shadow.bounds.size, "and it is the card's")
        }

        // Narrower: the outline goes with the card.
        stage.frame.size.width = 900
        stage.layoutSubtreeIfNeeded()
        for shadow in shadows {
            XCTAssertEqual(shadow.shadowPath?.boundingBox.size, shadow.bounds.size)
        }
    }
}
