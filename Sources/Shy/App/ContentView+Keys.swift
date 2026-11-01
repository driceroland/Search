import SwiftUI
import AppKit
import Combine

// Keys: what the window does with the ones the page and the field don't take.
extension ContentView {
    /// A web view takes first responder and keeps most of the keyboard, so the
    /// shortcuts are caught before the event ever reaches it. The menu carries
    /// the same commands for anyone looking for them, and never sees these
    /// keystrokes because this runs first.
    func watchKeys() {
        let id = ObjectIdentifier(browser)
        if let old = ContentView.monitors[id] { NSEvent.removeMonitor(old) }
        ContentView.monitors[id] = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { event in
            // A click on the tab switcher, in this window only (see
            // Browser.clickTabSwitcher), turned into the top-left coordinates
            // SwiftUI's frames are in.
            if event.type == .leftMouseDown {
                guard let window, event.window === window, let height = window.contentView?.bounds.height
                else { return event }
                let at = event.locationInWindow
                return browser.clickTabSwitcher(at: CGPoint(x: at.x, y: height - at.y)) ? nil : event
            }
            // Every window has a monitor, and every monitor hears every key:
            // each takes only its own window's, and the one in front takes
            // those of windows that aren't a browser's (a panel, the little
            // window).
            guard mine(event) else { return event }
            guard event.type == .keyDown else {
                // ⌃ let go of switches to the tab the switcher is on — or
                // whichever its key is held with (Settings › Shortcuts).
                if browser.tabSwitcher.active, !ShortcutStore.shared.recentHeld(event.modifierFlags) {
                    browser.commitTabSwitch()
                }
                // ⌘ let go of ends a ⌘K walk, wherever it stopped.
                if !event.modifierFlags.contains(.command) { browser.landSummon() }
                return event
            }
            // Escape on a page filling the screen is WebKit's, which leaves
            // on the first one, as Safari does. Its window isn't a browser's,
            // so the key came here first and put away what was left up in
            // the window behind the video, a find bar or the address field,
            // and only the second press reached the page.
            // A ⌃Tab switcher up behind it goes too, or letting ⌃ go would
            // switch tabs as the page comes back. With Esc twice asked for
            // (Settings › General), as in Arc, the first press only puts a
            // reminder up (see FullScreenEscape).
            if event.keyCode == 53, let page = ContentView.pageFillingScreen(event) {
                if browser.tabSwitcher.active { browser.tabSwitcher.cancel() }
                guard browser.prefs.escapeTwice else { return event }
                return FullScreenEscape.shared.passes(event, to: page) ? event : nil
            }
            // A key typed while the field is on its way is the field's (holdKey),
            // Escape in a full-screen window included.
            if browser.holdKey(event) { return nil }
            // Escape in this window while it is itself in macOS full screen
            // (the green button, ⌃⌘F). Nothing in Shy wanting it, it went
            // on through the page to AppKit, which takes the window out of
            // full screen on it: one press, whatever it was meant for. With
            // Esc twice asked for, Shy's own Escape jobs still go first and
            // at one press — the find bar, the address field, a peek, a panel,
            // a rename, a new tab never sent anywhere, the ⌃Tab switcher —
            // and a press none of them wants is kept from the page and from
            // AppKit and counted instead (see FullScreenEscape): the first
            // puts the reminder up, a second within two seconds leaves. Held
            // down, its repeats are kept and count for nothing.
            if event.keyCode == 53, browser.prefs.escapeTwice, let window, event.window === window,
               window.styleMask.contains(.fullScreen) {
                if event.isARepeat { return nil }
                if take(event) { return nil }
                FullScreenEscape.shared.press(event, leaving: window)
                return nil
            }
            return take(event) ? nil : event
        }
        ContentView.keyHooks[id] = { event in take(event) ? nil : event }
    }

    /// Each browser's key monitor. Kept here rather than in the view, so
    /// that a window closed for good takes its monitor and hook with it
    /// (see `forget`), and they no longer hold its browser.
    private static var monitors: [ObjectIdentifier: Any] = [:]

    static func forget(_ browser: Browser) {
        let id = ObjectIdentifier(browser)
        if let monitor = monitors.removeValue(forKey: id) { NSEvent.removeMonitor(monitor) }
        keyHooks[id] = nil
    }

    /// Whether a key is this window's to act on.
    private func mine(_ event: NSEvent) -> Bool {
        if let window = event.window, let owner = Browsers.browser(for: window) {
            // Popup hosts have no ContentView monitor of their own.
            return owner.isPopup ? Browsers.acting === browser : window === self.window
        }
        return Browsers.acting === browser
    }

    /// The page a key goes to, if it fills the screen: one WebKit has in its
    /// own window, where the page's view takes the keys, or one whose page
    /// said it is going (Tab.immersed, which is how the bench fakes it).
    private static func pageFillingScreen(_ event: NSEvent) -> PageView? {
        guard let page = event.window?.firstResponder as? PageView else { return nil }
        let fills = page.fullscreenState != .notInFullscreen
            || Browsers.all.contains { $0.tabs.contains { $0.immersed && $0.built === page } }
        return fills ? page : nil
    }

    /// The same handling the key monitor gives an event, for the bench to
    /// put a key through the app's own path — each window's own.
    static var keyHooks: [ObjectIdentifier: (NSEvent) -> NSEvent?] = [:]

    /// The last key handed to the page before Shy acted on it (see
    /// `pageFirst`): if WebKit sends it back unused, it is Shy's.
    static var passed: NSEvent?

    /// The key a page was given in place of ⌘S, kept so it is dropped if
    /// WebKit sends it back unused (see Browser.handOver).
    static var handedOver: NSEvent?

    /// A key a page may want for itself — ⌘K in Slack, ⌘F in a Google Doc,
    /// ⌘S in an editor — goes to the page first, as it does in Chrome, and is
    /// Shy's only if the page leaves it unused: WebKit then sends the same
    /// event back through the app, and it comes here a second time. Only
    /// while the page has the keyboard; in the address field or a panel,
    /// Shy's keys are Shy's. The keys that make and close tabs and move
    /// between them stay Shy's first, as Chrome keeps them its own.
    ///
    /// ⌘K is always Shy's, on every page: the way to any open page is
    /// the one key that must never be taken (Drice; #238). Slack, X, GitHub
    /// and ChatGPT use it themselves, and given it first they kept it.
    ///
    /// ⌘← and ⌘→ are Shy's too while nothing is being typed: WebKit takes
    /// them to scroll the page sideways and never hands them back, so
    /// passing them on left them dead for going back and forward (#324).
    private func pageFirst(_ event: NSEvent, key: String, shifted: Bool) -> Bool {
        let reserved = (key == "t") || (key == "w") || (key == "n" && shifted)
            || ((key == "[" || key == "]" || key == "{" || key == "}") && shifted)
            || (key == "z" && browser.veiling)
            || (key == "k" && !shifted)
            || (!shifted && (event.keyCode == 123 || event.keyCode == 124) && !caretIn(event))
        guard !reserved, event.window?.firstResponder is PageView else { return false }
        if let passed = ContentView.passed, PageView.same(passed, event) {
            ContentView.passed = nil
            return false
        }
        ContentView.passed = event
        return true
    }

    /// Whether the caret is in something editable: the address field or a
    /// panel's, or a text box on the page. The page's own word on typing
    /// misses a click straight into a frame and never reaches into another
    /// site's, such as an embedded comment box; the web view has an input
    /// context while the caret is in something editable, in any frame.
    private func caretIn(_ event: NSEvent) -> Bool {
        event.window?.firstResponder is NSTextView || browser.active?.typing == true
            || browser.active?.built?.inputContext != nil
    }

    /// Whether the caret is in the window's address field: its field editor
    /// answers to the field, and the field to AddressField (Omnibox.swift).
    private static func inAddressField(_ window: NSWindow) -> Bool {
        guard let editor = window.firstResponder as? NSTextView else { return false }
        return (editor.delegate as? NSTextField)?.delegate is AddressField.Coordinator
    }

    /// Whether the tab switcher can come up: in this window, with nothing
    /// over the page it would have to cover. The find bar isn't one: it sits
    /// in a corner, stays open, and looks again on the tab picked (#553).
    private func canSwitchTabs(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        // Settings, History and the rest are tabs, and ⌃Tab goes to and
        // from them like any other.
        return !browser.reviewing && !browser.bookmarksOpen &&
            !browser.veiling && !browser.summoning && !browser.makingSpace &&
            browser.peekTab == nil && browser.editingTab == nil &&
            browser.asking == nil && browser.offering == nil && browser.suggesting == nil
    }

    /// The keys of the top row, by where they sit rather than what they type.
    static let digits: [UInt16: Int] = [

        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 0,
    ]

    private func take(_ event: NSEvent) -> Bool {
        // The ⇧⌘S a page was handed for its ⌘S (see Browser.handOver), back
        // unused: nobody's. Let through, the menu took it for ⌘S and the
        // sidebar folded straight back.
        if let back = ContentView.handedOver, PageView.same(back, event), event.modifierFlags.contains(.command),
           event.modifierFlags.intersection([.shift, .option]) == back.modifierFlags.intersection([.shift, .option]) {
            ContentView.handedOver = nil
            return true
        }
        // A question hanging from the window (Ask) answers its own keys. Esc
        // there is its Cancel: taken here, it closed the panel under it and
        // left the question up, with Return still on its first button.
        if event.window?.sheetParent != nil || NSApp.modalWindow != nil { return false }
        // A small window's keys are its own (see Little.swift).
        if let little = LittleWindow.owning(event.window) { return little.take(event) }
        // A popup window: ⌘W closes it, not a tab of the
        // window menus act on. New tabs return to its browser; Escape
        // dismisses its permission question.
        if let popup = Browsers.browser(for: event.window), popup.isPopup {
            if popup.websitePopup, let combo = KeyCombo(event: event) {
                if combo == ShortcutStore.shared.key(for: "file.newTab") { popup.newTab(); return true }
                if combo == ShortcutStore.shared.key(for: "file.newPrivateTab") { popup.newShyTab(); return true }
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, flags.isEmpty, popup.asking != nil {
                popup.cancelCapture()  // the screen's question too
                return true
            }
            guard event.shortcutCharacters == "w", flags == .command else { return false }
            popup.window?.performClose(nil)
            return true
        }
        // A key being typed into Settings › Shortcuts is for the box.
        guard !ShortcutStore.shared.recording else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.shortcutCharacters
        // ⌃Tab, or the key Settings › Shortcuts gave the switcher instead,
        // and whether ⇧ sends it back.
        let recent = ShortcutStore.shared.recentSwitch(event)

        // While the tab switcher is up, ⌃ and the arrows move through it and
        // ⌃Tab goes on below; any other key puts it away, and Escape does
        // nothing else. ⌃ is whatever the switcher's key is held with.
        if browser.tabSwitcher.active, recent == nil {
            if ShortcutStore.shared.recentOnly(flags) {
                let direction: TabSwitcher.Direction? = switch event.keyCode {
                case 123: .left
                case 124: .right
                case 125: .down
                case 126: .up
                default: nil
                }
                if let direction {
                    browser.tabSwitcher.move(direction)
                    return true
                }
            }
            // ⌃W, ⌃R, ⌃M, ⌃O, when Settings › Tabs has them on: the card
            // picked, closed, reloaded, muted or kept, and the switcher stays up.
            if let action = TabSwitcher.Action(event), let id = browser.tabSwitcher.selectedID {
                if !event.isARepeat { browser.act(action, onCard: id, in: browser.tabSwitcher) }
                return true
            }
            browser.tabSwitcher.cancel()
            if event.keyCode == 53 { return true }
        }

        // Escape puts the page back. On a blank tab there is no page to put
        // back, so it belongs to whatever else wants it.
        if event.keyCode == 53 {
            if browser.editingTab != nil {
                browser.cancelTabEdit()
                return true
            }
            if browser.peekTab != nil {
                browser.closePeek()
                return true
            }
            if browser.makingSpace {
                browser.cancelSpaceCreation()
                withAnimation(Motion.glide) { browser.makingSpace = false }
                return true
            }
            // The same panels in the same order as ⌘W (Browser.closeFront).
            if browser.closePanel() { return true }
            if browser.suggesting != nil {
                browser.dropChoice()
                return true
            }
            if browser.veiling {
                browser.toggleHiding()
                return true
            }
            if browser.reviewing {
                browser.reviewing = false
                return true
            }
            if browser.finding {
                browser.closeFind()
                return true
            }
            // One step at a time: the list first, then the field.
            if browser.picked != nil {
                browser.picked = nil
                return true
            }
            // A new tab never sent anywhere is itself what is open: Escape
            // takes it away, back to the tab you were on, which is the one
            // touched last. Chosen before closing, so close() doesn't wake a
            // neighbour on the way. Anything typed keeps it; so does being
            // the last tab, where closing it would close the window.
            if let blank = browser.active, blank.isBlank, browser.typed.isEmpty,
               let back = browser.tabs.filter({ $0.id != blank.id }).max(by: { $0.touched < $1.touched }) {
                browser.select(back)
                browser.close(blank)
                return true
            }
            guard browser.editing, browser.active?.isBlank == false else { return false }
            browser.dismiss()
            return true
        }

        // Keep split focus ahead of WebKit's arrow-key handling. Its panes
        // remain native first responders, so the menu shortcut alone would
        // never see ⌃⌘→ on a page.
        if browser.activeSplit != nil, let combo = KeyCombo(event: event) {
            let store = ShortcutStore.shared
            if combo == store.key(for: "tabs.focusLeftPane") { browser.focusPane(onLeft: true); return true }
            if combo == store.key(for: "tabs.focusRightPane") { browser.focusPane(onLeft: false); return true }
            if combo == store.key(for: "tabs.focusOtherPane") { browser.focusOtherPane(); return true }
        }

        // ⌘Return keeps a peek, as its other button does: Return or the
        // keypad's Enter, by the key rather than what it types, whatever Caps
        // Lock says. Not while typing in the peeked page — a comment box or
        // a mail there sends with the same keys — by the page's word or by
        // the caret being in something editable, in any frame.
        // ⌥⌘Return keeps it beside the page instead.
        if event.keyCode == 36 || event.keyCode == 76,
           flags.intersection([.command, .shift, .option, .control]) == .command
            || (flags.intersection([.command, .shift, .option, .control]) == [.command, .option]),
           let peek = browser.peekTab, !peek.typing, peek.built?.inputContext == nil {
            browser.keepPeek(beside: flags.contains(.option))
            return true
        }

        // Tab is the page's: it moves between a form's fields and a page's
        // links, as in every browser. It used to walk the row of tabs, which
        // took it from anyone filling in a form. ⌃Tab walks the row and comes
        // round to the first again, ⌃⇧Tab the other way — the keys every
        // other browser uses for that.
        //
        // ⌃Tab brings up the switcher instead, most recently used first —
        // whenever there is nothing over the page it would have to cover;
        // otherwise it walks the row as before.
        //
        // While an address is being typed, the list under the field is what
        // there is to move through, and Return takes whatever the walk landed on.
        //
        // The switcher's key can be another (Settings › Shortcuts, as in
        // Arc); ⌃Tab is then whatever command has it, or the page's.
        if let backwards = recent {
            if canSwitchTabs(event) {
                // A key held down doesn't race through them.
                if !event.isARepeat { browser.switchTabs(backwards: backwards) }
                return true
            }
            browser.step(backwards ? -1 : 1)
            return true
        }
        if event.keyCode == 48, !flags.contains(.command), !flags.contains(.option), !flags.contains(.control) {
            if browser.editingTab != nil { return true }
            // "red" then Tab: Reddit, in the field (SiteSearch.swift).
            if browser.fieldShowing, !flags.contains(.shift), browser.lockSiteOffer() { return true }
            if browser.fieldShowing, !browser.offers.isEmpty {
                browser.walk(flags.contains(.shift) ? -1 : 1)
                return true
            }
            return false
        }

        // Space keys have no menu; other commands arrive here when rebound.
        // A key taken off a command goes back to the page.
        if ShortcutStore.shared.anyChanged, let combo = KeyCombo(event: event) {
            if let command = ShortcutStore.shared.customCommand(on: combo) {
                if command.section == .spaces { return false }
                command.run(browser)
                return true
            }
            if ShortcutStore.shared.isFreed(combo) { return false }
        }

        // A shortcut an extension registered — ⌥⇧D, ⌃⇧Y — before ours, since
        // none of ours use those. Never one of ours, nor one of the Mac's:
        // those an extension doesn't get (see ShortcutStore.adopt).
        if #available(macOS 15.4, *), !flags.intersection([.command, .option, .control]).isEmpty,
           KeyCombo(event: event).map({ !ShortcutStore.shared.keepsFromExtensions($0) }) ?? true,
           Extensions.shared.take(event) {
            return true
        }

        guard flags.contains(.command) else { return false }
        let shifted = flags.contains(.shift)

        if flags.contains(.option), !shifted, !flags.contains(.control),
           event.shortcutKey == "r" {
            if pageFirst(event, key: "r", shifted: false) { return false }
            browser.reload(fromOrigin: true)
            return true
        }

        // Other shortcuts with ⌥ or ⌃ on top are somebody else's.
        guard !flags.contains(.option), !flags.contains(.control) else { return false }

        // ⌘Return in the address field: what is typed there in a new tab,
        // the one you are on left as it was, as in Safari; ⇧⌘Return goes to
        // it. Here rather than in the field's delegate, which ⌘Return doesn't
        // reliably reach. Only this window's own address field: ⌘Return in a
        // page, the peek, or another box (Settings, History's search) is
        // theirs as before.
        if event.keyCode == 36 || event.keyCode == 76, browser.fieldShowing,
           browser.editingTab == nil, let window, event.window === window,
           ContentView.inAddressField(window) {
            browser.submit(aside: true, front: shifted)
            return true
        }

        // ⌘1 through ⌘9, and ⌘0, by the key rather than the character it
        // types. On AZERTY and many other layouts the top row types &, é, "…
        // unless shift is held, so matching the character left these
        // shortcuts dead there; the shortcut belongs to the key, as it does
        // in every other browser. The ninth is the last tab or folded folder;
        // a folded folder counts once, under its name.
        if !shifted, let number = ContentView.digits[event.keyCode] {
            if number == 0 {
                browser.resetZoom()
            } else {
                browser.select(index: number == 9 ? browser.tabShortcutTargets.count - 1 : number - 1)
            }
            return true
        }

        // Keep the clearing controls reachable from a focused page editor.
        if shifted, event.keyCode == 51 {
            browser.recallMode = .clearing
            return true
        }

        // ⌘S is Shy's even on a page that wants it: the page gets ⇧⌘S instead.
        if key == "s", !shifted, flags == .command, let page = event.window?.firstResponder as? PageView,
           ShortcutStore.shared.key(for: "view.fold") == KeyCombo("s") {
            // Held down, it folds once rather than flickering in and out.
            if event.isARepeat { return true }
            browser.toggleFold()
            browser.handOver(event, to: page)
            return true
        }

        // The page's turn first, for the keys it may want (Refs #147).
        if pageFirst(event, key: key, shifted: shifted) { return false }

        switch key {
        case "t" where !shifted:
            browser.launch()
        case "t" where shifted:
            browser.reopen()
        case "c" where shifted:
            browser.copyAddress()
        case "d" where !shifted:
            browser.duplicate()
        case "n" where shifted:
            browser.newShyTab()
        // Shown, or brought forward if open: never a second one, and never
        // closed by the key that opened it — ⌘W does that, as for any tab.
        case "y" where !shifted:
            browser.recalling = true
        case "j" where shifted:
            browser.hoarding = true
        case "v" where shifted:
            // In a text field this key is paste without formatting — a Google
            // Doc, a form, the address field. It only means Paste and Go when
            // nothing is being typed. Passing the key on is not enough: WebKit
            // has no use for ⌘⇧V, hands it back, and the menu's Paste and Go
            // takes it. So the plain paste is done here, as Chrome does.
            // A web view has an input context only while the caret is in
            // something editable, in any frame — including frames the page's
            // own script can't look into, like the one a Google Doc types in.
            if browser.active?.typing == true || browser.active?.built?.inputContext != nil
                || browser.editing || event.window?.firstResponder is NSTextView {
                _ = event.window?.firstResponder?.tryToPerform(#selector(NSTextView.pasteAsPlainText(_:)), with: nil)
            } else {
                browser.pasteAndGo()
            }
        case "p" where !shifted:
            browser.printPage()
        case "f" where !shifted:
            browser.openFind()
        case "g":
            browser.look(forward: !shifted)
        case "m" where shifted:
            browser.pauseMedia()
        case "p" where shifted:
            browser.toggleFloat()
        case "k" where !shifted:
            // Held down, ⌘K walks the list a step at a time; letting go of ⌘
            // takes wherever it stopped.
            if browser.editing, !browser.offers.isEmpty {
                browser.stepSummon()
            } else {
                browser.summon()
            }
        case "s" where !shifted:
            // The column or the strip, folded away (see Fold.swift).
            browser.toggleFold()
        case "b" where shifted:
            browser.bookmarkCurrent()
        case "," where !shifted:
            browser.tuning = true
        case "h" where shifted:
            browser.toggleHiding()
        case "u" where shifted:
            browser.reviewing.toggle()
        case "z" where !shifted:
            // Only while pointing. Everywhere else undo belongs to the page.
            guard browser.veiling else { return false }
            browser.undoHiding()
        // ⌘+ arrives as "=" or "+" depending on the keyboard; both mean bigger.
        case "=", "+":
            browser.zoom(by: 1.1)
        case "-":
            browser.zoom(by: 1 / 1.1)
        case "0":
            browser.resetZoom()
        case "w" where !shifted:
            browser.closeFront()
        case "w" where shifted:
            browser.closeWindow()
        case "l" where !shifted:
            browser.edit()
        case "r" where !shifted:
            browser.reload()
        case "r" where shifted:
            browser.toggleReader()
        case "[":
            shifted ? browser.step(-1) : browser.back()
        case "]":
            shifted ? browser.step(1) : browser.forward()
        default:
            // Moving or selecting text belongs to the editor, not the page's
            // history — in web forms and in the browser's own fields alike.
            guard !shifted, !caretIn(event) else { return false }
            // ⌘← and ⌘→, for hands that never learned the brackets.
            if event.keyCode == 123 { browser.back(); return true }
            if event.keyCode == 124 { browser.forward(); return true }
            return false
        }
        return true
    }
}
