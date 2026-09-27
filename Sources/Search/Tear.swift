import AppKit
import SwiftUI

// A tab carried out of its row, Safari's way. Past the edge of the bar the
// pill grows into a small picture of the page that follows the pointer — over
// the desktop, over other windows, anywhere — and the row closes up behind
// it. Let go in the open, the picture grows into a window of its own there.
// Carried over a window's row of tabs, that row makes way where it would
// land, and let go there the picture shrinks into the row and the tab joins
// it. Back over its own row it shrinks into a pill in the row again, and the
// drag goes on as a reorder (see Carried in TabBar.swift).

/// Where each tab of a row or column is drawn, in the window's coordinates
/// (SwiftUI's global space), reported by the tabs themselves, for a carried
/// tab to find its place among them.
struct TabFrames: PreferenceKey {
    static var defaultValue: [Tab.ID: CGRect] = [:]

    static func reduce(value: inout [Tab.ID: CGRect], nextValue: () -> [Tab.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

@MainActor
enum Tear {
    private(set) static var tab: Tab?
    private(set) static var source: Browser?
    /// The window whose row the tab is over, its `arrival` set.
    private static var destination: Browser?
    private static var panel: NSPanel?
    /// The picture's card, drawn in the panel: what grows and shrinks.
    private static var card: NSView?
    private static var picture: NSImageView?
    /// The page's picture, kept for the drag: the tab may leave its row,
    /// come back, and leave again.
    private static var kept: (id: Tab.ID, image: NSImage)?

    /// The picture's width; its height follows the page's shape.
    private static let width: CGFloat = 200
    /// A pill's height, which the picture grows out of and shrinks into.
    private static let pillHeight: CGFloat = 28
    /// Where the hand holds the picture, in from its top-left corner, as
    /// Safari holds it — and what it grows from and shrinks to.
    private static let hand = NSPoint(x: 40, y: 28)
    /// How long the picture takes to grow out of the pill, or back into one.
    private static let morph: TimeInterval = 0.18
    /// How long it takes to grow into a window.
    private static let unfold: TimeInterval = 0.26

    /// Whether the tab can leave its row: not a pin, which every window has,
    /// nor a bench's; and not the last tab of the only window, which has
    /// nowhere else to be.
    static func can(_ tab: Tab, leave browser: Browser) -> Bool {
        guard tab.pin == nil, !tab.bench else { return false }
        return browser.tabs.count > 1 || Browsers.all.contains { $0 !== browser && $0.isOpen }
    }

    /// The tab has left its row at `point`: the picture grows out of a pill
    /// `pill` wide under the hand.
    static func begin(_ tab: Tab, from browser: Browser, at point: NSPoint, pill: CGFloat) {
        guard self.tab == nil else { return }
        self.tab = tab
        source = browser
        // The page's shape, which the picture is of. A sleeping tab's page
        // isn't there to draw, and a new tab's has no size yet: the window's
        // shape stands in, less the strip.
        var shape = tab.asleep ? .zero : tab.web.bounds.size
        if shape.width < 1 || shape.height < 1 {
            let frame = browser.window?.frame.size ?? NSSize(width: 1180, height: 780)
            shape = NSSize(width: frame.width, height: frame.height - Metrics.strip)
        }
        show(shape: shape, at: point, pill: pill)
        if let kept, kept.id == tab.id {
            picture?.image = kept.image
            return
        }
        // The page as it stands, if it is awake; a sleeping tab isn't woken
        // for a picture, and shows its ground alone.
        guard !tab.asleep, !tab.isBlank else { return }
        Task { @MainActor in
            guard let image = try? await tab.web.takeSnapshot(configuration: nil) else { return }
            kept = (tab.id, image)
            if self.tab === tab { picture?.image = image }
        }
    }

    /// The hand has moved to `point`: the picture follows, and the window
    /// whose row it is over, if any, is told where the tab would land.
    static func move(to point: NSPoint) {
        guard let tab, let source else { return }
        panel?.setFrameOrigin(origin(for: point))
        let over = Browsers.all
            .filter { $0 !== source && $0.isOpen && $0.window?.frame.contains(point) == true }
            .min { ($0.window?.orderedIndex ?? .max) < ($1.window?.orderedIndex ?? .max) }
        let place = over?.place(for: point, of: tab)
        let target = place == nil ? nil : over
        // Over a row, the row draws the tab under the hand as a pill of its
        // own, and the picture keeps out of sight.
        if let target, let frame = target.window?.frame {
            target.arrivalHand = CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
        }
        if (target != nil) == shown { veil(target != nil) }
        guard target !== destination || place != destination?.arrival else { return }
        withAnimation(Motion.settle) {
            destination?.arrival = nil
            destination?.arrivalHand = nil
            target?.arrival = place
        }
        destination = target
    }

    /// Whether the picture is in sight: not while the tab is drawn in a row.
    private static var shown = true

    private static func veil(_ veiled: Bool) {
        shown = !veiled
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.reduced ? 0 : 0.12
            panel.animator().alphaValue = veiled ? 0 : 1
        }
    }

    /// The drag is over without the tab having left: the page's picture
    /// kept for it is let go, so the next drag takes a fresh one.
    static func forget() {
        kept = nil
    }

    /// Back over its own row: the picture shrinks into a pill `pill` wide
    /// under the hand, and the drag carries on as a reorder.
    static func home(pill: CGFloat) {
        guard tab != nil else { return }
        tab = nil
        source = nil
        withAnimation(Motion.settle) {
            destination?.arrival = nil
            destination?.arrivalHand = nil
        }
        destination = nil
        settle(pill: pill)
    }

    /// Let go at `point`: into the row it is over, where the picture shrinks
    /// into the row; or a window of its own there, which the picture grows
    /// into.
    static func end(at point: NSPoint) {
        guard let tab, let source else { return }
        let destination = self.destination
        let place = destination?.arrival
        kept = nil
        // Once the drag has let go, not inside it: the row is about to lose
        // a tab the gesture is still attached to. The tab stays known until
        // then, so the row it is over keeps drawing it under the hand
        // rather than blinking it out for the turn in between.
        DispatchQueue.main.async {
            self.tab = nil
            self.source = nil
            self.destination = nil
            if let destination, let place {
                withAnimation(Motion.settle) {
                    destination.arrival = nil
                    destination.arrivalHand = nil
                    source.moveToWindow(tab, destination, place: place)
                }
                settle(pill: destination.tabFrames[tab.id]?.width ?? Metrics.tabWidth)
            } else if source.tabs.count > 1,
                      let opened = source.moveToWindow(tab, nil, at: point, unveiled: false),
                      let window = opened.window {
                unfold(into: window)
            } else {
                // Nowhere to go: the tab stays, and the picture goes.
                hide()
            }
        }
    }

    // MARK: - the picture

    /// The picture, full size under the hand from the first, so it follows
    /// the hand from the first; what grows is the card drawn in it, out of a
    /// pill's shape, about the point the hand holds it by.
    private static func show(shape: NSSize, at point: NSPoint, pill: CGFloat) {
        let height = (width * shape.height / max(shape.width, 1)).rounded()
        let full = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        let panel = NSPanel(contentRect: full, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above every window while it is carried, on whichever desktop, and
        // never in the way of the drag itself.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false

        let ground = NSView(frame: full)
        ground.wantsLayer = true
        let card = NSView(frame: full)
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = Palette.NS.ground.cgColor
        // Its own shadow, since the card and not the panel is what has a
        // shape while it grows. The picture is cut to the corners in a view
        // of its own, so the cut doesn't take the shadow with it.
        card.shadow = NSShadow()
        card.shadow?.shadowBlurRadius = 14
        card.shadow?.shadowOffset = NSSize(width: 0, height: -4)
        card.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.22)
        let frame = NSView(frame: full)
        frame.wantsLayer = true
        frame.layer?.cornerRadius = 8
        frame.layer?.cornerCurve = .continuous
        frame.layer?.masksToBounds = true
        frame.layer?.borderWidth = 1
        frame.layer?.borderColor = Palette.NS.hairline.cgColor
        frame.autoresizingMask = [.width, .height]
        let picture = NSImageView(frame: full)
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.imageAlignment = .alignTop
        picture.autoresizingMask = [.width, .height]
        frame.addSubview(picture)
        card.addSubview(frame)
        ground.addSubview(card)
        panel.contentView = ground
        panel.setFrameOrigin(origin(for: point, height: height))
        panel.orderFrontRegardless()
        self.panel = panel
        self.card = card
        self.picture = picture
        shown = true

        // Grown about the point the hand holds it by.
        if let layer = card.layer {
            layer.anchorPoint = CGPoint(x: hand.x / width, y: 1 - hand.y / height)
            layer.position = CGPoint(x: hand.x, y: height - hand.y)
            scale(layer, from: pillShape(pill, in: full.size), to: CATransform3DIdentity, opacity: (0.3, 1), over: morph)
        }
    }

    /// The picture shrunk into a pill `pill` wide where it is, then gone.
    private static func settle(pill: CGFloat) {
        guard let panel, let card else { return }
        self.panel = nil
        self.card = nil
        picture = nil
        guard let layer = card.layer else { panel.orderOut(nil); return }
        scale(layer, from: CATransform3DIdentity, to: pillShape(pill, in: card.bounds.size), opacity: (1, 0), over: morph) {
            panel.orderOut(nil)
        }
    }

    /// The picture grown into the window, which comes up in its place.
    private static func unfold(into window: NSWindow) {
        guard let panel, let card else { window.alphaValue = 1; return }
        self.panel = nil
        self.card = nil
        picture = nil
        // The card fills the panel again as the panel grows.
        card.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        card.layer?.position = CGPoint(x: card.bounds.midX, y: card.bounds.midY)
        card.autoresizingMask = [.width, .height]
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.reduced ? 0 : unfold
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(window.frame, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = Motion.reduced ? 0 : 0.12
                    window.animator().alphaValue = 1
                    panel.animator().alphaValue = 0
                }, completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
            }
        })
    }

    private static func hide() {
        panel?.orderOut(nil)
        panel = nil
        card = nil
        picture = nil
    }

    /// A pill's shape as a scaling of the picture: its width, a pill's height.
    private static func pillShape(_ pill: CGFloat, in size: NSSize) -> CATransform3D {
        CATransform3DMakeScale(min(1, pill / max(size.width, 1)), pillHeight / max(size.height, 1), 1)
    }

    /// The card's layer from one shape and opacity to another, on Core
    /// Animation's own clock: the panel is moved by the hand meanwhile.
    private static func scale(_ layer: CALayer, from: CATransform3D, to: CATransform3D, opacity: (Swift.Float, Swift.Float), over duration: TimeInterval, then: (@MainActor () -> Void)? = nil) {
        layer.transform = to
        layer.opacity = opacity.1
        guard !Motion.reduced else { then?(); return }
        let shape = CABasicAnimation(keyPath: "transform")
        shape.fromValue = from
        shape.toValue = to
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity.0
        fade.toValue = opacity.1
        let both = CAAnimationGroup()
        both.animations = [shape, fade]
        both.duration = duration
        both.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { then?() } }
        layer.add(both, forKey: "morph")
        CATransaction.commit()
    }

    /// Where the panel goes for the hand at `point`.
    private static func origin(for point: NSPoint, height: CGFloat? = nil) -> NSPoint {
        let height = height ?? panel?.frame.height ?? 0
        return NSPoint(x: point.x - hand.x, y: point.y - (height - hand.y))
    }
}

extension Browser {
    /// The row of tabs, on the screen: the band across the top of the
    /// window, or the column down its side, unless folded away or under a
    /// page that has the screen. A carried tab over it lands in the row.
    var bar: NSRect? {
        guard let window, isOpen, !folded, active?.immersed != true else { return nil }
        let frame = window.frame
        if prefs.sidebar {
            let x = prefs.sidePosition == .right ? frame.maxX - prefs.sideWidth : frame.minX
            return NSRect(x: x, y: frame.minY, width: prefs.sideWidth, height: frame.height)
        }
        // Past the window's buttons, which full screen keeps no corner for.
        let lights = fullScreen ? 12 : Metrics.lights
        return NSRect(x: frame.minX + lights, y: frame.maxY - Metrics.strip,
                      width: frame.width - lights, height: Metrics.strip)
    }

    /// Where a tab carried over this window would land: among the loose
    /// tabs, past the ones whose middle the point has passed, in the run's
    /// own count; nil when the point isn't over the row.
    func place(for point: NSPoint, of tab: Tab) -> Int? {
        guard let bar, bar.contains(point), let window else { return nil }
        // In the window's own coordinates, as the tabs reported theirs.
        let local = CGPoint(x: point.x - window.frame.minX, y: window.frame.maxY - point.y)
        let run = prefs.usesTabGroups ? tabs(in: nil) : tabs.filter { $0.pin == nil }
        return run.filter { other in
            guard other.id != tab.id, let box = tabFrames[other.id] else { return false }
            return prefs.sidebar ? box.midY < local.y : box.midX < local.x
        }.count
    }
}
