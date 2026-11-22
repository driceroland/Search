import Foundation
import UniformTypeIdentifiers
import WebKit

/// The pages an extension's manifest lists under "sandbox", served as Chrome
/// serves them: apart from the extension's origin, without its APIs or
/// storage, and allowed to eval, Manifest V3's one way to run code given as
/// text. Zotero Connector runs its translators so (#1236). WebKit ignores the
/// key, so they loaded as ordinary extension pages, where eval is refused.
/// The shim points the extension's frames on such a page here.
@available(macOS 15.4, *)
@MainActor
final class ExtensionSandbox: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "chrome-extension-sandbox"
    /// Chrome's for sandbox pages, as WebKit reads it: an opaque origin, and
    /// no script-src, the directive WebKit's extension modes strip
    /// 'unsafe-eval' and 'unsafe-inline' from, so eval and inline script are
    /// left to the page's own policy. No fetching: the extension's view lets
    /// its pages read the sites it was granted, cookies and all, and code a
    /// sandbox page is given must not do that itself. (A frame it navigates
    /// elsewhere has the reach of any site the extension frames.)
    nonisolated static let policy = "sandbox allow-scripts allow-forms allow-popups allow-modals; script-src-elem 'self' 'unsafe-inline'; script-src-attr 'unsafe-inline'; connect-src 'none'; child-src 'self'"

    let id: String
    let folder: URL
    let pages: Set<String>

    init(id: String, folder: URL, pages: Set<String>) {
        self.id = id
        self.folder = folder
        self.pages = pages
    }

    /// Put on each view Search makes for the extension's pages (a tab, a
    /// popup, the side panel, an offscreen document). Put on the controller's
    /// configuration before the controller was made, it was never asked
    /// (macOS 27.2).
    static func attach(_ configuration: WKWebViewConfiguration, for context: WKWebExtensionContext) {
        let manifest = context.webExtension.manifest
        guard let pages = sandboxPages(manifest), !pages.isEmpty,
              configuration.urlSchemeHandler(forURLScheme: scheme) == nil
        else { return }
        let id = context.uniqueIdentifier
        configuration.setURLSchemeHandler(ExtensionSandbox(id: id, folder: Extensions.folder(for: id), pages: pages), forURLScheme: scheme)
        // WebKit's Manifest V3 mode (2) strips 'unsafe-eval' from script-src
        // in every document of the view, the sandbox page's own policy
        // included (Zotero's asks for it); its Manifest V2 mode (1) keeps it.
        // WebKit since 322449@main applies the mode only to extension
        // schemes, and then this isn't needed. Private, so only where WebKit
        // has it, and only where mode 1 reads the extension's own pages'
        // policy as mode 2 would (mayLeaveEvalToFrames).
        if mayLeaveEvalToFrames(manifest), configuration.responds(to: NSSelectorFromString("_setContentSecurityPolicyModeForExtension:")) {
            configuration.setValue(1, forKey: "contentSecurityPolicyModeForExtension")
        }
    }

    /// A Manifest V3 extension whose pages' policy has nothing the two modes
    /// read differently: every directive they restrict allows only the
    /// package and WebAssembly, as Chrome requires; one policy, not several
    /// split by commas. WebKit's default policy qualifies. (On macOS 15.4's
    /// WebKit, mode 2 also drops 'wasm-unsafe-eval', which Chrome allows.)
    nonisolated static func mayLeaveEvalToFrames(_ manifest: [String: Any]) -> Bool {
        guard (manifest["manifest_version"] as? Int) == 3 else { return false }
        guard let given = manifest["content_security_policy"] else { return true }
        // One string, as Manifest V2 wrote it, is one WebKit may read either way.
        guard let policies = given as? [String: Any] else { return false }
        guard let pagesPolicy = policies["extension_pages"] else { return true }
        guard let text = pagesPolicy as? String, !text.contains(",") else { return false }
        let scripts: Set = ["script-src", "script-src-elem", "script-src-attr", "worker-src", "object-src", "default-src"]
        let allowed: Set = ["'self'", "'wasm-unsafe-eval'", "'none'"]
        return text.split(separator: ";").allSatisfy { directive in
            let words = directive.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
            guard let name = words.first, scripts.contains(name) else { return true }
            return words.dropFirst().allSatisfy(allowed.contains)
        }
    }

    /// The manifest's sandbox pages, as paths inside the package.
    nonisolated static func sandboxPages(_ manifest: [String: Any]) -> Set<String>? {
        guard let pages = (manifest["sandbox"] as? [String: Any])?["pages"] as? [String] else { return nil }
        return Set(pages.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }.filter { !$0.isEmpty })
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let (response, body) = serve(url, for: task.request.mainDocumentURL) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    /// One of the extension's files, asked for by one of its own pages; an
    /// HTML page only if the manifest lists it. Only the top document is
    /// known, so a website one of its pages frames can load the package's
    /// files from here (not read them: no CORS); never another extension's.
    func serve(_ url: URL, for document: URL?) -> (HTTPURLResponse, Data)? {
        guard url.scheme == Self.scheme, url.host() == id,
              let document, document.scheme == Extensions.scheme, document.host() == id,
              let file = ExtensionShims.inside(url.path(percentEncoded: false), of: folder),
              var body = try? Data(contentsOf: file)
        else { return nil }
        let script = ["js", "mjs"].contains(file.pathExtension.lowercased())
        let type = script ? "text/javascript; charset=utf-8" : UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if type == "text/html" {
            guard pages.contains(String(file.path.dropFirst(folder.standardizedFileURL.path.count + 1))) else { return nil }
            // A sandbox page has no extension APIs for Search's shim to fill in.
            if let html = String(data: body, encoding: .utf8) {
                body = Data(html.replacingOccurrences(of: "<script src=\"/\(ExtensionShims.file)\"></script>", with: "").utf8)
            }
        }
        let headers = [
            "Content-Type": type,
            "Content-Security-Policy": Self.policy,
            "X-Content-Type-Options": "nosniff",
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return nil }
        return (response, body)
    }
}
