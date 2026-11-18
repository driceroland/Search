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
// The content script's shim notices its own script element refused and asks
// here, through a message handler that exists only in that extension's
// content-script world ("searchPageScript", in WebExtension-<id>): neither
// the page, nor the extension's own pages, nor another extension can reach
// it, and WebKit says which tab and frame the message came from. Run only if
// - the frame is a tab's top frame, the tab isn't held for a sign-in nor
//   on its way to another address, and the frame's document is an http(s)
//   page the extension has been granted;
// - the extension may run scripts there: it has `scripting`, or a content
//   script of its manifest is for that page;
// - the file is its own, a file inside its folder named by a normalized path
//   (no "." or ".." part, links resolved) that its manifest's
//   web_accessible_resources list for that page;
// then, in one evaluation in the page's own world, without a user gesture:
// first a check that the document there is still the one at that address
// (else nothing runs), then document.currentScript set to the element (the
// page's own descriptor put back in a microtask), then the file. Nothing
// else: no inline code, no other extension's file, no frame. Every refusal
// goes to the extension's error list.

@available(macOS 15.4, *)
@MainActor
enum ExtensionPageScript {
    static let handlerName = "searchPageScript"

    /// Tokens already run, per extension: a request asked twice runs once.
    private static var ran = Set<String>()

    struct Refused: LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    // MARK: - what may run

    /// The path as a list of decoded parts: no empty, "." or ".." part, no
    /// NUL, no backslash. Nil if it isn't one.
    nonisolated static func normalized(_ path: String) -> String? {
        guard let decoded = path.removingPercentEncoding else { return nil }
        var parts = decoded.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.first == "" { parts.removeFirst() }
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\0") || $0.contains("\\") })
        else { return nil }
        return parts.joined(separator: "/")
    }

    /// Whether a manifest's web_accessible_resources let a page at `page`
    /// load `path` (normalized, relative). MV2's list of globs is for every
    /// page; MV3's entries each name the pages they are for.
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
            if patterns(entry["matches"], cover: page) { return true }
        }
        return false
    }

    /// Whether any of these match patterns takes the page.
    nonisolated static func patterns(_ list: Any?, cover page: URL) -> Bool {
        for string in list as? [String] ?? [] {
            if string == "<all_urls>", ["http", "https"].contains(page.scheme?.lowercased() ?? "") { return true }
            if let pattern = try? WKWebExtension.MatchPattern(string: string), pattern.matches(page) { return true }
        }
        return false
    }

    /// May the extension put a script in this page at all: with `scripting`,
    /// or by a content script its manifest names for the page.
    nonisolated static func mayScript(_ page: URL, manifest: [String: Any], hasScripting: Bool) -> Bool {
        if hasScripting { return true }
        for entry in manifest["content_scripts"] as? [[String: Any]] ?? [] {
            if patterns(entry["matches"], cover: page), !patterns(entry["exclude_matches"], cover: page) { return true }
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

    /// The file a normalized path names inside the extension's folder,
    /// still inside once links are resolved, and a file.
    nonisolated static func file(_ relative: String, in folder: URL) -> URL? {
        let url = relative.split(separator: "/").reduce(folder) { $0.appendingPathComponent(String($1)) }
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

    /// The address without its fragment, as location.href reads it.
    nonisolated static func withoutFragment(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        return parts?.url?.absoluteString ?? url.absoluteString
    }

    /// What is evaluated: the check, the element, then the file. A source
    /// that starts in strict mode keeps it: its "use strict" goes first.
    nonisolated static func evaluation(source: String, expected: String, token: String) -> String {
        let strict = source.range(of: #"^\s*(?:(?://[^\n]*\n|/\*[\s\S]*?\*/)\s*)*(["'])use strict\1"#, options: .regularExpression) != nil
        let quoted = (try? JSONSerialization.data(withJSONObject: [expected], options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        let name = "search-page-script-" + token
        return (strict ? "\"use strict\";" : "") + """
        (() => {
          if (String(location.href).split("#")[0] !== \(quoted)) throw new Error("\(movedMarker)");
          let element = null;
          const take = (event) => { element = event.target; };
          document.addEventListener("\(name)", take, true);
          document.dispatchEvent(new Event("\(name)-ask"));
          document.removeEventListener("\(name)", take, true);
          const saved = Object.getOwnPropertyDescriptor(document, "currentScript");
          queueMicrotask(() => {
            try { if (saved) Object.defineProperty(document, "currentScript", saved); else delete document.currentScript; } catch (e) {}
          });
          if (element instanceof HTMLScriptElement && element.isConnected) {
            try { Object.defineProperty(document, "currentScript", { configurable: true, get: () => element }); } catch (e) {}
          }
        })();
        """ + source + "\n;void 0"
    }

    nonisolated static let movedMarker = "search: the page has moved on"

    // MARK: - the handler

    /// One per extension, in its content-script world (attached beside
    /// ExtensionWorkerRecovery's).
    final class Handler: NSObject, WKScriptMessageHandlerWithReply {
        let id: String
        let world: WKContentWorld

        init(id: String) {
            self.id = id
            world = .world(name: "WebExtension-" + id)
            super.init()
        }

        func attach(_ controller: WKUserContentController) {
            controller.addScriptMessageHandler(self, contentWorld: world, name: ExtensionPageScript.handlerName)
        }

        func detach(_ controller: WKUserContentController) {
            controller.removeScriptMessageHandler(forName: ExtensionPageScript.handlerName, contentWorld: world)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
            let body = message.body as? [String: Any] ?? [:]
            let path = body["path"] as? String ?? "", token = body["token"] as? String ?? ""
            let id = self.id
            Task { @MainActor in
                do {
                    let ran = try await ExtensionPageScript.run(path: path, token: token, from: message, extension: id)
                    replyHandler(["ran": ran], nil)
                } catch {
                    Extensions.shared.noteError("page script \(String(path.prefix(200))) not run — \(error.localizedDescription)", for: id)
                    replyHandler(["ran": false], nil)
                }
            }
        }
    }

    // MARK: - running it

    static func run(path: String, token: String, from message: WKScriptMessage, extension id: String) async throws -> Bool {
        guard let context = Extensions.shared.contexts[id], context.isLoaded else { throw Refused(why: "the extension isn't loaded") }
        guard message.frameInfo.isMainFrame else { throw Refused(why: "only a tab's top frame is supported") }
        guard let web = message.webView,
              let tab = Browsers.all.lazy.flatMap({ $0.tabs }).first(where: { $0.built === web }) else {
            throw Refused(why: "not asked from a tab")
        }
        guard tab.held == nil else { throw Refused(why: "the tab is held for a sign-in") }
        // The document the content script is in, as WebKit has it. A tab
        // still loading (content scripts run while it does) must be loading
        // that same document, not another address it is on its way to; and
        // the check the evaluation starts with holds it to that document as
        // it runs, whatever has happened since.
        guard let page = message.frameInfo.request.url, let scheme = page.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw Refused(why: "the frame isn't showing a web page")
        }
        guard let shown = web.url, withoutFragment(shown) == withoutFragment(page) else {
            throw Refused(why: web.isLoading ? "the tab is on its way to another page" : "the frame isn't the page the tab shows")
        }
        guard token.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else { throw Refused(why: "malformed request") }
        let key = id + ":" + token
        guard !ran.contains(key) else { return true }
        let status = context.permissionStatus(for: page)
        guard status == .grantedExplicitly || status == .grantedImplicitly else { throw Refused(why: "the extension hasn't been granted this site") }
        let manifest = context.webExtension.manifest
        let scripting = context.permissionStatus(for: WKWebExtension.Permission.scripting)
        guard mayScript(page, manifest: manifest, hasScripting: scripting == .grantedExplicitly || scripting == .grantedImplicitly) else {
            throw Refused(why: "it has neither scripting nor a content script for this site")
        }
        guard let relative = normalized(path) else { throw Refused(why: "not a plain path") }
        guard accessible(relative, to: page, manifest: manifest) else {
            throw Refused(why: "not among the manifest's web_accessible_resources for this site")
        }
        guard let url = file(relative, in: Extensions.folder(for: id)),
              let source = try? String(contentsOf: url, encoding: .utf8) else { throw Refused(why: "no such file in the extension") }
        // Without a user gesture: a page given one could open windows and
        // play sound as though you had clicked.
        let evaluate = NSSelectorFromString("_evaluateJavaScript:withSourceURL:inFrame:inContentWorld:withUserGesture:completionHandler:")
        guard web.responds(to: evaluate) else { throw Refused(why: "this version of WebKit can't run it without a user gesture") }
        ran.insert(key)
        if ran.count > 1000 { ran.removeAll() }
        let script = evaluation(source: source, expected: withoutFragment(page), token: token)
        let address = URL(string: "\(Extensions.scheme)://\(id)/\(relative)")
        typealias Evaluate = @convention(c) (AnyObject, Selector, NSString, NSURL?, WKFrameInfo?, WKContentWorld, Bool,
                                             @escaping @convention(block) (Any?, Error?) -> Void) -> Void
        let call = unsafeBitCast(web.method(for: evaluate), to: Evaluate.self)
        let error: Error? = await withCheckedContinuation { done in
            call(web, evaluate, script as NSString, address as NSURL?, nil, .page, false) { _, error in done.resume(returning: error) }
        }
        // The check refused it: another document is there now. Anything
        // else the script threw is the script's own, as a loaded script that
        // throws still fires load.
        if let error = error as NSError?,
           (error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription).contains(movedMarker) {
            ran.remove(key)
            throw Refused(why: "the page has moved on")
        }
        return true
    }
}
