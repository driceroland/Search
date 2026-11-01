import SwiftUI
import WebKit
import Combine

// Picture in picture, and the page put forward for a tab.
extension Browser {
    /// With a pair on screen, its other page: what goes when the focused
    /// one has nothing playing.
    var otherPane: Tab? {
        guard let pair = activeSplit, let id = activeID else { return nil }
        return tabs.first { $0.id == pair.partner(of: id) }
    }

    func appLeft() {
        guard prefs.floatsAway, Browsers.front == nil || Browsers.front === self else { return }
        liftedAway = pictured == nil
        picture(active, quietly: true, otherwise: otherPane)
    }

    /// Back, and still on the tab it came from: into the tab again.
    func appBack() {
        defer { liftedAway = false }
        if liftedAway, let id = pictured, id == activeID { unpicture() }
    }

    /// ⌘⇧P, for sending one by hand, or bringing it back.
    func toggleFloat() {
        picture(active, quietly: false, toggle: true, otherwise: otherPane)
    }

    /// The video playing in `tab` into picture in picture (NativePiP).
    /// `toggle`: ⇧⌘P, which also brings one back.
    func picture(_ tab: Tab?, quietly: Bool, toggle: Bool = false, otherwise: Tab? = nil) {
        guard let tab, !tab.isBlank, !tab.asleep, tab.web.fullscreenState == .notInFullscreen else {
            if let otherwise { picture(otherwise, quietly: quietly, toggle: toggle) }
            return
        }
        if quietly, !Players.knows(tab.address) || tab.pageAddress?.host().map({ Grounded.holds($0, in: tab.profile) }) == true {
            if let otherwise { picture(otherwise, quietly: quietly, toggle: toggle) }
            return
        }
        tab.web.evaluateInShy(NativePiP.script(toggle: toggle)) { [weak self, weak tab] answer in
            MainActor.assumeIsolated {
                guard let self, let tab else { return }
                switch answer as? String {
                case "in": self.pictured = tab.id
                case "out": if self.pictured == tab.id { self.pictured = nil }
                case "refused": if !quietly { self.announce("This page keeps its video to itself") }
                default:
                    if let otherwise { return self.picture(otherwise, quietly: quietly, toggle: toggle) }
                    if !quietly { self.announce("Nothing is playing here") }
                }
            }
        }
    }

    /// Back into its tab, from macOS's picture in picture.
    func unpicture() {
        guard let id = pictured else { return }
        pictured = nil
        // Its tab may be parked in another space by now.
        (tabs + parkedTabs).first { $0.id == id }?.web.evaluateInShy(NativePiP.off)
    }

    func prepare(_ tab: Tab) {
        tab.delegate = self
        // With two pages up, the keys going to the other one — Tab walked
        // past the last field of this one — make it the focused page, so the
        // outline, ⌘L and the site card follow what is being typed into.
        tab.onKeys = { [weak self] tab in
            guard let self, let pair = activeSplit, pair.contains(tab.id), activeID != tab.id else { return }
            focusPane(tab)
        }
        tab.onLink = { [weak self] tab, address in
            guard let self, visibleTabIDs.contains(tab.id) else { return }
            linkStatus.show(address, over: tab.built)
        }
        tab.onPick = { [weak self] tab, selector, label, note in
            guard let self, let host = curtain.host(of: tab.address) else { return }
            let curtain = Profiles.curtain(tab.profile)
            // A private tab writes nothing down, hidden.json included: taken
            // off this page only.
            if tab.shy {
                passingVeils[tab.id, default: []].append(selector)
                tab.applyVeils(curtain.css(on: host) + passingCSS(tab.id))
                announce("Hidden on this page — ⌘Z puts it back")
                return
            }
            curtain.hide(selector, label: label, note: note, on: host)
            let css = curtain.css(on: host)
            tab.arm(hiding: css)
            tab.applyVeils(css)
            announce("Hidden — ⌘Z puts it back")
        }
        tab.onPickEnd = { [weak self] _ in self?.veiling = false }
        tab.onImageMenu = { [weak self] tab, url in self?.showImageMenu(for: tab, at: url) }
        tab.searchName = { [weak self] in self.map { $0.prefs.engine.name(custom: $0.prefs.customEngine) } }
        tab.onSearch = { [weak self] tab, text in
            guard let self, let url = self.searchURL(for: text) else { return }
            // From a private tab, the search is private too (see open(_:foreground:atEnd:from:)).
            self.open(url, foreground: true, from: tab)
        }
        tab.onStoreAdd = { [weak self] tab in self?.addFromStore(tab) }
        // The middle button on a link opens it beside the tab you are on, as
        // it does in every other browser (see MiddleRelay).
        // From a private tab, the new one is private too, as for ⌘-click.
        tab.onMiddleClick = { [weak self] tab, url in self?.openClicked(url, foreground: false, from: tab, view: tab.built) }
        tab.onCross = { [weak self] tab, url in self?.replace(tab, going: url) }
        tab.onFileLink = { [weak self] tab, url, blank in
            if blank { self?.open(url, foreground: true, from: tab) } else { tab.go(to: url) }
        }

        // The caret in a sign-in box: the accounts kept for this site hang
        // from the box, and go when the caret does. Nothing is filled on
        // its own — the way Safari does it, and what a person expects.
        tab.onField = { [weak self] tab, spot, passwords, name in
            self?.hang(from: tab, spot, passwords: passwords, name: name)
        }

        tab.onCredentials = { [weak self] tab, host, user, password, clear in
            // an extension's own page isn't a site: Bitwarden's unlock pin was offered as its password.
            guard let self, prefs.savesPasswords, !password.isEmpty, !tab.shy,
                  !Vault.isNever(host, in: self.profile(of: tab)), tab.address.flatMap(Browser.extensionHost(of:)) == nil
            else { return }
            // A password manager extension that asked Chrome's way to do the
            // saving itself.
            if #available(macOS 15.4, *), Extensions.of(profileID).passwordSavingTakenBy != nil { return }
            let profile = self.profile(of: tab)
            let known = Vault.kept(for: host, in: profile)
            // Nothing to ask about one that is already known. Only that
            // account's secret is read, not every one kept for the site.
            if var same = known.first(where: { $0.user == user }).flatMap(Vault.login), same.password == password {
                // Where it was last used is where it is offered from now on.
                same.clear = clear
                Vault.touch(same)
                return
            }
            let offer = Offer(
                login: Login(host: host, user: user, password: password, used: nil, clear: clear, profile: profile),
                changed: known.contains { $0.user == user }
            )
            guard offering != offer else { return }
            offering = offer
        }
        tab.onPickTrouble = { [weak self] _, reason in
            self?.announce("Couldn't hide that — \(reason)")
        }

        // The line at the bottom doubles as the zoom read-out: it keeps being
        // rewritten while you pinch and fades a moment after you stop.
        tab.onZoom = { [weak self] _, value in
            guard let self else { return }
            let percent = Int((value * 100).rounded())
            guard percent != zoomShown else { return }
            zoomShown = percent
            announce("\(percent)%")
        }

        // A page's title lands a beat after the page itself, and a history
        // entry that only ever holds an address is half a memory.
        // Anywhere a tab lands is worth remembering for next launch.
        tab.$address
            .dropFirst()
            .sink { [weak self] _ in self?.rememberSession() }
            .store(in: &bag)

        tab.$title
            .dropFirst()
            .sink { [weak self, weak tab] title in
                // A translated title is the page's in your words, not its own:
                // history keeps the page's (Translate.swift).
                guard let tab, !tab.shy, tab.translator == nil, let url = tab.address else { return }
                guard let self else { return }
                Profiles.history(profile(of: tab)).retitle(url, title)
            }
            .store(in: &bag)
    }
}
