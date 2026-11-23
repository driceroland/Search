import AppKit
import WebKit
import XCTest
@testable import Search

/// The per-session models' home: one model per session and type, let go
/// (and told) when the session disconnects; and the protocol readers.
@MainActor
final class DeveloperSessionModelsTests: XCTestCase {
    private final class Probe: DeveloperSessionModel {
        var closed = 0
        func sessionClosed() { closed += 1 }
    }

    func testModelsLiveUntilTheSessionDisconnects() async {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = PageView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        XCTAssertNil(DeveloperSessionModels.existing(Probe.self, for: session))
        let probe = DeveloperSessionModels.model(for: session) { _ in Probe() }
        XCTAssertTrue(DeveloperSessionModels.model(for: session) { _ in Probe() } === probe)
        XCTAssertTrue(DeveloperSessionModels.existing(Probe.self, for: session) === probe)
        await session.disconnect().value
        XCTAssertEqual(probe.closed, 1)
        XCTAssertNil(DeveloperSessionModels.existing(Probe.self, for: session))
    }

    func testReadersMeanWhatTheirCastsMean() {
        let raw: [String: Any] = ["id": 3, "half": 1.5, "on": true, "name": "a", "child": ["x": 1], "list": [["y": 2]]]
        XCTAssertEqual(raw.int("id"), 3)
        XCTAssertNil(raw.int("half"))
        XCTAssertEqual(raw.double("half"), 1.5)
        XCTAssertEqual(raw.double("id"), 3)
        XCTAssertEqual(raw.bool("on"), true)
        XCTAssertTrue(raw.flag("on"))
        XCTAssertFalse(raw.flag("missing"))
        XCTAssertEqual(raw.string("name"), "a")
        XCTAssertEqual(raw.object("child")?.int("x"), 1)
        XCTAssertEqual(raw.objects("list")?.first?.int("y"), 2)
        XCTAssertEqual(DeveloperProtocolValue.numeric("Infinity"), .infinity)
        XCTAssertEqual(DeveloperProtocolValue.numeric("2.5"), 2.5)
        XCTAssertNil(DeveloperProtocolValue.number("2.5"))
    }
}
