import SwiftUI
import WebKit
import Combine

// The camera, the microphone and the screen: what a page asks, and the answers kept.
extension Browser {
    /// A page asking to see or hear you, waiting for an answer. WebKit hands
    /// over a decision handler and holds the page until it is called — so this
    /// keeps the handler and the question together, and never drops either.
    struct CaptureAsk: Equatable, Identifiable {
        let host: String
        let wants: String
        /// Location is also given for this once, and kept only when you say
        /// always; in a private tab it is never kept.
        var once = false
        var keeps = true
        var screen = false
        /// The page also asks for the Mac's own sound with the screen.
        var sound = false
        /// When it came up. A page can time a click to land where Allow is
        /// about to be: the card takes none in its first half second.
        var shown = Date()
        var id: String { host + wants }
    }

    var permissionBusy: Bool { decide != nil || decideDisplay != nil }

    private(set) static var displayAnswered: Int?

    func allowCapture() { answerCapture(.grant) }

    func allowCaptureOnce() { answerCapture(.grant, keep: false) }

    func denyCapture() { answerCapture(.deny) }

    func shareScreen() { answerDisplay(1) }

    func shareWindow() { answerDisplay(2) }

    func denyShare() { answerDisplay(0) }

    private func answerDisplay(_ decision: Int) {
        guard decideDisplay != nil, let asking, asking.screen,
              Date().timeIntervalSince(asking.shown) > 0.5 else { return }
        finishDisplay(decision)
    }

    func cancelDisplay(for webView: WKWebView? = nil) {
        guard webView == nil || displayTab?.built === webView else { return }
        finishDisplay(0)
    }

    private func finishDisplay(_ decision: Int) {
        guard let reply = decideDisplay else { return }
        decideDisplay = nil
        displayRequest = nil
        if let tab = displayTab, let held = displayHeld {
            heldDialogs[tab.id]?.removeAll { $0 === held }
        }
        displayHeld = nil
        displayTab = nil
        if asking?.screen == true { asking = nil }
        // A test records the choice without ever opening the system picker.
        if Store.testing { Browser.displayAnswered = decision }
        reply(Store.testing ? 0 : decision)
    }

    /// A page or popup going away must settle its permission callback too,
    /// the screen's included.
    func cancelCapture() {
        cancelDisplay()
        let pending = decide
        decide = nil
        askedAbout = ""
        asking = nil
        pending?(.deny)
    }

    /// A site's camera, microphone, screen or location answer, kept per
    /// profile: what one profile allowed, another still asks about, and a
    /// site can't see in one profile what it was allowed in another and so
    /// tell the two are the same person. Personal's keys are what they
    /// always were.
    ///
    /// Whose answer it is comes from the page's own store, not from the row
    /// on screen: a peek, a little window or a parked space's tab is in no
    /// row, and a private peek once borrowed the space's answer and kept its
    /// own. Nil — nothing read, nothing kept — for a page that keeps nothing,
    /// or whose profile is gone.
    func scoped(_ key: String, for webView: WKWebView) -> String? {
        let store = webView.configuration.websiteDataStore
        guard store.isPersistent, let profile = Profiles.owner(of: store) else { return nil }
        return profile == Profile.personalID ? key : "\(profile.uuidString)|" + key
    }

    private func answerCapture(_ decision: WKPermissionDecision, keep: Bool = true) {
        guard let decide, let asking, Date().timeIntervalSince(asking.shown) > 0.5 else { return }
        // Remembered per site, so a call you take every week asks once.
        if keep, !askedAbout.isEmpty { Store.settings.set(decision == .grant, forKey: "capture." + askedAbout) }
        self.decide = nil
        askedAbout = ""
        self.asking = nil
        decide(decision)
    }

    /// Everything a site has been allowed or refused, for the day you want to
    /// change your mind.
    func forgetCaptureChoices() {
        for key in Store.settings.dictionaryRepresentation().keys
        where key.hasPrefix("capture.") || key.hasPrefix(Grounded.prefix) {
            Store.settings.removeObject(forKey: key)
        }
        SiteNotifications.shared.objectWillChange.send()
        announce("Camera, microphone, location and notification choices forgotten")
    }

    /// What was last answered to a page asking where you are, in a test run
    /// — which never goes on to ask the Mac: that would put macOS's own
    /// question on the screen of whoever is working beside it.
    static var locationAnswered: String?
}
