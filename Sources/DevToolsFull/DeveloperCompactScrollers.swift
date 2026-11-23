import AppKit
import SwiftUI
import WebKit

/// Thin overlay scrollers on every scroll view inside DevTools, as Chrome
/// DevTools keeps its scrollbars slim, whatever the system's "Show scroll
/// bars" setting: with a mouse connected or "Always" chosen, AppKit's
/// legacy scrollers take a wide gutter beside every list, editor and tab
/// strip. The probe sits behind the DevTools root and restyles the scroll
/// views that fall inside its frame: when it joins a window, when the
/// panel or drawer changes (with a few later passes for lazily built
/// lists), when its frame changes, when the system style changes back,
/// and, coalesced, when DevTools redraws. Each pass walks only the views
/// that overlap DevTools, never the browser chrome or the page.
struct DeveloperCompactScrollers: NSViewRepresentable {
    /// Inputs that bring new scroll views: changing them restyles at once.
    let panel: DeveloperPanel
    let drawer: Bool

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.update(key: "\(panel)|\(drawer)")
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: NSView {
        private var observer: NSObjectProtocol?
        /// The panel and drawer last seen, so only a real change bursts.
        private var key: String?
        /// A coalesced pass is already queued.
        private var pending = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            burst()
            observer = NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            }
        }

        override func setFrameSize(_ newSize: NSSize) {
            let changed = newSize != frame.size
            super.setFrameSize(newSize)
            if changed { coalesce() }
        }

        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        /// From SwiftUI's update: a new panel or drawer state restyles at
        /// once and again as its lazy lists fill in; any other redraw (a new
        /// request's details, a sidebar opening) gets one coalesced pass.
        func update(key next: String) {
            if next != key {
                key = next
                burst()
            } else {
                coalesce()
            }
        }

        func schedule() {
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        /// A pass now and a few after, for scroll views SwiftUI builds late.
        private func burst() {
            schedule()
            for delay in [0.3, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.apply() }
            }
        }

        /// One pass shortly after layout settles, however many ask for it.
        private func coalesce() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                self.pending = false
                self.apply()
            }
        }

        private func apply() {
            guard let window, window.contentView != nil, !isHiddenOrHasHiddenAncestor else { return }
            let area = convert(bounds, to: nil).insetBy(dx: -1, dy: -1)
            guard area.width > 1, area.height > 1, let root = searchRoot(area) else { return }
            Self.walk(root, area: area) { scroll in
                let frame = scroll.convert(scroll.bounds, to: nil)
                guard area.contains(frame) else { return }
                Self.compact(scroll)
            }
        }

        /// The highest ancestor that still lies within DevTools, or, when
        /// even the probe's parent reaches beyond it (SwiftUI hosts the
        /// probe beside its siblings), the nearest one that holds DevTools.
        /// The walk below skips whatever lies outside DevTools' frame.
        private func searchRoot(_ area: NSRect) -> NSView? {
            var root: NSView? = superview
            while let view = root, let parent = view.superview {
                let frame = view.convert(view.bounds, to: nil)
                guard area.contains(frame) else { break }
                root = parent
            }
            return root ?? window?.contentView
        }

        private static func walk(_ view: NSView, area: NSRect, _ body: (NSScrollView) -> Void) {
            if view is WKWebView { return }
            let frame = view.convert(view.bounds, to: nil)
            // An empty frame says nothing about where its children lie.
            if !frame.isEmpty && !frame.intersects(area) { return }
            if let scroll = view as? NSScrollView { body(scroll) }
            for child in view.subviews { walk(child, area: area, body) }
        }

        static func compact(_ scroll: NSScrollView) {
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
            for scroller in [scroll.verticalScroller, scroll.horizontalScroller].compactMap({ $0 })
            where scroller.controlSize != .small {
                scroller.controlSize = .small
            }
        }
    }
}
