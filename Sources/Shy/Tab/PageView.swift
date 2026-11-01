import Combine
import ImageIO
import SwiftUI
import WebKit

/// A web view that reads the two-finger swipe for itself.
final class PageView: WKWebView {
    var onMenuClosed: (() -> Void)?

    /// A page's questions (Dialogs.show): how many came hard on each
    /// other's heels, when the last one was answered, and whether you said
    /// "no more" — until the next page arrives (Tab.didCommit).
    var questionsInARow = 0
    var lastAnswered = Date.distantPast
    var questionsHushed = false
    /// An "Open in another app?" question is up: one at a time, however
    /// often the page asks (Browser.handOff).
    var askingForApp = false

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        onMenuClosed?()
    }

    /// The page's own right-click menu. WebKit puts extensions' items for the
    /// page in it itself; Shy adding them again showed each one twice.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // WebKit names it for a window, but a new window's page arrives here
        // as a new tab (Browser's createWebViewWith), so it says so. The tab
        // stays behind this one, as in Safari and Chrome, and as a ⌘-click's
        // does; with ⌥ held the item becomes one that goes to it, WebKit's
        // own, as it always was. Without a mouse's middle button, this is
        // the way to a tab in the background that needs no key held.
        if let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }) {
            let item = menu.items[index]
            if let front = item.copy() as? NSMenuItem {
                front.title = "Open Link in New Tab and Go to It"
                front.keyEquivalentModifierMask = .option
                front.isAlternate = true
                menu.insertItem(front, at: index + 1)
            }
            openLink = (item.target, item.action)
            item.title = "Open Link in New Tab"
            item.keyEquivalentModifierMask = []
            item.target = self
            item.action = #selector(openLinkBehind(_:))
        }
        // Copy Clean Link (#594): under WebKit's Copy Link, the same link
        // without its tracking parameters. On the page itself, under Reload,
        // only when the page's own address has some, as Safari does.
        if let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopyLink" }) {
            let item = menu.items[index]
            if let clean = item.copy() as? NSMenuItem {
                copyLink = (item.target, item.action)
                clean.title = "Copy Clean Link"
                clean.identifier = NSUserInterfaceItemIdentifier("ShyCopyCleanLink")
                clean.target = self
                clean.action = #selector(copyCleanLink(_:))
                menu.insertItem(clean, at: index + 1)
            }
        } else if let url, CleanLink.clean(url) != url,
                  let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierReload" }) {
            let clean = NSMenuItem(title: "Copy Clean Link", action: #selector(copyCleanPage(_:)), keyEquivalent: "")
            clean.identifier = NSUserInterfaceItemIdentifier("ShyCopyCleanLink")
            clean.target = self
            clean.representedObject = url
            menu.insertItem(clean, at: index + 1)
        }
        // The bench's linkmenu: the item it names is chosen as the menu
        // comes up, the way a hand would choose it, and the menu goes.
        if Store.testing, let title = PageView.picking {
            PageView.picking = nil
            RunLoop.main.perform(inModes: [.eventTracking, .default]) {
                if let index = menu.items.firstIndex(where: { $0.title == title }) { menu.performActionForItem(at: index) }
                menu.cancelTracking()
            }
        }
        // Translate Page, off unless switched on in Settings (Translate.swift).
        if let item = translateItem() {
            menu.addItem(.separator())
            menu.addItem(item)
        }
        if let item = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierSearchWeb" }),
           let name = searchName?() {
            webSearch = (item.target, item.action)
            selection = nil
            evaluateJavaScript(PageView.selected, in: nil, in: .defaultClient) { [weak self] result in
                self?.selection = (try? result.get()) as? String ?? ""
            }
            item.title = "Search with \(name)"
            item.target = self
            item.action = #selector(searchSelection(_:))
        }
    }

    /// Translate Page to <your language>, or Show Original once it is:
    /// nothing while the switch is off.
    func translateItem() -> NSMenuItem? {
        guard PageTranslator.enabled, let on = translating?() else { return nil }
        let language = PageTranslator.name(PageTranslator.code(PageTranslator.reader))
        let item = NSMenuItem(title: on ? "Show Original" : "Translate Page to \(language)", action: #selector(translatePage(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func translatePage(_ item: NSMenuItem) { onTranslate?() }
    /// Whether the page is translated, and Translate Page / Show Original.
    var translating: (() -> Bool)?
    var onTranslate: (() -> Void)?

    /// The item the bench's linkmenu will choose in the next menu.
    static var picking: String?
    var searchName: (() -> String?)?
    var onSearch: ((String) -> Void)?
    private var selection: String?

    /// The words selected where the right-click was, read when the menu
    /// opens. The selection of a text field is its own, not the page's, so a
    /// field with the caret in it is asked first; a frame with the caret in it
    /// is looked into when it is of the same site. One of another site can't
    /// be, and gives nothing, so WebKit's own action takes the click, as it
    /// always did. A password field gives nothing either.
    static let selected = Scripts.load("tab-selected")
    private var webSearch: (target: AnyObject?, action: Selector?) = (nil, nil)

    /// WebKit's Open Link in New Window, handed on once the tab it makes is
    /// marked to stay behind. WebKit asks for that tab a moment later, from
    /// the page's process (Browser's createWebViewWith), so the mark lasts a
    /// second and is used up by the first tab asked for.
    private var openLink: (target: AnyObject?, action: Selector?) = (nil, nil)
    private var behindSince: Date?

    @objc private func openLinkBehind(_ item: NSMenuItem) {
        guard let action = openLink.action else { return }
        behindSince = Date()
        NSApp.sendAction(action, to: openLink.target, from: item)
    }

    /// Whether the tab being made now is the menu's, to stay behind.
    func takeBehind() -> Bool {
        defer { behindSince = nil }
        return behindSince.map { Date().timeIntervalSince($0) < 1 } ?? false
    }

    /// WebKit's Copy Link, for Copy Clean Link to clean what it copies.
    private var copyLink: (target: AnyObject?, action: Selector?) = (nil, nil)

    @objc private func copyCleanLink(_ item: NSMenuItem) {
        guard let action = copyLink.action else { return }
        let count = NSPasteboard.general.changeCount
        NSApp.sendAction(action, to: copyLink.target, from: item)
        CleanLink.rewrite(since: count)
    }

    @objc private func copyCleanPage(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        CleanLink.copy(url)
    }

    @objc private func searchSelection(_ item: NSMenuItem) {
        defer { selection = nil }
        guard let selection, !selection.isEmpty else {
            if let action = webSearch.action { NSApp.sendAction(action, to: webSearch.target, from: item) }
            return
        }
        let words = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { onSearch?(words) }
    }

    /// Told where a sideways swipe has got to, and nil when there is none.
    var onPull: ((Pull?) -> Void)?
    /// What a swipe back means with nothing to go back to, where it means
    /// anything: a small window's first page was, a step back, no window at
    /// all (see Little.swift). Nil everywhere else, where back there does
    /// nothing. Only the swipe: it shows the disc and can be drawn back
    /// before letting go, and a mouse's back button can't, so a stray press
    /// would lose the page with no way to reopen it.
    var leave: (() -> Void)?
    /// Told the moment the page is reached for — a click, a scroll — so the
    /// picture of a tab waking up never stands between you and the page.
    var onTouch: (() -> Void)?
    /// The page's first frame is on screen (see showFirstFrame).
    var onFirstFrame: (() -> Void)?
    /// Told when the keys come to this page, however they got here — a
    /// click, or Tab walked past the other page's last field. With two
    /// pages up it makes this one the focused page (Browser.prepare), which
    /// is safe only because a page can't ask for the keys itself: Shy
    /// doesn't implement WebKit's focus request, so element.focus() and
    /// window.focus() never make this view first responder. If that is ever
    /// added, it must not do so for the page that isn't focused.
    var onKeys: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { onKeys?() }
        return took
    }

    override func mouseDown(with event: NSEvent) {
        onTouch?()
        super.mouseDown(with: event)
    }

    /// The side buttons a mouse has for back and forward — button 3 and 4.
    /// No standard hands out that numbering; it's the X11 button order
    /// (0 left, 1 right, 2 middle, 3 back, 4 forward) that most mouse
    /// drivers settled on regardless, so it's what a mouse's own firmware
    /// is tuned to send.
    override func otherMouseDown(with event: NSEvent) {
        switch event.buttonNumber {
        case 3 where canGoBack: goBack()
        case 4 where canGoForward: goForward()
        default: super.otherMouseDown(with: event)
        }
    }

    /// Logi Options+ sends its Back/Forward buttons as a swipe, not buttons
    /// 3 and 4 — deltaX 1 for back, -1 for forward, as Safari reads it.
    override func swipe(with event: NSEvent) {
        if event.deltaX > 0, canGoBack { goBack() }
        else if event.deltaX < 0, canGoForward { goForward() }
        else { super.swipe(with: event) }
    }

    // MARK: - keys the page didn't use

    /// The keys lately handed to the page. WebKit sends a key the page didn't
    /// use back up the responder chain — the same event, a second time —
    /// where nothing takes it and macOS plays its "can't do that" sound.
    /// Editors that put the text in themselves (X's reply box, anything built
    /// on Draft.js) leave WebKit thinking their keys unused, and so does a
    /// game that moves on the arrows without saying so (#402). Safari keeps
    /// those quiet, and so does this view. The app's own shortcuts never get
    /// this far: its key monitor takes them before the page sees the key.
    ///
    /// Several, not the last one: WebKit answers a moment later, and keys
    /// pressed quickly — or held, repeating — arrive before the answer for
    /// the one before. Remembering only the last, every earlier key beeped.
    private var handed: [NSEvent] = []
    /// How many came back unused and were kept quiet, for the bench.
    static var quieted = 0

    override func keyDown(with event: NSEvent) {
        if let index = handed.firstIndex(where: { PageView.same($0, event) }) {
            handed.remove(at: index)
            PageView.quieted += 1
            return
        }
        handed.append(event)
        // A key the page did use never comes back: only the latest few are
        // kept, and none older than a couple of seconds.
        let now = event.timestamp
        handed.removeAll { now - $0.timestamp > 2 }
        if handed.count > 32 { handed.removeFirst(handed.count - 32) }
        super.keyDown(with: event)
    }

    /// The same key press: the event WebKit sends back is the one it was
    /// given, and no two presses share a timestamp.
    static func same(_ one: NSEvent, _ other: NSEvent) -> Bool {
        one === other || (one.timestamp == other.timestamp && one.keyCode == other.keyCode && one.type == other.type)
    }

    // MARK: - the first frame

    /// A web view that has never drawn is opaque white. In a dark window that
    /// is a flash of it between a link that opens a tab and the page arriving,
    /// so a fresh view starts unseen, over the window's own ground, and comes
    /// in once WebKit says there is something on it worth seeing.
    private(set) var unpainted = false

    /// WebKit says when the first frame is only through names outside the
    /// public framework, so it is asked whether it answers to them first. One
    /// that doesn't gets a view shown straight away, as before.
    func holdForFirstFrame() {
        let observe = NSSelectorFromString("_setObservedRenderingProgressEvents:")
        guard responds(to: observe) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(method(for: observe), to: Setter.self)(self, observe, PageView.firstFrame)
        unpainted = true
        alphaValue = 0
    }

    /// In, quickly: the page is there, and the fade only covers the frame
    /// between WebKit laying it out and putting it on screen.
    func showFirstFrame() {
        guard unpainted else { return }
        unpainted = false
        onFirstFrame?()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    /// _WKRenderingProgressEventFirstVisuallyNonEmptyLayout — the moment
    /// Safari takes down the picture it shows while a page comes back.
    static let firstFrame: UInt = 1 << 1

    // MARK: - two fingers sideways

    private enum Axis { case across, down }

    private var sideways: CGFloat = 0
    private var gatheredX: CGFloat = 0
    private var gatheredY: CGFloat = 0
    private var axis: Axis?
    /// Which way the gesture set off, decided once and kept. Turning round
    /// mid-swipe pulls the disc back; it never becomes the other disc.
    private var back = true
    /// The page's word on whether this swipe is its own. Nil until it says.
    private var free: Bool?
    private var asked: Date?
    /// Already went somewhere, or was refused: nothing more this gesture.
    private var spent = false
    private var armedNow = false
    private var showing = false
    private var going = false
    private var pulls = 0
    /// Armed and held there: in a moment the disc becomes the list of pages
    /// that way, and moving the fingers up or down picks one (as in Dia).
    private var holding: DispatchWorkItem?
    private var stops: [Stop]?
    private var items: [WKBackForwardListItem] = []
    private var picked = 0
    /// How far the fingers have gone up (or down, below nought) since the
    /// last step through the list.
    private var climbed: CGFloat = 0
    /// How long armed before the list, and how far up or down a step is.
    private static let hold: TimeInterval = 0.45
    private static let step: CGFloat = 22

    /// How far the fingers travel before letting go means it. It was 110,
    /// and going back took a long reach across the trackpad — "too far",
    /// people said; Safari goes on less.
    private static let arm: CGFloat = 70
    /// A quick flick goes too, short of that, as it does in Safari: at least
    /// this far, within `flickTime` of setting off.
    private static let flick: CGFloat = 30
    private static let flickTime: TimeInterval = 0.25
    /// Less than this and there is nothing to show yet — or nothing left to.
    private static let show: CGFloat = 6

    override func scrollWheel(with event: NSEvent) {
        onTouch?()
        // The page gets every event first and scrolls as it always did. The
        // swipe is only read, never taken — except while its list is open,
        // when up and down are picking a page, not scrolling this one. The
        // gesture's end still reaches the page, which saw it begin.
        if stops == nil || event.phase == .ended || event.phase == .cancelled {
            super.scrollWheel(with: event)
        }
        // Only a live trackpad gesture — not its glide afterwards, and not a
        // mouse wheel, which has no beginning or end to speak of.
        guard event.momentumPhase == [] else { return }
        // And only while the Mac says a swipe may go between pages.
        guard Swipe.followsTheMac else { return }

        switch event.phase {
        case .mayBegin, .began:
            sideways = 0
            gatheredX = 0
            gatheredY = 0
            axis = nil
            free = nil
            asked = nil
            spent = false
            armedNow = false
            showing = false
            holding?.cancel()
            holding = nil
            stops = nil
            items = []
            // A disc still on its way out belongs to the last gesture. It is
            // already invisible; it is only taken off the stage so the next
            // one arrives fresh rather than fading back in.
            pulls += 1
            if going {
                going = false
                onPull?(nil)
            }
        case .changed:
            guard !spent else { return }
            if axis == nil {
                // A few points in, the gesture has shown which way it means
                // to go. Only a clearly sideways one is read further.
                gatheredX += abs(event.scrollingDeltaX)
                gatheredY += abs(event.scrollingDeltaY)
                sideways += event.scrollingDeltaX
                guard gatheredX + gatheredY > 6 else { return }
                axis = gatheredX > gatheredY * 1.3 ? .across : .down
                if axis == .down {
                    spent = true
                    return
                }
                back = sideways > 0
                // Nowhere to go that way: nothing to show, and nothing more
                // to read from this gesture.
                if back ? !canGoBack && leave == nil : !canGoForward {
                    spent = true
                    return
                }
                asked = Date()
                tell()
                return
            }
            sideways += event.scrollingDeltaX
            if stops != nil { climb(event) }
            tell()
        case .ended:
            release()
        case .cancelled:
            spent = true
            settle(nil)
        default:
            break
        }
    }

    /// The page has said whether the swipe would scroll something.
    func answer(free yes: Bool) {
        guard axis != .down, !spent else { return }
        guard yes else {
            free = false
            spent = true
            settle(nil)
            return
        }
        guard free == nil else { return }
        free = true
        tell()
    }

    /// Back from the first page, where that means leaving.
    private var leaves: Bool { back && !canGoBack && leave != nil }

    /// Not from inside the event: leaving closes the window this view is in,
    /// and the page with it.
    private func leaveSoon() {
        DispatchQueue.main.async { [weak self] in self?.leave?() }
    }

    /// Only the distance in the direction it set off in. Past the origin the
    /// other way is just nought.
    private var travel: CGFloat { max(0, back ? sideways : -sideways) }

    private func tell() {
        if free == nil, let asked, Date().timeIntervalSince(asked) > 0.18 {
            // A page that never answers — a PDF, a page that failed to load —
            // still has to be leavable by hand.
            free = true
        }
        guard free == true else { return }

        let travel = travel
        // Drawn all the way back, the disc goes; drawn out again, it returns.
        // Nothing is decided until the fingers lift.
        guard travel >= PageView.show else {
            if showing { settle(nil) }
            return
        }

        let armed = travel >= PageView.arm
        if stops == nil, armed != armedNow {
            holding?.cancel()
            holding = nil
            if armed {
                let hold = DispatchWorkItem { [weak self] in self?.openList() }
                holding = hold
                DispatchQueue.main.asyncAfter(deadline: .now() + PageView.hold, execute: hold)
            }
        }
        if armed != armedNow, stops == nil {
            // Two different taps: one for reaching it, a lighter one for
            // stepping back from it, so you know without looking that
            // letting go now is safe.
            NSHapticFeedbackManager.defaultPerformer.perform(
                armed ? .levelChange : .alignment, performanceTime: .now
            )
        }
        armedNow = armed
        settle(Pull(back: back, travel: travel, armed: armed, going: false, stops: stops, picked: picked, leaves: leaves))
    }

    /// Held long enough: the pages that way, nearest to the fingers — at the
    /// bottom going back, at the top going forward — and that one picked.
    private func openList() {
        holding = nil
        guard !spent, armedNow, stops == nil else { return }
        let list = back ? Array(backForwardList.backList.suffix(8)) : Array(backForwardList.forwardList.prefix(8))
        guard list.count >= 2 else { return }
        items = list
        stops = list.map { Stop(title: $0.title ?? "", url: $0.url) }
        picked = back ? list.count - 1 : 0
        climbed = 0
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        tell()
    }

    /// Through the list a step at a time, the list sliding with the fingers
    /// under a light that stays put, as in Dia: down brings the row above
    /// under it — further back, or nearer going forward — and up the row
    /// below. With natural scrolling the deltas run with the fingers,
    /// without it against them.
    private func climb(_ event: NSEvent) {
        guard let stops else { return }
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        climbed += -sign * event.scrollingDeltaY
        var moved = false
        while climbed >= PageView.step, picked < stops.count - 1 {
            picked += 1
            climbed -= PageView.step
            moved = true
        }
        while climbed <= -PageView.step, picked > 0 {
            picked -= 1
            climbed += PageView.step
            moved = true
        }
        // At either end, the fingers going on further count for nothing.
        climbed = max(-PageView.step, min(PageView.step, climbed))
        if moved { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    private func release() {
        defer { spent = true }
        // Let go before the list came: it doesn't come now.
        holding?.cancel()
        holding = nil
        let flicked = !spent && free == true && travel >= PageView.flick
            && (asked.map { Date().timeIntervalSince($0) <= PageView.flickTime } ?? false)
        guard !spent, free == true, armedNow || flicked || stops != nil else {
            settle(nil)
            return
        }
        going = true
        settle(Pull(back: back, travel: travel, armed: true, going: true, stops: stops, picked: picked, leaves: leaves))
        if stops != nil, items.indices.contains(picked) {
            go(to: items[picked])
        } else if leaves {
            leaveSoon()
        } else if back {
            goBack()
        } else {
            goForward()
        }
        pulls += 1
        let mine = pulls
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self, pulls == mine else { return }
            going = false
            settle(nil)
        }
    }

    private func settle(_ pull: Pull?) {
        if pull == nil {
            holding?.cancel()
            holding = nil
            stops = nil
            items = []
        }
        showing = pull != nil
        onPull?(pull)
    }
}
