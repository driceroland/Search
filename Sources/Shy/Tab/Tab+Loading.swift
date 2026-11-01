import Combine
import ImageIO
import SwiftUI
import WebKit

// Loading and coming back: a crashed page, a sleeping tab woken, reload, back and forward, closing.
extension Tab {
    /// What the store page's own button should say: added, on its way, or
    /// free to add.
    func tellStore(installed: [String], busy: String?) {
        guard let built,
              let data = try? JSONSerialization.data(withJSONObject: ["installed": installed, "busy": busy.map { $0 as Any } ?? NSNull()]),
              let json = String(data: data, encoding: .utf8)
        else { return }
        built.evaluateInShy("window.__officeStore && window.__officeStore.state(\(json))")
    }

    /// The picture comes off the moment there is something better under it
    /// — the page, painted — or you reach for the page yourself.
    func uncover(after delay: TimeInterval = 0) {
        guard let shown = cover else { return }
        guard delay > 0 else {
            cover = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.cover === shown else { return }
            self.cover = nil
        }
    }

    /// The process behind this page just died while it was the one on
    /// screen. `reload()`/`reloadFromOrigin()` lean on state the dead
    /// process was keeping — asking for the address back instead is the
    /// same trick `revive()` and the hollow branch of `reload()` already
    /// use, and the one that doesn't depend on anything the crash took with
    /// it. Tried twice: right after a process dies, WebKit doesn't always
    /// accept the very next load, which is what a reload that looks like it
    /// did nothing actually was.
    func recoverFromCrash() {
        guard let address else { return }
        failure = nil
        loadAndVerify(address)
    }

    /// `web.load`, checked a moment later rather than trusted outright: a
    /// load handed to WebKit right after a process just died, or as the
    /// very first thing a freshly-built view is asked to do, doesn't always
    /// take — no error, no navigation, just a view that goes on sitting on
    /// about:blank with nothing left to say so. Still there, or still
    /// answering for a process that's already gone, is asked once more.
    private func loadAndVerify(_ url: URL, state: Any? = nil, tries: Int = 0) {
        // Wait for the stage to take the view back before loading into it. A
        // page loaded while its view is off any window boots as a hidden tab,
        // and a site that holds everything until it is shown — x.com does,
        // right down to making no request at all — can then miss being shown a
        // moment later and sit on its placeholder for good. Coming back to a
        // pinned tab after ⌘W is exactly that: select() asks for the view back
        // and wakes the page in the same breath, one synchronous step ahead of
        // SwiftUI actually putting the view on screen. Bounded at about a
        // second, so a wake with no stage waiting for it still loads rather
        // than hanging on one that will never come.
        let view = web
        if view.window == nil, tries < 50 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.loadAndVerify(url, state: state, tries: tries + 1)
            }
            return
        }
        // A tab that slept has its own history to go back to — the page, its
        // back list and its scroll position, in one. Anything else starts
        // from the address. A file does too: its history comes back without
        // the folder it may read, and showed nothing.
        if let state, !url.isFileURL {
            view.interactionState = state
        } else {
            view.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            guard built?.url?.absoluteString != "about:blank" else {
                web.open(url)
                return
            }
            web.quietly("document.readyState") { [weak self] result in
                let error: Error? = if case .failure(let e) = result { e } else { nil }
                MainActor.assumeIsolated {
                    guard let self, let error = error as NSError? else { return }
                    guard error.domain == WKErrorDomain,
                          error.code == WKError.webContentProcessTerminated.rawValue
                    else { return }
                    self.web.open(url)
                }
            }
        }
    }

    /// Coming back to a tab. A page whose process was taken away out of sight
    /// — memory pressure, a long sleep — comes back as a white rectangle, and
    /// WebKit does not always say so for a view that was out of its window.
    /// Asked anything at all, the page answers with one particular error, and
    /// the answer to that is to load it again.
    func revive() {
        if stale {
            stale = false
            recoverFromCrash()
            return
        }
        guard isWeb, pending == nil, !loading, failure == nil else { return }
        // A view with no document behind an address: whatever emptied it, the
        // address is what to show, and reload alone would have nothing to do.
        if hollow, let address {
            web.open(address)
            return
        }
        web.quietly("document.readyState") { [weak self] result in
            let error: Error? = if case .failure(let e) = result { e } else { nil }
            MainActor.assumeIsolated {
                guard let self, let error = error as NSError? else { return }
                guard error.domain == WKErrorDomain,
                      error.code == WKError.webContentProcessTerminated.rawValue
                else { return }
                self.recoverFromCrash()
            }
        }
    }

    /// Opened for the first time since the app started, or coming back from
    /// ⌘W while pinned. Answers whether there was anything to wake — the
    /// caller's own `revive()`, right after this, is for a tab that went
    /// quiet a different way, and firing it too here raced this very load
    /// with a second one of its own for the same address.
    @discardableResult
    func wake() -> Bool {
        guard let url = pending else { return false }
        pending = nil
        failure = nil
        reader = false
        typing = false
        immersed = false
        let state = memory
        memory = nil
        if let picture, let image = NSImage(data: picture) {
            cover = image
            // Whatever happens to the page, the picture doesn't outstay it.
            uncover(after: 4)
        }
        picture = nil
        loadAndVerify(url, state: state)
        return true
    }

    /// A tab opened by a link is not blank, even though WebKit hasn't started
    /// loading it yet. Saying so now keeps the empty state from flashing up in
    /// the frame between the tab appearing and the page committing.
    func setAddressOptimistically(_ url: URL) {
        address = url
        failure = nil
        adoptIcon()
    }

    /// A new tab again: where it was going turned out to be a file, not a
    /// page, and an address kept for it downloads the file once more
    /// whenever the tab is opened (see Browser.dropEmpty).
    func forget() {
        address = nil
        icon = nil
    }

    func touch(at when: Date = Date()) { touched = when }

    /// True when the web view holds nothing — never loaded, or emptied —
    /// while the tab still names a page. The white page, in other words.
    var hollow: Bool {
        guard let built else { return address != nil }
        guard let there = built.url else { return address != nil }
        return there.absoluteString == "about:blank" && pending == nil && address != nil
    }

    /// A view that has lost its document is given the address back instead:
    /// there is nothing else for it to reload.
    func reload(fromOrigin: Bool = false) {
        // Shy's own pages are drawn from what is there now, always.
        guard page == nil else { return }
        // A pin put down with ⌘W has no view left to reload; waking it is
        // the reload.
        guard !wake() else { return }
        reader = false
        // A file is read again with the folder it may read (see open).
        if let address, hollow || address.isFileURL {
            web.open(address)
        } else if fromOrigin {
            web.reloadFromOrigin()
        } else {
            web.reload()
        }
    }

    func stop() { web.stopLoading() }

    /// Straight through, every time. A page that has to be fetched again is
    /// fetched again — nothing is kept behind to make that look otherwise.
    func back() {
        if let page {
            guard let last = trail.popLast() else { return }
            ahead.append(page)
            self.page = last
            title = last.title
            adoptIcon()
            steps()
            return
        }
        // At the first web page after one of Shy's own: back to it.
        if let behind, built?.canGoBack != true {
            show(behind, stepping: false)
            return
        }
        web.goBack()
    }

    func forward() {
        if let page {
            guard let next = ahead.popLast() else { return }
            trail.append(page)
            self.page = next
            title = next.title
            adoptIcon()
            steps()
            return
        }
        web.goForward()
    }

    /// Every page that way, nearest first, for the list a held Back or
    /// Forward shows: the web pages WebKit keeps. Nothing for a tab whose
    /// page was never built, or one showing a page of Shy's own, whose
    /// steps are kept apart (`trail`, `ahead`).
    func pages(back: Bool) -> [WKBackForwardListItem] {
        guard let built, page == nil else { return [] }
        return back ? built.backForwardList.backList.reversed() : built.backForwardList.forwardList
    }

    /// Straight to a page several steps away, as one step.
    func go(to item: WKBackForwardListItem) { web.go(to: item) }

    /// Called when the tab is thrown away. Without it the view keeps running
    /// whatever the page left behind — timers, video, sockets.
    func close() {
        onZoom = nil
        onLink = nil
        onPick = nil
        onPickEnd = nil
        onSignIn = nil
        onField = nil
        onCredentials = nil
        discard()
        // The last private tab gone, in every window: what its pages wore
        // goes with it.
        guard shy else { return }
        let others = Browsers.all.flatMap { $0.tabs + $0.parkedTabs }
        if !others.contains(where: { $0.shy && $0 !== self }) { Favicons.of(Profile.personalID).forgetShy() }
    }
}
