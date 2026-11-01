import AppKit
import WebKit
import IOKit.pwr_mgt
import CryptoKit

// The Chrome APIs WebKit doesn't have, filled in by the browser itself.
//
// Safari's extension engine covers tabs, storage, scripting, request rules,
// cookies, menus, alarms and messaging. Chrome extensions also reach for
// bookmarks, history, downloads, the side panel, offscreen documents, tab
// groups and OAuth — and fall over when those are undefined.
//
// So when an extension is installed, a small script is put at the front of
// its background and of every page it ships: `chrome.bookmarks` and the rest
// are defined there, and every call becomes a native message to this app,
// which answers from its own bookmarks, history and downloads. To the
// extension it looks like Chrome. The files are changed after the store's
// signature has been checked, and only by adding.

@available(macOS 15.4, *)
@MainActor
enum ExtensionShims {
    /// The name native messages to the browser itself go to.
    static let application = "shy"
    nonisolated static let file = "shy-shim.js"
    /// Shy's passkey patch, put first in every script an extension runs in
    /// a page's own world (see Passkeys.swift, and `first` in the script).
    nonisolated static let passkeys = "shy-passkeys.js"
    /// The first line of a worker that already carries the shim.
    nonisolated static let marker = "/* Shy: Chrome APIs WebKit lacks, filled in (ExtensionShims.swift) */"
    nonisolated static let ender = "/* Shy: end of shim */"

    // MARK: - at install

    /// Written beside a prepared extension: which shim it carries. The same
    /// one needs nothing redone, which matters at launch — preparing reads
    /// every script and page an extension ships.
    nonisolated static let stamp = ".shy-shim"
    /// Raised when `prepare` changes what it does to a package, so that
    /// extensions prepared before are prepared again.
    nonisolated private static let preparation = "4"
    nonisolated static let version: String = {
        SHA256.hash(data: Data((script + PasskeyRelay.page + preparation).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + (Store.testing ? "-test" : "")
    }()

    /// `fresh`: a package just unpacked or copied in. What only Shy writes
    /// beside an extension — which permissions it added, which shim it
    /// carries — is Shy's to say, never the package's: anything by those
    /// names that came inside it goes before a word of it is read.
    nonisolated static func prepare(_ folder: URL, fresh: Bool = false, workerGeneration: Int = 0) throws {
        let files = FileManager.default
        if fresh {
            for name in [stamp, ".shy-added"] { try? files.removeItem(at: folder.appendingPathComponent(name)) }
        }
        let stampURL = folder.appendingPathComponent(stamp)
        let revision = version + "-worker-\(workerGeneration)"
        if (try? String(contentsOf: stampURL, encoding: .utf8)) == revision { return }
        defer { try? revision.write(to: stampURL, atomically: true, encoding: .utf8) }
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        else { throw Crx.Refused.unpack }

        let script = shim(for: folder).replacingOccurrences(of: "__SHY_WORKER_GENERATION__", with: String(workerGeneration))
        try script.write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try PasskeyRelay.page.write(to: folder.appendingPathComponent(passkeys), atomically: true, encoding: .utf8)

        // Native messaging is how the shim reaches the browser; user scripts
        // are carried out through WebKit's registered content scripts, which
        // need scripting. What is added is written down, so the extension is
        // described by what it asked for, not by what Shy gave it.
        var permissions = manifest["permissions"] as? [Any] ?? []
        let asked = Set(permissions.compactMap { $0 as? String })
        var added = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".shy-added")))) as? [String] ?? []
        for needed in ["nativeMessaging"] + (asked.contains("userScripts") ? ["scripting"] : []) where !asked.contains(needed) {
            permissions.append(needed)
            added.append(needed)
        }
        manifest["permissions"] = permissions
        if let data = try? JSONSerialization.data(withJSONObject: Array(Set(added)).sorted()) {
            try? data.write(to: folder.appendingPathComponent(".shy-added"))
        }

        // The background, whichever kind it is, gets the shim first. A
        // classic service worker gets it written at the top of its own file;
        // a module one imports it first, as its imports run before anything
        // written above them.
        if var background = manifest["background"] as? [String: Any] {
            // A manifest is not a way out of its own package: a worker path
            // that resolves outside the folder, or is a link, is left alone.
            if let worker = background["service_worker"] as? String { unlink(worker, in: folder) }
            if let worker = background["service_worker"] as? String,
               let path = inside(worker, of: folder) {
                if var source = try? String(contentsOf: path, encoding: .utf8) {
                    // Already carrying one: take the old one off, so a newer
                    // Shy puts its newer shim in its place.
                    if source.hasPrefix(marker), let end = source.range(of: ender) {
                        source = String(source[end.upperBound...]).trimmingPrefix("\n").description
                    }
                    // A copy from before there was an end marker: it ends
                    // where its function does, the first `})();` that
                    // starts a line.
                    while source.hasPrefix(marker), let end = source.range(of: "\n})();\n") {
                        source = String(source[end.upperBound...])
                    }
                    let first = "import \"/\(file)\";\n"
                    while source.hasPrefix(first) { source.removeFirst(first.count) }
                    let module = (background["type"] as? String) == "module"
                    try (module ? first + source : marker + "\n" + script + "\n" + ender + "\n" + source).write(to: path, atomically: true, encoding: .utf8)
                }
            }
            // Scripts, alone or beside a worker — WebKit runs them as a page
            // when a manifest names both.
            if var scripts = background["scripts"] as? [String] {
                if scripts.first != file { scripts.insert(file, at: 0) }
                background["scripts"] = scripts
            }
            manifest["background"] = background
        }

        // Content scripts too — there only Chrome's behaviour is mended. One
        // that runs in the page's own world has Shy's passkey patch before
        // it: a password manager's there keeps a reference to
        // navigator.credentials as it finds it, and that has to be Shy's,
        // not WebKit's (see Passkeys.swift).
        if let entries = manifest["content_scripts"] as? [[String: Any]] {
            manifest["content_scripts"] = entries.map { entry -> [String: Any] in
                var entry = entry
                if var js = entry["js"] as? [String] {
                    if !js.contains(file) { js.insert(file, at: 0) }
                    if (entry["world"] as? String)?.uppercased() == "MAIN", !js.contains(passkeys) { js.insert(passkeys, at: 0) }
                    entry["js"] = js
                }
                return entry
            }
        }

        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: manifestURL, options: .atomic)

        // Every page it ships — popup, options, background page, side panel —
        // and scripts a content script may insert into a website. WebKit
        // decodes those in the site's encoding unless the resource says
        // otherwise: Backpack's Unicode regexes break on a windows-1252
        // page. A UTF-8 signature keeps the script's text independent of
        // the page without changing the page's own encoding or scripts.
        let signature = Data([0xEF, 0xBB, 0xBF])
        let walker = files.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  inside(String(url.path.dropFirst(folder.path.count)), of: folder) != nil
            else { continue }
            if ["js", "mjs"].contains(url.pathExtension.lowercased()) {
                guard let bytes = try? Data(contentsOf: url),
                      !bytes.starts(with: signature), bytes.contains(where: { $0 >= 0x80 }),
                      String(data: bytes, encoding: .utf8) != nil,
                      // A hashbang must stay at the very first character.
                      !bytes.starts(with: [0x23, 0x21])
                else { continue }
                // As every other rewrite here: one that fails leaves the
                // file as it was, and the stamp is still written (see the
                // defer above), so it isn't tried again at every launch.
                try? (signature + bytes).write(to: url, options: .atomic)
                continue
            }
            guard ["html", "htm"].contains(url.pathExtension.lowercased()),
                  var html = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            if let chained = chainModules(html, page: url, folder: folder) {
                html = chained
                try? html.write(to: url, atomically: true, encoding: .utf8)
            }
            guard !html.contains(file) else { continue }
            let tag = "<script src=\"/\(file)\"></script>"
            if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                html.insert(contentsOf: tag, at: head.upperBound)
            } else {
                html = tag + html
            }
            try? html.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// A page's module scripts, two or more of them with one that awaits,
    /// made one module that imports them in their order: nil when there is
    /// nothing to do. Chrome waits for a module still at a top-level await
    /// before running a later tag's module that imports it; WebKit runs the
    /// later one at once, which then reads the first one's exports before
    /// they exist ("Cannot access 'd' before initialization"). Vimium C's
    /// options page lists five, the second awaiting its translations, and
    /// stayed blank. Inside one module's imports WebKit does wait, so the
    /// tags become one, in a file of Shy's beside the page (named with
    /// `search-` like the shim). The modules themselves are not touched. Only
    /// plain tags: one marked async, or a src that isn't the package's own
    /// file, leaves the page as it is.
    nonisolated static func chainModules(_ html: String, page: URL, folder: URL) -> String? {
        let tags = try! NSRegularExpression(pattern: #"<script\b([^>]*)>\s*</script>"#, options: [.caseInsensitive])
        let module = try! NSRegularExpression(pattern: #"\btype\s*=\s*["']?module\b"#, options: [.caseInsensitive])
        let source = try! NSRegularExpression(pattern: #"\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, options: [.caseInsensitive])
        let async = try! NSRegularExpression(pattern: #"(^|\s)async(\s|=|$)"#, options: [.caseInsensitive])
        let whole = NSRange(html.startIndex..., in: html)
        var found: [(range: Range<String.Index>, attributes: String, src: String)] = []
        for match in tags.matches(in: html, range: whole) {
            guard let range = Range(match.range, in: html), let inner = Range(match.range(at: 1), in: html) else { continue }
            let attributes = String(html[inner])
            let span = NSRange(attributes.startIndex..., in: attributes)
            guard module.firstMatch(in: attributes, range: span) != nil else { continue }
            guard async.firstMatch(in: attributes, range: span) == nil,
                  let named = source.firstMatch(in: attributes, range: span),
                  let src = (1...3).lazy.compactMap({ Range(named.range(at: $0), in: attributes) }).first.map({ String(attributes[$0]) }),
                  !src.isEmpty, !src.contains(":"), !src.hasPrefix("//"), !src.contains(where: \.isNewline)
            else { return nil }
            found.append((range, attributes, src))
        }
        guard found.count >= 2 else { return nil }
        // The package's own files, and one of them awaiting at all: without
        // an await, every module has run by the time the next tag's does.
        let directory = page.deletingLastPathComponent()
        let root = folder.standardizedFileURL.path + "/"
        var awaits = false
        for entry in found {
            let path = entry.src.split(separator: "?").first.map(String.init) ?? entry.src
            let file = (path.hasPrefix("/") ? folder.appendingPathComponent(String(path.dropFirst())) : directory.appendingPathComponent(path)).standardizedFileURL
            guard file.path.hasPrefix(root), let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            if text.range(of: #"\bawait\b"#, options: .regularExpression) != nil { awaits = true }
        }
        guard awaits else { return nil }
        let name = "shy-modules-" + page.deletingPathExtension().lastPathComponent + ".js"
        let imports = found.map { entry -> String in
            let spec = entry.src.hasPrefix("/") || entry.src.hasPrefix("./") || entry.src.hasPrefix("../") ? entry.src : "./" + entry.src
            return "import \"\(spec.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\";"
        }
        do {
            try ("// Shy: this page's module scripts, in their order (ExtensionShims.chainModules).\n" + imports.joined(separator: "\n") + "\n")
                .write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        } catch { return nil }
        // The first tag, its other attributes kept (blocking="render"), now
        // naming the one module; the others gone.
        var html = html
        for (index, entry) in found.enumerated().reversed() {
            if index == 0 {
                let span = NSRange(entry.attributes.startIndex..., in: entry.attributes)
                let attributes = source.stringByReplacingMatches(in: entry.attributes, range: span, withTemplate: NSRegularExpression.escapedTemplate(for: "src=\"\(name)\""))
                html.replaceSubrange(entry.range, with: "<script\(attributes)></script>")
            } else {
                html.removeSubrange(entry.range)
            }
        }
        return html
    }

    /// A worker that is a link to another file of its own package
    /// (StopTheMadness ships `background-143.js` → `background.js`) is made
    /// a copy of that file, so it can carry the shim. A link that leads out
    /// of the package is left as it is, and so left alone.
    nonisolated private static func unlink(_ name: String, in folder: URL) {
        let path = folder.appendingPathComponent(name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).standardizedFileURL
        guard path.path.hasPrefix(folder.standardizedFileURL.path + "/"),
              (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        else { return }
        let root = folder.resolvingSymlinksInPath().path
        let parent = path.deletingLastPathComponent().resolvingSymlinksInPath().path
        let target = path.resolvingSymlinksInPath()
        guard parent == root || parent.hasPrefix(root + "/"),
              target.path.hasPrefix(root + "/"),
              (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let data = try? Data(contentsOf: target)
        else { return }
        try? FileManager.default.removeItem(at: path)
        try? data.write(to: path)
    }

    /// A path a package names, resolved and kept inside the folder it came
    /// in: `..` in a manifest is not a way out of the package. Nor is a
    /// symbolic link, which a folder install keeps as it is: the worker is
    /// read through it and written back over it as a regular file, so a
    /// link to a file elsewhere would put that file's bytes in the package.
    /// A folder on the way that is a link is caught by where it resolves.
    nonisolated private static func inside(_ name: String, of folder: URL) -> URL? {
        let path = folder.appendingPathComponent(name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).standardizedFileURL
        guard path.path.hasPrefix(folder.standardizedFileURL.path + "/"),
              (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              path.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
        else { return nil }
        return path
    }

    /// The shim as this extension gets it: with the events its code mentions
    /// — `chrome.tabs.onUpdated`, `e.runtime.onInstalled` — so its worker
    /// can take their listeners late (see the end of the script).
    nonisolated static func shim(for folder: URL) -> String {
        var found = Set<String>()
        let pattern = try! NSRegularExpression(pattern: #"\.([a-zA-Z]+)\.(on[A-Z][A-Za-z]+)\b"#)
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "js", url.lastPathComponent != file,
                  var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // Not the shim's own words, in a worker that already carries it.
            if text.hasPrefix(marker), let end = text.range(of: ender) { text = String(text[end.upperBound...]) }
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text) else { continue }
                found.insert("\(text[a]).\(text[b])")
            }
        }
        let list = (try? JSONSerialization.data(withJSONObject: found.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        // And the scripts it ships, so its worker can be told at once that
        // one isn't there (see importScripts in the script).
        var scripts: [String] = []
        let all = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = all?.nextObject() as? URL {
            guard url.pathExtension == "js" else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count))
            // An empty one is marked: there is nothing to run in it.
            let empty = ((try? String(contentsOf: url, encoding: .utf8)) ?? "x").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            scripts.append((empty ? "-" : "") + path)
        }
        let shipped = (try? JSONSerialization.data(withJSONObject: scripts.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return script.replacingOccurrences(of: "__SHY_EVENTS__", with: list)
            .replacingOccurrences(of: "__SHY_SCRIPTS__", with: shipped)
            .replacingOccurrences(of: "__SHY_CHROME__", with: Crx.chromeVersion)
            .replacingOccurrences(of: "__SHY_VERBOSE__", with: Store.testing ? "true" : "false")
    }

    /// Defines only what is missing, so the day WebKit implements an API,
    /// WebKit's is the one used.
    nonisolated static let script = Scripts.load("shim")

    // MARK: - answering

    /// Remembered per extension: the side panel it set, and whether its
    /// button should open it.
    static var panelPath: [String: String] = [:]
    static var panelOnClick: Set<String> = []
    /// Turned off for the whole window (setOptions enabled: false).
    static var panelOff: Set<String> = []
    /// What setOptions said for one tab, by the extension's tab id.
    static var panelTabs: [String: [Int: (path: String?, enabled: Bool?)]] = [:]
    /// One voice for every extension that reads aloud.
    static let speaker = NSSpeechSynthesizer()

    static func answer(_ message: Any, from context: WKWebExtensionContext, owner: Extensions) async throws -> Any? {
        guard let body = message as? [String: Any], let api = body["api"] as? String else {
            return ["error": "Not a Shy message"]
        }
        let args = body["args"] as? [Any] ?? []
        do {
            return ["value": try await run(api, args, context: context, owner: owner) ?? NSNull()]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    struct Unsupported: LocalizedError {
        let what: String
        var errorDescription: String? { what }
    }

    /// What a part of `run` answers for a call it does not know, as opposed
    /// to nil, which is an answer.
    struct Unhandled {}

    /// The families whose answers leave the extension's own origin: what the
    /// browser knows about the person using it. WebKit keeps no permission
    /// object for them, they are the APIs this shim exists to supply, so the
    /// gate reads the names the extension's own manifest asked for.
    private static let gates: [String: String] = [
        "bookmarks": "bookmarks",
        "history": "history",
        "downloads": "downloads",
        "sessions": "sessions",
        "topSites": "topSites",
        "browsingData": "browsingData",
        "readingList": "readingList",
        "userScripts": "userScripts",
        "identity": "identity",
        "search": "search",
        "notifications": "notifications",
        "idle": "idle",
        "power": "power",
        "tts": "tts",
        "tabGroups": "tabGroups",
    ]

    /// What this extension asked for: the names in its manifest and any
    /// optional ones granted since. The checks inside the shim are a
    /// courtesy to honest code, the shim runs beside the extension's own,
    /// so the one that counts is here. The manifest is the one WebKit
    /// already holds, not the file read again on every call.
    static func allowed(_ id: String, context: WKWebExtensionContext, profile: UUID? = nil) -> Set<String> {
        let asked = (context.webExtension.manifest["permissions"] as? [Any] ?? []).compactMap { $0 as? String }
        return Set(asked + (Store.settings.stringArray(forKey: Extensions.grantKey("granted", context, profile: profile)) ?? []))
    }

    private static func run(_ api: String, _ args: [Any], context: WKWebExtensionContext, owner: Extensions) async throws -> Any? {
        guard let browser = owner.browser else { throw Unsupported(what: "No browser window") }
        let first = args.first
        let id = context.uniqueIdentifier

        if api.hasPrefix("setting.") {
            // A browser setting (chrome.privacy…) belongs to the family its
            // name starts with, and only an extension that asked for that
            // family may read or change it, as in Chrome.
            let name = api.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let family = String(name.prefix(while: { $0 != "." }))
            guard !family.isEmpty, allowed(id, context: context).contains(family) else {
                throw Unsupported(what: "The extension never asked for \u{201C}\(family)\u{201D}")
            }
            return setting(api, first as? [String: Any] ?? [:], extension: id, owner: owner)
        }

        // What leaves this app is answered here, not in the injected script:
        // the shim runs beside the extension's own code, so its checks stop
        // only the honest. A family this extension never asked for is an
        // error, the way Chrome answers a call to an API it lacks.
        // `tabs.describe` is the one call inside a family WebKit does own
        // where the permission guards reading a tab rather than moving or
        // selecting it. WebKit keeps that permission, optional grants
        // included, so it is asked.
        if api == "tabs.describe", !context.hasPermission(.tabs) {
            throw Unsupported(what: "The extension never asked for \u{201C}tabs\u{201D}")
        }
        if let needed = gates[String(api.prefix(while: { $0 != "." }))], !allowed(id, context: context).contains(needed) {
            throw Unsupported(what: "The extension never asked for \u{201C}\(needed)\u{201D}")
        }

        let parts = [runData, runTabs, runWorker, runSystem]
        for part in parts {
            let value = try await part(api, args, context, owner, browser)
            if !(value is Unhandled) { return value }
        }
        throw Unsupported(what: "\(api) isn't available in Shy")
    }

    // MARK: - the side panel

    /// A function sent by an extension page inside a website's frame cannot
    /// survive the JSON message to its worker. Write it as a file for WebKit's
    /// scripting API, with its JSON arguments and final result intact.
    static func scriptingFile(_ function: String, arguments: [Any], in folder: URL) throws -> String {
        // A megabyte of source at most: a page gone wrong can't fill the
        // extension's folder with big files (Security).
        guard !function.isEmpty, function.utf8.count <= 1_000_000, JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments),
              let args = String(data: data, encoding: .utf8)
        else { throw Unsupported(what: "Invalid script function or arguments") }
        let source = "(\(function))(...\(args))\n"
        let name = "script-" + SHA256.hash(data: Data(source.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + ".js"
        let dir = folder.appendingPathComponent("_shy", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try source.write(to: url, atomically: true, encoding: .utf8) }
        for old in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where old.lastPathComponent.hasPrefix("script-") && old != url {
            let age = (try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? 0
            if age > 60 { try? FileManager.default.removeItem(at: old) }
        }
        return "_shy/" + name
    }

    /// A user script as a file WebKit can inject: its code — inline, or read
    /// from the extension's own files — inside a block that leaves at once
    /// on a page its globs rule out and, for Chrome's USER_SCRIPT world,
    /// gives the code a `chrome` whose messages are marked as a user
    /// script's. Named by what is in it, so a changed script is a new file
    /// and never a stale one WebKit has already read.
    static func userScriptFile(_ script: [String: Any], in folder: URL) throws -> String {
        let json = { (value: Any) in
            (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        var code = ""
        for source in script["js"] as? [[String: Any]] ?? [] {
            if let inline = source["code"] as? String {
                code += inline + "\n;\n"
            } else if let file = source["file"] as? String,
                      // One of the extension's own files, and nothing outside
                      // its folder: a name is resolved before it is read.
                      let path = inside(file, of: folder),
                      let text = try? String(contentsOf: path, encoding: .utf8) {
                code += text + "\n;\n"
            }
        }
        let userWorld = (script["world"] as? String) != "MAIN"
        let prelude = #"""
          const chrome = (() => {
            const runtime = globalThis.chrome.runtime;
            return { runtime: {
              id: runtime.id, getURL: (path) => runtime.getURL(path), get lastError() { return runtime.lastError; },
              sendMessage: (message, ...rest) => runtime.sendMessage({ __shyUserScript: true, message }, ...rest.filter((r) => typeof r === "function" || (r && typeof r === "object"))),
              connect: (info) => runtime.connect({ ...(info || {}), name: "shy-us:" + ((info && info.name) || "") }),
            } };
          })();
          const browser = chrome;
        """#
        let text = #"""
        /* Shy: a user script (chrome.userScripts) */
        shy_user_script: {
          const __shyHref = location.href;
          const __shyGlob = (g) => new RegExp("^" + g.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$");
          const __shyIn = \#(json(script["includeGlobs"] ?? [])), __shyOut = \#(json(script["excludeGlobs"] ?? []));
          if ((__shyIn.length && !__shyIn.some((g) => __shyGlob(g).test(__shyHref))) || __shyOut.some((g) => __shyGlob(g).test(__shyHref))) break shy_user_script;
        \#(userWorld ? prelude : "")
        \#(code)
        }
        """#
        let name = "us-" + SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + ".js"
        let dir = folder.appendingPathComponent("_shy", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try text.write(to: url, atomically: true, encoding: .utf8) }
        return "_shy/" + name
    }

    /// Popups extensions set for their buttons: per tab, or "*" for all.
    static var popups: [String: [String: String]] = [:]
    /// The page an extension's downloads.download goes through: the tab in
    /// front, or another of yours, never a private tab — a download goes
    /// with the sign-ins of the page it's made through, and a private tab's
    /// are its own, whatever the extension may see.
    static func downloadPage(active: Tab?, tabs: [Tab]) -> WKWebView? {
        ([active].compactMap { $0 } + tabs).filter { !$0.shy }.lazy.compactMap(\.built).first
    }

    /// Downloads an extension asked for, by address, until they land; then
    /// the files they became, which are the only ones it may open.
    static var askedDownloads: [URL: String] = [:]
    static var ownDownloads: [String: Set<String>] = [:]

    /// Keep-awake assertions, one per extension that asked.
    static var awake: [String: IOPMAssertionID] = [:]

    /// chrome.privacy and chrome.proxy: what each extension set, kept across
    /// launches as Chrome keeps it. Shy acts on one of them — an
    /// extension turning the browser's own offer to save passwords off,
    /// which is how every password manager asks Chrome to step aside.
    private static func setting(_ api: String, _ details: [String: Any], extension id: String, owner: Extensions) -> Any? {
        let parts = api.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let name = parts[1]
        var mine = Extensions.settings(for: id)
        switch parts[0] {
        case "setting.set":
            mine[name] = details["value"]
        case "setting.clear":
            mine[name] = nil
        default:
            let value = mine[name] ?? defaultSetting(name, owner: owner)
            return ["value": value ?? NSNull(), "levelOfControl": mine[name] != nil ? "controlled_by_this_extension" : "controllable_by_this_extension"]
        }
        Extensions.setSettings(mine, for: id)
        owner.objectWillChange.send()
        return nil
    }

    private static func defaultSetting(_ name: String, owner: Extensions) -> Any? {
        switch name {
        case "privacy.services.passwordSavingEnabled": return owner.browser?.prefs.savesPasswords ?? true
        case "privacy.network.webRTCIPHandlingPolicy": return "default"
        case "privacy.websites.doNotTrackEnabled", "privacy.websites.adMeasurementEnabled",
             "privacy.websites.fledgeEnabled", "privacy.websites.topicsEnabled",
             "privacy.services.safeBrowsingExtendedReportingEnabled": return false
        case "proxy.settings": return ["mode": "system"]
        default: return true
        }
    }


    static func defaultPanel(_ context: WKWebExtensionContext) -> String? {
        (context.webExtension.manifest["side_panel"] as? [String: Any])?["default_path"] as? String
    }

    /// One of the extension's own pages, from the path it gave: resolved
    /// rather than appended, since a path can carry a query (Claude's side
    /// panel names its tab, sidepanel.html?tabId=…), which appended would be
    /// escaped into the file's name. Never anywhere but inside the
    /// extension: a full address given as a "path" is refused.
    static func page(_ path: String, in context: WKWebExtensionContext) -> URL? {
        let base = context.baseURL
        guard let url = URL(string: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host
        else { return nil }
        return url
    }

    /// The extension's button, for one that asked for its panel on a
    /// press (openPanelOnActionClick): its panel up, or down again.
    static func openPanel(_ context: WKWebExtensionContext, owner: Extensions) {
        let id = context.uniqueIdentifier
        guard !panelOff.contains(id), let path = panelPath[id] ?? defaultPanel(context) else { return }
        // Resolved, not appended: a path can carry a query — Claude's names
        // the tab its panel is for, sidepanel.html?tabId=… — which appended
        // would be escaped into the file's name.
        guard let url = ExtensionShims.page(path, in: context) else { return }
        // In the side panel; a tab of its own if the panel can't be made,
        // as before there was a panel to put it in. Beside a private tab
        // this extension may not see, the button does nothing.
        guard let browser = owner.browser else { return }
        if browser.toggleSidePanel(context, url: url) == .noPanel {
            browser.open(url, foreground: true)
        }
    }

}
