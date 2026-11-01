import SwiftUI
import WebKit
import Combine

// The address field: what you type, what it guesses, and what the engine suggests.
extension Browser {
    /// Put the cursor back in the field, from wherever asked.
    func askFocus() { focusRequest += 1 }

    /// A key typed between ⌘T and the field taking the keys, kept for it.
    ///
    /// The field comes a turn or two of the run loop after it is asked for —
    /// later still with Split View, where it waits for the stage to say where
    /// the page is — and a hand already typing got there first: the first
    /// letter or two went to the page being left, or nowhere. Held for half
    /// a second at most, and only typing: a key with ⌘ or ⌃ is a shortcut.
    func holdKey(_ event: NSEvent) -> Bool {
        guard let asked = focusAsked, CACurrentMediaTime() - asked < 0.5,
              fieldShowing, editingTab == nil,
              event.modifierFlags.intersection([.command, .control]).isEmpty
        else { return false }
        if heldKeys.isEmpty {
            // The field never came: what was typed goes where it would have.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.heldKeys.isEmpty else { return }
                self.focusAsked = nil
                self.letGo(in: event.window)
            }
        }
        heldKeys.append(event)
        return true
    }

    /// The field has the keys: what was held goes to it, in order.
    func fieldFocused(in window: NSWindow) {
        focusAsked = nil
        letGo(in: window)
    }

    private func letGo(in window: NSWindow?) {
        let held = heldKeys
        heldKeys = []
        // Straight to the window, which hands a key to whatever has the
        // keys: not back through the app, whose monitor would hold it again.
        for event in held { window?.sendEvent(event) }
    }

    /// ⌘K again, with ⌘ still down: one step further down the list.
    func stepSummon() {
        cycling = true
        walk(1)
    }

    /// ⌘ let go of: take whatever the walk landed on.
    func landSummon() {
        guard cycling else { return }
        cycling = false
        guard picked != nil else { return }
        submit()
    }

    /// ⌘K. Only what is open, nothing else.
    func summon() {
        reviewing = false
        cancelTabEdit()
        launching = false
        summoning = true
        typed = ""
        editing = true
        focusRequest += 1
    }

    func guess() {
        // Only a plain field asks the engine (see askEngine, at the end).
        if summoning || siteChip != nil || typed.trimmingCharacters(in: .whitespaces).isEmpty {
            suggester.stop()
            engineWords = ("", [])
        }
        guard !summoning else {
            offers = openPages(matching: typed)
            ending = nil
            // The most recent page is already chosen, so ⌘K then Return is the
            // whole gesture.
            picked = offers.isEmpty ? nil : 0
            return
        }

        // A site in the field: only its search, for what is typed after it.
        if let site = siteChip {
            siteOffer = nil
            ending = nil
            picked = nil
            let words = typed.trimmingCharacters(in: .whitespaces)
            offers = words.isEmpty ? [] : site.url(for: words).map {
                [Suggestion(key: words, title: site.name, url: $0, kind: .search)]
            } ?? []
            return
        }

        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else {
            offers = []
            ending = nil
            picked = nil
            siteOffer = nil
            return
        }
        // "red": Reddit's search, a Tab away.
        let site = !summoning ? SiteSearch.match(typed, in: profileID) : nil
        if siteOffer != site { siteOffer = site }

        (offers, ending) = placeOffers(for: typed)
        // A row that was picked stops being the right row the moment the
        // question changes.
        picked = nil
        askEngine()
    }

    /// The question this field may ask the engine, or nil when it may not:
    /// the switch off, a private tab, ⌘K, a site or a shortcut in charge,
    /// or words that look like anything but a search.
    func engineQuestion(for typed: String) -> URL? {
        guard prefs.engineSuggests, !summoning, siteChip == nil, active?.shy != true,
              EngineSuggest.sendable(typed),
              Keyword.match(typed, in: prefs.keywords) == nil
        else { return nil }
        let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return EngineSuggest.url(for: words, engine: prefs.engine, test: EngineSuggest.testEndpoint)
    }

    private func askEngine() {
        guard let question = engineQuestion(for: typed) else {
            suggester.stop()
            engineWords = ("", [])
            return
        }
        let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // Until the answer: last time's words that still begin with these.
        let lower = words.lowercased()
        let places = Set(offers.map { $0.key.lowercased() })
        let still = engineWords.words.filter {
            $0.lowercased().hasPrefix(lower) && $0.lowercased() != lower && !places.contains($0.lowercased())
        }
        if !still.isEmpty { offers += engineOffers(still) }
        suggester.ask(question, words: words) { [weak self] answer in
            guard let self else { return }
            // Typed on since, or the field gone: nothing to answer.
            guard self.typed.trimmingCharacters(in: .whitespacesAndNewlines) == words,
                  self.fieldShowing, self.engineQuestion(for: self.typed) != nil
            else { return }
            let mine = self.offers.filter { $0.kind != .suggested }
            // A row of the engine's that the arrow keys are on stays put.
            if let picked = self.picked, picked >= mine.count { return }
            self.engineWords = (words, answer)
            let places = Set(mine.map { $0.key.lowercased() })
            self.offers = mine + self.engineOffers(answer.filter { !places.contains($0.lowercased()) })
        }
    }

    private func engineOffers(_ words: [String]) -> [Suggestion] {
        words.prefix(EngineSuggest.most).compactMap { word in
            searchURL(for: word).map { Suggestion(key: word, title: "", url: $0, kind: .suggested) }
        }
    }

    /// What an address field offers for what is typed in it, and the rest of
    /// the address it would complete to: ⌘L's field and the one in the tab
    /// ask the same question (#534).
    func placeOffers(for typed: String) -> (offers: [Suggestion], ending: String?) {
        // Three places and, if it can't be a place, a search. No open pages:
        // ⌘K exists for those, and mixing them in here made the list long
        // enough that reading it cost more than typing the address would have.
        var list = history.suggestions(for: typed, limit: 3)
        // Last in the list, and only when what was typed cannot be a place.
        if !typed.isEmpty, Address.url(from: typed) == nil {
            if let (keyword, rest) = Keyword.match(typed, in: prefs.keywords),
               let asked = Engine.url(for: rest, template: keyword.template) {
                list.append(Suggestion(key: typed, title: keyword.name, url: asked, kind: .search))
            } else if let asked = searchURL(for: typed) {
                list.append(
                    Suggestion(key: typed, title: prefs.engine.name(custom: prefs.customEngine), url: asked, kind: .search)
                )
            }
        }
        // First, not last: typing "settings" to reach Settings is the whole
        // point, and it would otherwise sit under a search for the word.
        let command = AddressCommand.matching(typed, in: self)
        if let command { list.insert(.command(command), at: 0) }
        // Neither a page already open nor a command has an address to
        // complete towards. And with a command on top, Return runs it: a
        // grey ending in the field ("history" finishing as history.com)
        // would promise a place Return doesn't go to.
        let ending = command != nil ? nil
            : history.completion(for: typed, among: list.filter { $0.kind != .open && !$0.kind.isCommand })
        return (list, ending)
    }

    /// What is open, most recently looked at first, filtered by what has been
    /// typed. On an empty field this is the whole point of the summon: it is
    /// the tab strip, except you read it only when you ask for it.
    private func openPages(matching typed: String) -> [Suggestion] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        return tabs
            .filter { $0.id != activeID && !$0.isBlank }
            .filter { tab in
                guard !needle.isEmpty else { return true }
                let address = tab.address.map { Address.pretty($0) } ?? ""
                return tab.label.lowercased().contains(needle) || address.contains(needle)
            }
            .sorted { $0.touched > $1.touched }
            .prefix(needle.isEmpty ? 6 : 3)
            .compactMap { tab in
                guard let url = tab.address else { return nil }
                return Suggestion(
                    key: tab.label,
                    title: Address.pretty(url),
                    url: url,
                    kind: .open,
                    tab: tab.id
                )
            }
    }

    /// A row clicked in the list, taken directly rather than through the
    /// keyboard's selection. The pointer and the arrow keys are answering the
    /// same question but must not share an answer: a list that appears under a
    /// resting cursor would otherwise rewrite the field before you had moved.
    func take(_ offer: Suggestion) {
        summoning = false
        if case .command(let command) = offer.kind {
            command.run(on: self)
        } else if let id = offer.tab, let tab = tabs.first(where: { $0.id == id }) {
            select(tab)
        } else if launching {
            open(offer.url, foreground: true, from: active)
        } else {
            (active ?? tabs.first)?.go(to: offer.url)
        }
        editing = false
        typed = ""
        picked = nil
    }

    /// A backspace means the ending was not wanted. Recomputing it on the very
    /// next keystroke is right; putting it back on this one is what makes a
    /// field impossible to shorten.
    func stopCompleting() { ending = nil }

    /// Tab with a site offered: the site goes into the field as a chip, and
    /// what was typed to name it is let go. True when it did.
    func lockSiteOffer() -> Bool {
        guard siteChip == nil, let site = siteOffer else { return false }
        siteOffer = nil
        typed = ""
        siteChip = site
        return true
    }

    /// The arrow keys walk the list, and walking off the top lets go of it.
    func walk(_ step: Int) {
        guard !offers.isEmpty else { return }
        switch picked {
        case nil:
            picked = step > 0 ? 0 : offers.count - 1
        case let here?:
            let next = here + step
            picked = (next < 0 || next >= offers.count) ? nil : next
        }
    }

    /// ⌘L. The current address comes up selected, so typing over it replaces it
    /// and Escape puts it back.
    func edit() {
        // ⌘L in an empty window: a new tab, its field ready.
        guard active != nil || activeSplit != nil else { return newTab() }
        summoning = false
        launching = false
        // Never a name and password written into the address: they would be
        // on screen, and in whatever you copy from here.
        typed = active?.shownURL.map { url -> String in
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.user != nil || parts.password != nil
            else { return url.absoluteString }
            parts.user = nil
            parts.password = nil
            return parts.string ?? ""
        } ?? ""
        editing = true
        focusRequest += 1
    }

    func dismiss() {
        summoning = false
        cycling = false
        // The floating new tab was never a tab: nothing is left behind.
        if launching {
            launching = false
            siteChip = nil
            editing = false
            typed = ""
            return
        }
        // Esc with a site in the field: the site goes, the field stays.
        if siteChip != nil {
            siteChip = nil
            return
        }
        // Esc on the empty page of a pair: the page isn't wanted after all.
        if let tab = active, tab.isBlank, split(for: tab) != nil {
            editing = false
            typed = ""
            close(tab)
            return
        }
        // A blank tab has nothing behind the field to go back to.
        guard active?.isBlank == false else { return }
        editing = false
        typed = ""
    }

    /// Return. A row picked from the list wins; otherwise what the field was
    /// finishing for you wins; otherwise what you actually typed. If none of
    /// those is a place, nothing happens and the field says so.
    ///
    /// `aside`: ⌘Return, as in Safari. The place opens in a new tab and the
    /// tab you were on is left as it was, behind it unless `front` (⇧⌘Return)
    /// asks to go there.
    func submit(aside: Bool = false, front: Bool = false) {
        // A page already open is switched to, not opened again.
        if let picked, offers.indices.contains(picked),
           let id = offers[picked].tab,
           let tab = tabs.first(where: { $0.id == id }) {
            summoning = false
            // From the empty page of a pair: that tab comes into the pair.
            if let blank = active, blank.isBlank, split(for: blank) != nil, !aside,
               tab.shy == blank.shy, split(for: tab)?.contains(blank.id) != true {
                fill(blank, with: tab)
                return
            }
            select(tab)
            editing = false
            typed = ""
            return
        }

        // The switcher proposes nothing but pages you have open. It still has
        // to accept an address typed into it, though — the two fields look
        // alike, and a Return that quietly does nothing is the worst answer
        // either of them could give.
        if summoning {
            summoning = false
            guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else {
                editing = false
                return
            }
        }

        // The row the arrow keys chose, or else the top one: a command is
        // only ever on top, and there it is what Return does. Walked past,
        // Return goes where it always went.
        let chosen = (picked.flatMap { offers.indices.contains($0) ? offers[$0] : nil }) ?? offers.first
        if case .command(let command) = chosen?.kind {
            command.run(on: self)
            editing = false
            typed = ""
            picked = nil
            return
        }

        let target: URL?
        if let picked, offers.indices.contains(picked) {
            target = offers[picked].url
        } else if ending != nil {
            target = Address.url(from: completed)
        } else {
            target = destination(for: typed)
        }

        guard let url = target else {
            refusals += 1
            return
        }
        // shy://settings and the rest: the page's own tab, one of each.
        if let page = InternalPage(url: url) {
            show(page)
            picked = nil
            return
        }
        if launching, !aside {
            // The floating new tab: what was typed gets a tab of its own, and
            // the page the field was raised over stays as it was.
            open(url, foreground: true, from: active)
        } else if aside {
            // Opened behind the page by hand, as a ⌘-clicked link is: it may
            // wait to load (Settings › Tabs › Load background tabs…).
            open(url, foreground: front, from: active, mayWait: true)
        } else if let active {
            active.go(to: url)
        } else {
            // From the empty window: a tab of its own.
            open(url, foreground: true)
        }
        editing = false
        typed = ""
    }

    func zoom(by factor: CGFloat) { active?.magnify(by: factor) }

    func resetZoom() { active?.resetZoom() }

    /// ⌘⇧R. The article, and nothing that was arranged around it.
    func toggleReader() {
        guard let tab = active else { return }
        tab.toggleReader { [weak self] worked in
            guard !worked else { return }
            self?.announce("Nothing to read on this page")
        }
    }

    func reload(fromOrigin: Bool = false) { active?.reload(fromOrigin: fromOrigin) }

    func back() { active?.back() }

    func forward() { active?.forward() }
}
