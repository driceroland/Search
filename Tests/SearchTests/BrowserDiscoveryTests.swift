import Foundation
import XCTest
@testable import Search

final class BrowserDiscoveryTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "browser-import-\(ProcessInfo.processInfo.processIdentifier)", 1)
        super.setUp()
    }

    func testChosenFolderIsIgnoredByTestRunsAndNeverPersisted() {
        let source = Chromium.Source(name: "Fixture-\(UUID().uuidString)", folder: "Fixture", service: "", account: "", app: "")
        let selected = FileManager.default.temporaryDirectory.appendingPathComponent("other-browser")

        Chromium.useForSession(selected, for: source)

        XCTAssertTrue(Store.testing)
        XCTAssertNil(Chromium.chosenRoot(for: source.name))
        XCTAssertEqual(source.root, Chromium.base.appendingPathComponent(source.folder, isDirectory: true))
        XCTAssertNil(Store.settings.string(forKey: "import.folder.\(source.name)"))
    }
}
