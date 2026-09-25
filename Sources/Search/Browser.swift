import SwiftUI
import WebKit
import Combine

// The profile: everything the windows share — preferences, history, bookmarks,
// passwords, downloads, extensions, spaces — and the registry of windows
// themselves. What is on screen in one window lives on WindowModel.

@MainActor
final class Browser: NSObject, ObservableObject {
    /// Every open window. Starts with one; ⌘N and tear-off add more.
    @Published private(set) var windows: [WindowModel] = []
    /// The model the SwiftUI scene window draws. Extra windows are
    /// BrowserHosts. Commands use `key`, which moves; this does not.
    private(set) var sceneModel: WindowModel?
    /// The window that receives ⌘T and links from other apps. Set on
    /// didBecomeKey; replaces Browser.front and Links.window as the answer
    /// to "which window".
    @Published private(set) var key: WindowModel?

    /// The tab whose page is currently out in the little window. Nothing
    /// floating means no window: the two are checked against each other rather
    /// than trusted to stay in step.
    @Published private(set) var floating: Tab.ID? {
        didSet {
            guard floating == nil, floater.showing else { return }
            floater.drop()
        }
    }

    /// Everything there is to set. Held here so the whole window redraws when
    /// one of them changes.
    let prefs = Preferences()
    let linkStatus = LinkStatus()
    /// The settings panel.
    @Published var tuning = false
    /// The first-launch walk-through, over everything. Also from the menu.
    @Published var welcoming = false

    // MARK: - bookmarks

    let bookmarks = Bookmarks()
    /// The full list, for taking things out.
    @Published var bookmarking = false
    /// The dropdown off the button.
    @Published var bookmarksOpen = false

    /// ⇧⌘B. The page you are on, at the end of the list.
    func bookmarkCurrent() {
        guard let tab = key?.active, let url = tab.address else { return }
        guard !bookmarks.contains(url) else {
            announce("Already a bookmark")
            return
        }
        bookmarks.add(url, title: tab.title)
        announce("Bookmarked")
    }

    /// Another browser's bookmarks, folders and all — and, behind them, the
    /// icons it had for those sites, so the menu wears them from the start
    /// instead of a letter each. Returns how many pages came over.
    @discardableResult
    func takeBookmarks(from source: Chromium.Source) -> Int {
        let found = Chromium.bookmarks(in: source)
        bookmarks.take(found, from: source.name)
        let count = Bookmarks.count(found)
        announce(count == 0 ? "No bookmarks in \(source.name)" : "\(count) bookmarks from \(source.name)")
        let urls = Bookmarks.urls(found)
        DispatchQueue.global(qos: .utility).async {
            let icons = Chromium.icons(in: source, for: urls)
            Task { @MainActor in
                for (host, data) in icons { await Favicons.shared.adopt(data, for: host) }
                self.objectWillChange.send()
            }
        }
        return count
    }

    /// ⇧⌘S. The same tabs, down the left or across the top.
    func toggleSidebar() {
        withAnimation(Motion.glide) { prefs.sidebar.toggle() }
    }

    func searchURL(for text: String) -> URL? {
        Engine.url(for: text, template: prefs.engine.template(custom: prefs.customEngine))
    }

    func destination(for typed: String) -> URL? {
        Address.url(from: typed) ?? searchURL(for: typed)
    }

    let history = History()

    // MARK: - taking things off pages

    let curtain = Curtain()
    let loot = Loot()
    let floater = Float()
    /// True while the pointer is picking things to hide.
    @Published var veiling = false
    /// True while the list of what is hidden here is up.
    @Published var reviewing = false {
        didSet { if !reviewing { stopPeeking() } }
    }

    var hereHost: String? { curtain.host(of: key?.active?.address) }
    var hereVeils: [Veil] { curtain.veils(on: hereHost) }

    /// ⌘⇧H. Point at anything on the page and it goes, for good, on this site.
    func toggleHiding() {
        guard let tab = key?.active, !tab.isBlank else { return }
        if veiling {
            veiling = false
            tab.stopPicking()
        } else {
            reviewing = false
            veiling = true
            tab.startPicking()
        }
    }

    /// ⌘Z, while pointing: the last thing you took off comes back.
    func undoHiding() {
        guard let host = hereHost, let back = curtain.undo(on: host) else { return }
        redress()
        announce("\(back.label) is back")
    }

    /// The pointer resting on a row in the list brings that one thing back,
    /// outlined, and scrolls the page to it.
    func peek(_ veil: Veil) {
        guard let tab = key?.active else { return }
        tab.peek(veil.selector, keeping: curtain.css(on: hereHost, without: veil.selector))
    }

    func stopPeeking() {
        key?.active?.unpeek(curtain.css(on: hereHost))
    }

    func restore(_ veil: Veil) {
        guard let host = hereHost else { return }
        curtain.restore(veil, on: host)
        redress()
    }

    func restoreAll() {
        guard let host = hereHost else { return }
        curtain.restoreAll(on: host)
        redress()
        reviewing = false
        announce("Everything is back")
    }

    /// Both the page in front of you and the one that loads next time.
    private func redress() {
        guard let tab = key?.active else { return }
        let css = curtain.css(on: hereHost)
        tab.arm(hiding: css)
        tab.applyVeils(css)
    }

    // MARK: - passwords

    /// A name and password a page has just sent, waiting to be offered a place
    /// in the keychain. Held only until you answer.
    @Published var offering: Offer?

    struct Offer: Equatable {
        let login: Login
        /// The same account is already kept, with a different password.
        let changed: Bool
    }

    /// The accounts kept for the site whose sign-in box has the caret, and
    /// where that box is — a list hangs from it, and a click fills the form.
    /// Nothing is put into a page until you have pointed at it.
    @Published var suggesting: Suggesting?

    struct Suggesting: Equatable {
        let tab: Tab.ID
        let spot: CGRect
        let logins: [Login]
        /// The page the list was made for: its site, and whether it came in
        /// the clear. A click fills only a page that still is that one.
        let host: String
        let clear: Bool
    }
    /// Set once you have picked, so the list doesn't come straight back for
    /// the box you are still in. Cleared when the caret leaves the boxes.
    var pickedInto: Tab.ID?
    /// The list is taken down a beat after the caret leaves, not the same
    /// instant: clicking a row can take the caret out of the page first, and
    /// a list that vanished on the way down would never be clicked.
    var lowering: DispatchWorkItem?

    func keepOffer() {
        guard let offer = offering else { return }
        offering = nil
        let login = offer.login
        guard Vault.save(host: login.host, user: login.user, password: login.password, used: Date(), clear: login.clear) else {
            announce("The keychain refused it")
            return
        }
        relist()
        announce(offer.changed ? "Password updated for \(login.host)" : "Password saved for \(login.host)")
    }

    func dropOffer() { offering = nil }

    /// Never for this site. Some sites you sign into on purpose with nothing
    /// you want remembered.
    func neverOffer() {
        guard let offer = offering else { return }
        Vault.never(offer.login.host)
        offering = nil
        announce("Never for \(offer.login.host)")
    }

    /// One of the accounts in the list, picked by name.
    func choose(_ login: Login) {
        lowering?.cancel()
        guard let list = suggesting, let tab = tab(for: list.tab) else { return }
        suggesting = nil
        // The tab may have gone somewhere else while the list was up: a
        // redirect, a script. What was offered for one site is never put
        // into another's page.
        guard curtain.host(of: tab.address) == list.host,
              (tab.address?.scheme?.lowercased() == "http") == list.clear
        else { return }
        pickedInto = tab.id
        tab.fill(user: login.user, password: login.password) { [weak self] worked in
            if !worked { self?.announce("Couldn't find the sign-in fields anymore") }
        }
        Vault.touch(login)
    }

    func dropChoice() { suggesting = nil }

    // The list of what is kept.

    @Published var managing = false { didSet { if managing { relist() } } }
    @Published private(set) var saved: [Login] = []
    @Published var hunting = ""

    struct SiteRow {
        let host: String
        let logins: [Login]
    }

    /// Grouped by site, filtered by what has been typed.
    var shownSites: [SiteRow] {
        let needle = hunting.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = needle.isEmpty ? saved : saved.filter {
            $0.host.contains(needle) || $0.user.lowercased().contains(needle)
        }
        let groups = Dictionary(grouping: rows, by: \.host)
        return groups.keys.sorted().map { host in
            SiteRow(host: host, logins: groups[host]!.sorted { $0.user < $1.user })
        }
    }

    func relist() { saved = Vault.all() }

    func keep(host: String, user: String, password: String) {
        guard Vault.save(host: host, user: user, password: password) else {
            announce("The keychain refused it")
            return
        }
        relist()
        announce("Kept for \(host)")
    }

    func forget(_ login: Login) {
        Vault.forget(host: login.host, user: login.user)
        relist()
    }

    /// A password copied is asked for the way one shown is. It goes on this
    /// Mac's clipboard only, not to your other devices', marked concealed
    /// and transient, which is what clipboard managers go by to keep it out
    /// of their history, and it is taken off again after a minute and a
    /// half unless something else has been copied since.
    func copy(_ login: Login) {
        Vault.prove("copy the password for \(login.host)") { [weak self] ok in
            guard ok, let self else { return }
            let board = NSPasteboard.general
            board.prepareForNewContents(with: .currentHostOnly)
            board.setString(login.password, forType: .string)
            board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            let copied = board.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
                if board.changeCount == copied { board.clearContents() }
            }
            announce("Password copied")
        }
    }

    /// What came back from another browser's store, put in the keychain.
    func took(_ outcome: Result<Chromium.Found, Error>, from source: Chromium.Source) {
        switch outcome {
        case .success(let found):
            var kept = 0
            for login in found.logins
            where Vault.save(host: login.host, user: login.user, password: login.password, used: login.used, clear: login.clear) {
                kept += 1
            }
            var never = Vault.never
            found.never.forEach { never.insert($0) }
            Vault.never = never
            relist()
            announce(kept == 0 ? "Nothing new in \(source.name)" : "\(kept) passwords from \(source.name)")
        case .failure(Chromium.Trouble.noPassphrase):
            announce("\(source.name) didn't give up its keychain key")
        case .failure:
            announce("Nothing readable in \(source.name)")
        }
    }

    /// The other browser's history, into this one's. Off the main thread for
    /// the reading; the merge itself is a moment.
    func takePlaces(from source: Chromium.Source, then done: @escaping (Int) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let places = Chromium.places(in: source)
            DispatchQueue.main.async {
                for place in places {
                    self.history.take(place.url, title: place.title, count: place.count, last: place.last)
                }
                self.history.settle()
                done(places.count)
            }
        }
    }

    /// Takes in a CSV as Google Password Manager exports one. The file is read
    /// once and never copied.
    func importPasswords() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "A passwords export, as Chrome, Dia or Google Password Manager write it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            announce("Couldn't read that file as text")
            return
        }
        let result = Vault.take(csv: text)
        relist()
        announce(
            result.skipped == 0
                ? "\(result.kept) passwords in the keychain"
                : "\(result.kept) in the keychain, \(result.skipped) skipped"
        )
    }

    // MARK: - what is kept, and getting rid of it

    @Published var recalling = false
    @Published var hoarding = false
    @Published var recallHunt = ""

    /// Cookies, caches, local storage — everything a site left on this Mac,
    /// in every space. Clearing it signs you out of everything, which is
    /// the point.
    func clearSites() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        for space in spaces {
            Spaces.store(for: space.id).removeData(ofTypes: types, modifiedSince: .distantPast) {}
        }
        announce("Signed out of everything")
    }

    /// Only what was fetched to draw pages, not what identifies you.
    func clearCache() {
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
        ]
        for space in spaces {
            Spaces.store(for: space.id).removeData(ofTypes: types, modifiedSince: .distantPast) {}
        }
        announce("Cache cleared")
    }

    func clearHistory() {
        history.forget()
        announce("History cleared")
    }

    /// The last few places, for the History menu.
    var recentlyVisited: [History.Trace] {
        history.recent()
    }

    // MARK: - the camera and the microphone

    /// A page asking to see or hear you, waiting for an answer. WebKit hands
    /// over a decision handler and holds the page until it is called — so this
    /// keeps the handler and the question together, and never drops either.
    struct CaptureAsk: Equatable, Identifiable {
        let host: String
        let wants: String
        var id: String { host + wants }
    }

    @Published private(set) var asking: CaptureAsk?
    private var decide: ((WKPermissionDecision) -> Void)?
    private var askedAbout = ""

    func allowCapture() { answerCapture(.grant) }
    func denyCapture() { answerCapture(.deny) }

    private func answerCapture(_ decision: WKPermissionDecision) {
        guard let decide else { return }
        // Remembered per site, so a call you take every week asks once.
        Store.settings.set(decision == .grant, forKey: "capture." + askedAbout)
        decide(decision)
        self.decide = nil
        askedAbout = ""
        asking = nil
    }

    /// Everything a site has been allowed or refused, for the day you want to
    /// change your mind.
    func forgetCaptureChoices() {
        for key in Store.settings.dictionaryRepresentation().keys
        where key.hasPrefix("capture.") {
            Store.settings.removeObject(forKey: key)
        }
        announce("Camera and microphone choices forgotten")
    }

    // MARK: - saying so

    /// A line that rises from the bottom, says one thing, and leaves.
    @Published private(set) var announcement: String?


    func announce(_ text: String) {
        announcement = text
        hush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.announcement = nil }
        hush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7, execute: work)
    }

    /// The names extensions asked their downloads to be saved under.
    var namedDownloads: [URL: String] = [:]

    private var bag = Set<AnyCancellable>()
    /// The minute-by-minute look for tabs to put to sleep, and the ear for
    /// macOS saying memory is short. See Sleep.swift.
    var dozing: Timer?
    var pressure: DispatchSourceMemoryPressure?
    /// Downloads still under way. See `keep(_:)`.
    var downloading: [WKDownload] = []
    /// The Chrome Web Store's pages, told when installs come and go. See StoreRelay.swift.
    var storeWatch: AnyCancellable?
    private var hush: DispatchWorkItem?
    private var remembering = false
    /// Spaces (see Spaces.swift): every one this profile knows. Which one a
    /// window is in lives on the window.
    @Published var spaces = Spaces.read() {
        didSet { Spaces.sharing = Set(spaces.filter { $0.sharesSignIns == true }.map(\.id)) }
    }

    // MARK: - beginning and ending

    override init() {
        super.init()
        Shield.shared.enabled = prefs.shielded
        Shield.shared.compile()
        if #available(macOS 15.4, *) { Extensions.shared.start(for: self) }
        if prefs.bench {
            Bench.shared.start(for: self)
        } else if prefs.benchRefused {
            announce("“Let a script drive Search” was turned on outside Settings, and stays off")
        }
        welcoming = !prefs.welcomed
        // Once a day, quietly: is there a newer one?
        Updater.shared.checkIfDue { [weak self] line in self?.announce(line) }
        FormRelay.passkeysOffered = prefs.passkeys

        // The History menu lists what the history holds, and the menu is drawn
        // from this object's changes — so the history's are passed on.
        history.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)
        bookmarks.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)

        // An icon that arrives is put on every tab showing that site, not only
        // the one that happened to ask for it.
        Favicons.shared.arrived = { [weak self] host, image in
            guard let self else { return }
            for tab in allTabs where tab.address?.host()?.lowercased() == host {
                tab.icon = image
            }
        }
        // The little window's own three buttons.
        floater.onReturn = { [weak self] in
            guard let self else { return }
            // The window closes first, and unconditionally. Hanging that on
            // finding the tab again is how a little window survives the button
            // meant to dismiss it.
            let came = self.floating
            self.land()
            if let came, let tab = self.tab(for: came), let owner = tab.owner {
                owner.select(tab)
            }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.contentView != nil }?.makeKeyAndOrderFront(nil)
        }
        floater.onSkip = { [weak self] seconds in
            guard let self, let id = self.floating,
                  let tab = self.tab(for: id)
            else { return }
            tab.web.evaluateInSearch(Isolate.skip(seconds))
        }
        floater.onProgress = { [weak self] answer in
            guard let self, let id = self.floating,
                  let tab = self.tab(for: id)
            else { return }
            tab.web.evaluateInSearch(Isolate.where_) { found in
                MainActor.assumeIsolated {
                    guard let pair = found as? [Any], pair.count == 2,
                          let through = pair[0] as? Double,
                          let playing = pair[1] as? Bool
                    else { return }
                    answer(through, playing)
                }
            }
        }
        floater.onPlayPause = { [weak self] answer in
            guard let self, let id = self.floating,
                  let tab = self.tab(for: id)
            else { return }
            tab.web.evaluateInSearch(Isolate.toggle) { playing in
                MainActor.assumeIsolated { answer((playing as? Bool) ?? true) }
            }
        }
        floater.onClose = { [weak self] in self?.land() }

        // Yesterday's tabs, or one empty one. Either way a web view is built
        // now, which starts a content process while the window is still being
        // drawn — so the first address you type navigates instead of waiting
        // for WebKit to get up.
        defer {
            follow()
            watchForSleep()
        }

        // What a deleted space left behind, if WebKit wouldn't let it go then.
        Spaces.sweep()
        Spaces.sharing = Set(spaces.filter { $0.sharesSignIns == true }.map(\.id))
        // The space you were in, when there are spaces (see Spaces.swift).
        var space = Space.firstID
        if prefs.usesSpaces, let last = Store.settings.string(forKey: "space.current").flatMap(UUID.init),
           spaces.contains(where: { $0.id == last }) {
            space = last
            Spaces.current = last
        }
        // One window per row the session kept for this space; a file from
        // before windows, or none at all, is one window.
        let saved = Session.read(space: space)
        let rows = saved.windows.isEmpty
            ? [Session.WindowShape(id: nil, tabs: [], active: 0)]
            : saved.windows
        var made: [WindowModel] = []
        for shape in rows {
            let model = WindowModel(
                id: WindowID(rawValue: shape.id ?? UUID()),
                profile: self,
                spaceID: space
            )
            model.folded = prefs.sidebar && prefs.sideHides
            model.frameRequest = shape.frame
            made.append(model)
        }
        windows = made
        sceneModel = made.first
        key = made.first
        for model in made {
            model.restoreSession()
            if prefs.usesSpaces { model.preloadSpaces() }
        }
        // The first row goes in the scene's window; any the session also
        // kept need a window of their own.
        for model in made.dropFirst() {
            BrowserHost.show(model)
        }
    }

    // MARK: - the window registry

    /// Every tab in every window, live and parked — for the sleep timer,
    /// favicons, and prefs sweeps that must reach every page.
    var allTabs: [Tab] { windows.flatMap { $0.tabs + $0.parkedTabs } }

    /// A tab by id, wherever it lives.
    func tab(for id: Tab.ID) -> Tab? {
        windows.lazy.compactMap { $0.tab(id) }.first
    }

    /// The model behind a window id. Nil between a close and the scene noticing.
    func window(for id: WindowID) -> WindowModel? {
        windows.first { $0.id == id }
    }

    /// The NSWindow hosting a model, once dress() has claimed it.
    private var hosts: [WindowID: NSWindow] = [:]

    func claim(_ window: NSWindow, for model: WindowModel) {
        hosts[model.id] = window
    }

    func host(of model: WindowModel) -> NSWindow? {
        hosts[model.id]
    }

    /// The model behind an NSWindow, for a key event or a notification.
    /// Falls back to the window in front, which is where unclaimed keys go.
    func model(owning host: NSWindow?) -> WindowModel? {
        guard let host else { return key }
        return windows.first { self.host(of: $0) === host } ?? key
    }

    /// The window in front, as AppKit sees it.
    var keyHost: NSWindow? {
        key.flatMap { host(of: $0) }
    }

    /// A window came forward: it is the one ⌘T and links from other apps
    /// belong to. Replaces tracking this through didBecomeKey notifications
    /// and a static of whichever window was last in front.
    func becameKey(_ model: WindowModel) {
        key = model
    }

    /// A new window with one blank tab. ⌘N. The App layer turns the returned
    /// model into a real NSWindow.
    @discardableResult
    func open(space: Space.ID? = nil) -> WindowModel {
        let model = WindowModel(
            profile: self,
            spaceID: space ?? key?.spaceID ?? Space.firstID
        )
        model.folded = prefs.sidebar && prefs.sideHides
        adopt(model)
        model.adopt(model.makeTab())
        BrowserHost.show(model)
        return model
    }

    private func adopt(_ model: WindowModel) {
        windows.append(model)
        if key == nil { key = model }
    }

    /// ⌘W on a tab: through the window that holds it (or the key window).
    func closeTab(_ tab: Tab) {
        (tab.owner ?? key)?.close(tab)
    }

    /// Closing a window from inside, when its last tab is gone or the user
    /// asked. Detach refuses to leave the app with no windows.
    func close(_ window: WindowModel) {
        guard windows.count > 1 else {
            // Last window: a blank tab closes the window only as the system
            // would — through the window itself, which leaves the app running.
            host(of: window)?.performClose(nil)
            return
        }
        for tab in window.tabs { tab.close() }
        windows.removeAll { $0.id == window.id }
        if key === window { key = windows.first }
        if let host = hosts.removeValue(forKey: window.id) {
            host.close()
        }
    }

    func appLeft() {
        guard prefs.floatsAway else { return }
        liftedAway = !floater.showing
        lift(key?.active, quietly: true)
    }

    /// Back, and still on the tab it came from: into the tab again.
    func appBack() {
        defer { liftedAway = false }
        if liftedAway, let id = floating, id == key?.activeID { land() }
    }

    /// Another app in front: the video comes along, as in Arc (Settings ›
    /// General). Only one lifted this way goes home on its own when Search
    /// comes back.
    private var liftedAway = false

    /// The few settings that something else has to be told about. The rest are
    /// read where they are used.
    private func follow() {
        followStore()
        // Spaces turned off: back to the first, whose tabs are the ones there
        // were before (see Spaces.swift).
        prefs.$usesSpaces
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if on {
                    for window in windows { window.preloadSpaces() }
                } else {
                    leaveSpaces()
                }
            }
            .store(in: &bag)
        prefs.$shielded
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                Shield.shared.enabled = on
                Shield.shared.apply(to: allTabs.compactMap { $0.built?.configuration.userContentController })
                announce(on ? "Ads and trackers blocked" : "Blocking off — reload to see the difference")
            }
            .store(in: &bag)

        // The look changes — from Settings, or from the Mac while set to
        // System — and the icons a site keeps for each scheme change with it.
        // A beat after, so the appearance has actually turned over.
        prefs.$look
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.relook() }
            }
            .store(in: &bag)
        DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.prefs.look == .system else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.relook() }
            }
            .store(in: &bag)

        prefs.$bench
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if on { Bench.shared.start(for: self) } else { Bench.shared.stop() }
                announce(on ? "Scripts can drive Search — see ./bench" : "The bench is closed")
            }
            .store(in: &bag)

        // Every tab's next page, and the page each is showing now (see AutoScroll.swift).
        prefs.$autoScroll
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                for tab in allTabs {
                    tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
                    tab.built?.evaluateInSearch(on ? AutoScroll.script : AutoScroll.off)
                }
            }
            .store(in: &bag)

        // Every tab's next page, and the page each is showing now.
        prefs.$showsLinks
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                if !on { linkStatus.dismiss() }
                for tab in allTabs {
                    tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
                    tab.built?.evaluateJavaScript(on ? HoveredLink.script : HoveredLink.off, in: nil, in: .defaultClient)
                }
            }
            .store(in: &bag)

        prefs.$passkeys
            .dropFirst()
            .sink { [weak self] on in
                guard let self else { return }
                FormRelay.passkeysOffered = on
                // Each tab keeps whatever is hidden on the site it is showing:
                // re-arming with nothing would quietly restore every element
                // this person had taken off, everywhere.
                for tab in allTabs {
                    tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
                }
                announce(on ? "Passkeys offered again — reload the page" : "Sites will ask for a password instead")
            }
            .store(in: &bag)

        // The window and the menus are drawn from this object; a setting that
        // changes what they show has to be heard here.
        prefs.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)

        // WebKit read the defaults once at the start and keeps its own copy.
        // The only way to change its mind while running is the same action
        // the Edit menu would send it, which also writes the default back.
        prefs.$autocorrect
            .dropFirst()
            .sink { [weak self] on in
                guard let self, let web = key?.active?.web else { return }
                let selector = NSSelectorFromString("toggleAutomaticSpellingCorrection:")
                guard web.responds(to: selector) else { return }
                // Toggling is all there is, so it is only sent when the two
                // actually disagree.
                if UserDefaults.standard.bool(forKey: "WebAutomaticSpellingCorrectionEnabled") != on {
                    web.perform(selector, with: nil)
                }
                Preferences.tellWebKit(autocorrect: on)
                announce(on ? "Autocorrect on" : "Autocorrect off")
            }
            .store(in: &bag)
    }

    private func relook() {
        Favicons.shared.relook(allTabs.filter { !$0.asleep })
    }

    func writeSession(now: Bool = false) {
        // One file per space, every window's row in it (see Session.swift) —
        // the ones on screen now, and the ones parked while their window is
        // in another space.
        var shapes: [UUID: [Session.WindowShape]] = [:]
        for window in windows {
            shapes[window.spaceID, default: []].append(
                window.sessionShape(tabs: window.tabs, active: window.activeID)
            )
            for (space, row) in window.parked {
                shapes[space, default: []].append(
                    window.sessionShape(tabs: row.tabs, active: row.active)
                )
            }
        }
        for (space, list) in shapes {
            Session.write(now: now, space: space, Session.Shape(windows: list))
        }
    }

    func rememberSession() {
        guard !remembering else { return }
        remembering = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            remembering = false
            writeSession()
        }
    }

    /// The app is quitting. Whatever the debounce above was waiting out, it
    /// stops waiting: this writes straight to disk, on the thread asking to
    /// quit, before there is a process left to finish the wait on its behalf.
    func flushSession() {
        writeSession(now: true)
    }


    /// An address from before extensions moved to chrome-extension://, as
    /// it is now; any other, as it is.
    static func page(_ url: URL) -> URL {
        if #available(macOS 15.4, *) { return Extensions.unpopped(Extensions.current(url)) }
        return url
    }

    /// The extension an address belongs to, or nil for the web.
    static func extensionHost(of url: URL) -> String? {
        guard #available(macOS 15.4, *) else { return nil }
        let url = Extensions.current(url)
        return url.scheme == Extensions.scheme ? url.host : nil
    }

    /// The configuration for an extension's page, or nil for anything else.
    static func extensionConfiguration(for url: URL) -> WKWebViewConfiguration? {
        guard #available(macOS 15.4, *) else { return nil }
        let url = Extensions.current(url)
        guard url.scheme == Extensions.scheme else { return nil }
        return Extensions.shared.controller.extensionContext(for: url)?.webViewConfiguration
    }


    /// ⌘P. The system's own sheet, which is also where "save as PDF" lives.
    func printPage() {
        guard let tab = key?.active, !tab.isBlank, let window = NSApp.keyWindow else { return }
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = false
        let job = tab.web.printOperation(with: info)
        job.view?.frame = tab.web.bounds
        job.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// ⌘⇧P, for lifting one out by hand.
    func toggleFloat() {
        if floater.showing {
            land()
            return
        }
        lift(key?.active, quietly: false)
    }

    /// Everything but the video goes out of the way, and the page it lives in
    /// moves house — into a small window that stays above everything.
    func lift(_ tab: Tab?, quietly: Bool) {
        // A tab just put down with ⌘W has no page to lift a video out of, and
        // asking it would only build an empty view to ask.
        guard let tab, !tab.isBlank, !tab.asleep, !floater.showing else { return }
        // On its own, only from a site whose video is the point of the site.
        // A hero background on a studio's home page is a video too, and it
        // followed people around the desktop. ⌘⇧P still lifts from anywhere.
        if quietly, !Players.knows(tab.address) { return }
        tab.web.evaluateInSearch(Isolate.on) { [weak self] answer in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard (answer as? String) == "floating" else {
                    if !quietly { self.announce("Nothing is playing here") }
                    return
                }
                self.floating = tab.id
                tab.floating = true
                self.floater.lift(tab.web)
            }
        }
    }

    /// Back into its tab. The stage takes the page again on its next layout,
    /// which is what the self-healing there is for.
    func land() {
        // The window closes whatever else is true. Tying that to the bookkeeping
        // is how a little window outlives the thing that opened it.
        if floater.showing { floater.drop() }
        guard let id = floating, let tab = tab(for: id) else { return }
        floating = nil
        tab.floating = false
        tab.web.evaluateInSearch(Isolate.off)
    }

}

// MARK: - WebKit

extension Browser: WKNavigationDelegate, WKUIDelegate {
    /// Links the window has no business showing — mail, calls, an app's own
    /// scheme — are handed to whoever does own them.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // "Download Image", "Download Linked File" from the page's own
        // context menu, and a link with the `download` attribute all arrive
        // as an ordinary-looking action with this one flag set. Answered
        // with `.allow`, as anything else here was, WebKit tries to load it
        // as if it were the next page — nowhere for that to go, so nothing
        // happens and nothing says why. `.download` is what turns it into
        // the `WKDownload` that `didBecome download:` below already knows
        // what to do with.
        guard !action.shouldPerformDownload else {
            decisionHandler(.download)
            return
        }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }

        // An extension's OAuth sign-in coming back: the address is the
        // answer, handed to the extension, and never loaded.
        if ExtensionAuth.intercept(url, browser: self, from: webView) {
            decisionHandler(.cancel)
            return
        }

        // An extension's page sending its own tab to a website (see
        // replace(_:going:)).
        if #available(macOS 15.4, *), ["http", "https"].contains(scheme),
           action.targetFrame?.isMainFrame ?? true,
           webView.url?.scheme == Extensions.scheme,
           let tab = tab(for: webView) {
            decisionHandler(.cancel)
            DispatchQueue.main.async { tab.owner?.replace(tab, going: url) }
            return
        }

        // ⌘-click opens beside this tab and leaves you where you are; ⌘⇧-click
        // takes you with it.
        //
        // The middle button is not judged here. WebKit hands the browser a
        // navigation action for a ⌘-click and none at all for a middle one,
        // and where it does report a button it answers with a mask — 1 left,
        // 2 right, 4 middle — so a check for 2 here would have meant the right
        // button, not the middle (see MiddleRelay, which is where the middle
        // button is answered).
        //
        // Should a WebKit ever hand one over for the middle button after all,
        // it is cancelled: MiddleRelay has already opened the link in a tab of
        // its own, and letting this one through would take the page there too.
        if action.navigationType == .linkActivated, action.buttonNumber == 4 {
            decisionHandler(.cancel)
            return
        }
        // Shift-click, when Settings says so: a peek at the link, over this
        // page (see Peek.swift). Only from a tab in the row — within a peek,
        // a link just goes.
        if prefs.peeksLinks, action.navigationType == .linkActivated,
           ["http", "https"].contains(scheme),
           action.modifierFlags.intersection([.shift, .command, .option, .control]) == .shift,
           let from = tab(for: webView), from.owner?.peekTab == nil {
            decisionHandler(.cancel)
            DispatchQueue.main.async { from.owner?.peek(url, from: from) }
            return
        }
        if action.navigationType == .linkActivated,
           ["http", "https"].contains(scheme),
           action.modifierFlags.contains(.command) {
            let from = tab(for: webView)
            from?.owner?.open(url, foreground: action.modifierFlags.contains(.shift), from: from)
            decisionHandler(.cancel)
            return
        }

        // The next document gets this site's stylesheet of hidden things,
        // decided here because here is the last moment before it loads.
        if action.targetFrame?.isMainFrame ?? true, let tab = tab(for: webView) {
            let host = curtain.host(of: url)
            tab.arm(hiding: curtain.css(on: host))
            // And the blocker, on or off for where it is going.
            Shield.shared.tune(webView.configuration.userContentController, for: host)
        }

        // chrome-extension: an extension's own pages — options, a side
        // panel, a tab it opened. WebKit serves them; nothing else here does.
        if ["http", "https", "file", "about", "data", "blob", "chrome-extension", "webkit-extension"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            handOff(url, scheme: scheme, action: action, from: webView)
        }
    }

    /// An address for another app — mail, a call, a meeting. Only the page
    /// itself may ask, or a click inside one of its frames; a frame that
    /// asks on its own (an advertisement, say) is ignored. And the other app
    /// opens only once you have said so, as in Safari — except a mail or
    /// phone link you just clicked on, which is exactly what it says.
    private func handOff(_ url: URL, scheme: String, action: WKNavigationAction, from webView: WKWebView) {
        let clicked = action.navigationType == .linkActivated
        guard action.targetFrame?.isMainFrame ?? true || clicked else { return }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        if clicked, ["mailto", "tel"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let alert = NSAlert()
        alert.messageText = "Open \u{201C}\(name)\u{201D}?"
        alert.informativeText = "\(webView.url?.host() ?? "This page") wants to open \(name)."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        Dialogs.show(alert, over: webView) { answer in
            guard answer == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// A link that asks for a new window gets a new tab in the opener's
    /// window. The configuration WebKit hands over has to be the one the new
    /// view is built with, or the opener and the opened can't talk to each other.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let opener = tab(for: webView)
        let from = opener?.id
        // WebKit's copy of the opener's configuration still holds the
        // opener's user content controller — its scripts and its message
        // handlers. Shared, the new tab claimed the opener's handlers as its
        // own, and closing or sleeping it took them off the opener's page:
        // right-click on a picture on X, after following a link out of it,
        // did nothing at all. Each tab gets a controller of its own.
        configuration.userContentController = WKUserContentController()
        let tab = Tab(shy: opener?.shy ?? false, configuration: configuration)
        tab.popup = windowFeatures.width != nil || windowFeatures.height != nil
            || windowFeatures.toolbarsVisibility?.boolValue == false
        // The tab belongs in the window that asked for it, not whatever
        // window happens to be key.
        let home = opener?.owner ?? key
        home?.adopt(tab)
        tab.opener = from
        home?.activeID = tab.id
        home?.editing = false
        // Returning the view is what makes it the target. WebKit loads the
        // request into it itself when the action carries one.
        if let url = action.request.url { tab.setAddressOptimistically(url) }
        return tab.web
    }

    /// Anything the window can't show is something to keep instead.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // A redirect (3xx) has nowhere to be shown and carries no content of
        // its own, but must be followed rather than downloaded — even if its
        // headers say `application/binary` or `application/octet-stream`, as
        // youtube.com and some servers do on their redirects.
        if let http = response.response as? HTTPURLResponse, (300...399).contains(http.statusCode) {
            decisionHandler(.allow)
            return
        }
        // A server that says "attachment" means a file to keep, even one
        // WebKit could show. Gmail's download button loads the attachment
        // into a hidden frame and counts on exactly that: a PDF shown there
        // instead was the button doing nothing at all.
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        keep(download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        keep(download)
    }

    /// Every download this window has going, heard from until it ends — and
    /// counted, so a tab still sending one to disk is never put to sleep.
    func keep(_ download: WKDownload) {
        download.delegate = self
        downloading.append(download)
    }

    /// Without this WebKit refuses every request out of hand, and a page that
    /// asks for the camera simply never gets an answer.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let host = origin.host.isEmpty ? (tab(for: webView)?.address?.host() ?? "This page") : origin.host
        let key = "\(host)|\(type.rawValue)"

        if let remembered = Store.settings.object(forKey: "capture." + key) as? Bool {
            decisionHandler(remembered ? .grant : .deny)
            return
        }
        // One question at a time. A second page asking while the first is still
        // waiting is refused rather than queued behind it.
        guard decide == nil else {
            decisionHandler(.deny)
            return
        }

        decide = decisionHandler
        askedAbout = key
        asking = CaptureAsk(host: host, wants: Browser.name(for: type))
    }

    private static func name(for type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: return "camera"
        case .microphone: return "microphone"
        case .cameraAndMicrophone: return "camera and microphone"
        @unknown default: return "camera and microphone"
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(webView, error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        fail(webView, error)
    }

    /// A page asking to close itself.
    ///
    /// Signing in with Google — or with anything using OAuth — happens in a
    /// window the page opens, and that window calls close() when it is done.
    /// With nobody listening for it, what is left behind is a tab holding the
    /// blank page the flow ended on: nothing to look at, and nothing for
    /// reload to fetch, because there is no longer an address to fetch.
    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tab(for: webView), let owner = tab.owner else { return }
        // Back to whoever opened it, so you land where you started the sign-in
        // rather than wherever the row happens to put you.
        if let opener = tab.opener, let home = owner.tab(opener) {
            owner.select(home)
        }
        tab.pin = nil
        owner.close(tab)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        if tab.id == tab.owner?.activeID { linkStatus.dismiss() }
        tab.failure = nil
        tab.typing = false
        // Whatever you last set this site to, before it draws a single frame
        // at the wrong size.
        tab.applyRememberedZoom()
        // A tab waking from sleep: the new document is in, and a moment
        // after it is on screen the picture of the old one can go.
        tab.uncover(after: 0.45)
    }

    /// The page has drawn something: a view kept out of sight until now, so
    /// as not to show the white it starts as, comes in. WebKit calls this only
    /// on a view asked to — see `PageView.holdForFirstFrame()`.
    @objc(_webView:renderingProgressDidChange:)
    func webView(_ webView: WKWebView, renderingProgressDidChange events: UInt) {
        guard events & PageView.firstFrame != 0 else { return }
        (webView as? PageView)?.showFirstFrame()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A page with nothing to lay out never has a first frame. Done is
        // done, and it is shown.
        (webView as? PageView)?.showFirstFrame()
        guard let tab = tab(for: webView), let url = tab.address else { return }
        tab.uncover()
        tellStore(tab)
        // A page that arrived after a password went out: did the sign-in take?
        tab.settleSignIn()
        // The icon is asked for whether or not the tab is showing one: it may
        // be turned on a moment later, and a tab that then has to wait for a
        // fetch looks broken.
        Favicons.shared.fetch(for: tab)
        guard !tab.shy, !tab.bench else { return }
        history.record(url, title: tab.title)
    }

    private func fail(_ webView: WKWebView, _ error: Error) {
        tab(for: webView)?.uncover()
        let nsError = error as NSError
        let code = nsError.code
        // Cancelled is not a failure: it's what a redirect, a stopped load, or
        // a second Return in quick succession looks like from here.
        guard code != NSURLErrorCancelled else { return }
        // Nor is a page that turned into a download: WebKit ends that
        // navigation with "frame load interrupted" (102) while the file goes
        // on arriving. Answered as a failure, it covered the page with "The
        // page didn't load" over a download that had worked — clicked again,
        // it downloaded again.
        guard !(nsError.domain == "WebKitErrorDomain" && code == 102) else { return }
        tab(for: webView)?.failure = message(for: code)
    }

    private func message(for code: Int) -> String {
        switch code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "No site at that address."
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "No connection."
        case NSURLErrorTimedOut:
            return "The site took too long to answer."
        case NSURLErrorCannotConnectToHost:
            return "The site refused the connection."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "The connection isn't secure."
        default:
            return "The page didn't load."
        }
    }

    func tab(for webView: WKWebView) -> Tab? {
        allTabs.first { $0.built === webView }
    }
}

// MARK: - keeping files

extension Browser: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let asked = response.url.flatMap { namedDownloads.removeValue(forKey: $0) }
        let name = asked ?? (suggestedFilename.isEmpty ? "download" : suggestedFilename)

        guard !prefs.asksWhereToSave else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.directoryURL = downloadsFolder
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else {
                completionHandler(nil)
                return
            }
            completionHandler(url)
            announce("Downloading \(url.lastPathComponent)")
            return
        }

        completionHandler(Browser.free(name, in: downloadsFolder))
        announce("Downloading \(name)")
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloading.removeAll { $0 === download }
        guard let file = download.progress.fileURL else {
            announce("Download finished")
            return
        }
        loot.add(
            Keep(
                name: file.lastPathComponent,
                from: download.originalRequest?.url?.host() ?? "",
                path: file.path,
                date: Date()
            )
        )
        announce("Saved \(file.lastPathComponent)")
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        downloading.removeAll { $0 === download }
        announce("Download failed")
    }

    /// WebKit refuses to write over a file that is already there, so the name
    /// gains a number rather than the download quietly failing.
    private static func free(_ name: String, in folder: URL) -> URL {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = folder.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }
}





