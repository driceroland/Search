import Foundation
import XCTest
@testable import Search

@available(macOS 14, *)
final class PrivacyPermissionListTests: XCTestCase {
    func testListAndResetKeepOriginAndPermissionBoundaries() throws {
        let suite = "PrivacyPermissionListTests.\(UUID())"
        let settings = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }

        let origin = "https://example.test"
        let explicit = origin + ":443"
        CaptureChoices.set(true, for: .camera, origin: origin, in: settings)
        CaptureChoices.set(false, for: .location, origin: origin, in: settings)
        CaptureChoices.set(true, for: .location, origin: explicit, in: settings)
        CaptureChoices.set(false, for: .notifications, origin: origin + ":8443", in: settings)
        let combined = CaptureChoices.keys(.cameraAndMicrophone, origin: origin)[0]
        settings.set(true, forKey: combined)

        let entries = CaptureChoices.saved(in: settings)
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries.filter { $0.kind == .camera }.map(\.origin), [origin])
        let record = try XCTUnwrap(entries.first { $0.kind == .location && $0.origin == explicit })
        XCTAssertTrue(record.alternativeSpelling)
        XCTAssertEqual(record.choice, .allow)

        CaptureChoices.set(nil, for: record.kind, origin: record.origin, in: settings)
        XCTAssertEqual(CaptureChoices.choice(.location, origin: explicit, in: settings), .ask)
        XCTAssertEqual(CaptureChoices.choice(.location, origin: origin, in: settings), .refuse)
        XCTAssertEqual(CaptureChoices.choice(.camera, origin: origin, in: settings), .allow)
        XCTAssertEqual(CaptureChoices.choice(.notifications, origin: origin + ":8443", in: settings), .refuse)
        XCTAssertTrue(settings.bool(forKey: combined))
    }
}
