import Foundation
import XCTest
@testable import Search

/// A Manifest V3 extension's pages' policy, as preparing a package leaves it:
/// held to Chrome's minimum. What its pages then run is
/// Tests/extension_page_policy.py.
@available(macOS 15.4, *)
final class ExtensionPagePolicyTests: XCTestCase {
    private let minimum = ExtensionShims.minimumPagesPolicy

    private func held(_ csp: Any?, version: Int = 3) -> Any? {
        var manifest: [String: Any] = ["manifest_version": version]
        if let csp { manifest["content_security_policy"] = csp }
        return ExtensionShims.holdingPagesPolicy(manifest)["content_security_policy"]
    }

    private func pages(_ policy: String) -> String? {
        (held(["extension_pages": policy, "sandbox": "sandbox allow-scripts; script-src 'self' 'unsafe-eval'"]) as? [String: Any])?["extension_pages"] as? String
    }

    func testAPolicyWithinTheMinimumIsLeftAlone() {
        for policy in [
            "script-src 'self'; object-src 'self'",
            "script-src 'self' 'wasm-unsafe-eval'; object-src 'self'",
            "script-src 'self'; img-src https: data:; connect-src *",
            "script-src 'self' http://localhost:8080; object-src 'self'",
            "default-src *; script-src 'self'",
        ] {
            XCTAssertEqual(pages(policy), policy, policy)
        }
        XCTAssertNil(held(nil), "no policy: WebKit's own")
        XCTAssertEqual((held(["sandbox": "sandbox allow-scripts"]) as? [String: Any])?.keys.sorted(), ["sandbox"])
    }

    func testAnyOtherGetsTheMinimumBesideIt() {
        for policy in [
            "object-src 'self'",
            "img-src 'self' data:",
            "default-src 'self'",
            "script-src 'self' 'unsafe-eval'",
            "script-src 'self' 'unsafe-inline'",
            "script-src 'self' https://cdn.example.com",
            "script-src 'self'; script-src-elem 'self' https://cdn.example.com",
            "script-src 'self'; script-src-attr 'unsafe-inline'",
            "script-src 'self'; worker-src blob:",
            "script-src 'self'; object-src *",
            "script-src 'self' http://localhost.example.com",
            "img-src *, script-src 'self'",
        ] {
            XCTAssertEqual(pages(policy), policy + ", " + minimum, policy)
        }
        XCTAssertEqual(pages(""), minimum)
        XCTAssertEqual(held("object-src 'self'") as? String, "object-src 'self', " + minimum, "one string")
    }

    func testHoldingAgainChangesNothing() {
        let once = ExtensionShims.holdingPagesPolicy(["manifest_version": 3, "content_security_policy": ["extension_pages": "object-src 'self'"]])
        let twice = ExtensionShims.holdingPagesPolicy(once)
        XCTAssertEqual((twice["content_security_policy"] as? [String: Any])?["extension_pages"] as? String, "object-src 'self', " + minimum)
        XCTAssertFalse(ExtensionSandbox.mayLeaveEvalToFrames(twice), "WebKit's Manifest V3 mode stays")
    }

    func testManifestV2IsLeftAsItIs() {
        XCTAssertEqual(held("script-src 'self' 'unsafe-eval'; object-src 'self'", version: 2) as? String, "script-src 'self' 'unsafe-eval'; object-src 'self'")
    }
}
