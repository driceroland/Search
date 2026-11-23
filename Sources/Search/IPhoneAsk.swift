import AppKit
import SwiftUI

// "Want Search on your iPhone?" — the iPhone beta's waitlist, offered in a
// few more quiet places, just for now:
//
//   · the About window: one line under the version, with an inline field;
//   · Help › Search for iPhone…: a small card with the same field;
//   · a blank tab: one small line under the field, for the first three days
//     it is seen.
//
// Every place is the same press as Settings › About's iPhone beta field
// (OptIn.swift): one POST to searchbrowser.app/api/ios-beta with the email
// and a fixed source (app-about, app-help, app-newtab), sent only when the
// button is pressed. Nothing else is sent, nothing is counted.
//
// Gone everywhere for good once the iPhone beta was asked for from any
// place (here, Settings, or the card or welcome with the iPhone box
// ticked), or once "Not now" was pressed in any one of them: one switch
// for all. Joining the Mac news list alone leaves it offered.
//
// To take it out in a later release: `on` to false, or delete this file and
// the lines that name IPhoneAsk (App.swift, About.swift, Browser.swift,
// Fold.swift, Bench.swift) and the three sources in OptIn.Source.

enum IPhoneAsk {
    /// The one switch for every place.
    static let on = true

    /// "Not now", pressed in any place: never offered again anywhere.
    nonisolated static let dismissedKey = "iphoneask.dismissed"
    /// When a blank tab first showed the line; it shows for `newTabDays`.
    nonisolated static let newTabSinceKey = "iphoneask.newtab.since"
    static let newTabDays = 3

    static let pitch = "Want Search on your iPhone? Leave your email and we'll send you the beta."
    static let short = "Want Search on your iPhone?"
    static let action = "Get the beta"
    static let notNow = "Not now"
    static let menuTitle = "Search for iPhone…"
    static let cardTitle = "Search for iPhone"

    /// Where the line is, and the word the site keeps with the address.
    enum Spot: String, CaseIterable {
        case about, help, newTab

        var source: OptIn.Source {
            switch self {
            case .about: return .about
            case .help: return .help
            case .newTab: return .newTab
            }
        }
    }

    /// Whether any place offers it: until the iPhone beta was asked for
    /// from any place, or "Not now" was pressed in one.
    static func open(_ store: UserDefaults = Store.settings) -> Bool {
        on && !OptIn.askedBeta(store) && !store.bool(forKey: dismissedKey)
    }

    static func dismiss(_ store: UserDefaults = Store.settings) {
        store.set(true, forKey: dismissedKey)
    }

    /// Whether a blank tab offers it now: while open, and for the first
    /// `newTabDays` days after a blank tab first showed it.
    static func onNewTab(_ store: UserDefaults = Store.settings, now: Date = Date()) -> Bool {
        guard open(store) else { return false }
        guard let since = store.object(forKey: newTabSinceKey) as? Date else { return true }
        return now.timeIntervalSince(since) < TimeInterval(newTabDays) * 86_400
    }

    /// The first time a blank tab shows it: the days count from here.
    static func seenOnNewTab(_ store: UserDefaults = Store.settings, now: Date = Date()) {
        if store.object(forKey: newTabSinceKey) == nil { store.set(now, forKey: newTabSinceKey) }
    }

    /// Whether this window's blank tab draws the line: the tab in front is
    /// blank, nothing is typed, and no list stands where it would go.
    @MainActor static func newTabShows(in browser: Browser, store: UserDefaults = Store.settings) -> Bool {
        on && browser.active?.isBlank == true && browser.typing.typed.isEmpty
            && !browser.prefs.recentInNewTab && onNewTab(store)
    }
}

// MARK: - the views

/// The line, closed: the question, "Get the beta" and "Not now". Opened, the
/// field (OptInForm, iPhone beta alone, with its typo hint) in its place;
/// joined, the form's own thanks. The field is never there before the
/// press, so it never takes the keys from anything.
struct IPhoneAskLine: View {
    let spot: IPhoneAsk.Spot
    var centred = false
    /// For pictures: start opened.
    var opened = false

    @AppStorage(OptIn.betaKey, store: Store.settings) private var beta = false
    @AppStorage(IPhoneAsk.dismissedKey, store: Store.settings) private var dismissed = false
    @State private var asking = false
    /// Kept up after the press, for its thanks.
    @State private var thanked = false
    @ObservedObject private var reach = OptIn.Reach.shared

    var body: some View {
        if IPhoneAsk.on && ((!beta && !dismissed && reach.online) || thanked) {
            Group {
                if asking || opened || thanked {
                    VStack(alignment: centred ? .center : .leading, spacing: 6) {
                        if !thanked {
                            Text(IPhoneAsk.pitch)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.muted)
                                .multilineTextAlignment(centred ? .center : .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        OptInForm(source: spot.source, betaOnly: true, button: "Join", offersBeta: false, compact: true) { _ in
                            thanked = true
                        }
                    }
                } else if spot == .about {
                    // The About window is narrow: the question, then the two.
                    VStack(spacing: 4) {
                        Text(IPhoneAsk.short)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                        choices
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(IPhoneAsk.short)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                        choices
                    }
                    .lineLimit(1)
                    .fixedSize()
                }
            }
            .transition(.opacity)
            .animation(Motion.settle, value: asking)
        }
    }

    /// "Get the beta · Not now".
    private var choices: some View {
        HStack(spacing: 6) {
                        Button { asking = true } label: {
                            Text(IPhoneAsk.action).underline()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.ink)
                        Text(verbatim: "·").font(.system(size: 11.5)).foregroundStyle(Palette.faint)
                        Button { IPhoneAsk.dismiss() } label: {
                            Text(IPhoneAsk.notNow)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.faint)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// A blank tab's line, hung under the field (and under the Home grid when
/// there is one). Watches the field, so it goes as soon as a key is typed.
struct IPhoneAskNewTab: View {
    let browser: Browser
    @ObservedObject private var typing: FieldState
    @ObservedObject private var prefs: Preferences
    @AppStorage(IPhoneAsk.dismissedKey, store: Store.settings) private var dismissed = false

    init(browser: Browser) {
        self.browser = browser
        typing = browser.typing
        prefs = browser.prefs
    }

    var body: some View {
        if !dismissed, IPhoneAsk.newTabShows(in: browser) {
            GeometryReader { page in
                let grid = HomeGrid.height(browser)
                IPhoneAskLine(spot: .newTab, centred: true)
                    .frame(width: min(Metrics.fieldWidth, max(0, page.size.width - 28)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, page.size.height / 2 - 30 + 25 + 16 + (grid > 0 ? grid + 14 : 0))
            }
            .onAppear { IPhoneAsk.seenOnNewTab() }
        }
    }
}

/// Help › Search for iPhone…: the line, opened, on a small card.
struct IPhoneAskCard: View {
    let close: () -> Void
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }

    var body: some View {
        Plate(IPhoneAsk.cardTitle, width: 400, close: close) {
            VStack(alignment: .leading, spacing: 10) {
                IPhoneAskLine(spot: .help, opened: true)
                OptInFinePrint(open: open)
            }
        } foot: {
            HStack {
                Spacer()
                Quick(IPhoneAsk.notNow, tint: Palette.muted) {
                    IPhoneAsk.dismiss()
                    close()
                }
            }
        }
    }
}

/// Whether the waitlist is still offered, for Help › Search for iPhone…
/// (App.swift): the menus are drawn again only when something the app
/// watches changes, so this watches the settings for it.
@MainActor final class IPhoneAskWatch: ObservableObject {
    static let shared = IPhoneAskWatch()
    @Published private(set) var open = IPhoneAsk.open()
    private var watching: NSObjectProtocol?

    private init() {
        watching = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let now = IPhoneAsk.open()
                if IPhoneAskWatch.shared.open != now { IPhoneAskWatch.shared.open = now }
            }
        }
    }
}
