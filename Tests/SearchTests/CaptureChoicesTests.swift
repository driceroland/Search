import XCTest
import WebKit
@testable import Search

final class CaptureChoicesTests: XCTestCase {
    func testChoicesForIndividualAndCombinedRequestsStaySeparate() throws {
        let name = "CaptureChoicesTests.\(UUID().uuidString)"
        let settings = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { settings.removePersistentDomain(forName: name) }
        let site = "https://example.test:8443"
        let combinedKey = "capture.\(site)|\(WKMediaCaptureType.cameraAndMicrophone.rawValue)"
        settings.set(false, forKey: combinedKey)
        CaptureChoices.set(true, for: .camera, origin: site, in: settings)
        CaptureChoices.set(true, for: .microphone, origin: site, in: settings)
        XCTAssertEqual(settings.object(forKey: combinedKey) as? Bool, false)
        XCTAssertTrue(CaptureChoices.combinedAllowed(origin: site, in: settings))
        CaptureChoices.set(nil, for: .camera, origin: site, in: settings)
        XCTAssertEqual(CaptureChoices.choice(.camera, origin: site, in: settings), .ask)
        XCTAssertEqual(CaptureChoices.choice(.microphone, origin: site, in: settings), .allow)
        XCTAssertEqual(settings.object(forKey: combinedKey) as? Bool, false)
    }

    func testCombinedChoiceUpdatesBothDevicesAndInvalidatesTheirRequests() throws {
        let name = "CaptureChoicesTests.\(UUID().uuidString)"
        let settings = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { settings.removePersistentDomain(forName: name) }
        let site = "https://example.test:8443"
        for value: Bool? in [true, false, nil] {
            let affected = CaptureChoices.set(value, for: .cameraAndMicrophone, origin: site, in: settings)
            for kind: CaptureChoices.Kind in [.camera, .microphone, .cameraAndMicrophone] {
                let key = "capture.\(site)|\(kind.suffix)"
                XCTAssertEqual(settings.object(forKey: key) as? Bool, value)
                XCTAssertTrue(affected.contains(key))
            }
        }
    }

    func testOldCombinedGrantDoesNotAllowMicrophoneWhenItIsUnset() throws {
        let name = "CaptureChoicesTests.\(UUID().uuidString)"
        let settings = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { settings.removePersistentDomain(forName: name) }
        let site = "https://example.test:8443"
        CaptureChoices.set(true, for: .cameraAndMicrophone, origin: site, in: settings)
        CaptureChoices.set(nil, for: .microphone, origin: site, in: settings)
        XCTAssertEqual(CaptureChoices.choice(.camera, origin: site, in: settings), .allow)
        XCTAssertEqual(CaptureChoices.choice(.microphone, origin: site, in: settings), .ask)
        XCTAssertFalse(CaptureChoices.combinedAllowed(origin: site, in: settings))
    }

    func testDefaultPortVariantsAreShownAndEditedWithoutChangingOtherKinds() throws {
        let name = "CaptureChoicesTests.\(UUID().uuidString)"
        let settings = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { settings.removePersistentDomain(forName: name) }
        let site = "https://example.test"
        let suffix = "\(WKMediaCaptureType.camera.rawValue)"
        let plain = "capture.\(site)|\(suffix)"
        let port = "capture.\(site):443|\(suffix)"
        settings.set(true, forKey: plain)
        XCTAssertEqual(CaptureChoices.choice(.camera, origin: site, in: settings), .allow)
        XCTAssertEqual(CaptureChoices.mediaDecision(.camera, origin: "\(site):443", in: settings), true)
        settings.set(false, forKey: "capture.\(site)|\(WKMediaCaptureType.microphone.rawValue)")
        XCTAssertTrue(CaptureChoices.combinedBlocked(origin: "\(site):443", in: settings))
        settings.set(false, forKey: port)
        settings.set(true, forKey: "capture.\(site)|location")
        XCTAssertEqual(CaptureChoices.choice(.camera, origin: site, in: settings), .different)
        XCTAssertEqual(CaptureChoices.mediaDecision(.camera, origin: site, in: settings), false)
        CaptureChoices.set(false, for: .camera, origin: site, in: settings)
        XCTAssertEqual(settings.object(forKey: plain) as? Bool, false)
        XCTAssertEqual(settings.object(forKey: port) as? Bool, false)
        XCTAssertEqual(CaptureChoices.choice(.location, origin: site, in: settings), .allow)
        CaptureChoices.set(nil, for: .camera, origin: site, in: settings)
        XCTAssertNil(settings.object(forKey: plain))
        XCTAssertNil(settings.object(forKey: port))
    }
}
