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
    private var escapeMonitor: Any?

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
        guard let sourceTab else { return false }
        let point = pointer(in: browser)
        let matched = match(browser: browser, source: sourceTab, at: point)
        target = matched
        switch matched {
        case .stage(let page, let onLeft):
            let shown = Preview(browserID: ObjectIdentifier(browser), targetID: page.id,
                                side: onLeft ? .left : .right)
            if preview != shown { preview = shown }
            return true
        default:
            if preview != nil { preview = nil }
            return false
        }
    }

    func finish(browser: Browser, tab: Tab) -> (source: Tab, drop: Drop, point: NSPoint) {
        let source = sourceTab ?? tab
        let point = pointer(in: browser)
        let result: Drop
        if cancelledID == tab.id {
            result = .cancelled
        } else if sourceBrowser === browser && gestureTab === tab {
            result = match(browser: browser, source: source, at: point)
        } else {
            result = .outside
        }
        clear()
        return (source, result, point)
    }

    /// The drag callback is delivered with a window-local NSEvent. Use that
    /// event as the source of truth: synthesized drags need not move macOS's
    /// global mouse location at the same time.
    private func pointer(in browser: Browser) -> NSPoint {
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
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.cancel()
            return nil
        }
    }

    private func cancel() {
        guard let gestureTab else { return }
        cancelledID = gestureTab.id
        preview = nil
        target = .cancelled
        removeMonitor()
    }

    private func clear() {
        preview = nil
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
            return .stage(page, onLeft: point.x < frame.midX)
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
