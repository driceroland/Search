import Foundation

@main
struct PolicyTests {
    static func main() {
        let id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let base = "chrome-extension://\(id)/"
        let source = URL(string: "https://accounts.example.test/")!
        func manifest(resources: [String] = ["callback.html"], matches: [String] = ["https://accounts.example.test/*"], dynamic: Bool = false) -> [String: Any] {
            ["manifest_version": 3, "web_accessible_resources": [["resources": resources, "matches": matches, "use_dynamic_url": dynamic]]]
        }
        var passed = 0
        func check(_ name: String, _ expected: Bool, _ target: String = "callback.html", _ from: URL? = nil, _ declaration: [String: Any]? = nil) {
            let result = ExtensionRedirectPolicy.allows(target: URL(string: base + target)!, sourceOrigin: from ?? source, manifest: declaration ?? manifest())
            precondition(result == expected, "FAILED: \(name): \(result), expected \(expected)")
            passed += 1
            print("PASS \(name)")
        }
        check("declared origin and resource", true)
        check("query and fragment do not change resource", true, "callback.html?code=TEST-ONLY#state=TEST-ONLY")
        check("non-public resource", false, "private.html")
        check("unlisted source", false, "callback.html", URL(string: "https://other.example.test/")!)
        check("HTTP is outside scope", false, "callback.html", URL(string: "http://accounts.example.test/")!)
        check("opaque source", false, "callback.html", URL(string: "about:blank")!)
        check("origin suffix spoof", false, "callback.html", URL(string: "https://accounts.example.test.evil.test/")!)
        check("origin prefix spoof", false, "callback.html", URL(string: "https://evilaccounts.example.test/")!)
        check("wildcard origin child", true, "callback.html", source, manifest(matches: ["https://*.example.test/*"]))
        check("wildcard origin parent", true, "callback.html", URL(string: "https://example.test/")!, manifest(matches: ["https://*.example.test/*"]))
        check("wildcard scheme for HTTPS", true, "callback.html", source, manifest(matches: ["*://accounts.example.test/*"]))
        check("explicit all URLs declaration", true, "callback.html", source, manifest(matches: ["<all_urls>"]))
        check("resource wildcard", true, "auth/callback.html", source, manifest(resources: ["auth/*.html"]))
        check("resource wildcard does not widen parent", false, "private/callback.html", source, manifest(resources: ["auth/*.html"]))
        check("resource regex punctuation stays literal", false, "callbackXhtml")
        check("missing manifest", false, "callback.html", source, [:])
        check("missing web accessible resources", false, "callback.html", source, ["manifest_version": 3])
        check("MV2 resource", true, "callback.html", source, ["manifest_version": 2, "web_accessible_resources": ["callback.html"]])
        check("MV2 wrong shape", false, "callback.html", source, ["manifest_version": 2, "web_accessible_resources": [["resources": ["callback.html"]]]])
        check("unsupported manifest version", false, "callback.html", source, ["manifest_version": 4, "web_accessible_resources": ["callback.html"]])
        check("dynamic origin refused", false, "callback.html", source, manifest(dynamic: true))
        check("extension IDs alone not web origin permission", false, "callback.html", source, ["manifest_version": 3, "web_accessible_resources": [["resources": ["callback.html"], "extension_ids": ["*"]]]])
        check("encoded traversal", false, "auth/%2e%2e/callback.html", source, manifest(resources: ["*"]))
        check("literal traversal", false, "auth/../callback.html", source, manifest(resources: ["*"]))
        check("encoded slash", false, "auth%2fcallback.html", source, manifest(resources: ["*"]))
        check("encoded backslash", false, "auth%5ccallback.html", source, manifest(resources: ["*"]))
        check("double encoded traversal", false, "%252e%252e/callback.html", source, manifest(resources: ["*"]))
        check("empty path segment", false, "auth//callback.html", source, manifest(resources: ["*"]))
        check("control character", false, "callback.html%0a", source, manifest(resources: ["*"]))
        check("encoded ordinary character", true, "%63allback.html")
        check("origin pattern invalid path", false, "callback.html", source, manifest(matches: ["https://accounts.example.test/private/*"]))
        check("origin pattern invalid port syntax", false, "callback.html", source, manifest(matches: ["https://accounts.example.test:443/*"]))
        check("unknown resource path", false, "callback.html/other")
        print("\(passed) policy checks passed.")
    }
}
