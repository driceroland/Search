import AppKit
import Combine
import SwiftUI
import WebKit

// Split View's stage, while the switch is on: one AppKit view that holds
// every page on screen, one or two, and is never rebuilt — not from one tab
// to the next, not from one page to two. Each page keeps a StageView of its
// own (see Stage.swift), so everything that stage learned about taking a
// page back holds here too. With the switch off none of this exists, and the
// window's stage is the one it always was.
//
// The divider is this view's own: it follows the pointer, lays the pages out
// as it goes, and tells the pair once, when the button comes up. Nothing is
// published while it moves — not to the window, the row or the menus.

/// The stage, for SwiftUI. Its identity never changes; what it shows does.
struct PaneStageView: NSViewRepresentable {
    let tabs: [Tab]
    let split: TabSplit?
    let focused: Tab.ID?
    let commit: (UUID, [Double]) -> Void
    let focus: (Tab) -> Void
    let frames: ([Tab.ID: CGRect]) -> Void

    func makeNSView(context: Context) -> PaneStage { PaneStage() }

    func updateNSView(_ stage: PaneStage, context: Context) {
        stage.onCommit = commit
        stage.onFocus = focus
        stage.onFrames = frames
        stage.show(tabs, split: split, focused: focused)
    }
}

final class PaneStage: NSView {
    var onCommit: ((UUID, [Double]) -> Void)?
    var onFocus: ((Tab) -> Void)?
    /// Where each page is, from the top left, each time that changes — never
    /// while the divider is being dragged.
    var onFrames: (([Tab.ID: CGRect]) -> Void)?

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

    private var tabs: [Tab] = []
    private var split: TabSplit?
    private var focused: Tab.ID?
    private var slots: [StageView] = []
    private var cues: [FocusCue] = []
    private let divider = PaneDivider()
    private var watching: [AnyCancellable] = []
    private var watched: [ObjectIdentifier] = []
    private var queued = false
    private var monitor: Any?
    private var told: [Tab.ID: CGRect] = [:]

    /// The first page's share while the divider is held; nil otherwise.
    private var live: Double?
    private var snapped = false

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
        if live != nil, split == nil { live = nil }
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

    /// The page a tab puts on the stage: none while it is blank, asleep or
    /// floating, as Page decides it (see Stage.swift).
    private func page(_ tab: Tab) -> NSView? {
        tab.isBlank || tab.asleep || tab.floating ? nil : tab.web
    }

    private func refill() {
        while slots.count < tabs.count {
            let slot = StageView()
            addSubview(slot, positioned: .below, relativeTo: divider)
            slots.append(slot)
            let cue = FocusCue()
            cue.alphaValue = 0
            addSubview(cue, positioned: .below, relativeTo: divider)
            cues.append(cue)
        }
        feed()
        needsLayout = true
        watchClicks()
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

    /// The first page's share, as it is drawn now.
    private var share: Double { live ?? split?.fraction ?? 0.5 }

    /// Two pages side by side, with room enough for both.
    private var paired: Bool {
        tabs.count == 2 && immersed == nil && bounds.width - Self.gutter >= 2 * Self.narrowest
    }

    /// A page lent to WebKit's full screen window: its slot has the stage.
    private var immersed: Int? { tabs.firstIndex { $0.immersed } }

    /// Whether the page in this slot is on screen.
    private func shown(_ index: Int) -> Bool {
        if tabs.count < 2 { return true }
        if let immersed { return index == immersed }
        if bounds.width - Self.gutter >= 2 * Self.narrowest || bounds.width == 0 { return true }
        return tabs[index].id == (focused ?? tabs[0].id)
    }

    override func layout() {
        super.layout()
        let area = bounds
        var frames: [CGRect] = Array(repeating: .zero, count: tabs.count)
        if paired {
            let room = area.width - Self.gutter
            let left = clampLeft(room * CGFloat(share), room: room)
            frames[0] = CGRect(x: 0, y: 0, width: left, height: area.height)
            frames[1] = CGRect(x: left + Self.gutter, y: 0, width: room - left, height: area.height)
            divider.frame = CGRect(x: left, y: 0, width: Self.gutter, height: area.height)
            divider.isHidden = false
        } else {
            for index in tabs.indices where shown(index) { frames[index] = area }
            divider.isHidden = true
        }
        for (index, slot) in slots.enumerated() {
            let frame = index < frames.count ? frames[index] : .zero
            let visible = index < tabs.count && shown(index) && frame.width > 0
            slot.isHidden = !visible
            if slot.frame != frame { slot.frame = frame }
            // Only with two pages on screen does it matter which one keys go to.
            let cue = cues[index]
            cue.frame = frame
            let lit = paired && index < tabs.count && tabs[index].id == focused
            if (cue.alphaValue == 1) != lit {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Motion.reduced ? 0 : 0.14
                    cue.animator().alphaValue = lit ? 1 : 0
                }
            }
        }
        // A window made too narrow for two takes the other page off, and
        // gives it back once there is room.
        feed()
        guard live == nil else { return }
        var now: [Tab.ID: CGRect] = [:]
        for (index, tab) in tabs.enumerated() where shown(index) { now[tab.id] = frames[index] }
        if now != told {
            told = now
            let frames = now
            DispatchQueue.main.async { [weak self] in self?.onFrames?(frames) }
        }
    }

    /// Neither page narrower than `narrowest` while both are on screen.
    private func clampLeft(_ left: CGFloat, room: CGFloat) -> CGFloat {
        min(max(left, Self.narrowest), room - Self.narrowest)
    }

    // MARK: - the divider, held

    fileprivate func dividerBegan() {
        live = split?.fraction ?? 0.5
        snapped = abs(live! - 0.5) < 0.0001
    }

    fileprivate func dividerMoved(to x: CGFloat) {
        guard live != nil else { return }
        let room = bounds.width - Self.gutter
        guard room > 0 else { return }
        var left = clampLeft(x - Self.gutter / 2, room: room)
        let even = room / 2
        if snapped {
            if abs(left - even) > Self.unsnap { snapped = false } else { left = even }
        } else if abs(left - even) <= Self.snap {
            snapped = true
            left = even
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        let fraction = Double(left / room)
        guard fraction != live else { return }
        live = fraction
        // Laid out now, not on the next pass: the pages are to keep up with
        // the hand.
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    fileprivate func dividerEnded() {
        guard let fraction = live else { return }
        let id = split?.id
        live = nil
        needsLayout = true
        if let id { onCommit?(id, [fraction, 1 - fraction]) }
    }

    /// Double-clicked, or asked by VoiceOver: even, or a step either way.
    fileprivate func setShare(_ fraction: Double) {
        guard let id = split?.id else { return }
        onCommit?(id, TabSplit.clamp([fraction, 1 - fraction]))
    }

    fileprivate var currentShare: Double { share }

    // MARK: - a click on a page focuses it

    /// With two pages up, a click in the one without the keys gives them to
    /// it, and is still the page's click. Watched rather than taken: the
    /// click belongs to WebKit.
    private func watchClicks() {
        let wanted = tabs.count == 2 && window != nil
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
}

/// A hairline round the page the keys go to, with two pages up. Mid-grey,
/// which shows on a white page and a dark one alike; drawn rather than a
/// layer's border, so a picture of the window has it too. It takes no clicks.
final class FocusCue: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        Palette.NS.muted.withAlphaComponent(0.55).setStroke()
        let line = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        line.lineWidth = 1
        line.stroke()
    }
}

/// The line between two pages. A hairline in a narrow gutter, that grows a
/// little under the pointer; dragged, the pages follow it; double-clicked,
/// they are made even. It never takes the keys: the page keeps them.
final class PaneDivider: NSView {
    weak var stage: PaneStage?

    private let line = CALayer()
    private var hovering = false
    private var dwell: DispatchWorkItem?
    private var dragging = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(line)
        line.actions = ["bounds": NSNull(), "position": NSNull()]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        line.backgroundColor = (hovering || dragging ? Palette.NS.muted : Palette.NS.faint).cgColor
    }

    override func layout() {
        super.layout()
        place()
    }

    private func place() {
        let width: CGFloat = hovering || dragging ? 3 : 1
        line.frame = CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
        line.cornerRadius = width / 2
    }

    private func light(_ on: Bool) {
        guard hovering != on else { return }
        hovering = on
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.reduced ? 0 : 0.14)
        place()
        line.backgroundColor = (on || dragging ? Palette.NS.muted : Palette.NS.faint).cgColor
        CATransaction.commit()
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
            stage.setShare(0.5)
            return
        }
        dragging = true
        dwell?.cancel()
        light(true)
        stage.dividerBegan()
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

    // MARK: - VoiceOver

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func accessibilityLabel() -> String? { "Divider between the pages" }
    override func accessibilityValue() -> Any? { Int(((stage?.currentShare ?? 0.5) * 100).rounded()) }
    override func accessibilityPerformIncrement() -> Bool {
        stage.map { $0.setShare($0.currentShare + 0.05) } != nil
    }
    override func accessibilityPerformDecrement() -> Bool {
        stage.map { $0.setShare($0.currentShare - 0.05) } != nil
    }
}
