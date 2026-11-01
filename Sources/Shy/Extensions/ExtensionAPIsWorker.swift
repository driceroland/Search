import AppKit
import WebKit

// An extension's own machinery: its worker, its pages, its scripts and the permissions it holds.
// Part of the Chrome APIs Shy answers itself (ExtensionShims.answer); each case
// is one call, and a call this part does not know is left for the others.

@available(macOS 15.4, *)
@MainActor
extension ExtensionShims {
    static func runWorker(_ api: String, _ args: [Any], _ context: WKWebExtensionContext, _ owner: Extensions, _ browser: Browser) async throws -> Any? {
        let first = args.first
        let id = context.uniqueIdentifier
        switch api {
        // MARK: offscreen — a page with a DOM for a worker that has none
        // MARK: capture — a stream id for the worker's chooseDesktopMedia
        case "capture.grant":
            return await ExtensionCapture.shared.grant(for: context)

        case "offscreen.createDocument":
            guard let path = (first as? [String: Any])?["url"] as? String
            else { throw Unsupported(what: "No page for the offscreen document") }
            let reasons = (first as? [String: Any])?["reasons"] as? [String] ?? []
            try await ExtensionOffscreen.create(path, reasons: reasons, for: context)
            return nil
        case "offscreen.closeDocument":
            ExtensionOffscreen.close(for: id)
            return nil
        case "offscreen.hasDocument":
            return ExtensionOffscreen.hasDocument(for: id)
        case "offscreen.sendMessage":
            guard args.count == 3, let token = first as? String,
                  let sender = args[2] as? [String: Any] else { return ["handled": false] }
            return try await ExtensionOffscreen.send(args[1], sender: sender, token: token, for: id)

        // MARK: the worker, up before a page talks to it
        case "background.observe":
            guard owner.contexts[id] === context, context.isLoaded else { return nil }
            return await ExtensionWorkerRecovery.shared.observe(id, generation: first as? Int ?? 0, token: args.dropFirst().first as? String ?? "")
        case "background.unobserve":
            guard owner.contexts[id] === context else { return nil }
            ExtensionWorkerRecovery.shared.cancel(id, token: first as? String ?? "")
            return nil
        case "background.wake":
            guard context.webExtension.hasBackgroundContent else { return nil }
            // WebKit sometimes fails to start a worker again after unloading
            // it, and then never tries again: every message waits for ever.
            // Tried twice more, then the extension is taken up afresh.
            for attempt in 0..<3 {
                // WebKit never calls back after some failed starts; eight
                // seconds without an answer counts as a failure.
                let error: Error? = await withCheckedContinuation { done in
                    var finished = false
                    let finish: (Error?) -> Void = { result in
                        guard !finished else { return }
                        finished = true
                        done.resume(returning: result)
                    }
                    context.loadBackgroundContent { error in MainActor.assumeIsolated { finish(error) } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish(Unsupported(what: "no answer from WebKit")) }
                }
                guard error != nil else { return nil }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(400)) }
            }
            owner.revive(id, because: "its worker wouldn't start")
            return nil
        // Whether this extension was loaded before in this run of the
        // browser — an "install" then is really a restart (see the shim).
        case "background.loadedBefore":
            return owner.loadedBefore.contains(id)
        // A page found the worker gone though WebKit believes it runs (see
        // the shim's ping).
        case "background.revive":
            return owner.revive(id, because: "its worker stopped answering")

        // MARK: what went wrong inside
        case "debug.error":
            owner.noteError(first as? String ?? "?", for: id)
            return nil
        case "memory.rulesBuilt":
            Trim.rulesBuilt()
            return nil

        // MARK: its own pages, for clients.matchAll() (see the shim)
        case "clients.pages":
            var pages: [[String: Any]] = []
            if let popup = ExtensionPopup.shared.client(of: id) { pages.append(popup) }
            for tab in browser.tabs where owner.seen(tab, for: context) {
                guard let web = tab.built, let url = web.url, Browser.extensionHost(of: url) == id else { continue }
                let shown = tab.id == browser.activeID && web.window?.occlusionState.contains(.visible) == true
                pages.append(["id": tab.id.uuidString, "url": url.absoluteString, "visible": shown, "focused": shown && web.window?.isKeyWindow == true])
            }
            // Its offscreen document too, as Chrome lists it.
            if let url = ExtensionOffscreen.url(for: id) { pages.append(["id": "offscreen", "url": url.absoluteString, "visible": false, "focused": false]) }
            return pages

        // MARK: the button's popup
        case "action.popup":
            let path = first as? String ?? ""
            let index = args.dropFirst().first as? Int ?? -1
            let visible = owner.visibleTabs(for: context)
            if index >= 0, visible.indices.contains(index) {
                popups[id, default: [:]][visible[index].id.uuidString] = path
            } else {
                popups[id, default: [:]]["*"] = path
                popups[id] = popups[id]?.filter { $0.key == "*" }
            }
            return nil

        // MARK: script injection and user scripts
        case "scripting.file":
            return try scriptingFile(first as? String ?? "", arguments: args.dropFirst().first as? [Any] ?? [], in: owner.folder(for: id))
        case "userScripts.file":
            return try userScriptFile(first as? [String: Any] ?? [:], in: owner.folder(for: id))
        case "userScripts.list":
            return (try? JSONSerialization.jsonObject(with: Data(contentsOf: owner.folder(for: id).appendingPathComponent("_shy/userscripts.json")))) ?? []
        case "userScripts.save":
            let folder = owner.folder(for: id).appendingPathComponent("_shy", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let scripts = first as? [[String: Any]] ?? []
            try JSONSerialization.data(withJSONObject: scripts).write(to: folder.appendingPathComponent("userscripts.json"), options: .atomic)
            // Files no saved script is written in any more, once a moment
            // has passed — one being injected right now is left alone.
            let keep = Set(scripts.compactMap { try? userScriptFile($0, in: owner.folder(for: id)) }.map { URL(fileURLWithPath: $0).lastPathComponent })
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where file.lastPathComponent.hasPrefix("us-") && !keep.contains(file.lastPathComponent) {
                let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? 999
                if age > 60 { try? FileManager.default.removeItem(at: file) }
            }
            return nil
        case "userScripts.world", "userScripts.worlds":
            let url = owner.folder(for: id).appendingPathComponent("_shy/worlds.json")
            var worlds = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [[String: Any]] ?? []
            if api == "userScripts.worlds" { return worlds }
            let props = first as? [String: Any] ?? [:]
            let world = props["worldId"] as? String ?? ""
            worlds.removeAll { ($0["worldId"] as? String ?? "") == world }
            if props["reset"] as? Bool != true { worlds.append(props) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: worlds).write(to: url, options: .atomic)
            return nil

        // MARK: permissions Shy grants itself
        case "permissions.granted":
            return Store.settings.stringArray(forKey: Extensions.grantKey("granted", context, profile: owner.profile)) ?? []
        case "permissions.request":
            let wanted = (first as? [String]) ?? []
            // As in Chrome: only what the manifest named, as a permission or
            // an optional one. What was agreed to at install still describes
            // the extension; it can't ask later for something it never named.
            let manifest = context.webExtension.manifest
            let named = Set(((manifest["permissions"] as? [Any] ?? []) + (manifest["optional_permissions"] as? [Any] ?? [])).compactMap { $0 as? String })
            guard wanted.allSatisfy(named.contains) else {
                throw Unsupported(what: "Only permissions specified in the manifest may be requested.")
            }
            // Those Chrome grants without a word, having nothing to warn of.
            let silent: Set<String> = ["tabGroups", "sidePanel", "offscreen", "idle", "power", "fontSettings", "search",
                                       "system.cpu", "system.memory", "system.display", "favicon"]
            let names = wanted.map { $0.replacingOccurrences(of: ".", with: " ") }.joined(separator: ", ")
            let yes = wanted.allSatisfy(silent.contains) ? true : await owner.ask(more: names, context: context)
            guard yes else { return false }
            let had = Store.settings.stringArray(forKey: Extensions.grantKey("granted", context, profile: owner.profile)) ?? []
            Store.settings.set(Array(Set(had + wanted)).sorted(), forKey: Extensions.grantKey("granted", context, profile: owner.profile))
            return true
        case "permissions.afterClick":
            // permissions.request for WebKit's own permissions and sites,
            // made from a click on the extension's button whose moment
            // WebKit lost while the shim filled in the tab it was given
            // (see `mend`). Only within seconds of that click, once, and
            // only what the manifest names, asked as WebKit would ask it.
            // A click or key in one of the extension's own pages counts too
            // (its options page in a tab, its popup): Chrome treats that as
            // the user gesture, and WebKit loses it as soon as the page
            // awaits anything before calling permissions.request.
            let when = [Extensions.clicked[id], Extensions.touched[id]].compactMap { $0 }.max()
            guard let when, Date().timeIntervalSince(when) < 10 else {
                throw Unsupported(what: "Invalid call to permissions.request(). Must be called during a user gesture.")
            }
            Extensions.clicked[id] = nil
            Extensions.touched[id] = nil
            let found = context.webExtension
            let wanted = ((first as? [String]) ?? []).map { WKWebExtension.Permission(rawValue: $0) }
            let origins = ((args.dropFirst().first as? [String]) ?? []).compactMap { try? WKWebExtension.MatchPattern(string: $0) }
                .filter { !Extensions.withheld($0) }
            let named = found.requestedPermissions.union(found.optionalPermissions)
            // Sites as the manifest names them, optional ones included —
            // which allRequestedMatchPatterns leaves out.
            let places = Set(found.allRequestedMatchPatterns.union(found.optionalPermissionMatchPatterns).map(\.string))
            guard wanted.allSatisfy(named.contains), origins.allSatisfy({ places.contains($0.string) }) else {
                throw Unsupported(what: "Only permissions specified in the manifest may be requested.")
            }
            let missing = wanted.filter { context.permissionStatus(for: $0) != .grantedExplicitly }
            let unreached = origins.filter { pattern in
                let status = context.permissionStatus(for: pattern)
                if status == .grantedExplicitly || status == .grantedImplicitly { return false }
                if status == .deniedExplicitly || status == .deniedImplicitly { return true }
                if context.deniedPermissionMatchPatterns.keys.contains(where: { !$0.matchesAllHosts && $0.matches(pattern) }) { return true }
                // WebKit can report a named pattern as requested even when a wildcard grants it.
                return !context.currentPermissionMatchPatterns.contains { granted in
                    granted.scheme == pattern.scheme && granted.path == pattern.path && granted.matches(pattern)
                }
            }
            guard !missing.isEmpty || !unreached.isEmpty else { return true }
            let every = unreached.contains { $0.matchesAllHosts || $0.matchesAllURLs }
            let sites = every ? "every website" : unreached.map(\.string).sorted().joined(separator: ", ")
            let question = unreached.isEmpty ? "asks for more access" : "wants to read and change \(sites)"
            let detail = missing.isEmpty ? "Until you remove the extension." : missing.map(\.rawValue).sorted().joined(separator: ", ")
            guard await owner.ask(question, detail: detail, context: context) else { return false }
            for permission in missing { context.setPermissionStatus(.grantedExplicitly, for: permission) }
            for pattern in unreached { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
            Extensions.fence(context)
            return true
        case "permissions.removeWebsites":
            // What fence() keeps of <all_urls> once it is given back, and
            // <all_urls> itself: both, and exactly those, so a host the
            // manifest names stays. Taken out of the granted list as it is:
            // WebKit's own "unknown" leaves *://*/* granted beside a named
            // host (AllURLsRemovalTests).
            let everything: Set<String> = ["<all_urls>", "*://*/*"]
            context.grantedPermissionMatchPatterns = context.grantedPermissionMatchPatterns
                .filter { !everything.contains($0.key.string) }
            return true
        case "permissions.remove":
            let gone = Set((first as? [String]) ?? [])
            let had = Store.settings.stringArray(forKey: Extensions.grantKey("granted", context, profile: owner.profile)) ?? []
            Store.settings.set(had.filter { !gone.contains($0) }, forKey: Extensions.grantKey("granted", context, profile: owner.profile))
            return true

        default:
            return Unhandled()
        }
    }
}
