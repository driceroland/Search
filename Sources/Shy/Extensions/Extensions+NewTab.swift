import AppKit
import SwiftUI
import WebKit
import Combine

// An extension's new tab page.
extension Extensions {
    /// The page an extension asks to show in new tabs — once you've said
    /// yes to it. Nil while nobody asks, or you said no.
    var newTabPage: URL? {
        newTabPageID.flatMap { contexts[$0]?.overrideNewTabPageURL }
    }

    /// The extension new tabs show, the one added last of those you said
    /// yes to.
    var newTabPageID: String? {
        newTabAskers.last { Store.settings.object(forKey: "extensions.newtab.\($0.id)") as? Bool == true }?.id
    }

    /// The extensions, on and running, that ask to replace the new tab page,
    /// in the order they were added.
    var newTabAskers: [Installed] {
        installed.filter { $0.enabled && contexts[$0.id]?.overrideNewTabPageURL != nil }
    }

    /// Settings › General › Home page: one extension's page in new tabs, or
    /// nil for Shy's own. Every other one that asks is answered no, so
    /// none of them puts its page back in by asking again.
    func setNewTabPage(_ id: String?) {
        for item in newTabAskers {
            Store.settings.set(item.id == id, forKey: "extensions.newtab.\(item.id)")
        }
        objectWillChange.send()
    }

    /// Chrome asks the first time an extension's page takes the place of
    /// the new tab — an extension that did it quietly could be anything.
    /// So does Shy, and then shows the page in the tab just opened. It
    /// asks even while another extension's page has new tabs, naming that
    /// one, so the first to ask doesn't keep them for good.
    func offerNewTabPage(into tab: Tab) {
        guard let item = newTabAskers.last(where: { Store.settings.object(forKey: "extensions.newtab.\($0.id)") == nil }),
              let url = contexts[item.id]?.overrideNewTabPageURL else { return }
        let holder = newTabPageID.flatMap { id in installed.first { $0.id == id } }
        let shown = newTabPage.flatMap(Browser.extensionHost(of:))
        let replacing = holder.map { "It asked to replace the new tab page, which “\($0.name)” shows now." } ?? "It asked to replace the new tab page."
        Task {
            let yes = await ask("Show “\(item.name)” in new tabs?", detail: "\(replacing) You can change this later in Settings › General › Home page.",
                                icon: contexts[item.id]?.webExtension.icon(for: CGSize(width: 64, height: 64)), yes: "Keep It", no: "Don't Allow")
            if yes { setNewTabPage(item.id) } else { Store.settings.set(false, forKey: "extensions.newtab.\(item.id)") }
            // The tab just opened, if it is still the page it opened on.
            let untouched = tab.isBlank || (shown != nil && tab.address.flatMap(Browser.extensionHost(of:)) == shown)
            if yes, untouched, let browser { browser.replaceNewTab(tab, with: url) }
        }
    }

    /// What an extension set through chrome.privacy and chrome.proxy.
    static func settings(for id: String) -> [String: Any] {
        Store.settings.dictionary(forKey: "extensions.settings.\(id)") ?? [:]
    }

    static func setSettings(_ values: [String: Any], for id: String) {
        if values.isEmpty { Store.settings.removeObject(forKey: "extensions.settings.\(id)") }
        else { Store.settings.set(values, forKey: "extensions.settings.\(id)") }
    }

    /// The extension, on and running, that asked the browser not to offer to
    /// save passwords — a password manager doing the saving itself.
    var passwordSavingTakenBy: String? {
        installed.first { $0.enabled && Extensions.settings(for: $0.id)["privacy.services.passwordSavingEnabled"] as? Bool == false }?.name
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].enabled = on
        save()
        if on {
            Task { await load(installed[index]) }
        } else {
            unload(id)
            ExtensionCapture.forget(id)
        }
    }

    func openOptions(_ id: String) {
        guard let url = contexts[id]?.optionsPageURL else { return }
        browser?.open(url, foreground: true)
    }
}
