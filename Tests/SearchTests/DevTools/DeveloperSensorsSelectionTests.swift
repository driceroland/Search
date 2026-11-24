import XCTest
@testable import Search

/// The Sensors Location picker after Settings › Locations changed the list.
@MainActor
final class DeveloperSensorsSelectionTests: XCTestCase {
    func testARemovedLocationBecomesOther() {
        let berlin = DeveloperLocation(title: "Berlin", latitude: 52.52, longitude: 13.405,
                                       timezone: "Europe/Berlin", locale: "de-DE")
        XCTAssertEqual(DeveloperSensorsView.selection("Berlin", in: [berlin]), "Berlin")
        XCTAssertEqual(DeveloperSensorsView.selection("Paris", in: [berlin]), DeveloperSensorsView.other)
        for fixed in [DeveloperSensorsView.noOverride, DeveloperSensorsView.other, DeveloperSensorsView.unavailable] {
            XCTAssertEqual(DeveloperSensorsView.selection(fixed, in: []), fixed)
        }
    }
}
