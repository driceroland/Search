import AppKit
import SwiftUI

/// A tab's existing drag gesture asks these passive markers what is under the
/// pointer. They never receive a mouse event or create a second drag session.
struct SplitDropZone: NSViewRepresentable {
    enum Kind: Equatable { case stage, strip }

    let browser: Browser
    let tab: Tab?
    let kind: Kind

    func makeNSView(context: Context) -> Marker {
        let view = Marker()
        view.browser = browser
        view.tab = tab
        view.kind = kind
        TabDrag.shared.register(view)
        return view
    }

    func updateNSView(_ view: Marker, context: Context) {
        view.browser = browser
        view.tab = tab
        view.kind = kind
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Marker, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    static func dismantleNSView(_ view: Marker, coordinator: ()) {
        TabDrag.shared.unregister(view)
    }

    final class Marker: NSView {
        weak var browser: Browser?
        weak var tab: Tab?
        var kind: Kind = .strip

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The half a carried pair lets go of, once it has been shown: the pair's
/// own item dims the half that stays (see SplitTabItem, IconPair). Apart
/// from TabDrag, so a split shown over a page redraws no pair in the row.
@MainActor
final class PairSeparation: ObservableObject {
    static let shared = PairSeparation()
    @Published fileprivate(set) var leaving: Tab.ID?
    private init() {}
}

/// Only the Stage observes `preview`; the browser's tab row stays still while
/// the pointer moves across a page. A marker is weakly kept and checked in
/// the source window before it can become a target.
@MainActor
final class TabDrag: ObservableObject {
    static let shared = TabDrag()

    enum Side: Equatable { case left, right }

    struct Preview: Equatable {
        let browserID: ObjectIdentifier
        let targetID: Tab.ID
        let side: Side
        /// The tab being carried, to name it in the half it would take.
        var sourceID: Tab.ID? = nil
    }

    enum Drop {
        case stage(Tab, onLeft: Bool)
        case strip(Tab?)
        case outside
        case cancelled
    }

    @Published private(set) var preview: Preview?
    @Published private(set) var cancelledID: Tab.ID?

    private final class WeakMarker {
        weak var view: SplitDropZone.Marker?
        init(_ view: SplitDropZone.Marker) { self.view = view }
    }

    private var markers: [ObjectIdentifier: WeakMarker] = [:]
    private weak var sourceBrowser: Browser?
    private weak var gestureTab: Tab?
    private weak var sourceTab: Tab?
    private var target: Drop = .outside
    /// The half of a pair let go of before `before` (nil: at the end), once
    /// the hand has rested over that place: a pair comes apart only where
    /// that was shown, as a page splits only where its split was.
    private var separation: (leaving: Tab.ID, before: Tab.ID?)?
    private var escapeMonitor: Any?

    /// Only a page's edges split it, a band of either side about a quarter
    /// of its width, and no narrower than this: carried across the middle
    /// of a page on its way elsewhere, a tab splits nothing.
    static let band: CGFloat = 120
    static let bandShare: CGFloat = 0.24
    /// How far out of the band the pointer goes before a shown split lets go.
    static let slack: CGFloat = 20
    /// The pointer at rest in a band — moved less than this in `still` — is
    /// what shows the split. No fixed wait, and no flicker from a tab
    /// carried straight across.
    static let settle: CGFloat = 6
    nonisolated static let still: TimeInterval = 0.09
    /// How long a carried pair's half rests over another tab before it is
    /// shown coming apart: longer than a split over a page, since the hand
    /// slows to a crawl right there on its way to moving the pair a place.
    static let parting: TimeInterval = 0.3

    /// Where the pointer has been lately, for whether it has settled.
    private var trail: [(point: NSPoint, at: TimeInterval)] = []
    /// A look again once the pointer may have come to rest.
    private var recheck: DispatchWorkItem?

    private init() {}

    func register(_ view: SplitDropZone.Marker) {
        markers[ObjectIdentifier(view)] = WeakMarker(view)
    }

    func unregister(_ view: SplitDropZone.Marker) {
        markers[ObjectIdentifier(view)] = nil
    }

    func update(browser: Browser, tab: Tab, translation: CGSize) -> Bool {
        guard browser.prefs.splitView else { return false }
        if sourceBrowser !== browser || gestureTab !== tab {
            let pointer = pointer(in: browser)
            let origin = NSPoint(x: pointer.x - translation.width, y: pointer.y + translation.height)
            begin(browser: browser, tab: tab, at: origin)
        }
        guard cancelledID != tab.id else { return true }
        guard sourceTab != nil else { return false }
        let point = pointer(in: browser)
        let now = ProcessInfo.processInfo.systemUptime
        trail.append((point, now))
        trail.removeAll { now - $0.at > 0.5 }
        return look(browser: browser, at: point)
    }

    /// The split under the pointer, shown once the pointer has settled in an
    /// edge band, or kept while it is still near the one shown.
    @discardableResult
    private func look(browser: Browser, at point: NSPoint) -> Bool {
        guard let sourceTab else { return false }
        let matched = match(browser: browser, source: sourceTab, at: point)
        target = matched
        if case .strip(let place) = matched {
            if preview != nil { preview = nil }
            separate(sourceTab, before: place, browser: browser, at: point)
            return false
        }
        if separation != nil { showSeparation(nil) }
        guard case .stage(let page, let onLeft) = matched else {
            recheck?.cancel()
            if preview != nil { preview = nil }
            return false
        }
        let wanted = Preview(browserID: ObjectIdentifier(browser), targetID: page.id, side: onLeft ? .left : .right, sourceID: sourceTab.id)
        if preview == wanted { return true }
        guard settled(at: point) else {
            // Look again once it may have stopped: a hand at rest sends
            // nothing more to look at.
            recheck?.cancel()
            let work = DispatchWorkItem { [weak self, weak browser] in
                guard let self, let browser, self.sourceBrowser === browser else { return }
                self.look(browser: browser, at: self.pointer(in: browser))
            }
            recheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + TabDrag.still, execute: work)
            return true
        }
        preview = wanted
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        return true
    }

    /// A carried pair's half over another tab, or past the last: the half
    /// that stays dims once the hand rests there, with the same tick as a
    /// split shown over a page. Carried along without stopping, or nudged
    /// past the pair's own edge on the way to its new place, it shows
    /// nothing, and the pair is let go of as one (#883).
    private func separate(_ half: Tab, before place: Tab?, browser: Browser, at point: NSPoint) {
        if let separation, separation.leaving == half.id, separation.before == place?.id { return }
        if separation != nil { showSeparation(nil) }
        // Known for less than that, the hand has only just set off: a
        // single point isn't a hand at rest.
        let now = ProcessInfo.processInfo.systemUptime
        let known = trail.first.map { now - $0.at >= TabDrag.parting } ?? false
        guard known, settled(at: point, for: TabDrag.parting) else {
            recheck?.cancel()
            let work = DispatchWorkItem { [weak self, weak browser] in
                guard let self, let browser, self.sourceBrowser === browser else { return }
                self.look(browser: browser, at: self.pointer(in: browser))
            }
            recheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + TabDrag.parting + 0.02, execute: work)
            return
        }
        showSeparation((half.id, place?.id))
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func showSeparation(_ shown: (leaving: Tab.ID, before: Tab.ID?)?) {
        separation = shown
        if PairSeparation.shared.leaving != shown?.leaving { PairSeparation.shared.leaving = shown?.leaving }
    }

    private func settled(at point: NSPoint, for still: TimeInterval = TabDrag.still) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let recent = trail.filter { now - $0.at <= still }
        // Nothing new for a while: at rest.
        guard let first = recent.first else { return true }
        return recent.allSatisfy { hypot($0.point.x - point.x, $0.point.y - point.y) < TabDrag.settle }
            && hypot(first.point.x - point.x, first.point.y - point.y) < TabDrag.settle
    }

    func finish(browser: Browser, tab: Tab) -> (source: Tab, drop: Drop, point: NSPoint) {
        let source = sourceTab ?? tab
        let point = pointer(in: browser)
        var result: Drop
        if cancelledID == tab.id {
            result = .cancelled
        } else if sourceBrowser === browser && gestureTab === tab {
            result = match(browser: browser, source: source, at: point)
            // A split only where one was shown.
            if case .stage(let page, let onLeft) = result,
               preview != Preview(browserID: ObjectIdentifier(browser), targetID: page.id, side: onLeft ? .left : .right, sourceID: sourceTab?.id) {
                result = .outside
            }
            // A pair apart only where that was shown.
            if case .strip(let place) = result,
               separation.map({ $0.leaving == source.id && $0.before == place?.id }) != true {
                result = .outside
            }
        } else {
            result = .outside
        }
        clear()
        return (source, result, point)
    }

    /// The drag callback is delivered with a window-local NSEvent. Use that
    /// event as the source of truth: synthesized drags need not move macOS's
    /// global mouse location at the same time.
    /// A test's hand, in screen points: a window off every screen gets its
    /// events from the test, and the gesture hears them once AppKit's event
    /// is no longer current, so neither would say where the hand is.
    static var testPointer: NSPoint?

    private func pointer(in browser: Browser) -> NSPoint {
        if Store.testing, let point = TabDrag.testPointer { return point }
        if let window = browser.window, let event = NSApp.currentEvent,
           event.window === window,
           event.type == .leftMouseDragged || event.type == .leftMouseUp {
            return window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        }
        return NSEvent.mouseLocation
    }

    private func begin(browser: Browser, tab: Tab, at origin: NSPoint) {
        clear()
        cancelledID = nil
        sourceBrowser = browser
        gestureTab = tab
        sourceTab = sourceHalf(browser: browser, gesture: tab, at: origin)
        // Escape is the drag's only while the button is down. A gesture
        // taken away mid-drag never says it ended, and its monitor stayed
        // to eat the next Escape anywhere, one meant for a video's full
        // screen too, which then took two.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, NSEvent.pressedMouseButtons & 1 != 0,
                  let self, self.gestureTab != nil else { return event }
            self.cancel()
            return nil
        }
    }

    /// The gesture carrying `tab` was taken away mid-drag (see CarryGuard):
    /// what it showed goes, and its Escape with it.
    func callOff(_ tab: Tab) {
        guard gestureTab === tab else { return }
        clear()
    }

    private func cancel() {
        // The monitor goes first: a drag whose tab has gone has nothing to
        // cancel, and kept, its monitor would go on asking.
        removeMonitor()
        guard let gestureTab else { return }
        cancelledID = gestureTab.id
        preview = nil
        showSeparation(nil)
        target = .cancelled
        removeMonitor()
    }

    private func clear() {
        recheck?.cancel()
        recheck = nil
        trail = []
        preview = nil
        showSeparation(nil)
        sourceBrowser = nil
        gestureTab = nil
        sourceTab = nil
        target = .outside
        removeMonitor()
    }

    private func removeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    private func match(browser: Browser, source: Tab, at point: NSPoint) -> Drop {
        guard let window = browser.window else { return .outside }
        markers = markers.filter { $0.value.view != nil }
        let candidates = markers.values.compactMap(\.view).filter { view in
            view.browser === browser && view.window === window && !view.isHiddenOrHasHiddenAncestor
                && window.convertToScreen(view.convert(view.bounds, to: nil)).contains(point)
        }
        if let stage = candidates.first(where: { view in
            view.kind == .stage && view.tab.map { browser.canSplit(source, with: $0) } == true
        }), let page = stage.tab {
            let frame = window.convertToScreen(stage.convert(stage.bounds, to: nil))
            let band = max(TabDrag.band, frame.width * TabDrag.bandShare)
            // The side shown keeps a little more room before it lets go.
            let shown = preview?.targetID == page.id ? preview?.side : nil
            let left = band + (shown == .left ? TabDrag.slack : 0)
            let right = band + (shown == .right ? TabDrag.slack : 0)
            if point.x <= frame.minX + left { return .stage(page, onLeft: true) }
            if point.x >= frame.maxX - right { return .stage(page, onLeft: false) }
        }
        guard browser.split(for: source) != nil else { return .outside }
        let pair = browser.split(for: source)
        if let stripTab = candidates.first(where: { view in
            view.kind == .strip && view.tab.map { pair?.contains($0.id) == false } == true
        }), let page = stripTab.tab {
            return .strip(page)
        }
        if candidates.contains(where: { view in
            view.kind == .strip && view.tab.map { pair?.contains($0.id) == true } == true
        }) { return .outside }
        if candidates.contains(where: { $0.kind == .strip && $0.tab == nil }) { return .strip(nil) }
        return .outside
    }

    private func sourceHalf(browser: Browser, gesture: Tab, at point: NSPoint) -> Tab {
        guard let pair = browser.split(for: gesture), let window = browser.window else { return gesture }
        markers = markers.filter { $0.value.view != nil }
        return markers.values.compactMap(\.view).first { view in
            view.kind == .strip && view.browser === browser && view.window === window
                && view.tab.map({ pair.contains($0.id) }) == true
                && window.convertToScreen(view.convert(view.bounds, to: nil)).contains(point)
        }?.tab ?? gesture
    }
}
