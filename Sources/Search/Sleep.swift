import AppKit
import WebKit

// Tabs you aren't using, put to sleep.
//
// A page open in a tab keeps its whole content process — a hundred to three
// hundred megabytes, running its timers, holding its sockets — for as long as
// the tab exists. Twenty tabs is two or three gigabytes spent on the nineteen
// nobody is looking at. So a tab left alone for half an hour gives its page
// back, and keeps what it takes to come back exactly where it was: its
// history, its scroll position, and a picture to show while the page is
// rebuilt underneath (see Tab.sleep).
//
// Some tabs never sleep, because waking them couldn't give back what they
// were doing: the one on screen, pinned tabs (those are put down by hand,
// with ⌘W), a tab playing sound, on a call, sending a download, holding its
// video out in the little window, or holding something typed and not sent.
// A pin stays awake while its window is open: with the last window closed
// it sleeps after the same wait as the tabs beside it, unless its site may
// send notifications, which a page asleep couldn't (#569).
//
// With the last window closed and the app still running, there is nothing
// on screen to wait for: the tabs the same rules let go sleep at once (see
// sleepShut), and the ones on screen wake when the window comes back.
//
// Half an hour is Normal. Settings › Tabs › How soon tabs sleep makes it
// two hours (Later) or ten minutes (Sooner).
//
// In Low Power Mode, with Settings › General › Save power in Low Power Mode
// turned on, the wait is never longer than Sooner's ten minutes: a page asleep
// runs no timers and wakes no processor. A Mac that is only hot keeps the pace
// chosen. The look reads the wait each time, so it follows the switch at once.
//
// When macOS says memory is short, the wait shrinks, whatever was chosen: to
// five minutes on a warning, to nothing when it is critical.

/// How soon tabs sleep, as chosen in Settings. Three levels rather than
/// numbers: what someone decides is how much a waking tab bothers them, not
/// how many minutes.
enum SleepPace: String, CaseIterable, Identifiable {
    case later, normal, sooner

    nonisolated static let key = "tabs.sleep.pace"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .later: return "Later"
        case .normal: return "Normal"
        case .sooner: return "Sooner"
        }
    }

    /// Away this long, a tab sleeps.
    var wait: TimeInterval {
        switch self {
        case .later: return 2 * 60 * 60
        case .normal: return 30 * 60
        case .sooner: return 10 * 60
        }
    }

    /// What the line in Settings says under the choice.
    var detail: String {
        switch self {
        case .later: return "After two hours away."
        case .normal: return "After half an hour away."
        case .sooner: return "After ten minutes away."
        }
    }

    /// The one chosen, Normal until someone chooses.
    nonisolated static var chosen: SleepPace {
        Store.settings.string(forKey: key).flatMap(SleepPace.init) ?? .normal
    }
}

extension Browser {
    /// How long a tab has to go without being looked at: the chosen pace's
    /// wait, no longer than Sooner's in Low Power Mode when the switch for it
    /// is on, or `sleep.after` in seconds, for the bench and the measurements.
    static var sleepAfter: TimeInterval {
        let set = Store.settings.double(forKey: "sleep.after")
        if set > 0 { return set }
        let wait = SleepPace.chosen.wait
        return Motion.savingPower ? min(wait, SleepPace.sooner.wait) : wait
    }

    /// Started once, at launch. The same look closes the tabs left alone
    /// longest, when tabs close themselves (see Closing.swift).
    func watchForSleep() {
        let every = min(60, max(5, Browser.sleepAfter / 4))
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sleepIdle()
                self?.closeLeftAlone()
            }
        }
        timer.tolerance = every / 4
        RunLoop.main.add(timer, forMode: .common)
        dozing = timer

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.pressure?.data else { return }
                self.sleepIdle(within: event.contains(.critical) ? 0 : 5 * 60)
            }
        }
        source.resume()
        pressure = source
    }

    /// Every tab that has gone long enough without being looked at, the one
    /// left longest first.
    func sleepIdle(within given: TimeInterval? = nil) {
        guard prefs.sleepsTabs else { return }
        let wait = given ?? Browser.sleepAfter
        let now = Date()
        let idle = tabs
            .filter { now.timeIntervalSince($0.touched) >= wait && awake(because: $0) == nil }
            .sorted { $0.touched < $1.touched }
        // One after another, not all at once: each is pictured at the screen's
        // pixels first, and under memory pressure every idle tab pictured
        // together asked for most memory in the very moment there was least.
        // A page that never answers holds up the rest for a moment at most.
        var rest = idle[...]
        func next() {
            guard let tab = rest.popFirst() else { return }
            // Looked at since the list was made, while the ones before it
            // slept: not idle any more.
            guard Date().timeIntervalSince(tab.touched) >= wait else { return next() }
            var moved = false
            let onward = {
                guard !moved else { return }
                moved = true
                next()
            }
            sleep(tab) { _ in onward() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { onward() }
        }
        next()
    }

    /// The last window closed with the app running (Browsers.closing):
    /// nothing is on screen any more, so every tab the rules here let go
    /// sleeps now rather than half an hour on, as Safari and Chrome close
    /// theirs. The tabs stay, with their history, place and picture, for
    /// the window that comes back (see `shut`). One playing sound, on a
    /// call, downloading, with its video out or holding something typed
    /// stays awake, as it would at any other time. A page still loading is
    /// looked at once more a little later.
    func sleepShut(again: Bool = true) {
        guard prefs.sleepsTabs, shut else { return }
        var loading = false
        for tab in tabs {
            if awake(because: tab) == "still loading" { loading = true }
            sleep(tab)
        }
        guard again, loading else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.sleepShut(again: false) }
    }

    /// The window back after `sleepShut`: the tabs it shows wake, the others
    /// wait to be looked at, as after a launch.
    func wakeShown() {
        for tab in tabs where visibleTabIDs.contains(tab.id) { _ = tab.wake() }
    }

    /// Why a tab has to stay awake — nil when nothing keeps it. The clock is
    /// the caller's business; this is everything else.
    func awake(because tab: Tab) -> String? {
        // With the last window closed (`shut`) nothing is on screen.
        if !shut, visibleTabIDs.contains(tab.id) { return "on screen" }
        if tab.pin != nil, let kept = pinKept(tab) { return kept }
        if tab.bench { return "a bench tab" }
        if tab.isBlank { return "blank" }
        if tab.asleep { return "already asleep" }
        guard tab.built != nil else { return "no page" }
        if tab.loading { return "still loading" }
        return busy(tab)
    }

    func keepsAwake(_ tab: Tab) -> Bool {
        guard prefs.keepsSitesAwake, let host = tab.awakeHost else { return false }
        return (tab.shy ? tab.awakeSites : prefs.awakeSites).contains(host)
    }

    func keepAwake(_ on: Bool, for tab: Tab) {
        guard let host = tab.awakeHost else { return }
        if tab.shy {
            if on { tab.awakeSites.insert(host) } else { tab.awakeSites.remove(host) }
        } else {
            if on { prefs.awakeSites.insert(host) } else { prefs.awakeSites.remove(host) }
        }
    }

    /// Why a pin stays awake: always while its window is open; with the last
    /// window closed, only while its site may send notifications.
    private func pinKept(_ tab: Tab) -> String? {
        guard shut else { return "pinned" }
        return mayNotify(tab) ? "pinned, and its site may send notifications" : nil
    }

    /// Whether the site on the tab is allowed to send notifications (see
    /// Notifications.swift): answered yes, with notifications on in Settings.
    func mayNotify(_ tab: Tab) -> Bool {
        guard prefs.siteNotifications, !tab.shy, let url = tab.address,
              let scheme = url.scheme, let host = url.host(), !host.isEmpty else { return false }
        let site = Browser.origin(scheme, host, url.port ?? 0)
        return Store.settings.object(forKey: SiteNotifications.key(site)) as? Bool == true
    }

    /// What the page is in the middle of that letting it go would cut off:
    /// the part of staying awake that closing a tab asks too (Closing.swift).
    func busy(_ tab: Tab) -> String? {
        if keepsAwake(tab) { return "kept awake for this site" }
        if tab.noisy { return "playing sound" }
        if tab.floating || floating == tab.id || pictured == tab.id { return "its video is out" }
        if let web = tab.built {
            if web.cameraCaptureState != .none || web.microphoneCaptureState != .none { return "on a call" }
            if #available(macOS 15.4, *), ExtensionCapture.screen(web) { return "recording the screen" }
            if downloading.contains(where: { $0.webView === web }) { return "downloading" }
        }
        if heldDialogs[tab.id]?.isEmpty == false || paneQuestions.contains(where: { $0.tab == tab.id }) {
            return "a question waiting"
        }
        // A sign-in window hands its answer back to the page that opened it.
        if let pair = activeSplit {
            if tabs.contains(where: { pair.contains($0.id) && $0.opener == tab.id }) {
                return "the page on screen came from it"
            }
        } else if active?.opener == tab.id {
            return "the page on screen came from it"
        }
        return nil
    }

    /// Asks the page whether it holds anything typed, pictures it, then lets
    /// it go — looking again at each step, since each takes a moment and you
    /// may have gone back to the tab in the meantime.
    func sleep(_ tab: Tab, done: ((String) -> Void)? = nil) {
        if let reason = awake(because: tab) {
            done?(reason)
            return
        }
        let web = tab.built, document = tab.documentGeneration, touched = tab.touched
        tab.unsaved { [weak self, weak tab] typed in
            guard let self, let tab else { done?("gone"); return }
            if typed {
                done?("holding something typed")
                return
            }
            if let reason = self.awake(because: tab) {
                done?(reason)
                return
            }
            tab.snapshot { [weak self, weak tab] picture in
                guard let self, let tab else { done?("gone"); return }
                if let reason = self.awake(because: tab) { done?(reason); return }
                KeptSession.capture(tab) { storage in
                    // A draft may have appeared while WebKit took the picture or read storage.
                    tab.unsaved { typed in
                        if tab.built !== web || tab.documentGeneration != document || tab.touched != touched {
                            done?("page changed")
                            return
                        }
                        if typed { done?("holding something typed"); return }
                        if let reason = self.awake(because: tab) { done?(reason); return }
                        KeptSession.remember(storage, for: tab, in: self)
                        tab.sleep(picture: picture)
                        done?("asleep")
                    }
                }
            }
        }
    }
}

// A tab keeps its sessionStorage through sleep.
//
// A sleeping tab's history and scroll come back with its view
// (`interactionState`), but the view made to wake it starts a new browsing
// session, and sessionStorage goes with the old one. Some sites keep a draft,
// a form half filled or a step of a checkout only there, so waking lost it.
// WebKit has no way to hand sessionStorage from one view to the next (nothing
// on WKWebView or its data store), so the page's own is read as it falls
// asleep and written back as it wakes, before any of its scripts run.
//
// The page itself only: frames inside it lose theirs, as before. Not for a
// private tab, so nothing of one is held after its view goes. Not past
// `cap`: sleep is there to give memory back. Held in memory only, never in
// the session file, and only until the woken page commits; a later page in
// the same tab never gets it, so nothing the page cleared since comes back.
// Read and written in Search's world, where a page can't stand in for the
// functions used, and storage is the same in every world.
@MainActor
enum KeptSession {
    /// What each sleeping tab's page had: `[origin, [[key, value], …]]` as JSON.
    private static var kept: [UUID: String] = [:]

    /// Past this, a page's storage isn't kept: about half a megabyte.
    static let cap = 512 * 1024

    private static let read = """
        (() => {
          try {
            const s = sessionStorage;
            if (!s.length) return null;
            const items = [];
            for (let i = 0; i < s.length; i++) { const k = s.key(i); items.push([k, s.getItem(k)]); }
            return JSON.stringify([location.origin, items]);
          } catch (e) { return null; }
        })()
        """

    /// Read the current page before its view goes. A page that doesn't answer keeps nothing.
    static func capture(_ tab: Tab, then: @escaping (String?) -> Void) {
        guard !tab.shy, let web = tab.built else { return then(nil) }
        web.evaluateJavaScript(read, in: nil, in: Web.world) { result in
            let json = (try? result.get()) as? String
            then(json.flatMap { $0.utf8.count <= cap ? $0 : nil })
        }
    }

    /// Publish the captured state only if the tab actually goes to sleep.
    static func remember(_ storage: String?, for tab: Tab, in browser: Browser) {
        let open = Set((browser.tabs).map(\.id))
        kept = kept.filter { open.contains($0.key) }
        kept[tab.id] = storage
    }

    /// For the woken tab's next document (Tab.arm), ahead of its scripts:
    /// only for the same origin, and only into a session that's still empty.
    static func script(for tab: Tab) -> String? {
        guard let json = kept[tab.id] else { return nil }
        return """
            (() => {
              try {
                const [origin, items] = \(json);
                if (location.origin !== origin || sessionStorage.length) return;
                for (const [k, v] of items) sessionStorage.setItem(k, v);
              } catch (e) {}
            })();
            """
    }

    /// The woken page committed (Tab.didCommit): its copy goes, and the
    /// answer says the tab should arm again without it. A blank page on the
    /// way there doesn't count.
    static func committed(_ tab: Tab) -> Bool {
        guard kept[tab.id] != nil, let url = tab.built?.url, url.absoluteString != "about:blank" else { return false }
        kept[tab.id] = nil
        return true
    }
}
