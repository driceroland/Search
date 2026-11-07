import AppKit
import WebKit
import XCTest
@testable import Search

/// A tab whose page is let go of stops saying it plays sound: the speaker
/// went with the view, and a tab still "playing sound" never sleeps.
@MainActor
final class NoisyRehomeTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "noisy-rehome-\(getpid())", 1)
        super.setUp()
    }

    /// A tab with its page made, heard playing.
    private func playing() -> Tab {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(configuration: configuration)
        tab.setAddressOptimistically(URL(string: "https://sound.example/")!)
        _ = tab.web
        tab.noisy = true
        return tab
    }

    func testMovedToSpaceWithItsOwnSignInsGoesQuiet() {
        let tab = playing()
        tab.rehome(in: UUID())
        XCTAssertNil(tab.built)
        XCTAssertFalse(tab.noisy)
    }

    func testPutDownPinGoesQuiet() {
        let tab = playing()
        tab.rest()
        XCTAssertNil(tab.built)
        XCTAssertFalse(tab.noisy)
    }

    func testPageKeptKeepsItsSound() {
        let tab = playing()
        tab.playbackChanged()
        XCTAssertNotNil(tab.built)
        XCTAssertTrue(tab.noisy)
    }
}
