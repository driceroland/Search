import Foundation
import WebKit

// A script of an extension's own, run in a page whose Content Security
// Policy refused it.
//
// In Chrome, a <script src="chrome-extension://<id>/file.js"> that a content
// script puts in a page loads whatever the page's policy says: the
// extension's own files are outside it. WebKit holds them to the page's
// policy, and YouTube's script-src names no extension — Language Reactor's
// and Ambient light's scripts never ran there, and nothing of theirs showed.
//
// The content script's shim notices its own script element refused, and its
// background asks here ("page.script"). Run only if:
// - the page is a tab's top frame, http(s), still at the address the
//   content script was in, and one the extension has been granted;
// - the file is the extension's own, named by its manifest's
//   web_accessible_resources for that page's address, a file inside its
//   folder (no "..", no link out);
// then the file's text runs in the page's own world, with
// document.currentScript the element it came from, as a loaded script has
// it. Nothing else: no inline code, no other extension's file, no frame.
// Every refusal is told to the extension's error list (by the shim).

@available(macOS 15.4, *)
@MainActor
enum ExtensionPageScript {
    /// Tokens already run, per extension: a request asked again (a
    /// background just waking can miss the first) runs nothing twice.
    private static var ran = Set<String>()

    struct Refused: LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    /// Whether a manifest's web_accessible_resources let a page at `page`
    /// load `path` (relative, no leading slash). MV2's list of globs is for
    /// every page; MV3's entries each name the pages they are for.
    nonisolated static func accessible(_ path: String, to page: URL, manifest: [String: Any]) -> Bool {
        let entries = manifest["web_accessible_resources"] as? [Any] ?? []
        for entry in entries {
            if let glob = entry as? String {
                if globMatches(glob, path) { return true }
                continue
            }
            guard let entry = entry as? [String: Any],
                  let resources = entry["resources"] as? [String],
                  resources.contains(where: { globMatches($0, path) }) else { continue }
            let matches = entry["matches"] as? [String] ?? []
            for string in matches {
                if string == "<all_urls>", ["http", "https"].contains(page.scheme?.lowercased() ?? "") { return true }
                if let pattern = try? WKWebExtension.MatchPattern(string: string), pattern.matches(page) { return true }
            }
        }
        return false
    }

    /// Chrome's resource glob: `*` stands for anything, `/` included.
    nonisolated static func globMatches(_ glob: String, _ path: String) -> Bool {
        let trimmed = glob.hasPrefix("/") ? String(glob.dropFirst()) : glob
        let pattern = "^" + trimmed.split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".*") + "$"
        return path.range(of: pattern, options: .regularExpression) != nil
    }

    /// The file `path` names inside the extension's folder: decoded, no
    /// empty, "." or ".." part, and still inside once links are resolved.
    nonisolated static func file(_ path: String, in folder: URL) -> URL? {
        guard let decoded = path.removingPercentEncoding else { return nil }
        let parts = decoded.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let relative = parts.first == "" ? Array(parts.dropFirst()) : parts
        guard !relative.isEmpty, !relative.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\0") }) else { return nil }
        let url = relative.reduce(folder) { $0.appendingPathComponent($1) }
        guard let base = realpath(folder.path, nil) else { return nil }
        defer { free(base) }
        guard let real = realpath(url.path, nil) else { return nil }
        defer { free(real) }
        let inside = String(cString: base) + "/"
        var directory: ObjCBool = false
        guard String(cString: real).hasPrefix(inside),
              FileManager.default.fileExists(atPath: String(cString: real), isDirectory: &directory), !directory.boolValue
        else { return nil }
        return URL(fileURLWithPath: String(cString: real))
    }

    /// The same document, its fragment aside.
    nonisolated static func sameDocument(_ a: URL, _ b: URL) -> Bool {
        var x = URLComponents(url: a, resolvingAgainstBaseURL: false), y = URLComponents(url: b, resolvingAgainstBaseURL: false)
        x?.fragment = nil
        y?.fragment = nil
        return x?.url != nil && x?.url == y?.url
    }

    /// Runs `path` of the extension in the tab's page; true once it has run
    /// (an exception thrown by the script itself counts as run, as a loaded
    /// script that throws still fires load).
    static func run(path: String, token: String, frameURL: String, in tab: Tab, context: WKWebExtensionContext) async throws -> Bool {
        guard let page = tab.address, let scheme = page.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw Refused(why: "the tab isn't showing a web page")
        }
        guard token.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else { throw Refused(why: "malformed request") }
        let key = context.uniqueIdentifier + ":" + token
        if ran.contains(key) { return true }
        // The content script's frame is still the page there.
        guard let asked = URL(string: frameURL), sameDocument(asked, page) else { throw Refused(why: "the tab has moved on to another page") }
        let status = context.permissionStatus(for: page)
        guard status == .grantedExplicitly || status == .grantedImplicitly else { throw Refused(why: "the extension hasn't been granted this site") }
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard accessible(relative, to: page, manifest: context.webExtension.manifest) else {
            throw Refused(why: "not among the manifest's web_accessible_resources for this site")
        }
        guard let url = file(relative, in: Extensions.folder(for: context.uniqueIdentifier)),
              let source = try? String(contentsOf: url, encoding: .utf8) else { throw Refused(why: "no such file in the extension") }
        guard let web = tab.built else { throw Refused(why: "the tab has no page loaded") }
        ran.insert(key)
        if ran.count > 1000 { ran.removeAll() }
        let address = "\(Extensions.scheme)://\(context.uniqueIdentifier)/\(relative)"
        // document.currentScript is the element while it runs, as for a
        // script that loaded: Language Reactor and Ambient light read their
        // settings from its attributes.
        let setUp = """
        (() => { const element = document.querySelector('script[data-search-page-script="\(token)"]');
          if (element) Object.defineProperty(document, "currentScript", { configurable: true, get: () => element }); })(); void 0
        """
        _ = await evaluate(setUp, in: web)
        _ = await evaluate(source + "\n;void 0\n//# sourceURL=" + address, in: web)
        _ = await evaluate("delete document.currentScript; void 0", in: web)
        return true
    }

    /// Evaluated in the page's own world; the error, if any.
    private static func evaluate(_ script: String, in web: WKWebView) async -> Error? {
        await withCheckedContinuation { done in
            web.evaluateJavaScript(script, in: nil, in: .page) { result in
                if case .failure(let error) = result { done.resume(returning: error) } else { done.resume(returning: nil) }
            }
        }
    }
}
