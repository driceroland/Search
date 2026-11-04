import AppKit
import SwiftUI

// Profiles in one window (idea 419; #726, #459): off unless turned on in
// Settings › Spaces & Pins, and only with more than one profile.
//
// A window still belongs to one profile for its whole life (Profiles.swift):
// its pages never end up under another profile's sign-ins. So choosing a
// space of another profile doesn't change the window's profile. That
// profile's window takes this one's place instead — the same frame on the
// same screen, full screen if this one was, its column folded or not as
// this one's — and this one is ordered out, kept as it is, its pages
// loaded: coming back is instant and nothing reloads. Together they are
// one merged window: one of them on screen, the others tucked behind it,
// out of Mission Control, ⌘` and the Window menu, as if there were one.
//
// Closing the one on screen closes the merged window: the tucked ones go
// with it, and ⇧⌘T brings them back together. The last window closed is
// kept whole, as the one window always was, its tucked ones with it. A
// relaunch brings back one window per merged window, the profile you were
// in on screen. Turned off, the tucked windows come out as windows of
// their own.
//
// Every profile's spaces are listed, profile by profile, in the space's
// menu; ⌃1–⌃9 count through them in that order; and a swipe past the
// window's first or last space goes on to the profile before or after.

@MainActor
enum OneWindow {
    /// Turned on, with more than one profile to put in it.
    static var on: Bool { Shared.prefs.profilesInOneWindow && Profiles.shared.several }

    /// The other windows of its merged window.
    static func siblings(of browser: Browser) -> [Browser] {
        guard let id = browser.mergeID else { return [] }
        return Browsers.all.filter { $0 !== browser && $0.mergeID == id && !$0.isPopup }
    }

    /// The one of its merged window that isn't tucked: on screen, or closed
    /// and kept. Nil for a window of its own.
    static func head(of browser: Browser) -> Browser? {
        guard browser.mergeID != nil else { return nil }
        return ([browser] + siblings(of: browser)).first { !$0.tucked }
    }

    /// Every merged window as it should be: exactly one of it untucked, and
    /// a window left on its own no longer merged.
    static func tidy() {
        var seen = Set<UUID>()
        for browser in Browsers.all {
            guard let id = browser.mergeID, seen.insert(id).inserted else { continue }
            let group = [browser] + siblings(of: browser)
            if group.count == 1 {
                browser.mergeID = nil
                if browser.tucked { untuck(browser) }
                continue
            }
            if !group.contains(where: { !$0.tucked }), let first = group.first {
                untuck(first)
            }
        }
    }

    /// Back on screen as a window of its own, where it was.
    static func untuck(_ browser: Browser) {
        browser.tucked = false
        guard let window = browser.window else { return }
        window.isExcludedFromWindowsMenu = false
        if !(Store.testing && NSApp.isHidden) { window.orderFront(nil) }
    }
}

extension Browsers {
    /// A space of another profile chosen in `current`: that profile's window
    /// takes its place, at that space.
    static func join(space id: UUID, from current: Browser) {
        let profile = Spaces.profile(of: id)
        guard profile != current.profileID else {
            current.enter(id)
            return
        }
        let next = sibling(of: current, in: profile, at: id)
        bring(next, over: current)
        if next.prefs.usesSpaces { next.enter(id) }
    }

    /// Another profile chosen in `current` (its badge, the Profile menu):
    /// its window takes this one's place, at the space it was last in.
    @discardableResult
    static func join(profile id: UUID, from current: Browser) -> Browser {
        if let next = OneWindow.siblings(of: current).first(where: { $0.profileID == id }) {
            bring(next, over: current)
            return next
        }
        let space = Store.settings.string(forKey: "space.current.\(id.uuidString)").flatMap(UUID.init)
            .flatMap { last in Spaces.read(profile: id).first { $0.id == last }?.id }
            ?? Profiles.shared.profile(id).home
        let next = sibling(of: current, in: id, at: space)
        bring(next, over: current)
        return next
    }

    /// The window of `profile` in `current`'s merged window: the one already
    /// there, a window of that profile standing on its own (it joins), or a
    /// new one, made out of sight at `space`.
    private static func sibling(of current: Browser, in profile: UUID, at space: UUID) -> Browser {
        let group = current.mergeID ?? UUID()
        current.mergeID = group
        current.window?.animationBehavior = .none
        if let there = OneWindow.siblings(of: current).first(where: { $0.profileID == profile }) { return there }
        if let alone = all.last(where: { other in
            other.profileID == profile && other.isOpen && !other.isPopup && other.mergeID == nil
                && other.window?.styleMask.contains(.fullScreen) != true
        }) {
            alone.mergeID = group
            alone.window?.animationBehavior = .none
            return alone
        }
        let made = Browser(record: WindowRecord(space: space))
        made.mergeID = group
        made.tucked = true
        open(made, frame: current.window?.frame)
        return made
    }

    /// `next` takes `current`'s place: its frame on its screen, full screen
    /// or not, the column folded or not; `current` goes out of sight, kept
    /// as it is.
    static func bring(_ next: Browser, over current: Browser) {
        guard next !== current else { return }
        next.tucked = false
        current.tucked = true
        next.shut = false
        next.folded = current.folded
        next.peeking = false
        guard let window = next.window else {
            becameKey(next)
            return
        }
        let old = current.window
        window.animationBehavior = .none
        window.isExcludedFromWindowsMenu = false
        old?.animationBehavior = .none
        old?.isExcludedFromWindowsMenu = true
        let wantsFull = old?.styleMask.contains(.fullScreen) == true
        let isFull = window.styleMask.contains(.fullScreen)
        if let old, !wantsFull, !isFull { window.setFrame(old.frame, display: false) }
        if Store.testing && NSApp.isHidden {
            // A hidden probe: nothing is ordered in (see show), only out.
            old?.orderOut(nil)
        } else if wantsFull == isFull {
            // Straight over it, then it steps out from under: no gap between.
            if let old, old.isVisible { window.order(.above, relativeTo: old.windowNumber) }
            window.makeKeyAndOrderFront(nil)
            old?.orderOut(nil)
        } else {
            // Full screen on one side only: macOS's own way into full screen,
            // or out of it, and the one left steps out once it is done.
            window.makeKeyAndOrderFront(nil)
            let frame = old?.frame
            FullScreenTurn.after(window, entering: wantsFull) {
                if !wantsFull, let frame { window.setFrame(frame, display: true) }
                if current.tucked { old?.orderOut(nil) }
            }
            window.toggleFullScreen(nil)
        }
        becameKey(next)
        save()
    }

    /// Profiles in one window turned off: every tucked window comes out as
    /// a window of its own, a step down and to the right of where it was.
    static func unmerge() {
        for browser in all where browser.mergeID != nil {
            browser.mergeID = nil
            guard browser.tucked, let window = browser.window else {
                browser.tucked = false
                continue
            }
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: window.frame.minX, y: window.frame.maxY)))
            OneWindow.untuck(browser)
        }
        save()
    }
}

/// Waits for a window to have gone into full screen, or out, once — or
/// for a few seconds, if macOS gives up on the way without a word.
@MainActor
private final class FullScreenTurn {
    private static var waiting: [FullScreenTurn] = []
    private var token: NSObjectProtocol?
    private var then: (@MainActor () -> Void)?

    static func after(_ window: NSWindow, entering: Bool, then: @escaping @MainActor () -> Void) {
        let turn = FullScreenTurn()
        turn.then = then
        let name = entering ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification
        turn.token = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak turn] _ in
            MainActor.assumeIsolated { turn?.done() }
        }
        waiting.append(turn)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak turn] in turn?.done() }
    }

    private func done() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        let run = then
        then = nil
        FullScreenTurn.waiting.removeAll { $0 === self }
        run?()
    }
}

extension Browser {
    /// Profiles in one window, in a window it applies to.
    var merges: Bool { OneWindow.on && !isPopup }

    /// Every space this window can go to, in order: its profile's, and with
    /// profiles in one window every profile's, profile by profile.
    var everySpace: [Space] {
        guard merges else { return spaces }
        return Profiles.shared.list.flatMap { $0.id == profileID ? spaces : Spaces.read(profile: $0.id) }
    }

    /// With profiles in one window, the profile before this window's (-1) or
    /// after it (1), in the order of the list; nil at either end.
    func profileBeyond(_ step: Int) -> UUID? {
        guard merges else { return nil }
        let list = Profiles.shared.list
        guard let at = list.firstIndex(where: { $0.id == profileID }), list.indices.contains(at + step) else { return nil }
        return list[at + step].id
    }

    /// Past this window's first space, the profile before's last; past its
    /// last, the next profile's first.
    func spaceBeyond(_ step: Int) -> UUID? {
        guard let profile = profileBeyond(step) else { return nil }
        let theirs = Spaces.read(profile: profile)
        return step > 0 ? theirs.first?.id : theirs.last?.id
    }

    /// Whether a swipe draws the page after the one at `at`: a space of
    /// its own, or past the last the card for a new one — unless another
    /// profile's spaces come next.
    func drawsPage(after at: Int) -> Bool {
        at < spaces.count && (at + 1 < spaces.count || makingSpace || profileBeyond(1) == nil)
    }
}
