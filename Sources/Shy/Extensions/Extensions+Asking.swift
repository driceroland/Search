import AppKit
import SwiftUI
import WebKit
import Combine

// Asking you: what an extension wants, in words, before it is added or gets more.
extension Extensions {
    /// What an extension was allowed, as it is written down and compared on
    /// every update: WebKit's permissions, the sites it reaches, and the
    /// APIs Shy answers for it (history, bookmarks…) — an update that
    /// adds any of them is asked about again.
    static func grants(_ found: WKWebExtension, in folder: URL) -> [String] {
        let added = Set((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".shy-added")))) as? [String] ?? [])
        let declared = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json")))) as? [String: Any])?["permissions"] as? [String] ?? []
        let ours = Set(Extensions.shyAnswered.map(\.0))
        var out = Set(found.requestedPermissions.map(\.rawValue).filter { !added.contains($0) })
        out.formUnion(found.allRequestedMatchPatterns.map { "site:" + $0.string })
        out.formUnion(declared.filter { ours.contains($0) && !added.contains($0) }.map { "shy:" + $0 })
        return out.sorted()
    }

    /// Extension pages, as a pattern names them: another extension's
    /// (chrome-extension://<its id>/*) or every one's. No extension is ever
    /// given them — not from its manifest, not asked for later — whatever
    /// the question said; its own pages are its own without asking.
    nonisolated static func reachesExtensions(_ pattern: WKWebExtension.MatchPattern) -> Bool {
        guard let scheme = pattern.scheme?.lowercased() else { return false }
        return [Extensions.scheme, Extensions.formerScheme, "webkit-extension"].contains(scheme)
    }

    /// Files on this Mac aren't an extension's to reach either, whatever its
    /// manifest names: Chrome keeps them from every extension until "Allow
    /// access to file URLs" is turned on for it, and Shy has no such
    /// switch. WebKit's <all_urls> leaves file: out; a pattern naming it
    /// (file:///*) would be granted with the rest.
    nonisolated static func reachesFiles(_ pattern: WKWebExtension.MatchPattern) -> Bool {
        pattern.scheme?.lowercased() == "file"
    }

    /// What no extension is given or asked about: extension pages and files.
    nonisolated static func withheld(_ pattern: WKWebExtension.MatchPattern) -> Bool {
        reachesExtensions(pattern) || reachesFiles(pattern)
    }

    /// The sites its manifest names, granted as it loads: never one for
    /// extension pages, another's or all of them, nor for files on this Mac
    /// (see `fence`, which is set after).
    static func grantSites(_ context: WKWebExtensionContext) {
        let patterns = context.webExtension.allRequestedMatchPatterns.filter { !withheld($0) }
        for pattern in patterns {
            // WebKit copies injected scripts per granted pattern. A wildcard
            // already covers its named hosts; keep schemes and paths unchanged.
            let covered = patterns.contains { other in
                other.string != pattern.string && other.scheme == pattern.scheme && other.path == pattern.path
                    && other.matches(pattern) && (!pattern.matches(other) || other.string < pattern.string)
            }
            guard !covered else { continue }
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
    }

    /// Other extensions' pages are never among "all sites" either: with
    /// chrome-extension registered as a scheme, WebKit counts them in
    /// <all_urls>, which Chrome doesn't, so they are refused outright. A
    /// refusal for all hosts doesn't outweigh a grant naming one — WebKit
    /// looks at those first — which is why none is ever made (see
    /// `reachesExtensions`). Set again after anything is granted.
    static func fence(_ context: WKWebExtensionContext) {
        // WebKit takes back any grant that covers what is refused here, so a
        // refusal of extension pages wipes a grant of <all_urls> the moment
        // it is made — permissions.request said yes, contains() says no, and
        // the extension (Figma's) waits forever. What <all_urls> means for
        // websites is kept as *://*/*, which the refusals don't touch.
        let everything = context.grantedPermissionMatchPatterns.keys.contains { $0.matchesAllURLs }
        defer {
            if everything, let web = try? WKWebExtension.MatchPattern(string: "*://*/*") {
                context.setPermissionStatus(.grantedExplicitly, for: web)
            }
        }
        for scheme in Set([Extensions.scheme, Extensions.formerScheme, "webkit-extension"]) {
            if let pages = try? WKWebExtension.MatchPattern(string: "\(scheme)://*/*") {
                context.setPermissionStatus(.deniedExplicitly, for: pages)
            }
        }
        // Nor files (see `reachesFiles`).
        for string in ["file:///*", "file://*/*"] {
            if let files = try? WKWebExtension.MatchPattern(string: string) {
                context.setPermissionStatus(.deniedExplicitly, for: files)
            }
        }
    }

    /// You let it into private tabs, by its id and off until you do, and its
    /// manifest doesn't refuse them ("incognito": "not_allowed"), which
    /// Chrome honours whatever was allowed. WebKit doesn't read that key.
    static func mayGoPrivate(_ context: WKWebExtensionContext, profile: UUID? = nil) -> Bool {
        Store.settings.bool(forKey: grantKey("private", context, profile: profile))
            && (context.webExtension.manifest["incognito"] as? String) != "not_allowed"
    }

    func setPrivate(_ id: String, _ on: Bool) {
        guard let context = contexts[id] else { return }
        Store.settings.set(on, forKey: Extensions.grantKey("private", id, profile))
        let allowed = Extensions.mayGoPrivate(context)
        guard context.hasAccessToPrivateData != allowed else { return }
        context.hasAccessToPrivateData = allowed
        // WebKit takes a tab's privacy from its window, and a window here
        // holds both kinds, so the extension is told of private tabs here:
        // opened when it is let in, closed when it is shut out, which also
        // ends the IDs it kept of them.
        if allowed {
            for browser in Browsers.all {
                for tab in visibleTabs(of: browser, for: context) where tab.shy {
                    context.didOpenTab(adapter(for: tab))
                }
            }
        } else {
            for case let adapter as ExtensionTab in context.openTabs where adapter.tab?.shy == true {
                context.didCloseTab(adapter, windowIsClosing: false)
            }
        }
        // Its side panel goes the same way where a private tab is in front:
        // through once it is let in, held back when it is shut out.
        for browser in Browsers.all { browser.sidePanelPrivacyChanged() }
        actionsChanged += 1
    }

    /// Its manifest asks to talk to apps on this Mac ("nativeMessaging"),
    /// required or optional, which WebKit's own grant — given to all, see
    /// `load` — doesn't say. Nor does the manifest WebKit reads: Shy
    /// writes nativeMessaging into every one for its own line
    /// (ExtensionShims.prepare), and notes it in .shy-added, so what it
    /// added there doesn't count as asked.
    static func asksForNative(_ context: WKWebExtensionContext) -> Bool {
        let folder = (Extensions.owner(of: context) ?? Extensions.shared).folder(for: context.uniqueIdentifier)
        let added = Set((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".shy-added")))) as? [String] ?? [])
        let required = context.webExtension.requestedPermissions.contains(.nativeMessaging) && !added.contains("nativeMessaging")
        return required || context.webExtension.optionalPermissions.contains(.nativeMessaging)
    }

    /// Whether this address is a page of an extension other than the one
    /// asking — which it never gets to see into.
    static func othersPage(_ url: URL?, for context: WKWebExtensionContext) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(),
              [Extensions.scheme, Extensions.formerScheme, "webkit-extension"].contains(scheme)
        else { return false }
        return url.host()?.lowercased() != context.uniqueIdentifier.lowercased()
    }

    /// Chrome's own APIs, which Shy answers itself, and what each lets an
    /// extension do.
    static let shyAnswered: [(String, String)] = [

        ("userScripts", "Run scripts you add to it on websites"), ("history", "Read and change your history"),

        ("bookmarks", "Read and change your bookmarks"), ("downloads", "Manage your downloads"),

        ("privacy", "Change your privacy settings"), ("browsingData", "Clear your browsing data"),

        ("management", "See your other extensions"), ("notifications", "Show notifications"),

        ("sessions", "See your recently closed tabs"), ("topSites", "See your most visited sites"),

        ("readingList", "Read and change your reading list"), ("downloads.open", "Open files it downloads"),

        ("desktopCapture", "Record your screen or a window, when you choose what to share"),

        ("tabCapture", "Record a tab, when you ask it to"),

        // Gated like the rest (ExtensionShims.gates), so named at install and
        // asked about again when an update adds one: identity alone runs a
        // sign-in out of sight with your cookies.
        ("identity", "Sign in to sites with your accounts"), ("search", "Search with your search engine"),

        ("idle", "See when you are away from your Mac"), ("power", "Keep your Mac awake"),

        ("tts", "Speak text aloud"), ("tabGroups", "See and change your tab groups"),
    ]

    /// What an extension wants, in words.
    static func describe(_ found: WKWebExtension, in folder: URL) -> [String] {
        var out: [String] = []
        // Leaving out what Shy itself added to the manifest.
        let added = Set((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".shy-added")))) as? [String] ?? [])
        let declared = Set(((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json")))) as? [String: Any])?["permissions"] as? [String] ?? [])
        let patterns = found.allRequestedMatchPatterns
        if patterns.contains(where: { $0.matchesAllHosts || $0.matchesAllURLs }) {
            out.append("Read and change everything on every website")
        } else if !patterns.isEmpty {
            let hosts = patterns.compactMap(\.host).filter { !$0.isEmpty }
            out.append("Read and change what's on " + (hosts.prefix(4).joined(separator: ", ")) + (hosts.count > 4 ? " and \(hosts.count - 4) more" : ""))
        }
        let words: [WKWebExtension.Permission: String] = [
            .tabs: "See your open tabs and their addresses",
            .cookies: "Read and change cookies",
            .webNavigation: "See where you go",
            .webRequest: "See the requests pages make",
            .declarativeNetRequest: "Block or change requests pages make",
            .clipboardWrite: "Write to the clipboard",
            .nativeMessaging: "Talk to apps on this Mac",
            .scripting: "Run scripts in pages",
        ]
        for (permission, sentence) in words where found.requestedPermissions.contains(permission) && !added.contains(permission.rawValue) {
            out.append(sentence)
        }
        // Chrome's own, which Shy answers itself.
        for (name, sentence) in Extensions.shyAnswered where declared.contains(name) { out.append(sentence) }
        return out
    }

    func ask(install name: String, wants: [String], icon: NSImage?, updating: Bool = false) async -> Bool {
        await ask(
            "Add “\(name)” to Shy?",
            detail: wants.isEmpty ? "It doesn't ask for anything special." : "It will be able to:\n• " + wants.joined(separator: "\n• "),
            icon: icon, yes: "Add Extension", no: "Cancel", updating: updating
        )
    }

    /// An extension asking, through permissions.request, for one of the
    /// permissions Shy answers itself.
    func ask(more names: String, context: WKWebExtensionContext) async -> Bool {
        await ask("asks for more access", detail: names, context: context)
    }

    /// Recording the screen: asked once, naming the extension; the Mac's own
    /// picker still asks what to share, every time.
    func ask(capture context: WKWebExtensionContext) async -> Bool {
        let name = context.webExtension.displayName ?? "An extension"
        return await ask(
            "“\(name)” wants to record your screen or a window.",
            detail: "macOS will ask what to share. Shy remembers your answer for \(name); Settings › Extensions takes it back.",
            icon: context.webExtension.icon(for: CGSize(width: 64, height: 64)), yes: "Continue", no: "Don't Allow")
    }

    func ask(_ question: String, detail: String, context: WKWebExtensionContext) async -> Bool {
        await ask(
            "\(context.webExtension.displayName ?? "An extension") \(question)",
            detail: detail, icon: context.webExtension.icon(for: CGSize(width: 64, height: 64)),
            yes: "Allow", no: "Don't Allow"
        )
    }

    /// One question at a time, as a sheet on the browser's window. An alert
    /// run modally would stop the whole browser — pages, downloads, every
    /// other extension — for as long as it waits, and an extension can ask
    /// when nobody is looking.
    func ask(_ title: String, detail: String, icon: NSImage?, yes: String, no: String, updating: Bool = false) async -> Bool {
        let before = question
        let task = Task { @MainActor [weak self] () -> Bool in
            _ = await before?.value
            self?.asked.append(title)
            if Store.testing, let answer = self?.answerForTests { return answer }
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            if let icon { alert.icon = icon }
            let confirm = alert.addButton(withTitle: yes)
            let cancel = alert.addButton(withTitle: no)
            var escape: Any?
            if updating {
                confirm.keyEquivalent = ""
                cancel.keyEquivalent = "\r"
                // Cancel keeps Escape too, as in Ask.sure(returnCancels:).
                escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.window === alert.window, event.keyCode == 53 else { return event }
                    cancel.performClick(nil)
                    return nil
                }
            }
            defer { if let escape { NSEvent.removeMonitor(escape) } }
            guard let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
                guard !updating else { return false }
                return alert.runModal() == .alertFirstButtonReturn
            }
            return await withCheckedContinuation { done in
                alert.beginSheetModal(for: window) { done.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
        question = task
        return await task.value
    }
}
