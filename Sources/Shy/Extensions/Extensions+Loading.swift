import AppKit
import SwiftUI
import WebKit
import Combine

// Loading an installed extension into WebKit.
extension Extensions {
    @discardableResult
    func load(_ item: Installed) async -> Bool {
        if let forgetting = forgetting[item.id] { await forgetting.value }
        // The shim this build of Shy carries, in place of whatever the
        // build that installed it carried — away from the main thread: the
        // first launch after an update reads and rewrites every script and
        // page each extension ships (Grammarly: 450 ms).
        let folder = self.folder(for: item.id)
        // One installed from a folder before links were looked at.
        if item.source != nil {
            do { try await Task.detached(priority: .userInitiated) { try Extensions.unlinkOutside(folder) }.value }
            catch { return false }
        }
        let generation = ExtensionWorkerRecovery.shared.generation(for: item.id)
        try? await Task.detached(priority: .userInitiated) { try ExtensionShims.prepare(folder, workerGeneration: generation) }.value
        do {
            let found = try await WKWebExtension(resourceBaseURL: folder)
            let context = WKWebExtensionContext(for: found)
            context.uniqueIdentifier = item.id
            // The same origin every launch. WebKit picks a fresh one
            // otherwise, and everything an extension keeps in its own pages
            // — localStorage, IndexedDB — is filed under its origin.
            if let stable = URL(string: "\(Extensions.scheme)://\(item.id)/") { context.baseURL = stable }
            context.isInspectable = true
            // Installing was the consent: everything it asked for then is
            // granted each time it loads. Optional ones are asked for when
            // the extension asks.
            for permission in found.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
            // Chrome lets "declarativeNetRequest" redirect or change headers
            // on the sites the extension has access to. WebKit does that only
            // with "declarativeNetRequestWithHostAccess", and otherwise drops
            // those rules without a word: Norma's redirect of a blocked site
            // to its own page never happened, and the site loaded (or failed)
            // instead. WebKit still holds the rules to the sites granted.
            if found.requestedPermissions.contains(.declarativeNetRequest) {
                context.setPermissionStatus(.grantedExplicitly, for: .declarativeNetRequestWithHostAccess)
            }
            Extensions.grantSites(context)
            // Its own sign-in address, https://<id>.chromiumapp.org, which
            // is never loaded (see ExtensionAuth.handOver). WebKit shows an
            // extension a tab's address only where it has access, where
            // Chrome's "tabs" is enough, and one watching its sign-in tab
            // for that address has to be able to see it.
            if ExtensionShims.allowed(item.id, context: context, profile: profile).contains("identity"),
               let own = try? WKWebExtension.MatchPattern(string: "https://\(item.id).chromiumapp.org/*") {
                context.setPermissionStatus(.grantedExplicitly, for: own)
            }
            Extensions.fence(context)
            Extensions.watchTouches()
            // Not yet anyone's: the profile loading it is named (see grantKey).
            context.hasAccessToPrivateData = Extensions.mayGoPrivate(context, profile: profile)
            let undoRecovery = ExtensionWorkerRecovery.shared.register(context)
            do { try controller.load(context) }
            catch { undoRecovery(); throw error }
            watch(context)
            if contexts[item.id] == nil, loadsThisRun.contains(item.id) { loadedBefore.insert(item.id) }
            loadsThisRun.insert(item.id)
            contexts[item.id] = context
            // Keys you gave its commands in Settings › Shortcuts (#189).
            ShortcutStore.shared.adopt(context, id: item.id)
            actionsChanged += 1
            return true
        } catch {
            NSLog("Extensions: couldn't load %@: %@", item.id, error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func unload(_ id: String, replacingContext: Bool = true) -> Bool {
        guard let context = contexts[id] else { return false }
        var unloaded = false
        do { try controller.unload(context); unloaded = true } catch {}
        // All paths retire the same endpoint: recovery, reload, disable and
        // remove. Complete observers before their views are closed, too.
        if unloaded { ExtensionWorkerRecovery.shared.restarted(id, replacingContext: replacingContext) }
        if replacingContext || !unloaded { ExtensionWorkerRecovery.shared.unregister(id) }
        // A reused context keeps native ports' weak context reference alive.
        // Retire only this extension's host/socket resources explicitly, rather
        // than waiting for isDisconnected to notice a deallocated context.
        for port in nativePorts.removeValue(forKey: id)?.allObjects ?? [] {
            let cleanup = port.disconnectHandler
            port.disconnectHandler = nil
            cleanup?(nil)
            if !port.isDisconnected { port.disconnect() }
        }
        Browsers.closePopups(of: id)
        // What it kept going outside WebKit goes with it: its offscreen
        // page, and a Mac kept awake on its behalf.
        ExtensionOffscreen.close(for: id)
        ExtensionCapture.shared.purge(id)
        // Its side panel, and what it said about it.
        SidePanelPages.shared.forget(id)
        ExtensionShims.panelTabs[id] = nil
        ExtensionShims.panelOff.remove(id)
        if let held = ExtensionShims.awake.removeValue(forKey: id) { IOPMAssertionRelease(held) }
        // Its ports read as gone only once WebKit has had a turn.
        DispatchQueue.main.async { ExtensionNative.stopOrphans() }
        contexts[id] = nil
        actionsChanged += 1
        // Disable/remove must release resources even when WebKit refuses the
        // unload. Only revive uses this result to decide whether to reload.
        return unloaded
    }

    func save() {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? JSONEncoder().encode(installed).write(to: list, options: .atomic)
    }
}
