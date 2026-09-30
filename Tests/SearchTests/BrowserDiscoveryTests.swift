import Foundation
import XCTest
@testable import Search

final class BrowserDiscoveryTests: XCTestCase {
    func testChosenFolderStaysInMemory() {
        let source = Chromium.Source(name: "Fixture-\(UUID().uuidString)", folder: "Fixture", service: "", account: "", app: "")
        let selected = FileManager.default.temporaryDirectory.appendingPathComponent("other-browser")

        Chromium.useForSession(selected, for: source)

        XCTAssertEqual(Chromium.chosenRoot(for: source.name), selected)
        XCTAssertEqual(source.root, selected)
        XCTAssertNil(Store.settings.string(forKey: "import.folder.\(source.name)"))
    }
}
