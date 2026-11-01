import SwiftUI

/// Back or Forward held: every page that way, nearest at the top, each with
/// its site's mark, as Safari and Chrome list them. Picking one goes straight
/// there, however many steps away. Read when the menu opens, so it is never
/// a page behind.
@MainActor
enum Rewind {
    static func menu(_ tab: Tab, back: Bool) -> NSMenu? {
        let pages = tab.pages(back: back)
        guard !pages.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for page in pages {
            let title = page.title.flatMap { $0.isEmpty ? nil : $0 } ?? page.url.host() ?? page.url.absoluteString
            let item = Pick(title: title) { [weak tab] in tab?.go(to: page) }
            item.toolTip = page.url.absoluteString
            if let image = Favicons.of(tab.profile).cached(for: page.url, shy: tab.shy)?.copy() as? NSImage {
                image.size = NSSize(width: 16, height: 16)
                item.image = image
            } else {
                item.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            }
            menu.addItem(item)
        }
        return menu
    }

    /// A menu row that runs its own closure, its own target.
    private final class Pick: NSMenuItem {
        private let run: () -> Void

        init(title: String, run: @escaping () -> Void) {
            self.run = run
            super.init(title: title, action: #selector(fire), keyEquivalent: "")
            target = self
        }

        required init(coder: NSCoder) { fatalError() }

        @objc private func fire() { run() }
    }
}

/// Back, forward, reload. They watch the live tab, not the window: whether
/// there is anywhere to go back to is the tab's to say, and it changes with
/// every page. Used here and, beside the traffic lights instead of at the
/// far end of the row, in the sidebar.
struct Helm: View {
    @ObservedObject var browser: Browser

    var body: some View {
        if let tab = browser.active {
            Wheel(browser: browser, tab: tab)
        } else {
            // Nowhere to go and nothing to reload: the doors stay in place,
            // greyed, so the row doesn't shift when a tab arrives.
            HStack(spacing: 4) {
                Door(icon: "chevron.left") {}
                Door(icon: "chevron.right") {}
                Door(icon: "arrow.clockwise") {}
            }
            .opacity(0.3)
            .allowsHitTesting(false)
        }
    }

    private struct Wheel: View {
        let browser: Browser
        @ObservedObject var tab: Tab

        var body: some View {
            let back = !tab.isBlank && tab.canGoBack
            let forward = !tab.isBlank && tab.canGoForward
            HStack(spacing: 4) {
                Door(icon: "chevron.left", help: "Back   ⌘[", held: { Rewind.menu(tab, back: true) }) { browser.back() }
                    .disabled(!back)
                    .opacity(back ? 1 : 0.3)
                Door(icon: "chevron.right", help: "Forward   ⌘]", held: { Rewind.menu(tab, back: false) }) { browser.forward() }
                    .disabled(!forward)
                    .opacity(forward ? 1 : 0.3)
                // Reload, or stop while it is still coming.
                Door(
                    icon: tab.loading ? "xmark" : "arrow.clockwise",
                    help: tab.loading ? "Stop   ⌘." : "Reload   ⌘R"
                ) {
                    if tab.loading { tab.stop() } else { browser.reload() }
                }
                .disabled(!tab.isWeb)
                .opacity(tab.isWeb ? 1 : 0.3)
                // The menu's second item is the reason for it: ⌥⌘R has no
                // button. Nothing to offer while the door is Stop.
                .contextMenu {
                    if !tab.loading && tab.isWeb {
                        Button("Reload Page") { browser.reload() }
                            .shortcut("view.reload")
                        Button("Reload Page From Origin") { browser.reload(fromOrigin: true) }
                            .shortcut("view.reloadOrigin")
                    }
                }
            }
            .animation(Motion.quick, value: back)
            .animation(Motion.quick, value: forward)
            .animation(Motion.quick, value: tab.loading)
        }
    }
}

/// The address, inside its own tab.
///
/// A field of its own rather than SwiftUI's, for one reason: the system paints
/// selected text as a solid block of accent colour, which over a pale grey pill
/// this size is the loudest thing in the window. Here it is a tenth of the ink.
/// A tab picked up and carried along its row, the others making way as it
/// passes them — across the top or down the column alike.
///
/// The hand's travel is the tab's own: every move of the pointer redraws the
/// one tab being carried, not the whole column or bar around it (with the
/// neighbouring spaces drawn beside it, that was every row and every square
/// of three spaces, each frame, and the tab trailed behind the hand). The row
/// only redraws when the tab actually changes place.
struct Carried: ViewModifier {
    let index: Int
    let count: Int
    /// One place in the row: the tab's length and the gap after it.
    let step: CGFloat
    let vertical: Bool
    /// The row's coordinate space, not the tab's: a tab that has just moved
    /// keeps its bearings (see the sidebar's grid).
    let space: String
    var onDrop: ((CGPoint) -> Void)? = nil
    /// A paired item can be picked up from either half; report that source.
    var onDropTab: ((Tab, CGPoint) -> Void)? = nil
    /// Let go outside the window: true when the tab was taken elsewhere —
    /// another window, or a new one (see Browser.dragOut).
    var outside: (() -> Bool)? = nil
    var browser: Browser? = nil
    var tab: Tab? = nil
    /// Carried over another block that would take it — the pins, for a
    /// tab; the tabs, for a pinned row — at this point in the row's space:
    /// true while that block shows where it would land, and the row then
    /// holds its place rather than moving along its own.
    var cross: ((CGPoint) -> Bool)? = nil
    /// Let go (nil: the drag was called off): true when that block took it.
    var land: ((CGPoint?) -> Bool)? = nil
    /// Over that block: faint, so the place it opened shows through.
    var faded = false
    let move: (Int) -> Void

    @State private var held = false
    @State private var from = 0
    @State private var travel: CGFloat = 0
    @State private var reordered = false

    func body(content: Content) -> some View {
        // What it has travelled, less the ground its new place has already
        // given it.
        let shift = held ? travel - CGFloat(index - from) * step : 0
        return content
            .offset(x: vertical ? 0 : shift, y: vertical ? shift : 0)
            // Under the hand exactly. Its place in the row springs when it
            // passes another tab, and the offset springs back the same way —
            // until the next move of the hand cuts the offset's spring short
            // and leaves the place's running: the tab jumped a whole slot and
            // drifted back each time it passed one. Only the others glide.
            .transaction { if held { $0.animation = nil } }
            .zIndex(held ? 1 : 0)
            .shadow(color: .black.opacity(held ? 0.14 : 0), radius: 12, y: 4)
            .opacity(held && faded ? 0.4 : 1)
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named(space))
                    .onChanged { value in
                        if !held {
                            held = true
                            from = index
                        }
                        travel = vertical ? value.translation.height : value.translation.width
                        // Asked every move, so the block it left lets go
                        // of it as soon as it is elsewhere.
                        let crossed = cross?(value.location) == true
                        if let browser, let tab,
                           TabDrag.shared.update(browser: browser, tab: tab,
                                                 translation: value.translation) { return }
                        if crossed { return }
                        let target = min(max(0, from + Int((travel / step).rounded())), count - 1)
                        if target != index {
                            reordered = true
                            withAnimation(Motion.settle) { move(target) }
                        }
                    }
                    .onEnded { value in
                        if let browser, let tab {
                            let finished = TabDrag.shared.finish(browser: browser, tab: tab)
                            let source = finished.source
                            // Let go over the pins, or out of them: theirs,
                            // before anything else here.
                            let cancelled: Bool
                            if case .cancelled = finished.drop { cancelled = true } else { cancelled = false }
                            if land?(cancelled ? nil : value.location) != true {
                                switch finished.drop {
                                case .stage(let target, let onLeft):
                                    browser.pair(source, with: target, onLeft: onLeft)
                                case .strip(let target):
                                    browser.dropTabIntoStrip(source, before: target)
                                case .outside:
                                    if !browser.dragOut(source, at: finished.point) {
                                        if let onDropTab { onDropTab(source, value.location) }
                                        else if source.id == tab.id { onDrop?(value.location) }
                                    }
                                case .cancelled:
                                    if reordered { move(from) }
                                }
                            }
                        } else if land?(value.location) != true, outside?() != true {
                            if let onDropTab, let tab { onDropTab(tab, value.location) }
                            else { onDrop?(value.location) }
                        }
                        withAnimation(Motion.settle) {
                            held = false
                            travel = 0
                            reordered = false
                        }
                    }
            )
            .onReceive(TabDrag.shared.$cancelledID) { id in
                guard id == tab?.id, held else { return }
                _ = land?(nil)
                if reordered { move(from) }
                held = false
                travel = 0
                reordered = false
            }
    }
}

struct TabAddressField: NSViewRepresentable {
    @ObservedObject var browser: Browser

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5)
        field.textColor = Palette.NS.ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        // Without this the field editor stays as wide as the field: the text
        // past the edge is cut off, and the caret, Home/End and a click can't
        // reach it. Scrollable, the editor grows to the text and follows the caret.
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.stringValue = browser.tabDraft
        context.coordinator.watch(field)
        // The site card stands under whichever field the address is in, and
        // the list of places once something is typed.
        SiteCardPanel.follow(browser, anchor: field)
        TabOffersPanel.follow(browser, anchor: field)
        return field
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.unwatch()
    }

    /// The width it is offered, never the address's own. Left to its own,
    /// the field was as wide as the whole address and the row cut it off:
    /// a field that never runs out of room never scrolls, so the caret went
    /// on out of sight with ← and →, and so did what was typed at the end.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        let natural = field.intrinsicContentSize
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: max(0, width), height: proposal.height ?? natural.height)
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser
        if !coordinator.typing, field.stringValue != browser.tabDraft {
            field.stringValue = browser.tabDraft
        }
        guard !coordinator.claimed else { return }
        coordinator.claimed = true
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.11)),
                .foregroundColor: Palette.NS.ink,
            ]
            editor.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var claimed = false
        var typing = false
        /// A key that takes letters off: the field mustn't put the same
        /// letters straight back as a completion, or it can't be shortened.
        private var deleting = false

        init(browser: Browser) { self.browser = browser }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            typing = true
            defer { typing = false }
            let text = field.stringValue
            let ending = browser.tabTyped(text)
            // The rest of a place you have been, typed in selected, as ⌘L's
            // field does: the next key replaces it and Return takes it.
            if !deleting, let ending, let editor = field.currentEditor() as? NSTextView {
                field.stringValue = text + ending
                editor.selectedRange = NSRange(location: (text as NSString).length, length: (ending as NSString).length)
            }
            deleting = false
            browser.tabDraft = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                // Returning true keeps the field editing, which is what lets a
                // refused address stay on screen instead of being thrown away.
                browser.commitTabEdit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                browser.cancelTabEdit()
                return true
            case #selector(NSResponder.moveDown(_:)) where !browser.tabOffers.isEmpty:
                browser.walkTab(1)
                return true
            case #selector(NSResponder.moveUp(_:)) where !browser.tabOffers.isEmpty:
                browser.walkTab(-1)
                return true
            case #selector(NSResponder.deleteBackward(_:)),
                 #selector(NSResponder.deleteForward(_:)),
                 #selector(NSResponder.deleteWordBackward(_:)),
                 #selector(NSResponder.deleteWordForward(_:)),
                 #selector(NSResponder.deleteToBeginningOfLine(_:)):
                deleting = true
                return false
            default:
                return false
            }
        }

        /// Clicking anywhere else keeps what was typed, as Return does.
        func controlTextDidEndEditing(_ note: Notification) {
            let browser = browser
            DispatchQueue.main.async { browser.finishTabEdit() }
        }

        /// A press on something that takes no focus — the strip's empty
        /// stretch, the column below the rows — leaves the field focused and
        /// editing, so presses are watched for while it is there: one anywhere
        /// but in the field ends the edit the same way. The press itself goes
        /// on to what it was for.
        private var watcher: Any?

        @MainActor func watch(_ field: NSTextField) {
            guard watcher == nil else { return }
            watcher = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self, weak field] event in
                guard let self, let field, event.window === field.window,
                      !field.bounds.contains(field.convert(event.locationInWindow, from: nil))
                else { return event }
                let browser = self.browser
                DispatchQueue.main.async { browser.finishTabEdit() }
                return event
            }
        }

        @MainActor func unwatch() {
            if let watcher { NSEvent.removeMonitor(watcher) }
            watcher = nil
        }
    }
}

/// What a right-click on any tab offers, wherever the tab is drawn.
struct TabMenu: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let close: () -> Void

    var body: some View {
        if browser.selectedTabIDs.contains(tab.id) && browser.visibleSelectedTabCount > 1 {
            pickedMenu
        } else {
            singleMenu
        }
    }

    /// Right-clicked among tabs picked with ⇧ or ⌘: what can be done to all
    /// of them at once.
    @ViewBuilder
    private var pickedMenu: some View {
        let picked = browser.pickedTabs
        let count = picked.count
        if count == 2 && !browser.pickedTabsArePaired {
            Button("Open 2 Tabs in Split View") { browser.pairPickedTabs(focus: tab) }
                .disabled(browser.pickedPair == nil)
            Divider()
        }
        Button("Pin \(count) Tabs") { browser.pinPicked() }
            .disabled(!picked.contains { $0.pin == nil && $0.isWeb && !$0.shy })
        Menu("Move \(count) Tabs to Space") {
            ForEach(browser.spaces.filter { $0.id != browser.spaceID }) { space in
                Button {
                    browser.movePicked(toSpace: space.id)
                } label: {
                    Label(space.name, systemImage: space.symbol)
                }
            }
        }
        .disabled(browser.spaces.count < 2)
        Button("Put \(count) Tabs to Sleep") { browser.sleepPicked() }
        Divider()
        Button("Copy Addresses") { browser.copySelectedTabLinks() }
            .disabled(browser.selectedTabLinkCount == 0)
        Divider()
        Button("Close \(count) Tabs") { browser.closePicked() }
        Button("Deselect") { browser.clearTabSelection() }
    }

    /// In sections, the way Safari's and Chrome's tab menus go: the tab
    /// itself, its pin, where it lives, how it is shown, copying it, and
    /// closing — each with a line between.
    @ViewBuilder
    private var singleMenu: some View {
        Button("Rename") { browser.beginTabRename(tab) }
        Button("Duplicate") {
            browser.select(tab)
            browser.duplicate()
        }
        .disabled(!tab.isWeb)
        // The card a click on the tab you are on shows under its address.
        Button("Site Information…") {
            if browser.activeID != tab.id { browser.select(tab) }
            browser.beginTabEdit(tab)
        }
        .disabled(tab.isBlank || tab.address == nil || tab.pin != nil)
        Button(tab.muted ? "Unmute Tab" : "Mute Tab") { tab.toggleMute() }
        // A copy of this site's sign-in for the agent's session, after a
        // card that says what goes (see HandoverCard). Never a private tab's.
        if Shared.prefs.agent, Agent.shared.running {
            Button("Hand Over to Agent…") { browser.handingOver = tab }
                .disabled(tab.shy || Agent.web(tab.address?.absoluteString) == nil)
        }
        // Its page let go of now, as it would be after half an hour unseen:
        // the row keeps its title and picture, and it loads again when gone
        // to. Not the tab on screen, nor one that has to stay awake (#310).
        Button("Put to Sleep") {
            browser.sleep(tab) { outcome in
                if outcome != "asleep" { browser.announce("Stays awake: \(outcome)") }
            }
        }
        .disabled(browser.awake(because: tab) != nil)
        // The bar under this tab's page (see DeveloperBar.swift): on by
        // itself for this Mac's own servers.
        Toggle("Developer Mode", isOn: Binding(get: { DevTools.shared.isOn(tab) },
                                               set: { DevTools.shared.set(tab, on: $0) }))
            .disabled(!tab.isWeb)
        Divider()
        if tab.pin == nil {
            Button("Pin") { browser.pin(tab) }
                .disabled(!tab.isWeb || tab.shy)
            Button("Pin as Row") { browser.pin(tab, listed: true) }
                .disabled(!tab.isWeb || tab.shy)
        } else {
            Button(tab.listed ? "Show as Square" : "Show as Row") { browser.setListed(tab, !tab.listed) }
            // A row's click is the address, so the way home a square's
            // double-click is (Browser.goHome) is here instead, while it
            // has wandered.
            if tab.listed {
                Button("Back to Pinned Page") { browser.goHome(tab) }
                    .disabled(tab.home.map { Browser.samePage($0, tab.address) } ?? true)
            }
            // The page it has wandered to kept as its pinned page instead.
            if browser.wandered(tab) {
                Button("Make This the Pinned Page") { browser.repin(tab) }
            }
            Button("Unpin") { browser.unpin(tab) }
        }
        Divider()
        // Into a folder among the pinned rows: kept there, as a pinned row
        // is (see Folders.swift). A folder in a folder is listed under the
        // one it is in, set in.
        if browser.filable(tab), tab.page == nil {
            let tops = Folders.tops(browser.folders)
            let current = browser.folder(of: tab)?.id
            Menu("Move to Folder") {
                Button("New Folder") {
                    if let made = browser.newFolder() { browser.move(tab, toFolder: made) }
                }
                if !tops.isEmpty { Divider() }
                ForEach(tops) { folder in
                    Button(folder.name) { browser.move(tab, toFolder: folder.id) }
                        .disabled(current == folder.id)
                    ForEach(browser.folders.filter { $0.parent == folder.id }) { inner in
                        Button("    " + inner.name) { browser.move(tab, toFolder: inner.id) }
                            .disabled(current == inner.id)
                    }
                }
                if current != nil {
                    Divider()
                    Button("Out of Folder") { browser.move(tab, toFolder: nil) }
                }
            }
        }
        if !tab.bench,
           tab.address.flatMap({ Browser.extensionHost(of: $0) }) == nil {
            Menu("Move to Space") {
                ForEach(browser.spaces.filter { $0.id != browser.spaceID }) { space in
                    Button {
                        browser.move(tab, toSpace: space.id)
                    } label: {
                        Label(space.name, systemImage: space.symbol)
                    }
                }
                if browser.spaces.count > 1 { Divider() }
                Button("New Space…") {
                    browser.askForSpace { space in
                        browser.move(tab, toSpace: space.id) {
                            browser.switchSpace(to: space.id)
                        }
                    }
                }
            }
            .help("Pages moved to a Space with different sign-ins reopen there.")
        }
        if tab.pin == nil, !tab.bench {
            // Another window, or a new one (see Browser.moveToWindow).
            let others = Browsers.all.filter { $0 !== browser && $0.isOpen && !$0.isPopup }
            if others.isEmpty {
                Button("Move to New Window") { browser.moveToWindow(tab, nil) }
                    .disabled(browser.tabs.count < 2)
            } else {
                Menu("Move to Window") {
                    Button("New Window") { browser.moveToWindow(tab, nil) }
                        .disabled(browser.tabs.count < 2)
                    Divider()
                    ForEach(Array(others.enumerated()), id: \.offset) { _, other in
                        Button(other.windowName) { browser.moveToWindow(tab, other) }
                    }
                }
            }
        }
        Divider()
        // Right-clicked among tabs picked in the column: those two side
        // by side. More than two can't be, so it is there but off.
        let picked = browser.selectedTabIDs.contains(tab.id) ? browser.visibleSelectedTabCount : 1
        if picked > 1 && !browser.pickedTabsArePaired {
            Button("Open 2 Tabs in Split View") { browser.pairPickedTabs(focus: tab) }
                .disabled(browser.pickedPair == nil)
        }
        if browser.split(for: tab) != nil {
            Button("Swap Pages") {
                browser.focusPane(tab)
                browser.swapSplit()
            }
            Button("Separate Split Tabs") { browser.detachSplit(tab) }
            Button("Close Both Pages") {
                browser.focusPane(tab)
                browser.closeSplit()
            }
        } else if picked == 1 {
            // Beside the page on screen; on that page itself, an empty
            // page beside it.
            Button("Open in Split View") { browser.openInSplit(tab) }
                .disabled(tab.bench)
        }
        Button("Open in Side Panel") { browser.openInSidePanel(tab) }
            .disabled(!tab.isWeb || tab.shy)
        Divider()
        Button("Copy Address") {
            browser.select(tab)
            browser.copyAddress()
        }
        .disabled(!tab.isWeb)
        Button("Copy Clean Link") {
            browser.select(tab)
            browser.copyCleanLink()
        }
        .disabled(!tab.isWeb)
        Button("Copy as Markdown Link") {
            browser.select(tab)
            browser.copyMarkdownLink()
        }
        .disabled(!tab.isWeb)
        // Right-clicked among tabs picked in the column: all their addresses.
        if browser.selectedTabIDs.contains(tab.id) && browser.visibleSelectedTabCount > 1 {
            Button("Copy Addresses") { browser.copySelectedTabLinks() }
                .disabled(browser.selectedTabLinkCount == 0)
        }
        Divider()
        Button("Close Tab", action: close)
        Button("Close Other Tabs") { browser.closeOthers(but: tab) }
            .disabled(browser.tabs.count < 2)
        // ⌘⇧T, and the History menu's Recently Closed, where few think to
        // look for it: here too, where tabs are closed.
        Button(browser.reopenTitle) { browser.reopen() }
            .disabled(browser.closedHere.isEmpty)
    }
}

/// Observe the press without recognizing a hold that would take the row's drag.
struct TabPress: ViewModifier {
    let enabled: Bool
    let active: Bool
    @Binding var selected: Bool
    /// Told when the button goes down on the tab and comes back up, whatever
    /// the press goes on to do, for the tab to give under it (see Give).
    var pressing: Binding<Bool>? = nil
    let act: () -> Void

    /// How far the hand may go before the press gives way to the row's
    /// drag, which starts at 5. A long press that never gave way (as this
    /// was first written, with no limit) kept the press to itself: the drag
    /// that carries a row or a pin waited for it to fail, which it only did
    /// at the release, so nothing moved under the hand — the row jumped to
    /// its place on letting go, and a pin held still a moment before
    /// letting go wasn't moved at all.
    static let travel: CGFloat = 4

    func body(content: Content) -> some View {
        content.onLongPressGesture(minimumDuration: .infinity, maximumDistance: TabPress.travel, pressing: { down in
            pressing?.wrappedValue = down
            if !down {
                // Given way to a drag, the button still down: what the press
                // did stands until the release, so the release can't take
                // it for a fresh click on the tab now on screen.
                if NSEvent.pressedMouseButtons & 1 != 0 {
                    TabPress.untilRelease { selected = false }
                    return
                }
                // The row's release handler must see which press selected it.
                DispatchQueue.main.async { selected = false }
                return
            }
            guard enabled, NSEvent.modifierFlags.intersection([.command, .control, .shift]).isEmpty else { return }
            selected = !active
            if selected { act() }
        }, perform: {})
    }

    /// Once, at the left button's release.
    private static func untilRelease(_ act: @escaping () -> Void) {
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            DispatchQueue.main.async(execute: act)
            return event
        }
    }
}

/// A modified tap selects tabs; a drag stays with the row's drag gesture.
struct ModifiedTabClick: ViewModifier {
    let act: (NSEvent.ModifierFlags) -> Void

    func body(content: Content) -> some View {
        content.simultaneousGesture(TapGesture().onEnded {
            let modifiers = NSEvent.modifierFlags
            if !modifiers.intersection([.command, .shift]).isEmpty { act(modifiers) }
        })
    }
}

/// One gesture or the other, never the two together.
struct OneClick: ViewModifier {
    let double: Bool
    let act: () -> Void

    /// One gesture whose count changes, not two in turn: a pin becomes
    /// the one on screen as the button goes down (TabPress), and swapping
    /// one tap for the other then made the square anew under the hand, which
    /// dropped the drag that had picked it up.
    func body(content: Content) -> some View {
        content.onTapGesture(count: double ? 2 : 1, perform: act)
    }
}

/// A click on a tab's cross closes it — taken by a real view laid over the
/// cross rather than by a SwiftUI tap. Out over the page, in the strip folded
/// away with ⌘S, the tap never came: the cross showed under the pointer and
/// clicking it did nothing (Drice). A view of AppKit's own is handed the
/// press by AppKit itself, as the middle button's is (MiddleClick), and it
/// answers only while the cross is there to be pressed, only to the left
/// button; to anything else it isn't there, and the tab goes on as before.
struct CloseClick: NSViewRepresentable {
    let armed: Bool
    let act: () -> Void

    func makeNSView(context: Context) -> NSView { Cross() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Cross)?.armed = armed
        (view as? Cross)?.act = act
    }

    private final class Cross: NSView {
        var armed = false
        var act: () -> Void = {}
        private var pressed = false

        /// Never the window's to drag from: the press is the cross's.
        override var mouseDownCanMoveWindow: Bool { false }

        /// Asked about every event over the cross, the pointer moving included;
        /// only a left press, while the cross shows, is this view's.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard armed, let event = NSApp.currentEvent,
                  event.type == .leftMouseDown, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            else { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            pressed = true
        }

        /// On the release, and only if it is still over the cross: a press
        /// taken back by moving off before letting go closes nothing.
        override func mouseUp(with event: NSEvent) {
            guard pressed else { return }
            pressed = false
            if bounds.contains(convert(event.locationInWindow, from: nil)) { act() }
        }
    }
}

/// The middle button on a tab closes it, as it does in every other browser.
///
/// SwiftUI has no gesture for that button, so this is a real view laid over
/// the tab — and a real view is asked first (see DragStrip). It says yes for
/// the middle button and nothing else: to a left click, a drag or a right
/// click it isn't there, and the tab's own gestures and menu go on as before.
struct MiddleClick: NSViewRepresentable {
    let act: () -> Void

    func makeNSView(context: Context) -> NSView { Catch() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Catch)?.act = act
    }

    private final class Catch: NSView {
        var act: () -> Void = {}
        private var pressed = false

        /// Asked about every event that lands on the tab, the pointer moving
        /// over it included; the one being delivered is the one to judge by.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .otherMouseDown || event.type == .otherMouseUp,
                  event.buttonNumber == 2
            else { return nil }
            return super.hitTest(point)
        }

        override func otherMouseDown(with event: NSEvent) {
            pressed = true
        }

        /// On the release, not the press, and only if it is still over the
        /// tab: a middle button pressed by mistake can be taken back the way
        /// a click on the cross can, by moving off before letting go.
        override func otherMouseUp(with event: NSEvent) {
            guard pressed else { return }
            pressed = false
            if bounds.contains(convert(event.locationInWindow, from: nil)) { act() }
        }
    }
}

/// An almost-closed ring, turning — the same one the canvas app uses, small
/// enough to sit inside a tab without becoming the loudest thing in it.
///
/// Turned by Core Animation rather than SwiftUI. A SwiftUI animation that
/// never ends has the whole window's view tree laid out and redrawn every
/// frame for as long as it runs — a fifth of a core, all the while a page
/// in some tab behind was still loading. A layer's own animation is played
/// by the render server and costs this process nothing.
struct Ring: NSViewRepresentable {
    var size: CGFloat = 10

    func makeNSView(context: Context) -> RingView { RingView() }
    func updateNSView(_ view: RingView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RingView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }

    final class RingView: NSView {
        private let ring = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            ring.fillColor = nil
            ring.lineWidth = 1.4
            ring.lineCap = .round
            ring.strokeEnd = 0.78
            // Nothing but the turn moves: a new size or colour is there at
            // once, not eased into by Core Animation's own quarter second.
            ring.actions = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(), "strokeColor": NSNull()]
            layer?.addSublayer(ring)
        }

        required init?(coder: NSCoder) { nil }

        /// Seen, never pressed: it sits in a tab, over the × while the page
        /// loads and in the middle of a tab down to its mark, and a real view
        /// would take the click meant for either.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            let inset = ring.lineWidth / 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.frame = bounds
            ring.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
            CATransaction.commit()
        }

        /// The colour is resolved against the window's appearance, so it is
        /// set again whenever that changes.
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            effectiveAppearance.performAsCurrentDrawingAppearance {
                ring.strokeColor = Palette.NS.muted.withAlphaComponent(0.7).cgColor
            }
        }

        /// Turning only while it is in a window: a layer animation is dropped
        /// when the view leaves one, so it is added each time it arrives.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            viewDidChangeEffectiveAppearance()
            ring.removeAnimation(forKey: "turn")
            guard window != nil else { return }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            // Clockwise, as the SwiftUI one turned: a layer's positive angle
            // is anticlockwise in a view that isn't flipped.
            turn.fromValue = 0
            turn.toValue = -2 * Double.pi
            turn.duration = 0.85
            turn.repeatCount = .infinity
            ring.add(turn, forKey: "turn")
        }
    }
}


