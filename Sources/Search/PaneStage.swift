import AppKit
import Combine
import SwiftUI
import WebKit

// Split View's stage, while the switch is on: one AppKit view that holds
// every page on screen, one to four, and is never rebuilt — not from one tab
// to the next, not from one page to two or more. Each page keeps a StageView of its
// own (see Stage.swift), so everything that stage learned about taking a
// page back holds here too. With the switch off none of this exists, and the
// window's stage is the one it always was.
//
// The dividers are this view's own: one between each two pages, each follows
// the pointer, lays the pages out as it goes, and tells the split once, when
// the button comes up. Nothing is
// published while it moves — not to the window, the row or the menus.

/// The stage, for SwiftUI. Its identity never changes; what it shows does.
struct PaneStageView: NSViewRepresentable {
    let tabs: [Tab]
    let split: TabSplit?
    let focused: Tab.ID?
    let commit: (UUID, [Double]) -> Void
    let focus: (Tab) -> Void
    let frames: ([Tab.ID: CGRect]) -> Void
    let action: (PaneStage.Action) -> Void
    let hover: (Tab.ID?) -> Void
    var find: Browser? = nil
    /// The accounts hanging from the sign-in box the caret is in, if any.
    var accounts: (browser: Browser, asked: Browser.Suggesting)? = nil
    /// Each page's corners, as a card (see CardEdge).
    var corner: CGFloat = 0
    /// The page filling the screen, if one is (see SplitStage.immersed).
    var immersed: Tab.ID? = nil

    func makeNSView(context: Context) -> PaneStage { PaneStage() }

    func updateNSView(_ stage: PaneStage, context: Context) {
        stage.corner = corner
        stage.immersedID = immersed
        stage.onCommit = commit
        stage.onFocus = focus
        stage.onFrames = frames
        stage.onAction = action
        stage.onHover = hover
        stage.show(tabs, split: split, focused: focused)
        stage.showFind(find)
        stage.showAccounts(accounts)
    }
}

final class PaneStage: NSView {
    /// Each page's corners, as a card (see CardEdge): with the tabs down the
    /// side, each page on the stage is a card of its own, with the window's
    /// ground in the gutter between two.
    var corner: CGFloat = 0 {
        didSet {
            guard corner != oldValue else { return }
            for slot in slots { slot.corner = corner }
            paint()
            needsLayout = true
        }
    }
    /// The shadow under each page's card, a layer of the stage's own behind
    /// the page — never the page's, which is cut to its corners.
    private var shadows: [CALayer] = []
    var onCommit: ((UUID, [Double]) -> Void)?
    var onFocus: ((Tab) -> Void)?
    /// Where each page is, from the top left, each time that changes — never
    /// while the divider is being dragged.
    var onFrames: (([Tab.ID: CGRect]) -> Void)?
    /// The divider's menu.
    var onAction: ((Action) -> Void)?
    /// The page under the pointer, as it changes; nil off the stage.
    var onHover: ((Tab.ID?) -> Void)?
    private var hovered: Tab.ID?

    enum Action { case swap, even, separate, closeBoth }

    /// Between the pages: room for the divider, and to keep it off the left
    /// page's scroll bar.
    static let gutter: CGFloat = 7
    /// Narrower than this, a page is no use: the pair shows the focused page
    /// alone until there is room again, and stays a pair.
    static let narrowest: CGFloat = 250
    /// How close to even the divider has to come to settle there.
    static let snap: CGFloat = 15
    /// And how far past it the pointer goes before it lets go.
    static let unsnap: CGFloat = 20

    fileprivate var tabs: [Tab] = []
    fileprivate var split: TabSplit?
    private var focused: Tab.ID?
    private var findBar: FindHost?
    private var findWidth: CGFloat?

    /// The controls belong to the stage so they stay above WebKit, below
    /// window panels, and follow every layout of the focused page.
    func showFind(_ browser: Browser?) {
        guard let browser else {
            findBar?.removeFromSuperview()
            findBar = nil
            findWidth = nil
            return
        }
        if findBar == nil {
            let bar = FindHost(rootView: FindBar(browser: browser))
            bar.rootView.onPillFrame = { [weak bar] in bar?.pillFrame = $0 }
            findBar = bar
            addSubview(bar, positioned: .above, relativeTo: nil)
        }
        needsLayout = true
    }

    private var accountList: AccountHost?
    private var accountsFor: Tab.ID?

    /// The accounts under a sign-in box, for the same reason: drawn by
    /// SwiftUI over the stage, they were under WebKit's pages and never
    /// seen, though the list was up and a click on the box did nothing.
    func showAccounts(_ accounts: (browser: Browser, asked: Browser.Suggesting)?) {
        guard let accounts else {
            accountList?.removeFromSuperview()
            accountList = nil
            accountsFor = nil
            return
        }
        var view = AccountList(browser: accounts.browser, asked: accounts.asked)
        if accountList == nil {
            let host = AccountHost(rootView: FromTopLeft(content: view))
            host.sizingOptions = []
            accountList = host
            addSubview(host, positioned: .above, relativeTo: nil)
        }
        guard let host = accountList else { return }
        view.onFrame = { [weak host] in host?.card = $0 }
        host.spot = accounts.asked.spot
        host.rootView = FromTopLeft(content: view)
        accountsFor = accounts.asked.tab
        needsLayout = true
    }
    fileprivate var slots: [StageView] = []
    /// Between the first two pages: always there, so what is laid over or
    /// under the pages has one place to be put against.
    fileprivate let divider = PaneDivider()
    /// Between the second and third, the third and fourth, as there are pages.
    private var moreDividers: [PaneDivider] = []
    /// Each divider, the one after page `index` at `index`.
    fileprivate var dividers: [PaneDivider] { [divider] + moreDividers }
    private var watching: [AnyCancellable] = []
    private var watched: [ObjectIdentifier] = []
    private var queued = false
    private var monitor: Any?
    private var told: [Tab.ID: CGRect] = [:]
    /// Where the pages are while a divider is held (see dividerMoved).
    private var held: [Tab.ID: CGRect] = [:]
    /// The pages whose own background is off for a resize, and when it
    /// comes back (see backPages).
    private let unbacked = NSHashTable<WKWebView>.weakObjects()
    private var rebacking: DispatchWorkItem?

    /// Each page's share while a divider is held; nil otherwise.
    private var live: [Double]?
    /// The divider held: the one after this page.
    private var liveIndex = 0
    private var snapped = false
    /// Just let go of: the pair then told of it is no move to show.
    fileprivate var dragged = false
    /// Which change is the latest: a picture that arrives for an older one
    /// is let go.
    fileprivate var generation = 0
    /// The pictures standing in for pages while they move.
    fileprivate var pictures: [NSImageView] = []
    fileprivate var motionLog: [(NSImageView, CGRect, CGRect)] = []

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        divider.stage = self
        addSubview(divider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    override func updateLayer() {
        layer?.backgroundColor = Palette.NS.ground.cgColor
    }

    // MARK: - what is shown

    func show(_ tabs: [Tab], split: TabSplit?, focused: Tab.ID?) {
        // A change the eye should follow — a page arriving beside another,
        // one leaving, the two swapping, the divider moving by itself — is
        // shown moving (see `animate`). Anything else, a tab switch among
        // them, is a cut, as it always was.
        guard let move = motion(to: tabs, split: split), window != nil else {
            // The same pages again — SwiftUI asking once more — leave a move
            // under way alone; different ones cut it short.
            if tabs.map(\.id) != self.tabs.map(\.id) || split?.sizes != self.split?.sizes {
                generation += 1
                clearPictures()
            }
            return apply(tabs, split: split, focused: focused)
        }
        let before = placed()
        let leaving = self.tabs.filter { before[$0.id] != nil }
        generation += 1
        let ticket = generation
        capture(leaving) { [weak self] pictures in
            guard let self, ticket == self.generation else { return }
            self.clearPictures()
            self.apply(tabs, split: split, focused: focused)
            self.layoutSubtreeIfNeeded()
            self.animate(move, from: before, pictures: pictures)
        }
    }

    private func apply(_ tabs: [Tab], split: TabSplit?, focused: Tab.ID?) {
        let ids = tabs.map(ObjectIdentifier.init)
        if ids != watched {
            watched = ids
            // A tab going from blank to a page, to sleep or to the floating
            // window changes what its slot holds; the tab says so, not the
            // window. Put right once per turn of the run loop, however many
            // of its values changed in it.
            watching = tabs.map { tab in
                tab.objectWillChange.sink { [weak self] _ in self?.queue() }
            }
        }
        self.tabs = tabs
        self.split = split
        self.focused = focused
        if live != nil, split == nil || live?.count != tabs.count { live = nil }
        refill()
    }

    private func queue() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            queued = false
            refill()
        }
    }

    /// The page a tab puts on the stage: none while it is blank, one of
    /// Search's own pages, asleep or floating, as Page decides it (see
    /// Stage.swift).
    private func page(_ tab: Tab) -> NSView? {
        !tab.isWeb || tab.asleep || tab.floating ? nil : tab.web
    }

    private func refill() {
        while slots.count < tabs.count {
            let slot = StageView()
            slot.corner = corner
            addSubview(slot, positioned: .below, relativeTo: divider)
            slots.append(slot)
            let shadow = CALayer()
            shadow.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            layer?.insertSublayer(shadow, at: 0)
            shadows.append(shadow)
        }
        while moreDividers.count < max(0, tabs.count - 2) {
            let more = PaneDivider()
            more.stage = self
            more.index = moreDividers.count + 1
            more.card = corner > 0
            addSubview(more, positioned: .above, relativeTo: divider)
            moreDividers.append(more)
        }
        // Which page each slot holds is put right with where the slots are,
        // in layout(), not here: told from SwiftUI's update, a page filling
        // the screen took the other one off a frame before the stage grew
        // to give it the room.
        paint()
        needsLayout = true
        watchClicks()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    /// The cards' edges and shadows, in this appearance's colours; nothing
    /// without corners, where the pages fill the stage as they always did.
    private func paint() {
        let card = corner > 0
        for line in dividers { line.card = card }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let edge = NSColor.labelColor.withAlphaComponent(CardEdge.edge).cgColor
            let ground = Palette.NS.ground.cgColor
            layer?.backgroundColor = card ? NSColor.clear.cgColor : ground
            for slot in slots {
                slot.layer?.borderWidth = card ? 1 : 0
                slot.layer?.borderColor = edge
            }
            for shadow in shadows {
                shadow.isHidden = !card
                shadow.backgroundColor = ground
                shadow.cornerRadius = corner
                shadow.cornerCurve = .continuous
                shadow.shadowColor = NSColor.black.cgColor
                shadow.shadowOpacity = Swift.Float(CardEdge.shadow)
                shadow.shadowRadius = 6
                shadow.shadowOffset = CGSize(width: 0, height: 1)
            }
        }
    }

    /// What each slot was last told to show.
    private var fed: [ObjectIdentifier?] = []

    /// Each slot its page, told only when that changes: which pages are on
    /// screen depends on the tabs and on the room, and both can change.
    private func feed() {
        while fed.count < slots.count { fed.append(nil) }
        for (index, slot) in slots.enumerated() {
            let wanted = index < tabs.count && shown(index) ? page(tabs[index]) : nil
            let id = wanted.map(ObjectIdentifier.init)
            guard fed[index] != id else { continue }
            fed[index] = id
            slot.show(wanted)
        }
    }

    // MARK: - where things go

    /// Each page's share, as it is drawn now.
    private var shares: [Double] {
        if let live, live.count == tabs.count { return live }
        if let sizes = split?.sizes, sizes.count == tabs.count { return sizes }
        return TabSplit.even(tabs.count)
    }

    /// Room for `count` pages side by side, none narrower than `narrowest`.
    private func fits(_ count: Int) -> Bool {
        bounds.width - CGFloat(max(0, count - 1)) * Self.gutter >= CGFloat(count) * Self.narrowest
    }

    /// Two or more pages side by side, with room enough for all.
    private var paired: Bool {
        tabs.count >= 2 && immersed == nil && fits(tabs.count)
    }

    /// A page lent to WebKit's full screen window: its slot has the stage.
    /// As the window says it, with its chrome, not from the tab: read from
    /// the tab, the other page went (or came back) a turn before the column
    /// and the card did, one more jump.
    var immersedID: Tab.ID? = nil {
        didSet { if immersedID != oldValue { needsLayout = true } }
    }
    fileprivate var immersed: Int? { immersedID.flatMap { id in tabs.firstIndex { $0.id == id } } }

    /// Whether the page in this slot is on screen.
    private func shown(_ index: Int) -> Bool {
        if tabs.count < 2 { return true }
        if let immersed { return index == immersed }
        if fits(tabs.count) || bounds.width == 0 { return true }
        return tabs[index].id == (focused ?? tabs[0].id)
    }

    override func layout() {
        super.layout()
        let area = bounds
        var frames: [CGRect] = Array(repeating: .zero, count: tabs.count)
        var grew = false // see backPages
        let lines = dividers
        if paired {
            let widths = self.widths(room: room)
            var x: CGFloat = 0
            for index in tabs.indices {
                frames[index] = CGRect(x: x, y: 0, width: widths[index], height: area.height)
                x += widths[index]
                if index < lines.count {
                    let line = lines[index]
                    if index < tabs.count - 1 {
                        line.frame = CGRect(x: x, y: 0, width: Self.gutter, height: area.height)
                        line.isHidden = false
                        x += Self.gutter
                    } else {
                        line.isHidden = true
                    }
                }
            }
            for line in lines.dropFirst(max(0, tabs.count - 1)) { line.isHidden = true }
        } else {
            for index in tabs.indices where shown(index) { frames[index] = area }
            for line in lines { line.isHidden = true }
        }
        for (index, slot) in slots.enumerated() {
            let frame = index < frames.count ? frames[index] : .zero
            let visible = index < tabs.count && shown(index) && frame.width > 0
            slot.isHidden = !visible
            // Grown, by a page not already covered for it by ⌘S's cover.
            if visible, slot.frame.width > 0,
               frame.width > slot.frame.width + 0.5 || frame.height > slot.frame.height + 0.5,
               !((page(tabs[index]) as? WKWebView).map { FoldCover.coming.contains($0) } ?? false) {
                grew = true
            }
            if slot.frame != frame { slot.frame = frame }
            if index < shadows.count {
                // Pages run the stage's full height, so its flip is no matter.
                let shadow = shadows[index]
                shadow.frame = frame
                shadow.isHidden = corner == 0 || !visible
            }
            // No line round the page the keys go to: as a card or edge to
            // edge, it read as a stray frame on one page of two (Drice,
            // 18 Nov 2026). The page clicked last is the one they go to.
        }
        // A window made too narrow for two takes the other page off, and
        // gives it back once there is room.
        feed()
        if grew { backPages() }
        if let bar = findBar {
            let page = focused.flatMap { id in tabs.firstIndex { $0.id == id } }
                .flatMap { frames.indices.contains($0) ? frames[$0] : nil }
            bar.isHidden = page == nil || page?.width == 0
            if let page, page.width > 0 {
                if findWidth != page.width {
                    findWidth = page.width
                    bar.rootView.availableWidth = page.width
                }
                let width = min(390, page.width)
                bar.frame = CGRect(x: page.maxX - width, y: page.minY,
                                   width: width, height: min(60, page.height))
            }
        }
        if let host = accountList {
            // Over the page the box is on, as large as it: the list places
            // itself under the box from that page's top-left.
            let page = accountsFor.flatMap { id in tabs.firstIndex { $0.id == id } }
                .flatMap { frames.indices.contains($0) ? frames[$0] : nil }
            host.isHidden = page == nil || page?.width == 0
            if let page, host.frame != page { host.frame = page }
        }
        var now: [Tab.ID: CGRect] = [:]
        for (index, tab) in tabs.enumerated() where shown(index) { now[tab.id] = frames[index] }
        // While a divider is held, kept for dividerMoved, which tells
        // SwiftUI only when it draws one of the pages.
        guard live == nil else { held = now; return }
        if now != told {
            told = now
            let frames = now
            DispatchQueue.main.async { [weak self] in self?.onFrames?(frames) }
        }
    }

    /// The pages' width between the dividers.
    private var room: CGFloat { bounds.width - CGFloat(max(0, tabs.count - 1)) * Self.gutter }

    /// Neither page narrower than `narrowest` while both are on screen.
    private func clampLeft(_ left: CGFloat, room: CGFloat) -> CGFloat {
        min(max(left, Self.narrowest), room - Self.narrowest)
    }

    /// Each page's width from its share, none narrower than `narrowest`:
    /// what a page under it is short is taken from the others, in
    /// proportion to what they have over it. Of two, the first page's
    /// share clamped, as it always was.
    private func widths(room: CGFloat) -> [CGFloat] {
        let shares = self.shares
        if shares.count == 2 {
            let left = clampLeft(room * CGFloat(shares[0]), room: room)
            return [left, room - left]
        }
        var widths = shares.map { room * CGFloat($0) }
        let short = widths.reduce(0) { $0 + max(0, Self.narrowest - $1) }
        guard short > 0 else { return widths }
        let spare = widths.reduce(0) { $0 + max(0, $1 - Self.narrowest) }
        guard spare > 0 else { return Array(repeating: room / CGFloat(widths.count), count: widths.count) }
        widths = widths.map { $0 < Self.narrowest ? Self.narrowest : $0 - ($0 - Self.narrowest) / spare * short }
        return widths
    }

    // MARK: - a divider, held

    fileprivate func dividerBegan(_ index: Int) {
        guard index + 1 < tabs.count else { return }
        let room = self.room
        // Of three or four, as drawn, so the pages don't jump when the hand
        // first moves; of two, as kept, as it always was.
        live = tabs.count > 2 && room > 0 ? widths(room: room).map { Double($0 / room) } : shares
        liveIndex = index
        let pair = live![index] + live![index + 1]
        snapped = abs(live![index] - pair / 2) < 0.0001
    }

    fileprivate func dividerMoved(to x: CGFloat) {
        guard var shares = live, liveIndex + 1 < shares.count else { return }
        let room = self.room
        guard room > 0 else { return }
        let index = liveIndex
        // The two pages either side of it share their room between them;
        // the others stay as they are.
        let start = CGFloat(shares[..<index].reduce(0, +)) * room + CGFloat(index) * Self.gutter
        let both = CGFloat(shares[index] + shares[index + 1]) * room
        var left = clampLeft(x - Self.gutter / 2 - start, room: both)
        let even = both / 2
        if snapped {
            if abs(left - even) > Self.unsnap { snapped = false } else { left = even }
        } else if abs(left - even) <= Self.snap {
            snapped = true
            left = even
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        let first = Double(left / room)
        let second = Double((both - left) / room)
        guard first != shares[index] else { return }
        shares[index] = first
        shares[index + 1] = tabs.count == 2 ? 1 - first : second
        live = shares
        // Laid out now, not on the next pass: the pages are to keep up with
        // the hand.
        needsLayout = true
        layoutSubtreeIfNeeded()
        // A page SwiftUI draws (Settings, History, an empty page) has
        // no view on the stage to resize: it's placed from the frames the
        // stage tells, which waited for the button to come up, so it kept
        // its old width while the divider moved off and left the ground in
        // between. Told now, as the stage lays out, it follows the hand.
        // Two web pages tell nothing, as before.
        if held != told, tabs.indices.contains(where: { shown($0) && page(tabs[$0]) == nil }) {
            told = held
            onFrames?(held)
        }
    }

    fileprivate func dividerEnded() {
        guard let shares = live else { return }
        let id = split?.id
        live = nil
        // Already where the hand left it: the split being told is no move.
        dragged = true
        needsLayout = true
        if let id { onCommit?(id, shares) }
    }

    // MARK: - the pages' own colour behind them while they resize

    /// Behind each page while the stage's pages change size — the divider
    /// held, the window resized, the column's edge let go — the page's own colour,
    /// until half a second after the last change. WebKit draws a page at its
    /// new size a frame or more after its view is resized, and the room it
    /// hadn't drawn yet showed the web view's own background, dark grey in
    /// dark mode: a strip at a white page's edge chasing the hand. That
    /// background is WebKit's to draw and has no public switch on macOS, so
    /// it's turned off with `_setDrawsBackground:` (private, checked for
    /// first) and the stage's slot shows `underPageBackgroundColor` there
    /// instead, as Safari does. Nothing runs while nothing resizes.
    ///
    /// Only for a page that grows: one that shrinks has nothing undrawn. And
    /// not for ⌘S, whose own cover lies over the room a page grows into
    /// (Browser.cover). Switched off and on, the background had WebKit paint
    /// the whole page twice and the page drawn clear, blended over what is
    /// under it, all through the column's slide, and the window server
    /// stuttered over it (idea 847: 1.0.16).
    private func backPages() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (index, slot) in slots.enumerated() {
                let web = index < tabs.count ? page(tabs[index]) as? WKWebView : nil
                slot.layer?.backgroundColor = web?.underPageBackgroundColor.cgColor
                if let web, !unbacked.contains(web), Self.drawsBackground(web, false) { unbacked.add(web) }
            }
        }
        rebacking?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.unbackPages() }
        rebacking = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Each page drawing its own background again, as it always does.
    private func unbackPages() {
        rebacking?.cancel()
        rebacking = nil
        for web in unbacked.allObjects { _ = Self.drawsBackground(web, true) }
        unbacked.removeAllObjects()
        for slot in slots { slot.layer?.backgroundColor = nil }
    }

    /// WebKit's switch for the background a web view draws where its page
    /// isn't drawn; false where this WebKit doesn't have it.
    private static func drawsBackground(_ web: WKWebView, _ on: Bool) -> Bool {
        guard web.responds(to: NSSelectorFromString("_setDrawsBackground:")) else { return false }
        web.setValue(on, forKey: "drawsBackground")
        return true
    }

    /// Double-clicked, or asked by VoiceOver: the two pages either side of
    /// divider `index` made even, or the line between them a step either
    /// way. Of two, the whole stage.
    fileprivate func setShare(_ fraction: Double, at index: Int = 0) {
        guard let id = split?.id, index + 1 < tabs.count else { return }
        var shares = self.shares
        if shares.count == 2 {
            onCommit?(id, TabSplit.clamp([fraction, 1 - fraction]))
            return
        }
        let before = shares[..<index].reduce(0, +)
        let both = shares[index] + shares[index + 1]
        let least = TabSplit.least(shares.count)
        let first = min(max(fraction - before, least), both - least)
        shares[index] = first
        shares[index + 1] = both - first
        onCommit?(id, TabSplit.clamp(shares))
    }

    /// Where divider `index` stands, as a share of the stage from its left.
    fileprivate func currentShare(at index: Int = 0) -> Double {
        shares.prefix(index + 1).reduce(0, +)
    }

    /// Where the two pages either side of divider `index` would be even.
    fileprivate func evenShare(at index: Int) -> Double {
        let shares = self.shares
        guard index + 1 < shares.count else { return 0.5 }
        return shares[..<index].reduce(0, +) + (shares[index] + shares[index + 1]) / 2
    }

    fileprivate var pageCount: Int { tabs.count }

    fileprivate func act(_ action: Action) { onAction?(action) }

    // MARK: - a click on a page focuses it

    /// With two pages up, a click in the one without the keys gives them to
    /// it, and is still the page's click. Watched rather than taken: the
    /// click belongs to WebKit.
    private func watchClicks() {
        let wanted = tabs.count >= 2 && window != nil
        if wanted, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                self?.clicked(event)
                return event
            }
        } else if !wanted, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func clicked(_ event: NSEvent) {
        guard let window, event.window === window, paired else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        // What is over the stage — the field, the find bar, a panel — is not
        // the page: a click there moves nothing.
        if let hit = window.contentView?.hitTest(event.locationInWindow), hit !== self,
           !hit.isDescendant(of: self) { return }
        for (index, slot) in slots.enumerated() where index < tabs.count && slot.frame.contains(point) {
            let tab = tabs[index]
            guard tab.id != focused else { return }
            DispatchQueue.main.async { [weak self] in self?.onFocus?(tab) }
            return
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        watchClicks()
    }

    /// Keeps `stages` pointing only at the window the stage is in.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { unbackPages() } // see backPages
        if let window, Self.stages.object(forKey: window) === self { Self.stages.removeObject(forKey: window) }
        if let newWindow { Self.stages.setObject(self, forKey: newWindow) }
    }

    /// Each window's stage, so a tab switch can reach it before SwiftUI does.
    static let stages = NSMapTable<NSWindow, PaneStage>.weakToWeakObjects()

    /// Puts the picked tab on the stage right away instead of waiting for
    /// SwiftUI to update the whole window. WebKit paints the page meanwhile,
    /// and both still reach the screen in the same frame. Only one page
    /// replacing another is handled here. Everything else is left to SwiftUI.
    func show(now tab: Tab, fading: Bool = false) {
        guard window != nil, tabs.count == 1, split == nil, immersedID == nil, page(tab) != nil else { return }
        // Another page brought ahead: the one going fades into it, rather
        // than giving way to it in a single frame.
        if fading, !Motion.reduced, tabs.first !== tab, let layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "space")
        }
        // The usual way in, so a move under way is cut short as any change of
        // pages cuts it: one page to another is never a move.
        show([tab], split: nil, focused: tab.id)
        layoutSubtreeIfNeeded()
    }

    // MARK: - the page under the pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited,
                                                              .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let under = paired ? slots.indices.first { $0 < tabs.count && slots[$0].frame.contains(point) }.map { tabs[$0].id } : nil
        hover(under)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover(nil)
    }

    private func hover(_ id: Tab.ID?) {
        guard hovered != id else { return }
        hovered = id
        onHover?(id)
    }
}

/// Between two pages: a narrow gutter that takes the pointer, with a small
/// pill in its middle (see Grip) — faint at rest, longer and darker under the
/// pointer and while held. As cards, the gap is what parts the pages; edge to
/// edge, a hairline down the gutter does. Dragged, the pages follow it;
/// double-clicked, they are made even. It never takes the keys: the page
/// keeps them.
final class PaneDivider: NSView {
    weak var stage: PaneStage?
    /// The page it follows: the first divider is after the first page.
    var index = 0
    /// The pages are cards (see PaneStage.paint): no hairline then.
    var card = false {
        didSet { if card != oldValue { needsDisplay = true } }
    }

    private let pill = CALayer()
    private let seam = CALayer()
    private var hovering = false
    private var dwell: DispatchWorkItem?
    private var dragging = false
    private var lit: Bool { hovering || dragging }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(seam)
        layer?.addSublayer(pill)
        for part in [pill, seam] {
            part.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull()]
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        paint()
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            pill.backgroundColor = (lit ? Palette.NS.muted : Palette.NS.faint).cgColor
            seam.backgroundColor = Palette.NS.hairline.cgColor
        }
        seam.isHidden = card
    }

    override func layout() {
        super.layout()
        place()
    }

    private func place() {
        let length = min(bounds.height, lit ? Grip.lit : Grip.rest)
        pill.frame = CGRect(x: (bounds.width - Grip.width) / 2, y: (bounds.height - length) / 2,
                            width: Grip.width, height: length)
        pill.cornerRadius = Grip.width / 2
        seam.frame = CGRect(x: (bounds.width - 1) / 2, y: 0, width: 1, height: bounds.height)
    }

    private func light(_ on: Bool) {
        guard hovering != on else { return }
        hovering = on
        // Only this change moves; the pill keeps still while the window or
        // the pages are being resized.
        let still = pill.actions
        pill.actions = nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.reduced ? 0 : 0.14)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        place()
        paint()
        CATransaction.commit()
        pill.actions = still
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        // A moment's rest first, so passing over it doesn't flicker.
        dwell?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.light(true) }
        dwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        dwell?.cancel()
        if !dragging { light(false) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let stage else { return }
        if event.clickCount == 2 {
            stage.setShare(stage.evenShare(at: index), at: index)
            return
        }
        dragging = true
        dwell?.cancel()
        light(true)
        stage.dividerBegan(index)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let stage else { return }
        NSCursor.resizeLeftRight.set()
        stage.dividerMoved(to: stage.convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        stage?.dividerEnded()
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        hovering = !inside
        light(inside)
    }

    // MARK: - its menu

    /// What can be done with the pair, from the page area itself: the tabs
    /// may be folded away.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let all = (stage?.pageCount ?? 2) > 2 ? "Close All" : "Close Both"
        for (title, action) in [("Swap Pages", PaneStage.Action.swap), ("Even Out", .even),
                                ("Separate", .separate), (all, .closeBoth)] {
            let item = NSMenuItem(title: title, action: #selector(chose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            menu.addItem(item)
            if action == .even { menu.addItem(.separator()) }
        }
        return menu
    }

    @objc private func chose(_ item: NSMenuItem) {
        guard let action = item.representedObject as? PaneStage.Action else { return }
        stage?.act(action)
    }

    // MARK: - VoiceOver

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func accessibilityLabel() -> String? { "Divider between the pages" }
    override func accessibilityValue() -> Any? { Int(((stage?.currentShare(at: index) ?? 0.5) * 100).rounded()) }
    override func accessibilityPerformIncrement() -> Bool {
        stage.map { $0.setShare($0.currentShare(at: index) + 0.05, at: index) } != nil
    }
    override func accessibilityPerformDecrement() -> Bool {
        stage.map { $0.setShare($0.currentShare(at: index) - 0.05, at: index) } != nil
    }
}

// MARK: - moving, not jumping

extension PaneStage {
    enum Move: Equatable {
        /// A page coming in beside the one on screen.
        case enter(Tab.ID)
        /// One of two going, the other taking the room.
        case leave(Tab.ID)
        case swap
        /// The divider moved by itself: evened out, or from VoiceOver.
        case resize
    }

    /// What the change from what is shown to `tabs` is, to the eye; nil for
    /// a cut.
    fileprivate func motion(to next: [Tab], split next2: TabSplit?) -> Move? {
        let old = tabs.map(\.id), new = next.map(\.id)
        defer { dragged = false }
        guard fits(max(2, old.count, new.count)), immersedID == nil, !old.isEmpty else { return nil }
        // One page more, the others as they were: the new one arriving.
        if new.count == old.count + 1, old.allSatisfy(new.contains), let other = new.first(where: { !old.contains($0) }) {
            return .enter(other)
        }
        // One page fewer: that one going, the others taking its room.
        if old.count >= 2, new.count == old.count - 1, new.allSatisfy(old.contains),
           let other = old.first(where: { !new.contains($0) }) {
            return .leave(other)
        }
        if old.count >= 2, old == Array(new.reversed()) { return .swap }
        if old.count >= 2, old == new, !dragged, let was = split, let now = next2, was.id == now.id,
           was.sizes.count == now.sizes.count, zip(was.sizes, now.sizes).contains(where: { abs($0 - $1) > 0.001 }) {
            return .resize
        }
        return nil
    }

    /// Where each page on screen is now.
    fileprivate func placed() -> [Tab.ID: CGRect] {
        var out: [Tab.ID: CGRect] = [:]
        for (index, tab) in tabs.enumerated() where index < slots.count && !slots[index].isHidden {
            out[tab.id] = slots[index].frame
        }
        return out
    }

    /// Pictures of the pages on screen, as they are. WebKit takes them in a
    /// frame or so; one slower than a twentieth of a second, and the change
    /// is a cut instead of a wait. Under Reduce Motion they are still
    /// taken, for the dissolve. A test run makes the move anyway, with
    /// stand-ins for the pictures still to come: a page just arrived in a
    /// window on no screen can keep WebKit waiting for seconds, and so can
    /// a busy machine.
    fileprivate func capture(_ pages: [Tab], _ done: @escaping ([Tab.ID: NSImage]) -> Void) {
        var pictures: [Tab.ID: NSImage] = [:]
        var sizes: [Tab.ID: NSSize] = [:]
        var waiting = pages.count
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            done(pictures)
        }
        guard waiting > 0 else { return finish() }
        for tab in pages {
            guard let web = tab.built, web.window === window, !web.isHidden else {
                waiting -= 1
                if waiting == 0 { finish() }
                continue
            }
            let size = web.bounds.size
            sizes[tab.id] = size
            web.takeSnapshot(with: nil) { image, _ in
                MainActor.assumeIsolated {
                    // A test run's window is on no screen, and WebKit pictures
                    // nothing there: a plain stand-in, so what moves can
                    // still be followed (see Bench, split motion).
                    if let image { pictures[tab.id] = image }
                    else if Store.testing { pictures[tab.id] = PaneStage.standIn(size) }
                    waiting -= 1
                    if waiting == 0 { finish() }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if !finished {
                if Store.testing {
                    for (id, size) in sizes where pictures[id] == nil { pictures[id] = PaneStage.standIn(size) }
                } else {
                    pictures = [:]
                }
            }
            finish()
        }
    }

    private static func standIn(_ size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        Palette.NS.hairline.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    /// The pictures moved from where the pages were to where they are now,
    /// over pages already laid out at their new size — laid out once, never
    /// frame by frame — then faded to the live pages. Cropped, never
    /// squashed: a picture keeps its size and shows what fits.
    fileprivate func animate(_ move: Move, from before: [Tab.ID: CGRect], pictures: [Tab.ID: NSImage]) {
        let after = placed()
        let reduced = Motion.reduced
        var moving: [(NSImageView, CGRect?)] = []
        for (id, image) in pictures {
            guard let start = before[id] else { continue }
            let view = NSImageView(frame: start)
            view.image = image
            view.imageScaling = .scaleNone
            view.imageAlignment = .alignTopLeft
            view.wantsLayer = true
            view.layer?.backgroundColor = Palette.NS.ground.cgColor
            // Moving as a card, when the pages are cards.
            view.layer?.cornerRadius = corner
            view.layer?.cornerCurve = .continuous
            view.layer?.masksToBounds = corner > 0
            addSubview(view, positioned: .below, relativeTo: divider)
            self.pictures.append(view)
            moving.append((view, after[id]))
        }
        motionLog = moving.map { view, end in (view, view.frame, end ?? view.frame) }
        // The page arriving comes up under the one making room for it.
        if case .enter(let id) = move, let index = tabs.firstIndex(where: { $0.id == id }), index < slots.count {
            let slot = slots[index]
            slot.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.seconds(reduced ? 0.15 : 0.3)
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                slot.animator().alphaValue = 1
            }
        }
        if case .enter = move {
            for line in dividers where !line.isHidden {
                line.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = reduced ? 0 : 0.14
                    line.animator().alphaValue = 1
                }
            }
        }
        let fade = { [weak self] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Motion.seconds(reduced ? 0.15 : 0.12)
                for (view, _) in moving { view.animator().alphaValue = 0 }
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    for (view, _) in moving { view.removeFromSuperview() }
                    self?.pictures.removeAll { view in moving.contains { $0.0 === view } }
                }
            })
        }
        // Under Reduce Motion nothing travels: the old pictures dissolve
        // into the new layout. With Reduce animations, not even that.
        guard !reduced else { return fade() }
        NSAnimationContext.runAnimationGroup({ context in
            // Search's glide, as near as a curve comes to its spring:
            // quick away, settling without a bounce, in about 0.3 s.
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            context.allowsImplicitAnimation = true
            for (view, end) in moving {
                if let end {
                    view.animator().frame = end
                } else {
                    // Leaving: a little smaller as it fades.
                    view.animator().frame = view.frame.insetBy(dx: view.frame.width * 0.01, dy: view.frame.height * 0.01)
                    view.animator().alphaValue = 0
                }
            }
        }, completionHandler: { MainActor.assumeIsolated { fade() } })
    }

    fileprivate func clearPictures() {
        for view in pictures { view.removeFromSuperview() }
        pictures.removeAll()
    }

    /// Each divider on screen, in the stage from its top-left: for the bench.
    var dividerFrames: [[Double]] {
        dividers.filter { !$0.isHidden && $0.superview != nil }.map { line in
            [line.frame.minX, line.frame.minY, line.frame.width, line.frame.height].map { Double($0) }
        }
    }

    /// The pictures moving now, where each started and where it is going,
    /// and where it is this moment: for the bench.
    var motionNow: [[String: [Double]]] {
        motionLog.compactMap { view, start, end in
            guard view.superview != nil else { return nil }
            let now = view.layer?.presentation()?.frame ?? view.frame
            func box(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { Double($0) } }
            return ["from": box(start), "to": box(end), "now": box(now)]
        }
    }
}

/// The find bar's box over the page's corner is wider and taller than its
/// pill; a press where the pill isn't goes to the page under it, rather than
/// to the box, which would have kept the click or carried the window off.
private final class FindHost: NSHostingView<FindBar> {
    var pillFrame = CGRect.zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Native controls keep their own hits while SwiftUI animates the pill.
        let hit = super.hitTest(point)
        guard hit === self else { return hit }
        let inside = convert(point, from: superview)
        // SwiftUI buttons can be hit on the hosting view itself.
        return Capsule().path(in: pillFrame).contains(inside) ? hit : nil
    }
}

/// A card that places itself by its offset from the page's top-left, in a
/// host as large as the page. A hosting view centres what it holds: the
/// card alone, offset from the centre, came out down and to the right of
/// its box — off the page for a box half way down — and the click meant for
/// it went to the page. Pinned to the top-left, the offset is from there.
struct FromTopLeft<Content: View>: View {
    static var space: String { "PaneStage.card" }
    let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .coordinateSpace(.named(Self.space))
    }
}

/// The accounts' box is the whole page, so the list can hang anywhere on it;
/// the list itself is a small card under the sign-in box. A press on the
/// card picks an account; anywhere else it is the page's, as if the box
/// weren't there — the sign-in box itself above all.
private final class AccountHost: NSHostingView<FromTopLeft<AccountList>> {
    /// The sign-in box, from the page's top-left (Browser.Suggesting.spot).
    var spot = CGRect.zero
    /// Where the card is drawn, from the host's top-left (AccountList.onFrame).
    var card = CGRect.zero
    /// The list up now, for the bench.
    static weak var shown: AccountHost?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Self.shown = self }
    }

    // Never the keys' view: a press on a row leaves the caret in the page's
    // box, as Safari's list does, so no blur of the box can take the list
    // down under the hand before the row's click is through.
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let inside = convert(point, from: superview)
        // Only the card, where it really is.
        return RoundedRectangle(cornerRadius: 10, style: .continuous).path(in: card).contains(inside)
            ? super.hitTest(point) : nil
    }
}

extension PaneStage {
    /// The account list's card and its host, in the window, from its
    /// top-left: for the bench, which asks whether the card hangs under the
    /// box it was drawn for.
    static func accountCard() -> (card: CGRect, host: CGRect)? {
        guard let host = AccountHost.shown, let window = host.window, !host.isHidden else { return nil }
        func top(_ r: CGRect) -> CGRect {
            let w = host.convert(r, to: nil)
            return CGRect(x: w.minX, y: window.frame.height - w.maxY, width: w.width, height: w.height)
        }
        return (top(host.card), top(host.bounds))
    }
}
