import WebKit
import XCTest
@testable import Search

@MainActor
final class CurtainTests: XCTestCase {
    private let veil = Veil(selector: "#bar", label: "bar", note: nil, date: Date(timeIntervalSince1970: 0))

    func testAVeilsKeyIsTheSameEveryLaunch() {
        XCTAssertEqual(veil.key, "lk4pdv")
        XCTAssertNotEqual(Veil(selector: "#baz", label: "", note: nil, date: Date()).key, "lk4pdv")
    }

    func testARuleKeepsToTheSiteAndThePageItself() throws {
        let rule = Curtain.rule(for: veil, on: "example.com")
        let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
        XCTAssertEqual(trigger["if-domain"] as? [String], ["example.com", "www.example.com"])
        XCTAssertEqual(trigger["load-context"] as? [String], ["top-frame"])
        let action = try XCTUnwrap(rule["action"] as? [String: String])
        XCTAssertEqual(action, [
            "type": "css-display-none",
            "selector": #":is(#bar):not(:is([data-office-spare~="lk4pdv"], [data-office-peek="lk4pdv"]) *)"#,
        ])
    }

    func testRulesCompileInWebKit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("curtain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: folder))
        // What the pointer makes: an id, a hook attribute, classes, a path.
        let rules = ["#bar", #"div[data-testid="cookie-banner"]"#, "aside.related-links",
                     "#main > div:nth-of-type(3) > section"].map {
            Curtain.rule(for: Veil(selector: $0, label: "", note: nil, date: Date()), on: "127.0.0.1")
        }
        let data = try JSONSerialization.data(withJSONObject: rules)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let list = try await store.compileContentRuleList(forIdentifier: "fixture", encodedContentRuleList: json)
        XCTAssertNotNil(list)
    }
}
