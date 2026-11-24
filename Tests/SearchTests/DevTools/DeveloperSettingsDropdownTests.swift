import SwiftUI
import XCTest
@testable import Search

@MainActor
final class DeveloperSettingsDropdownTests: XCTestCase {
    func testChoosingAnItemSelectsIt() {
        var value = "right"
        let selection = Binding(get: { value }, set: { value = $0 })
        let dropdown = SettingsDropdown(selection: selection,
                                        options: [("right", "Dock to right"), ("bottom", "Dock to bottom")])
        XCTAssertTrue(dropdown.isOn("right").wrappedValue)
        XCTAssertFalse(dropdown.isOn("bottom").wrappedValue)
        dropdown.isOn("bottom").wrappedValue = true
        XCTAssertEqual(value, "bottom")
        // Unchecking the current item leaves the value as it is.
        dropdown.isOn("bottom").wrappedValue = false
        XCTAssertEqual(value, "bottom")
    }
}
