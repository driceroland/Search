import SwiftUI
import WebKit
import Combine

// Looking for something on the page (PageFind.swift): the window's side of it.
extension Browser {
    /// The Settings page it opens on next.
    var settingsPage: SettingsPanel.Page {
        get {
            SettingsPanel.Page(rawValue: Store.settings.string(forKey: "settings.page") ?? "") ?? .general
        }
        set { Store.settings.set(newValue.rawValue, forKey: "settings.page") }
    }

    struct FindSpec: Equatable {
        let tab: Tab.ID
        let query: String
        let matchCase: Bool
        let wholeWords: Bool
    }

    /// A question to the page not answered yet, or one waiting to be asked.
    var findBusy: Bool { findAsking != nil || findFresh || findSteps != 0 }

    var findStatus: String? {
        guard !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let result = findResult else { return nil }
        guard result.available else { return "Search unavailable" }
        if result.nativeFallback {
            if wholeWords && !result.wholeWordsAvailable { return "Whole words unavailable" }
            return result.found ? "Match found" : "No matches"
        }
        guard let index = result.index, let count = result.count, count > 0 else { return "No matches" }
        return "\(index) of \(count)\(result.more ? "+" : "")"
    }

    func openFind() {
        guard active?.isWeb == true else { return }
        finding = true
        findFocus += 1
    }

    func closeFind() {
        guard finding || !needle.isEmpty || findResult != nil else { return }
        // The page's own selection back, and the match's highlight gone.
        resetFindState()
        // The keyboard back to the page, as in Safari. Left with the window,
        // the Mac's keyboard navigation handed it to the first button next.
        if let web = active?.built, let window = web.window,
           window.firstResponder === window || window.firstResponder is NSText {
            window.makeFirstResponder(web)
        }
    }

    func look(forward: Bool) {
        guard let tab = active else {
            missed = false
            findResult = nil
            return
        }

        guard !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            missed = false
            findResult = nil
            guard findSpec != nil || findWeb != nil else { return }
            let web = findWeb ?? tab.built
            forgetFind()
            if let web { clearFind(on: web) }
            return
        }

        let web = tab.web
        let spec = FindSpec(tab: tab.id, query: needle, matchCase: matchCase, wholeWords: wholeWords)
        if findSpec != spec || findWeb !== web {
            findGeneration &+= 1
            findSpec = spec
            findWeb = web
            findFresh = true
            findSteps = 0
        } else {
            findSteps += forward ? 1 : -1
        }
        askFind()
    }

    /// Sends what is waiting to the page, unless a question is still out:
    /// its answer sends the next one.
    private func askFind() {
        guard findAsking == nil, let spec = findSpec, let web = findWeb,
              findFresh || findSteps != 0 else { return }
        findAsked &+= 1
        let asking = findAsked
        let generation = findGeneration
        let steps = findSteps
        findAsking = asking
        findFresh = false
        findSteps = 0
        Task { [weak self, weak web] in
            guard let self else { return }
            guard let web, self.activeID == spec.tab, self.active?.built === web else {
                if self.findAsking == asking { self.findAsking = nil }
                return
            }
            let result = await self.pageFind.update(
                on: web,
                query: spec.query,
                matchCase: spec.matchCase,
                wholeWords: spec.wholeWords,
                steps: steps,
                generation: generation
            )
            // Something newer took over while the page was answering.
            guard self.findAsking == asking else { return }
            self.findAsking = nil
            if !result.stale, self.findGeneration == generation, self.findSpec == spec,
               self.activeID == spec.tab, self.active?.built === web {
                self.findResult = result
                self.missed = result.available && !result.found
                    && (!result.nativeFallback || !spec.wholeWords || result.wholeWordsAvailable)
            }
            self.askFind()
        }
    }

    /// Nothing asked or waiting any more; whatever answer is out is dropped.
    private func forgetFind() {
        findGeneration &+= 1
        findSpec = nil
        findWeb = nil
        findAsking = nil
        findFresh = false
        findSteps = 0
    }

    private func clearFind(on web: WKWebView) {
        let generation = findGeneration
        Task { [pageFind] in _ = await pageFind.clear(on: web, generation: generation) }
    }

    private func resetFindState() {
        let web = findWeb
        forgetFind()
        resettingFind = true
        finding = false
        needle = ""
        matchCase = false
        wholeWords = false
        resettingFind = false
        findResult = nil
        missed = false
        if let web { clearFind(on: web) }
    }

    /// A tab or document changed under an open find bar. Keep what was typed,
    /// but retire every result and callback tied to the page that just left.
    func invalidateFindPage(retryOnActiveTab: Bool) {
        let web = findWeb
        forgetFind()
        findResult = nil
        missed = false
        if let web { clearFind(on: web) }
        guard retryOnActiveTab, finding,
              !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let tab = active, !tab.loading, tab.isWeb else { return }
        look(forward: true)
    }

    /// ⌘⇧M. Whatever is making noise in this tab stops making noise.
    func pauseMedia() {
        guard let tab = active else { return }
        tab.web.pauseAllMediaPlayback()
        announce("Paused")
    }
}
