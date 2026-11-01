import AppKit
import SwiftUI
import WebKit
import Combine

// Installing: from the store, from a folder, and taking one away.
extension Extensions {
    /// A store link or an id, from the field in Settings or the bar that
    /// shows on a store page.
    /// `confirm: false` is for the bench in a test run only — there is no
    /// way to reach it from the real browser.
    func install(from text: String, confirm: Bool = true) {
        guard let id = Crx.id(in: text) else {
            browser?.announce(Crx.Refused.notAnID.localizedDescription)
            return
        }
        if installed.contains(where: { $0.id == id }) {
            browser?.announce("Already installed")
            return
        }
        busy = id
        Task { await install(id: id, confirm: confirm) }
    }

    /// One from the store by its id, done — asked about, and installed or
    /// not — before it returns, so several brought over from another
    /// browser go one after another.
    func install(id: String, confirm: Bool = true) async {
        // A store id, and nothing else, goes into the request and the folder
        // names below, whoever called.
        guard id.count == 32, id.allSatisfy({ ("a"..."p").contains($0) }) else { return }
        guard !installed.contains(where: { $0.id == id }) else { return }
        busy = id
        defer { busy = nil }
        let staged = stagingFolder(for: id)
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            let crx = try await Crx.fetch(id)
            let zip = try Crx.verifiedZip(crx, id: id)
            let target = folder(for: id)
            try Crx.unpack(zip, into: staged)
            try ExtensionShims.prepare(staged, fresh: true)
            try await admit(staged, as: id, fromStore: true, finalFolder: target, confirm: confirm || !Store.testing)
        } catch {
            browser?.announce(error.localizedDescription)
        }
    }

    /// An unpacked extension from disk — a developer's own, or one exported
    /// from another browser. Copied in, so moving the original breaks nothing.
    func installFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Load Extension"
        panel.message = "Choose the folder that holds the extension's manifest.json."
        guard panel.runModal() == .OK, let source = panel.url else { return }
        installFolder(at: source)
    }

    func installFolder(at source: URL, confirm: Bool = true) {
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
            browser?.announce("That folder has no manifest.json")
            return
        }
        let source = URL(fileURLWithPath: Crx.realPath(of: source), isDirectory: true)
        let id = Crx.unpackedID(for: source)
        if installed.contains(where: { $0.id == id }) {
            browser?.announce("Already installed. Press Reload to take its changes")
            return
        }
        let staged = stagingFolder(for: id)
        Task {
            defer { try? FileManager.default.removeItem(at: staged) }
            do {
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
                // The folder itself, wherever a link to it leads.
                try FileManager.default.copyItem(at: source.resolvingSymlinksInPath(), to: staged)
                try Extensions.unlinkOutside(staged)
                try ExtensionShims.prepare(staged, fresh: true)
                try await admit(staged, as: id, fromStore: false, finalFolder: folder(for: id), confirm: confirm || !Store.testing, source: source)
            } catch {
                browser?.announce("Couldn't install the extension: \(error.localizedDescription)")
            }
        }
    }

    /// Takes the extension up again — the way Chrome's reload button does
    /// in developer mode. One loaded from a folder is copied in afresh from
    /// that folder first, so what its author just saved is what runs.
    func reload(_ id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }), reloading.insert(id).inserted else { return }
        let original = installed[index]
        let target = folder(for: id)
        let staged = original.source.map { _ in stagingFolder(for: id) }
        Task {
            defer {
                if let staged { try? FileManager.default.removeItem(at: staged) }
                reloading.remove(id)
            }
            guard installed.contains(where: { $0.id == id }) else { return }
            if let path = original.source, let staged {
                let source = URL(fileURLWithPath: path, isDirectory: true)
                guard FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
                    browser?.announce("The folder \(original.name) was loaded from is gone")
                    return
                }
                guard original.sourceKeepsID else {
                    browser?.announce("\(original.name) wasn't reloaded — its folder now leads somewhere else")
                    return
                }
                do {
                    try FileManager.default.copyItem(at: source.resolvingSymlinksInPath(), to: staged)
                    try Extensions.unlinkOutside(staged)
                    try ExtensionShims.prepare(staged, fresh: true)
                } catch {
                    browser?.announce("Couldn't copy \(original.name) again: \(error.localizedDescription)")
                    return
                }
            }
            let resource = staged ?? target
            let found = try? await WKWebExtension(resourceBaseURL: resource)
            if found == nil, staged != nil {
                browser?.announce("\(original.name) wasn't reloaded — its manifest couldn't be read")
                return
            }
            var wants: [String]?
            if let found {
                let permissions = Extensions.grants(found, in: resource)
                wants = permissions
                if !Set(permissions).isSubset(of: Set(original.permissions)) {
                    let name = [found.displayName ?? original.name, found.version].compactMap { $0 }.joined(separator: " ")
                    guard await ask(install: name, wants: Extensions.describe(found, in: resource), icon: found.icon(for: CGSize(width: 64, height: 64))) else {
                        browser?.announce("\(original.name) wasn't reloaded — it asks for more than before")
                        return
                    }
                }
            }
            // Loading and asking can both suspend. A removed extension must
            // not be put back by the work that was already in flight.
            guard installed.contains(where: { $0.id == id }) else { return }
            if let staged {
                do {
                    try ExtensionFiles.replace(staged, at: target)
                } catch {
                    browser?.announce("Couldn't replace \(original.name): \(error.localizedDescription)")
                    return
                }
            }
            unload(id)
            errors[id] = nil
            workersChanged()
            if let found, let index = installed.firstIndex(where: { $0.id == id }), let wants {
                installed[index].name = found.displayName ?? installed[index].name
                installed[index].version = found.version ?? installed[index].version
                installed[index].permissions = wants
                save()
            }
            guard let item = installed.first(where: { $0.id == id }), item.enabled else { return }
            browser?.announce(await load(item) ? "\(item.name) reloaded" : "\(item.name) couldn't start — see Settings › Extensions")
        }
    }

    @discardableResult
    func revive(_ id: String, because reason: String) -> Bool {
        guard let item = installed.first(where: { $0.id == id }), item.enabled,
              let context = contexts[id],
              Date().timeIntervalSince(revived[id] ?? .distantPast) > 60 else { return false }
        let popup = ExtensionPopup.shared.extensionID == id ? ExtensionPopup.shared.view?.url : nil
        guard unload(id, replacingContext: false) else { return false }
        revived[id] = Date()
        workersChanged()
        noteError("restarted the extension: \(reason)", for: id)
        // WebKit API objects held by existing pages address this context's
        // internal identifier. A different context with the same extension id
        // strands fresh connects in those pages. Match WebKit's own reload:
        // unload and load the same instance, keeping its prepared resources.
        do {
            loadedBefore.insert(id)
            try controller.load(context)
            contexts[id] = context
            watch(context)
            ShortcutStore.shared.adopt(context, id: id)
            actionsChanged += 1
            if let popup {
                Task { [weak self] in
                    guard let self, self.contexts[id] === context, context.isLoaded else { return }
                    ExtensionPopup.shared.show(popup, for: context, from: self.anchor(for: id))
                }
            }
        } catch {
            if contexts[id] == nil, !context.isLoaded {
                ExtensionWorkerRecovery.shared.unregister(id)
            }
            noteError("couldn't reload the extension: \(error.localizedDescription)", for: id)
        }
        return true
    }

    func watch(_ context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        if let old = errorWatchers[id] { NotificationCenter.default.removeObserver(old) }
        errorWatchers[id] = NotificationCenter.default.addObserver(forName: WKWebExtensionContext.errorsDidUpdateNotification, object: context, queue: .main) { [weak self, weak context] _ in
            MainActor.assumeIsolated {
                guard let self, let context, self.contexts[id] === context else { return }
                let failed = context.errors.contains { error in
                    let e = error as NSError
                    return e.domain == WKWebExtensionContext.errorDomain && e.code == WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue
                }
                guard failed else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.contexts[id] === context else { return }
                    self.revive(id, because: "its worker failed to start")
                }
            }
        }
    }

    func setPinned(_ id: String, _ on: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].pinned = on
        save()
        actionsChanged += 1
    }

    /// Reads what was unpacked, asks, and — on yes — moves it into place and
    /// loads it. On no, nothing is left behind.
    private func admit(_ staged: URL, as id: String, fromStore: Bool, finalFolder: URL, confirm: Bool = true, source: URL? = nil) async throws {
        let found = try await WKWebExtension(resourceBaseURL: staged)
        let name = found.displayName ?? id
        let wants = Extensions.describe(found, in: staged)
        let accepted = confirm ? await ask(install: name, wants: wants, icon: found.icon(for: CGSize(width: 64, height: 64))) : true
        guard accepted, !installed.contains(where: { $0.id == id }) else { return }
        let permissions = Extensions.grants(found, in: staged)
        try ExtensionFiles.replace(staged, at: finalFolder)
        unload(id)
        errors[id] = nil
        workersChanged()
        let item = Installed(
            id: id, name: name, version: found.version ?? "?", enabled: true, fromStore: fromStore,
            permissions: permissions,
            source: source?.path
        )
        installed.removeAll { $0.id == id }
        installed.append(item)
        save()
        if await load(item) {
            browser?.announce("\(name) is installed")
        } else {
            browser?.announce("\(name) is installed, but WebKit couldn't start it")
        }
    }

    func remove(_ id: String) {
        unload(id)
        ExtensionCapture.forget(id)
        errors[id] = nil
        Extensions.setSettings([:], for: id)
        Store.settings.removeObject(forKey: Extensions.grantKey("granted", id, profile))
        loadsThisRun.remove(id)
        loadedBefore.remove(id)
        Store.settings.removeObject(forKey: "extensions.newtab.\(id)")
        Store.settings.removeObject(forKey: Extensions.grantKey("private", id, profile))
        installed.removeAll { $0.id == id }
        save()
        try? FileManager.default.removeItem(at: folder(for: id))
        var left = Store.settings.stringArray(forKey: key(Extensions.forgettingKey)) ?? []
        if !left.contains(id) { left.append(id) }
        Store.settings.set(left, forKey: key(Extensions.forgettingKey))
        forgetting[id] = Task { if await forgetData(of: id) { forgotten(id) } }
    }

    /// Ids whose data is still to clear, kept until it is: a quit or a crash
    /// in the middle of clearing would otherwise leave it for the next
    /// extension loaded at the same path, which gets the same id.
    private static let forgettingKey = "extensions.forgetting"

    private func forgotten(_ id: String) {
        let left = (Store.settings.stringArray(forKey: key(Extensions.forgettingKey)) ?? []).filter { $0 != id }
        if left.isEmpty { Store.settings.removeObject(forKey: key(Extensions.forgettingKey)) }
        else { Store.settings.set(left, forKey: key(Extensions.forgettingKey)) }
    }

    /// At launch, before anything loads: what a removal didn't finish clearing.
    func forgetLeftOver() async {
        for id in Store.settings.stringArray(forKey: key(Extensions.forgettingKey)) ?? [] where forgetting[id] == nil {
            if await forgetData(of: id) { forgotten(id) }
        }
    }

    /// Its chrome.storage, which WebKit keeps by id, and what its pages
    /// kept at chrome-extension://<id>. WebKit lists no website records
    /// for that origin (see `workersKey`), so the second is cleared from a
    /// blank page at that origin, which only an extension context can
    /// host: a stand-in with no worker, scripts or pages of its own, so
    /// nothing of the removed extension runs again.
    /// Whether all of it was cleared.
    private func forgetData(of id: String) async -> Bool {
        defer { forgetting[id] = nil }
        let types = WKWebExtensionController.allExtensionDataTypes
        let records = await controller.dataRecords(ofTypes: types).filter { $0.uniqueIdentifier == id }
        if !records.isEmpty { await controller.removeData(ofTypes: types, from: records) }
        guard let base = URL(string: "\(Extensions.scheme)://\(id)/") else { return false }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shy-forget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"manifest_version": 3, "name": "Shy", "version": "1"}"#.utf8).write(to: folder.appendingPathComponent("manifest.json"))
            let standIn = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
            standIn.uniqueIdentifier = id
            standIn.baseURL = base
            try controller.load(standIn)
            defer { try? controller.unload(standIn) }
            guard let configuration = standIn.webViewConfiguration else { return false }
            let page = HiddenPage(configuration)
            guard await page.loadBlank(at: base) else {
                NSLog("Extensions: couldn't open %@ to clear what it kept", id)
                return false
            }
            _ = try await page.web.callAsyncJavaScript(Extensions.forgetScript, contentWorld: .defaultClient)
            return true
        } catch {
            NSLog("Extensions: couldn't clear what %@ kept: %@", id, error.localizedDescription)
            return false
        }
    }

    private static let forgetScript = """

        localStorage.clear();

        for (const db of await indexedDB.databases()) {
            await new Promise(done => { const q = indexedDB.deleteDatabase(db.name); q.onsuccess = q.onerror = q.onblocked = done; });
        }

        for (const key of await caches.keys()) await caches.delete(key);

        """
}
