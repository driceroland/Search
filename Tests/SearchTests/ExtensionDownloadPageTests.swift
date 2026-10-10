import AppKit
import WebKit
import XCTest
@testable import Search

/// An extension's downloads.download never goes through a private tab.
@available(macOS 15.4, *)
@MainActor
final class ExtensionDownloadPageTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "sec-download-page-\(getpid())", 1)
        super.setUp()
    }

    func testAPrivateTabInFrontIsPassedOver() {
        let shy = Tab(shy: true), plain = Tab()
        _ = shy.web
        _ = plain.web
        XCTAssertTrue(ExtensionShims.downloadPage(active: shy, tabs: [shy, plain]) === plain.built)
        XCTAssertTrue(ExtensionShims.downloadPage(active: plain, tabs: [shy, plain]) === plain.built)
        XCTAssertNil(ExtensionShims.downloadPage(active: shy, tabs: [shy]))
    }
}
