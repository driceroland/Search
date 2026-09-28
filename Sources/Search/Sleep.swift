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
//
// Half an hour is Normal. Settings › Tabs › How soon tabs sleep makes it
// two hours (Later) or ten minutes (Sooner).
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
    /// wait, or `sleep.after` in seconds — for the bench and the measurements.
    static var sleepAfter: TimeInterval {
        let set = Store.settings.double(forKey: "sleep.after")
        return set > 0 ? set : SleepPace.chosen.wait
    }

    /// Started once, at launch.
    func watchForSleep() {
        let every = min(60, max(5, Browser.sleepAfter / 4))
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleepIdle() }
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
        // The rows of the other spaces too: parked is not the same as used.
        let idle = (tabs + parkedTabs)
            .filter { now.timeIntervalSince($0.touched) >= wait && awake(because: $0) == nil }
            .sorted { $0.touched < $1.touched }
        for tab in idle { self.sleep(tab) }
    }

    /// Why a tab has to stay awake — nil when nothing keeps it. The clock is
    /// the caller's business; this is everything else.
    func awake(because tab: Tab) -> String? {
        if visibleTabIDs.contains(tab.id) { return "on screen" }
        if tab.pin != nil { return "pinned" }
        if tab.bench { return "a bench tab" }
        if tab.isBlank { return "blank" }
        if tab.asleep { return "already asleep" }
        guard let web = tab.built else { return "no page" }
        if tab.loading { return "still loading" }
        if tab.noisy { return "playing sound" }
        if tab.floating || floating == tab.id { return "its video is out" }
        if web.cameraCaptureState != .none || web.microphoneCaptureState != .none { return "on a call" }
        if #available(macOS 15.4, *), ExtensionCapture.screen(web) { return "recording the screen" }
        if downloading.contains(where: { $0.webView === web }) { return "downloading" }
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
        tab.unsaved { [weak self, weak tab] typed in
            guard let self, let tab else { return }
            if typed {
                done?("holding something typed")
                return
            }
            if let reason = self.awake(because: tab) {
                done?(reason)
                return
            }
            tab.snapshot { [weak self, weak tab] picture in
                guard let self, let tab else { return }
                if let reason = self.awake(because: tab) {
                    done?(reason)
                    return
                }
                tab.sleep(picture: picture)
                done?("asleep")
            }
        }
    }
}
