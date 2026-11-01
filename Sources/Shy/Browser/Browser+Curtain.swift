import SwiftUI
import WebKit
import Combine

// Taking things off pages (Curtain.swift): the window's side of it.
extension Browser {
    /// What is hidden on sites, as the page in front's profile keeps it.
    var curtain: Curtain { Profiles.curtain(active?.profile ?? profileID) }

    var hereHost: String? { curtain.host(of: active?.address) }

    var hereVeils: [Veil] { curtain.veils(on: hereHost) }

    /// ⌘⇧H. Point at anything on the page and it goes, for good, on this site.
    func toggleHiding() {
        guard let tab = active, tab.isWeb else { return }
        if veiling {
            veiling = false
            tab.stopPicking()
        } else {
            reviewing = false
            veiling = true
            tab.startPicking()
        }
    }

    func passingCSS(_ id: Tab.ID) -> String {
        (passingVeils[id] ?? []).map { "\n\($0) { display: none !important; }" }.joined()
    }

    /// ⌘Z, while pointing: the last thing you took off comes back.
    func undoHiding() {
        if let tab = active, tab.shy {
            guard var list = passingVeils[tab.id], !list.isEmpty else { return }
            list.removeLast()
            passingVeils[tab.id] = list
            tab.applyVeils(curtain.css(on: hereHost) + passingCSS(tab.id))
            announce("It's back")
            return
        }
        guard let host = hereHost, let back = curtain.undo(on: host) else { return }
        redress()
        announce("\(back.label) is back")
    }

    /// The pointer resting on a row in the list brings that one thing back,
    /// outlined, and scrolls the page to it.
    func peek(_ veil: Veil) {
        guard let tab = active else { return }
        tab.peek(veil.selector, keeping: curtain.css(on: hereHost, without: veil.selector))
    }

    func stopPeeking() {
        active?.unpeek(curtain.css(on: hereHost))
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
        guard let tab = active else { return }
        let css = curtain.css(on: hereHost)
        tab.arm(hiding: css)
        tab.applyVeils(css)
    }
}
