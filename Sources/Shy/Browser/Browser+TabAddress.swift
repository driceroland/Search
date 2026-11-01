import SwiftUI
import WebKit
import Combine

// The address, in the tab itself: renaming a tab and editing where it goes.
extension Browser {
    func beginTabEdit(_ tab: Tab) {
        guard let url = tab.shownURL else {
            edit()
            return
        }
        renamingTab = false
        tabDraft = Address.editable(url)
        tabOriginal = tabDraft
        tabOffers = []
        tabPicked = nil
        editingTab = tab.id
    }

    /// Typed into the field in the tab: its list, and the rest of the
    /// address the field completes to, if any.
    func tabTyped(_ text: String) -> String? {
        tabPicked = nil
        let words = text.trimmingCharacters(in: .whitespaces)
        guard editingTab != nil, !renamingTab, !words.isEmpty, text != tabOriginal else {
            tabOffers = []
            return nil
        }
        let (offers, ending) = placeOffers(for: text)
        tabOffers = offers
        return ending
    }

    /// ↓ and ↑ in the tab's field, off either end and back to what was typed.
    func walkTab(_ step: Int) {
        guard !tabOffers.isEmpty else { return }
        switch tabPicked {
        case nil: tabPicked = step > 0 ? 0 : tabOffers.count - 1
        case let here?:
            let next = here + step
            tabPicked = (next < 0 || next >= tabOffers.count) ? nil : next
        }
    }

    /// A row of the tab's list, clicked or walked to and Return pressed.
    func takeTabOffer(_ offer: Suggestion) {
        guard let id = editingTab, let tab = tabs.first(where: { $0.id == id }) else { return }
        cancelTabEdit()
        if case .command(let command) = offer.kind {
            command.run(on: self)
        } else if let open = offer.tab, let other = tabs.first(where: { $0.id == open }) {
            select(other)
        } else {
            tab.go(to: offer.url)
        }
    }

    /// Rename. The name the tab is wearing arrives selected, so typing
    /// replaces it; emptying the field gives the page its own title back.
    func beginTabRename(_ tab: Tab) {
        renamingTab = true
        tabDraft = tab.label
        editingTab = tab.id
    }

    func commitTabEdit() {
        guard let id = editingTab, let tab = tabs.first(where: { $0.id == id }) else { return }
        if renamingTab {
            let typed = tabDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            tab.name = typed.isEmpty ? nil : typed
            cancelTabEdit()
            writeSession(now: true)
            return
        }
        if let picked = tabPicked, tabOffers.indices.contains(picked) {
            takeTabOffer(tabOffers[picked])
            return
        }
        guard let url = destination(for: tabDraft) else {
            // Stay put and say so, rather than quietly throwing the edit away.
            refusals += 1
            return
        }
        editingTab = nil
        tabOffers = []
        tabPicked = nil
        tab.go(to: url)
    }

    func cancelTabEdit() {
        editingTab = nil
        renamingTab = false
        tabDraft = ""
        tabOffers = []
        tabPicked = nil
    }

    /// A click somewhere else — the page, the column below, the rest of the
    /// strip — while a tab's address or name is being edited in the tab: what
    /// was typed is kept, as Return keeps it. An address left as it was loads
    /// nothing again, and a field left empty is let go.
    func finishTabEdit() {
        guard let id = editingTab, let tab = tabs.first(where: { $0.id == id }) else { return }
        if renamingTab {
            commitTabEdit()
            return
        }
        let draft = tabDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.isEmpty || tab.address.map({ Address.editable($0) == draft }) == true
            || destination(for: draft) == nil {
            cancelTabEdit()
            return
        }
        commitTabEdit()
    }
}
