import XCTest
@testable import Search

/// What an extension that runs can't do here, said in Settings and at
/// install (Extensions.cantDo): requests it can't block (#1208), and
/// WebAssembly in a Manifest V3 extension's pages on macOS 15 (#1383).
@available(macOS 15.4, *)
@MainActor
final class ExtensionLimitsTests: XCTestCase {
    private let bitwarden: [String: Any] = [
        "manifest_version": 3, "name": "Bitwarden",
        "content_security_policy": ["extension_pages": "script-src 'self' 'wasm-unsafe-eval'; object-src 'self'"],
    ]

    func testWebAssemblyIsSaidOnlyOnMacOS15ForManifestV3() {
        XCTAssertNotNil(Extensions.cantDo(bitwarden, macOS: 15)?.range(of: "WebAssembly"), "macOS 15, MV3, asks for it")
        XCTAssertNil(Extensions.cantDo(bitwarden, macOS: 26), "macOS 26 runs it")
        var noWasm = bitwarden
        noWasm["content_security_policy"] = ["extension_pages": "script-src 'self'; object-src 'self'"]
        XCTAssertNil(Extensions.cantDo(noWasm, macOS: 15), "one that doesn't ask for it")
        XCTAssertNil(Extensions.cantDo(["manifest_version": 3, "name": "Plain"], macOS: 15), "nor one with no policy")
        let v2: [String: Any] = ["manifest_version": 2, "content_security_policy": "script-src 'self' 'wasm-unsafe-eval'; object-src 'self'"]
        XCTAssertNil(Extensions.cantDo(v2, macOS: 15), "Manifest V2's pages run it on 15")
    }

    func testBlockingStillSaidAndBothTogether() {
        let ubo: [String: Any] = ["manifest_version": 2, "name": "uBlock Origin", "permissions": ["webRequest", "webRequestBlocking"]]
        XCTAssertNotNil(Extensions.cantDo(ubo, macOS: 26)?.range(of: "Can’t block requests"))
        var both = bitwarden
        both["permissions"] = ["webRequestBlocking"]
        let said = Extensions.cantDo(both, macOS: 15) ?? ""
        XCTAssertTrue(said.contains("Can’t block requests") && said.contains("WebAssembly"), said)
    }
}
