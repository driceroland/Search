import AppKit
import WebKit

// A video that keeps playing after you have gone somewhere else, in a small
// window that stays above everything — other tabs, and other apps.
//
// macOS WKWebView exposes no public native-PiP enablement switch. Support
// depends on the engine and player, so this path does not assume it is there.
//
// The same live page is moved instead. Where its video fits in the source
// viewport, a native crop scales it without resizing WebKit's separately
// hosted video layer. Whole pages resize normally so their controls remain
// responsive. Neither mode reloads or duplicates the media session.

@MainActor
final class Float {
    enum Presentation { case video, page }

    private var panel: NSPanel?
    private var controls: Controls?
    private weak var page: NSView?
    private var magnification = true
    private var autoresizing: NSView.AutoresizingMask = []
    private(set) var presentation: Presentation = .video

    /// Asked to go away. The browser does the bookkeeping and calls back into
    /// `drop` — there is one way this window closes, and it is not this class
    /// quietly tidying up behind everyone's back. Two paths to closing is how
    /// it stayed on screen after the page had already gone home.
    var onClose: (() -> Void)?
    /// Bring the window forward and go to the tab it came from.
    var onReturn: (() -> Void)?
    /// Stop or start the video. Answers with whether it is playing now.
    var onPlayPause: ((@escaping (Bool) -> Void) -> Void)?
    /// Step over the bit you missed, or back to it.
    var onSkip: ((Double) -> Void)?
    /// Asked every half second while the window is up, for the line along the
    /// bottom edge.
    var onProgress: ((@escaping (Double, Bool) -> Void) -> Void)?
    /// A meeting may end without navigating away from its room's address.
    var onPageCheck: (() -> Void)?

    private var ticker: Timer?

    var showing: Bool { panel != nil }

    func holds(_ view: NSView) -> Bool { showing && page === view }

    /// Where a test run's bench opens the window instead: off every screen,
    /// at the size it would have had, and not remembered (see `film float`
    /// in Bench.swift). Nil everywhere else.
    static var benchAway: NSPoint?

    /// Two fingers flick the window to a corner instead of pushing it
    /// along (Settings › General). Off unless asked for.
    static var flicks = false

    /// Where a flick sends the window, a margin in from the edges of
    /// `area`. A swipe clearly both ways — between about 22° and 68° — takes
    /// it to the corner it points at; a straighter one along its stronger
    /// direction, against whichever of the other two edges it is nearer.
    nonisolated static func corner(for frame: NSRect, in area: NSRect, toward way: CGVector, margin: CGFloat = 12) -> NSPoint {
        let left = area.minX + margin, right = area.maxX - margin - frame.width
        let bottom = area.minY + margin, top = area.maxY - margin - frame.height
        let across = abs(way.dx), up = abs(way.dy)
        let x = way.dx > 0 ? right : left, y = way.dy > 0 ? top : bottom
        if min(across, up) >= 0.4 * max(across, up) { return NSPoint(x: x, y: y) }
        if across >= up { return NSPoint(x: x, y: frame.midY > area.midY ? top : bottom) }
        return NSPoint(x: frame.midX > area.midX ? right : left, y: y)
    }

    /// Where docking leaves the window: off the side of `area`, but for a
    /// sliver to bring it back by.
    nonisolated static func docked(_ frame: NSRect, right: Bool, in area: NSRect, sliver: CGFloat = 10) -> NSPoint {
        NSPoint(x: right ? area.maxX - sliver : area.minX - frame.width + sliver, y: frame.minY)
    }

    /// Whether the window can go into that side of `area`, one of `screens`:
    /// not where another screen carries on, where it would only slide onto
    /// that one instead.
    nonisolated static func dockable(_ frame: NSRect, right: Bool, in area: NSRect, screens: [NSRect]) -> Bool {
        let beyond = NSRect(x: right ? area.maxX : area.minX - frame.width, y: frame.minY, width: frame.width, height: frame.height)
        return !screens.contains { !$0.contains(area) && $0.intersects(beyond) }
    }

    /// Screens a test run's bench makes up, far off the real ones, for the
    /// window to flick and dock about (see `float` in Bench.swift). Nil
    /// everywhere else.
    static var benchScreens: [NSRect]?

    func lift(_ page: NSView, presentation: Presentation = .video, title: String = "", videoRect: NSRect? = nil) {
        guard panel == nil else { return }
        self.page = page
        self.presentation = presentation

        let videoSize = videoRect?.size
        var size = presentation == .video ? NSSize(width: 440, height: 247) : NSSize(width: 640, height: 480)
        if presentation == .video, let videoSize { size.height = size.width * videoSize.height / videoSize.width }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        // Where it was last, at the size it was, if a screen still shows it;
        // otherwise the bottom right of this one.
        var spot = remembered ?? NSRect(
            x: screen.maxX - size.width - 24,
            y: screen.minY + 24,
            width: size.width,
            height: size.height
        )
        if presentation == .video, videoSize != nil { spot.size.height = spot.width * size.height / size.width }
        if let away = Float.benchAway { spot.origin = away }

        let panel = Panel(
            contentRect: spot,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above every ordinary window, this app's and everyone else's, and
        // present on whichever desktop you happen to be looking at.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // No shadow. A window with one is composited by WindowServer on every
        // frame of the video; without it the video can go straight to the
        // display, as it does in a tab. Measured on 1080p and 4K YouTube:
        // WindowServer's GPU time 28% with the shadow, 16–20% without, 22%
        // playing in the tab.
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // The bench's, off every screen, is left out when a probe is hidden.
        panel.canHide = Float.benchAway == nil
        if presentation == .video { panel.aspectRatio = size }
        // Kept once a move or a resize is over, not on each step of one: at
        // the end of a resize by its edges, as it closes (see drop), and as
        // the app quits with it open, which closes nothing.
        let keep: (Notification.Name, AnyObject) -> NSObjectProtocol = { [weak self] name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let frame = self?.restingFrame { self?.remembered = frame }
                }
            }
        }
        keeping = [
            keep(NSWindow.didEndLiveResizeNotification, panel),
            keep(NSApplication.willTerminateNotification, NSApp),
        ]
        panel.minSize = presentation == .video ? NSSize(width: 260, height: 260 * size.height / size.width) : NSSize(width: 360, height: 280)
        if presentation == .page {
            limitPage(panel)
            spot = panel.frame
            let limit: @Sendable (Notification) -> Void = { [weak self, weak panel] _ in
                MainActor.assumeIsolated {
                    guard let self, let panel else { return }
                    self.limitPage(panel)
                }
            }
            keeping.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: panel, queue: .main, using: limit))
            keeping.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: limit))
        }

        // At the size the window opens at. Built at the default size and
        // then stretched to a remembered one, the page was laid out twice,
        // and the first frames of video filled only part of the window
        // (#257).
        let ground = NSView(frame: NSRect(origin: .zero, size: spot.size))
        ground.wantsLayer = true
        ground.layer?.backgroundColor = NSColor.black.cgColor
        ground.layer?.cornerRadius = 14
        ground.layer?.masksToBounds = true

        // WebKit puts its own pinch recogniser on a web view, and a gesture
        // recogniser is consulted before the responder chain is. With it left
        // on, every pinch aimed at this window went into zooming the page
        // inside it instead of sizing the window. It comes back on landing.
        magnification = (page as? WKWebView)?.allowsMagnification ?? true
        autoresizing = page.autoresizingMask
        if presentation == .video { (page as? WKWebView)?.allowsMagnification = false }

        page.removeFromSuperview()
        let header: CGFloat = presentation == .page ? 44 : 0
        var cropped = false
        if presentation == .video, let videoRect,
           NSRect(origin: .zero, size: page.bounds.size).contains(videoRect) {
            // The video keeps its existing layout and GPU-layer size. Only
            // this native ancestor scales; resizing PiP need not reflow a page.
            let viewport = VideoViewport(frame: ground.bounds, videoSize: videoRect.size)
            viewport.autoresizingMask = [.width, .height]
            page.autoresizingMask = []
            page.setFrameOrigin(NSPoint(x: -videoRect.minX, y: videoRect.maxY - page.frame.height))
            viewport.addSubview(page)
            ground.addSubview(viewport)
            cropped = true
        } else {
            // A player larger than its source viewport cannot be cropped
            // whole without relayout. Keep the viewport-fitting path for it.
            page.frame = NSRect(x: 0, y: 0, width: spot.width, height: spot.height - header)
            page.autoresizingMask = [.width, .height]
            ground.addSubview(page)
        }

        // Page controls live above the viewport, never over a site's buttons.
        let controls = Controls(frame: presentation == .video ? ground.bounds
                                : NSRect(x: 0, y: spot.height - header, width: spot.width, height: header),
                                presentation: presentation, title: title)
        controls.autoresizingMask = presentation == .video ? [.width, .height] : [.width, .minYMargin]
        controls.onClose = { [weak self] in self?.onClose?() }
        controls.onReturn = { [weak self] in self?.onReturn?() }
        controls.onPlayPause = { [weak self] in
            self?.onPlayPause? { playing in
                self?.controls?.playing = playing
            }
        }
        controls.onSkip = { [weak self] seconds in self?.onSkip?(seconds) }
        ground.addSubview(controls)
        self.controls = controls

        panel.contentView = ground
        self.panel = panel
        let show = { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel,
                  self.page?.isDescendant(of: ground) == true else { return }
            let fades = !Motion.reduced
            if fades { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            if fades {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.14
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                }
            }
        }
        if presentation == .video, !cropped, let web = page as? WKWebView {
            // Isolation belongs to the destination viewport, not the source
            // page. Show only after WebKit has accepted that final layout.
            web.evaluateInSearch(Isolate.present) { _ in
                MainActor.assumeIsolated { show() }
            }
        } else {
            show()
        }

        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                // A window that no longer holds the page has nothing to show
                // and no reason to exist. Something else took the page back —
                // and rather than hunt every path that could, this makes it
                // impossible for the empty black rectangle to outlive it by
                // more than half a second.
                if self.page?.isDescendant(of: ground) != true {
                    self.onClose?()
                    return
                }

                if self.presentation == .video {
                    self.onProgress? { through, playing in
                        self.controls?.progress = through
                        self.controls?.playing = playing
                    }
                } else {
                    self.onPageCheck?()
                }
            }
        }
    }

    /// The window's last place and size, kept across closing it and quitting,
    /// and given back only while a screen still shows most of it.
    private var frameKey: String { presentation == .video ? "float.frame" : "float.pageFrame" }

    private var remembered: NSRect? {
        get {
            guard let text = Store.settings.string(forKey: frameKey) else { return nil }
            let frame = NSRectFromString(text)
            let shown = NSScreen.screens.contains {
                let seen = $0.visibleFrame.intersection(frame)
                return seen.width * seen.height > 0.6 * frame.width * frame.height
            }
            let minimum = presentation == .video ? NSSize(width: 260, height: 146) : NSSize(width: 360, height: 280)
            return frame.width >= minimum.width && frame.height >= minimum.height && shown ? frame : nil
        }
        set {
            guard Self.benchAway == nil else { return }
            Store.settings.set(newValue.map(NSStringFromRect), forKey: frameKey)
        }
    }

    private var keeping: [NSObjectProtocol] = []

    private func limitPage(_ panel: NSPanel) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let maximum = NSSize(width: screen.visibleFrame.width / 2, height: screen.visibleFrame.height / 2)
        panel.minSize = NSSize(width: min(360, maximum.width), height: min(280, maximum.height))
        panel.maxSize = maximum
        var frame = panel.frame
        let size = NSSize(width: min(frame.width, maximum.width), height: min(frame.height, maximum.height))
        guard size != frame.size else { return }
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: false)
    }

    /// Where the window is, or was before it was docked at a side: a docked
    /// window is kept as it was, not as the sliver it is.
    private var restingFrame: NSRect? {
        guard let panel else { return nil }
        guard let home = controls?.dockedFrom else { return panel.frame }
        return NSRect(origin: home, size: panel.frame.size)
    }

    /// Puts the page down and closes. Whoever owns the page takes it back on
    /// their next layout.
    func drop() {
        guard let panel else { return }
        if let frame = restingFrame { remembered = frame }
        keeping.forEach(NotificationCenter.default.removeObserver)
        keeping = []
        ticker?.invalidate()
        ticker = nil
        (page as? WKWebView)?.allowsMagnification = magnification
        page?.autoresizingMask = autoresizing
        page?.removeFromSuperview()
        page = nil
        controls = nil
        panel.orderOut(nil)
        panel.close()
        self.panel = nil
    }

    /// A fixed-size video crop composited at the panel's size. The web view's
    /// own frame and viewport do not follow this view's frame changes.
    private final class VideoViewport: NSView {
        private let videoSize: NSSize

        init(frame: NSRect, videoSize: NSSize) {
            self.videoSize = videoSize
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            setBoundsSize(videoSize)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            setBoundsSize(videoSize)
        }
    }

    /// What a small window of video needs, and nothing else: a way out, a way
    /// back, a way to stop it, and a way to step over the bit you missed.
    ///
    /// Out of sight until the pointer is over the window — the whole point of
    /// this window is the picture.
    private final class Controls: NSView {
        var onClose: (() -> Void)?
        var onReturn: (() -> Void)?
        var onPlayPause: (() -> Void)?
        var onSkip: ((Double) -> Void)?

        var playing = true {
            didSet {
                if playing != oldValue { pause.image = glyph(playing ? "pause.fill" : "play.fill", 17) }
            }
        }

        /// Nought to one. Drawn as a hairline along the bottom edge.
        var progress: Double = 0 {
            didSet { line.through = progress }
        }

        private let close = NSButton()
        private let back = NSButton()
        private let pause = NSButton()
        private let rewind = NSButton()
        private let forward = NSButton()
        private let scrim = CAGradientLayer()
        private let line = Line()
        private let title = NSTextField(labelWithString: "")
        private let presentation: Presentation
        private var near = false

        init(frame: NSRect, presentation: Presentation, title: String) {
            self.presentation = presentation
            super.init(frame: frame)
            wantsLayer = true

            dress(close, "xmark", 11, round: 15, action: #selector(pressedClose))
            dress(back, "arrow.up.forward", 12, round: 15, action: #selector(pressedReturn))
            close.toolTip = "Close Floating Window"
            close.setAccessibilityLabel("Close Floating Window")
            back.toolTip = "Return to Tab"
            back.setAccessibilityLabel("Return to Tab")
            if presentation == .video {
                // A wash at the top and bottom, so white buttons hold against a
                // bright frame of film without covering it.
                scrim.colors = [
                    NSColor(white: 0, alpha: 0.45).cgColor,
                    NSColor(white: 0, alpha: 0).cgColor,
                    NSColor(white: 0, alpha: 0).cgColor,
                    NSColor(white: 0, alpha: 0.5).cgColor,
                ]
                scrim.locations = [0, 0.28, 0.66, 1]
                scrim.opacity = 0
                layer?.addSublayer(scrim)

                dress(rewind, "gobackward.15", 15, round: 19, action: #selector(pressedRewind))
                dress(pause, "pause.fill", 17, round: 25, action: #selector(pressedPause))
                dress(forward, "goforward.15", 15, round: 19, action: #selector(pressedForward))

                line.alphaValue = 0
                addSubview(line)
                buttons.forEach { $0.alphaValue = 0 }
            } else {
                near = true
                layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
                self.title.stringValue = title.isEmpty ? "Floating Page" : title
                self.title.font = .systemFont(ofSize: 12, weight: .medium)
                self.title.textColor = .white
                self.title.lineBreakMode = .byTruncatingTail
                addSubview(self.title)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        private var buttons: [NSButton] { presentation == .video ? [close, back, rewind, pause, forward] : [close, back] }

        private func dress(
            _ button: NSButton,
            _ symbol: String,
            _ size: CGFloat,
            round: CGFloat,
            action: Selector
        ) {
            button.image = glyph(symbol, size)
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.imagePosition = .imageOnly
            button.target = self
            button.action = action
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.55).cgColor
            button.layer?.cornerRadius = round
            addSubview(button)
        }

        private func glyph(_ name: String, _ size: CGFloat) -> NSImage? {
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            let look = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
                .applying(.init(paletteColors: [.white]))
            return image?.withSymbolConfiguration(look)
        }

        override func layout() {
            super.layout()
            if presentation == .page {
                close.frame = NSRect(x: 10, y: 10, width: 24, height: 24)
                back.frame = NSRect(x: bounds.width - 34, y: 10, width: 24, height: 24)
                title.frame = NSRect(x: 48, y: 14, width: max(0, bounds.width - 96), height: 16)
                return
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scrim.frame = bounds
            CATransaction.commit()

            close.frame = NSRect(x: 14, y: bounds.height - 44, width: 30, height: 30)
            back.frame = NSRect(x: bounds.width - 44, y: bounds.height - 44, width: 30, height: 30)

            let middle = bounds.midY - 25
            pause.frame = NSRect(x: bounds.midX - 25, y: middle, width: 50, height: 50)
            rewind.frame = NSRect(x: bounds.midX - 25 - 54, y: middle + 6, width: 38, height: 38)
            forward.frame = NSRect(x: bounds.midX + 25 + 16, y: middle + 6, width: 38, height: 38)

            line.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 3)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard presentation == .video else { return }
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                    owner: self
                )
            )
        }

        override func mouseEntered(with event: NSEvent) { fade(to: 1) }
        override func mouseExited(with event: NSEvent) { fade(to: 0) }

        private func fade(to value: CGFloat) {
            guard presentation == .video else { return }
            near = value > 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                buttons.forEach { $0.animator().alphaValue = value }
                line.animator().alphaValue = value
            }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.16)
            scrim.opacity = Swift.Float(value)
            CATransaction.commit()
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Everything reaches this layer.
        ///
        /// isMovableByWindowBackground never worked here: the window's whole
        /// background is a web view, and a web view swallows every drag before
        /// the window sees it. So every gesture is taken here, above it.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let inside = convert(point, from: superview)
            if presentation == .page, !bounds.contains(inside) { return nil }
            if near {
                for button in buttons where button.frame.contains(inside) {
                    return button
                }
            }
            return self
        }

        // MARK: - moving and sizing

        private var grab = NSPoint.zero
        private var origin = NSRect.zero
        private var stretching = false

        private func atCorner(_ point: NSPoint) -> Bool {
            presentation == .video && point.x > bounds.maxX - 22 && point.y < bounds.minY + 22
        }

        override func resetCursorRects() {
            guard presentation == .video else { return }
            addCursorRect(
                NSRect(x: bounds.maxX - 22, y: bounds.minY, width: 22, height: 22),
                cursor: .crosshair
            )
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            // A click on the sliver of a docked window brings it back.
            if docked != nil {
                undock()
                ignoringDrag = true
                return
            }
            ignoringDrag = false
            stopGlide()
            origin = window.frame
            stretching = atCorner(convert(event.locationInWindow, from: nil))
            if stretching {
                grab = NSEvent.mouseLocation
            } else {
                // WindowServer tracks the original event, rather than sampling
                // a newer global cursor position for each queued drag event.
                window.performDrag(with: event)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard window != nil, !ignoringDrag, stretching else { return }
            let now = NSEvent.mouseLocation
            let dx = now.x - grab.x
            resize(to: origin.width + dx, from: origin)
        }

        /// Two fingers on the trackpad move the window. There is nothing to
        /// scroll here — the window holds one picture — so the gesture is free
        /// to mean the thing you actually want it to mean.
        ///
        /// And the pointer travels with it. Moving the window alone leaves the
        /// cursor behind: it drifts towards the edge, falls out, and the window
        /// stops answering mid-gesture. Carrying it keeps it at the same place
        /// in the frame, so the window can be pushed as far as the screen goes.
        override func scrollWheel(with event: NSEvent) {
            guard let window else { return }
            // Only while fingers are actually down. Letting the glide continue
            // would fling the pointer across the screen after them.
            guard event.momentumPhase == [] else { return }
            if Float.flicks { return flickWheel(with: event) }
            // Docked, and flicks turned off since: out first, where it was.
            if docked != nil { return undock() }

            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            guard dx != 0 || dy != 0 else { return }

            let spot = window.frame.origin
            window.setFrameOrigin(NSPoint(x: spot.x + dx, y: spot.y - dy))

            // Screen coordinates run up from the bottom, the cursor's run down
            // from the top of the first display.
            guard let ground = NSScreen.screens.first else { return }
            let mouse = NSEvent.mouseLocation
            CGWarpMouseCursorPosition(
                CGPoint(
                    x: mouse.x + dx,
                    y: ground.frame.height - (mouse.y - dy)
                )
            )
            // Without this the pointer and the physical trackpad stay parted
            // for a moment, and the next flick arrives from the wrong place.
            CGAssociateMouseAndMouseCursorPosition(1)
        }

        /// Two fingers flick the window to a corner, as in Dia and Arc: a
        /// swipe up takes it to the top on the side it is on, a swipe left to
        /// the left at the height it is at, a diagonal one to that corner —
        /// one move a swipe, however long the swipe. Dragging it anywhere is
        /// still the click's.
        private var swipe: CGVector = .zero
        private var flicked = false
        /// For a wheel, which has no gesture to belong to: one flick a turn.
        private var lastWheelFlick = Date.distantPast

        private func flickWheel(with event: NSEvent) {
            // Which way the fingers went, on screen: with natural scrolling
            // the deltas run with the fingers, without it against them.
            let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            let step = CGVector(dx: sign * event.scrollingDeltaX, dy: -sign * event.scrollingDeltaY)

            if event.phase == [] {
                // A mouse's wheel: every turn is a flick, a moment apart.
                guard Date().timeIntervalSince(lastWheelFlick) > 0.4, step != .zero else { return }
                lastWheelFlick = Date()
                if docked != nil {
                    if inward(step) { undock() }
                } else if let side = against(), outward(step, from: side) {
                    dock(side)
                } else {
                    flick(step)
                }
                return
            }
            if event.phase.contains(.began) {
                swipe = .zero
                flicked = false
                pulling = nil
                pullFrom = window?.frame.origin ?? .zero
            }
            swipe.dx += step.dx
            swipe.dy += step.dy
            let lifted = event.phase.contains(.ended) || event.phase.contains(.cancelled)

            // Docked: a swipe back towards the middle brings it out.
            if docked != nil {
                if !flicked, inward(swipe), abs(swipe.dx) > 24 || lifted {
                    flicked = true
                    undock()
                }
                if lifted {
                    swipe = .zero
                    flicked = false
                }
                return
            }

            // Against a side, and swiped at it: it gives, heavily, under the
            // fingers, and on lifting either goes into the side — only a
            // sliver left — or springs back out.
            if pulling == nil, !flicked, let side = against(), outward(swipe, from: side), abs(swipe.dx) > 6 {
                pulling = side
                // A spring still settling from the last one would pull the
                // other way, a frame at a time.
                stopGlide()
            }
            if pulling != nil {
                window?.setFrameOrigin(NSPoint(x: pullFrom.x + swipe.dx * Controls.give, y: pullFrom.y))
                // The window moves out from under the pointer as it gives, and
                // the fingers lifting can then be told to whatever is under
                // it instead: if nothing more comes, the pull is over anyway.
                settling?.cancel()
                let settle = DispatchWorkItem { [weak self] in self?.letGo() }
                settling = settle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: settle)
                if lifted { letGo() }
                return
            }
            // Read from the whole swipe, as the fingers lift: a swipe often
            // sets off along one side before it turns diagonal, and read
            // early it went the wrong way. A long one doesn't wait.
            let length = hypot(swipe.dx, swipe.dy)
            if !flicked, length > 120 || (lifted && length > 20) {
                flicked = true
                flick(swipe)
            }
            if lifted {
                swipe = .zero
                flicked = false
            }
        }

        // Docking at a side, as in Dia: a strong swipe at the side the window
        // is against slides it off, leaving a sliver to bring it back by.
        enum Side { case left, right }
        private(set) var docked: Side?
        /// Where it was before it docked: where it goes back to.
        private(set) var dockedFrom: NSPoint?
        private var pulling: Side?
        private var pullFrom: NSPoint = .zero
        private var ignoringDrag = false
        /// How much of it stays on screen, docked.
        static let sliver: CGFloat = 10
        /// How far the fingers go at the side before letting go docks it.
        static let dockAt: CGFloat = 90
        /// How much the window gives under the fingers while pulled at a side.
        static let give: CGFloat = 0.35

        /// The usable part of the screen the window is on.
        private var area: NSRect? {
            if let made = Float.benchScreens, let window {
                let middle = NSPoint(x: window.frame.midX, y: window.frame.midY)
                return made.first { $0.contains(middle) } ?? made.first
            }
            return (window?.screen ?? NSScreen.main)?.visibleFrame
        }

        /// The side the window is up against, if it is, and if it can go
        /// into it.
        private func against() -> Side? {
            guard let window, let area else { return nil }
            let screens = Float.benchScreens ?? NSScreen.screens.map(\.frame)
            if window.frame.maxX >= area.maxX - 16,
               Float.dockable(window.frame, right: true, in: area, screens: screens) { return .right }
            if window.frame.minX <= area.minX + 16,
               Float.dockable(window.frame, right: false, in: area, screens: screens) { return .left }
            return nil
        }

        /// Clearly sideways, and at that side.
        private func outward(_ way: CGVector, from side: Side) -> Bool {
            abs(way.dx) > abs(way.dy) * 1.2 && (side == .right ? way.dx > 0 : way.dx < 0)
        }

        /// Back towards the middle from the side it is docked at.
        private func inward(_ way: CGVector) -> Bool {
            guard let docked else { return false }
            return abs(way.dx) > abs(way.dy) && (docked == .right ? way.dx < 0 : way.dx > 0)
        }

        private var settling: DispatchWorkItem?

        /// A pull at a side over: into the side, or back out.
        private func letGo() {
            settling?.cancel()
            settling = nil
            guard let side = pulling else { return }
            if outward(swipe, from: side), abs(swipe.dx) >= Controls.dockAt {
                dock(side, from: pullFrom)
            } else {
                glide(to: pullFrom, bouncing: true)
            }
            pulling = nil
            swipe = .zero
            flicked = false
        }

        private func dock(_ side: Side, from origin: NSPoint? = nil) {
            guard let window, let area else { return }
            dockedFrom = origin ?? window.frame.origin
            docked = side
            glide(to: Float.docked(window.frame, right: side == .right, in: area, sliver: Controls.sliver))
        }

        private func undock() {
            guard let window else { return }
            let back = dockedFrom ?? window.frame.origin
            docked = nil
            dockedFrom = nil
            glide(to: back, bouncing: true)
        }

        /// To the corner the swipe points at, a margin in from the edges of
        /// the screen's usable part.
        private func flick(_ way: CGVector) {
            guard let window, let area else { return }
            let target = Float.corner(for: window.frame, in: area, toward: way)
            guard target != window.frame.origin else { return }
            glide(to: target)
        }

        // The glide, a frame at a time off the display's own refresh — 120
        // a second on a ProMotion screen, where AppKit's window animation
        // stepped at 60 — on a critically damped spring: quick away,
        // settling into the corner without overshooting it.
        private var gliding: CADisplayLink?
        private var glideFrom: NSPoint = .zero
        private var glideTo: NSPoint = .zero
        private var glideStart: CFTimeInterval = 0
        /// Back out from a side: a spring that goes a little past and settles.
        private var glideBounces = false

        private func glide(to target: NSPoint, bouncing: Bool = false) {
            guard let window else { return }
            glideBounces = bouncing
            glideFrom = window.frame.origin
            glideTo = target
            glideStart = CACurrentMediaTime()
            if window.screen == nil {
                // On no screen — the bench's window, off every one — there
                // is no display to keep time by: a clock does instead.
                ticking = ticking ?? Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.glideStep() }
                }
            } else if gliding == nil {
                let link = displayLink(target: self, selector: #selector(glideStep(_:)))
                link.add(to: .main, forMode: .common)
                gliding = link
            }
        }

        private var ticking: Timer?

        @objc private func glideStep(_ link: CADisplayLink) { glideStep() }

        private func glideStep() {
            guard let window else { stopGlide(); return }
            let t = CGFloat(CACurrentMediaTime() - glideStart)
            let p: CGFloat
            let done: Bool
            if glideBounces {
                // Underdamped: past the place, and back to it.
                let omega: CGFloat = 16, zeta: CGFloat = 0.5
                let damped = omega * sqrt(1 - zeta * zeta)
                done = t > 0.9
                p = done ? 1 : 1 - exp(-zeta * omega * t) * (cos(damped * t) + zeta / sqrt(1 - zeta * zeta) * sin(damped * t))
            } else {
                let omega: CGFloat = 15
                done = t > 0.6
                p = done ? 1 : 1 - (1 + omega * t) * exp(-omega * t)
            }
            window.setFrameOrigin(NSPoint(
                x: glideFrom.x + (glideTo.x - glideFrom.x) * p,
                y: glideFrom.y + (glideTo.y - glideFrom.y) * p
            ))
            if done { stopGlide() }
        }

        private func stopGlide() {
            gliding?.invalidate()
            gliding = nil
            ticking?.invalidate()
            ticking = nil
        }

        /// A pinch sizes it about the pointer: whatever is under your fingers
        /// stays under your fingers, and the rest grows away from it. Sizing
        /// about the centre instead makes the picture slide sideways under a
        /// hand that never moved, which is what felt wrong.
        private var pinching: CGFloat = 0

        override func magnify(with event: NSEvent) {
            guard let window else { return }
            if event.phase == .began { pinching = 0 }
            pinching += event.magnification

            // Every event would mean a window resize, a web view relayout and a
            // video re-fit sixty times a second, which is the stutter. Moving
            // in steps of a fiftieth is below what an eye reads as a jump and
            // an order of magnitude less work.
            guard abs(pinching) > 0.02 else { return }
            let by = pinching
            pinching = 0
            resize(
                to: window.frame.width * (1 + by),
                from: window.frame,
                around: NSEvent.mouseLocation
            )
        }

        private func resize(to width: CGFloat, from was: NSRect, around anchor: NSPoint? = nil) {
            guard let window, was.width > 0 else { return }
            let limit = NSScreen.main?.visibleFrame.width ?? 1600
            // Keeps the shape: a video window that can be squashed is a video
            // window showing bars.
            let maximum = presentation == .page
                ? min(window.maxSize.width, window.maxSize.height * was.width / was.height) : limit * 0.85
            let minimum = presentation == .page
                ? max(window.minSize.width, window.minSize.height * was.width / was.height) : window.minSize.width
            let wide = min(max(minimum, width), maximum)
            let tall = wide * was.height / was.width

            let spot: NSPoint
            if let anchor {
                // Where the pointer sits within the window, as a fraction, kept
                // at the same fraction of the new one.
                let across = (anchor.x - was.minX) / was.width
                let up = (anchor.y - was.minY) / was.height
                spot = NSPoint(x: anchor.x - across * wide, y: anchor.y - up * tall)
            } else {
                spot = NSPoint(x: was.minX, y: was.maxY - tall)
            }
            // Not display: true — asking for an immediate redraw on every step
            // is what makes a live resize stutter. The next frame is soon
            // enough.
            window.setFrame(
                NSRect(x: spot.x, y: spot.y, width: wide, height: tall),
                display: false
            )
        }

        @objc private func pressedClose() { onClose?() }
        @objc private func pressedReturn() { onReturn?() }
        @objc private func pressedRewind() { onSkip?(-15) }
        @objc private func pressedForward() { onSkip?(15) }
        @objc private func pressedPause() {
            playing.toggle()
            onPlayPause?()
        }

        /// How far through, along the bottom edge. Quiet enough to ignore.
        final class Line: NSView {
            var through: Double = 0 {
                didSet { if through != oldValue { needsDisplay = true } }
            }

            override func draw(_ dirty: NSRect) {
                NSColor(white: 1, alpha: 0.22).setFill()
                bounds.fill()
                NSColor(white: 1, alpha: 0.85).setFill()
                NSRect(x: 0, y: 0, width: bounds.width * through, height: bounds.height).fill()
            }

            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }
}

/// Sites with a player worth following into the little window.
///
/// Anywhere else, a playing video is as likely to be a background as a film,
/// and the difference isn't something a script can tell from the outside. So
/// the list is of places people go to watch, and the shortcut covers the rest.
enum Players {
    /// Explicit meeting routes, not a marketing page or a lookalike host.
    static func meeting(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        let path = url.path.lowercased()
        if host == "meet.google.com" {
            return path.range(of: "^/[a-z]{3}-[a-z]{4}-[a-z]{3}/?$", options: .regularExpression) != nil
                || path.hasPrefix("/lookup/")
        }
        if host == "teams.microsoft.com" || host == "teams.live.com" || host == "teams.cloud.microsoft" {
            return path.hasPrefix("/l/meetup-join/") || path == "/v2" || path.hasPrefix("/v2/")
        }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            return path.hasPrefix("/wc/")
        }
        return false
    }

    /// Read-only, provider-specific evidence. Device capture is not membership:
    /// a joined call can have both camera and microphone off.
    static func meetingState(_ url: URL?) -> String? {
        guard meeting(url), let host = url?.host()?.lowercased() else { return nil }
        let provider = host == "meet.google.com" ? "meet" : host.hasSuffix("zoom.us") ? "zoom" : "teams"
        return """
        (function () {
          function visible(element) {
            return element && element.getClientRects().length > 0
              && getComputedStyle(element).visibility !== 'hidden';
          }
          var provider = '\(provider)';
          var joined = false;
          if (provider === 'teams') {
            joined = Array.from(document.querySelectorAll('#hangup-button, [data-inp="hangup-button"]')).some(visible);
          } else if (provider === 'meet') {
            var buttons = Array.from(document.querySelectorAll('button, [role="button"]'));
            joined = buttons.some(function (button) {
              return (/leave (call|meeting)/i.test(button.getAttribute('aria-label') || '')
                || Array.from(button.querySelectorAll('i, span')).some(function (icon) {
                  return icon.textContent.trim() === 'call_end';
                })) && visible(button);
            });
            if (document.querySelector('[data-call-ended="true"]')) return 'ended';
          } else {
            joined = Array.from(document.querySelectorAll('button[aria-label*="mute my microphone" i], [role="button"][aria-label*="mute my microphone" i]')).some(visible);
          }
          // A quoted chat message must not end a call whose controls are up.
          if (joined) return 'joined';
          var text = (document.body ? document.body.innerText : '').replace(/\\s+/g, ' ');
          if (/you(?:'ve|’ve)? left the (meeting|call)|this meeting has been ended|you have been removed/i.test(text)) {
            return 'ended';
          }
          return 'unknown';
        })();
        """
    }

    /// A host suffix, and for a few shops that also stream, the path that
    /// separates the film from the product page.
    private static let known: [(host: String, path: String?)] = [
        ("youtube.com", nil), ("youtu.be", nil), ("netflix.com", nil),
        ("primevideo.com", nil), ("amazon.com", "/gp/video"), ("amazon.fr", "/gp/video"),
        ("amazon.co.uk", "/gp/video"), ("amazon.de", "/gp/video"),
        ("disneyplus.com", nil), ("tv.apple.com", nil), ("twitch.tv", nil),
        ("vimeo.com", nil), ("dailymotion.com", nil), ("max.com", nil), ("hbomax.com", nil),
        ("canalplus.com", nil), ("mycanal.fr", nil), ("arte.tv", nil), ("france.tv", nil),
        ("tf1.fr", nil), ("6play.fr", nil), ("crunchyroll.com", nil), ("plex.tv", nil),
        ("peacocktv.com", nil), ("hulu.com", nil), ("paramountplus.com", nil),
        ("molotov.tv", nil), ("ocs.fr", nil), ("mubi.com", nil), ("criterionchannel.com", nil),
        ("ted.com", nil), ("nebula.tv", nil), ("curiositystream.com", nil),
    ]

    static func knows(_ url: URL?) -> Bool {
        guard let url, let host = url.host()?.lowercased() else { return false }
        let path = url.path().lowercased()
        return known.contains { entry in
            guard host == entry.host || host.hasSuffix("." + entry.host) else { return false }
            guard let needle = entry.path else { return true }
            return path.hasPrefix(needle)
        }
    }
}

/// Sites whose videos never float out on their own: the site card's Don't
/// Float Videos Here (#267). Only switching tabs or apps is held back; ⇧⌘P
/// still lifts one by hand. Kept by host, as a site's sound is, and
/// forgotten with the other site choices (Browser.forgetCaptureChoices).
enum Grounded {
    static let prefix = "nofloat."

    static func holds(_ host: String) -> Bool {
        Store.settings.bool(forKey: prefix + host)
    }

    /// Off keeps nothing, as Autoplay's does.
    static func set(_ on: Bool, for host: String) {
        if on {
            Store.settings.set(true, forKey: prefix + host)
        } else {
            Store.settings.removeObject(forKey: prefix + host)
        }
    }
}

/// A panel that takes key status without bringing the whole app forward.
///
/// Borderless windows refuse to become key by default, and a window that never
/// becomes key is a window the system stops routing gestures to.
private final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum Isolate {
    /// Everything but the video, out of the way. Visibility is inherited, so
    /// hiding the body and turning it back on for the video alone leaves the
    /// player's own machinery running untouched — which is what keeps the
    /// stream alive where cutting the DOM about would kill it.
    static func on(_ request: UUID) -> String {
        """
    (function () {
      var videos = document.querySelectorAll('video');
      var best = null, area = 0;
      for (var i = 0; i < videos.length; i++) {
        var v = videos[i];
        if (v.paused || v.ended || v.readyState < 2) continue;
        var box = v.getBoundingClientRect();
        if (box.width * box.height >= area) { area = box.width * box.height; best = v; }
      }
      if (!best) return 'none';
      var box = best.getBoundingClientRect();
      if (box.width <= 0 || box.height <= 0) return 'none';

      // A landing still waiting for its tab is called off: the page is out
      // again.
      window.__officeFloatLanding = null;
      window.__officeFloatRequest = '\(request.uuidString)';
      document.documentElement.classList.remove('office-floating', 'office-float-fit');
      best.setAttribute('data-office-float', '');
      var sheet = document.getElementById('office-float');
      if (!sheet) {
        sheet = document.createElement('style');
        sheet.id = 'office-float';
        (document.head || document.documentElement).appendChild(sheet);
      }
      sheet.textContent = [
        'html.office-float-fit, html.office-float-fit body {',
        'background:#000 !important; overflow:hidden !important; margin:0 !important}',
        'html.office-floating body > * { visibility:hidden !important }',
        'html.office-floating [data-office-float] {visibility:visible !important}',
        'html.office-float-fit [data-office-float] {',
        'position:fixed !important;',
        'left:0 !important; top:0 !important; right:0 !important; bottom:0 !important;',
        'width:' + box.width + 'px !important; height:' + box.height + 'px !important;',
        'max-width:none !important; max-height:none !important;',
        // Players such as Netflix center the element with a translation.
        // With our top/left at zero, that moves it out of the floating window.
        'transform:none !important; translate:none !important; rotate:none !important; scale:none !important;',
        'opacity:1 !important; object-fit:contain !important; z-index:2147483647 !important}',
        // Netflix renders timed text after the video, in a layer of its own
        // beside it or one level up. Keep it above the video without
        // exposing the rest of the player.
        'html.office-floating [data-office-float] ~ .player-timedtext,',
        'html.office-floating :has(> [data-office-float]) > .player-timedtext,',
        'html.office-floating :has([data-office-float]) > .player-timedtext {',
        'visibility:visible !important; z-index:2147483647 !important}',
        // Fixed or not, the video is still cut to the box of any ancestor
        // that clips — YouTube's player does — and in a window this small
        // that box sits partly or wholly off screen, more so on a page that
        // was scrolled. That was the black window.
        'html.office-float-fit body :has([data-office-float]) {',
        'overflow:visible !important;',
        // And fixed is only fixed to the window while no ancestor makes a
        // box of its own for it: a transform, a filter, containment, a
        // perspective, a backdrop, a container query — Twitch's player has
        // some — and the video was placed and sized inside that box instead,
        // part of it or none of it in the window. An ancestor drawn only
        // when on screen (content-visibility) wasn't drawn at all once the
        // rest of the page was hidden, and one faded out hid the video too.
        'transform:none !important; translate:none !important; rotate:none !important; scale:none !important;',
        'filter:none !important; backdrop-filter:none !important; -webkit-backdrop-filter:none !important;',
        'perspective:none !important; contain:none !important; container-type:normal !important;',
        'will-change:auto !important; content-visibility:visible !important;',
        'clip-path:none !important; mask:none !important; -webkit-mask:none !important;',
        'opacity:1 !important}',
        // The player's own controls would sit under ours, and two sets of
        // buttons on one small window is one set too many.
        'html.office-floating [data-office-float]::-webkit-media-controls {',
        'display:none !important}'
      ].join('');

      // The mark has to be defended.
      //
      // Everything but the marked element is hidden, so the moment a player
      // rebuilds its DOM — and they all do, on a quality change, an ad break,
      // a React re-render — the mark goes with the old element and the window
      // turns pure black while still holding a perfectly live page. That is the
      // black rectangle, and it is not an orphaned window at all.
      //
      // So the mark is put back on whatever is playing now, four times a
      // second, for as long as the page is out.
      clearInterval(window.__officeFloatWatch);
      window.__officeFloatWatch = setInterval(function () {
        if (document.querySelector('[data-office-float]')) return;
        var again = null, most = 0;
        var all = document.querySelectorAll('video');
        for (var j = 0; j < all.length; j++) {
          var one = all[j];
          if (one.paused || one.ended || one.readyState < 2) continue;
          var shape = one.getBoundingClientRect();
          if (shape.width * shape.height >= most) {
            most = shape.width * shape.height;
            again = one;
          }
        }
        if (again) again.setAttribute('data-office-float', '');
      }, 250);

      document.documentElement.classList.add('office-floating');
      return [box.x, box.y, box.width, box.height];
    })();
    """
    }

    /// The native destination geometry is installed. Preparing the stylesheet
    /// earlier must not stretch the video in its source tab.
    static let present = """
    (function () {
      if (!window.__officeFloatRequest) return false;
      var sheet = document.getElementById('office-float');
      if (sheet) sheet.textContent += 'html.office-floating [data-office-float] {width:100vw !important; height:100vh !important}';
      document.documentElement.classList.add('office-floating', 'office-float-fit');
      var video = document.querySelector('[data-office-float]');
      if (video) video.getBoundingClientRect();
      return true;
    })();
    """

    /// Stop or start it, and say which it is now.
    /// Step over the bit you missed, or back to it.
    static func skip(_ seconds: Double) -> String {
        """
        (function () {
          var video = document.querySelector('[data-office-float]')
            || document.querySelector('video');
          if (!video) return false;
          video.currentTime = Math.max(0, video.currentTime + (\(seconds)));
          return true;
        })();
        """
    }

    /// How far through, and whether it is running.
    static let where_ = """
    (function () {
      var video = document.querySelector('[data-office-float]')
        || document.querySelector('video');
      if (!video || !video.duration || !isFinite(video.duration)) return [0, true];
      return [video.currentTime / video.duration, !video.paused];
    })();
    """

    static let toggle = """
    (function () {
      var video = document.querySelector('[data-office-float]')
        || document.querySelector('video');
      if (!video) return true;
      if (video.paused) { video.play(); } else { video.pause(); }
      return !video.paused;
    })();
    """

    /// The stage has installed the destination frame. Allow page resize
    /// handlers to run, even when returning did not change the viewport.
    static let landed = """
    (function () {
      var landing = window.__officeFloatLanding;
      if (!landing || !landing.put) return;
      requestAnimationFrame(function () {
        requestAnimationFrame(function () {
          if (window.__officeFloatLanding === landing) landing.put();
        });
      });
    })();
    """

    /// Everything back as it was — once the page is back in its tab and laid
    /// out at the tab's size. Put back at once, while the page still had
    /// the little window's size, the player fitted the video to that, and
    /// the tab's first frames could show it so: YouTube's, 720×240 in a
    /// 720×405 window, dropped to a strip before it grew again (#257).
    static func off(_ request: UUID? = nil, waitForResize: Bool = true) -> String {
        """
    (function () {
      // A cancelled request must not undo a newer lift of the same page.
      var request = '\(request?.uuidString ?? "")';
      if (request && window.__officeFloatRequest !== request) return 'obsolete';
      clearInterval(window.__officeFloatWatch);
      window.__officeFloatWatch = null;
      // The engine may have put the video in its own floating window as well —
      // some players ask for that themselves. Leaving one and not the other
      // leaves you with two.
      try {
        var out = document.querySelector('video[data-office-float]')
          || document.querySelector('video');
        if (out) {
          if (out.webkitPresentationMode === 'picture-in-picture') {
            out.webkitSetPresentationMode('inline');
          }
          if (document.pictureInPictureElement && document.exitPictureInPicture) {
            document.exitPictureInPicture();
          }
        }
      } catch (e) {}

      var root = document.documentElement;
      var landing = window.__officeFloatLanding = {};
      function put() {
        // Floated again in the meantime: that is the float's now.
        if (window.__officeFloatLanding !== landing) return;
        window.__officeFloatLanding = null;
        window.__officeFloatRequest = null;
        root.classList.remove('office-floating', 'office-float-fit');
        var sheet = document.getElementById('office-float');
        if (sheet) sheet.textContent = '';
        var video = document.querySelector('[data-office-float]');
        if (video) video.removeAttribute('data-office-float');
      }
      landing.put = put;
      if (!\(waitForResize)) { put(); return 'landed'; }
      // Each frame until the page is laid out at another size than the
      // little window's — the tab's — and its player has had that frame's
      // resize to fit the video to it. A page not drawn, its tab no longer
      // the one in front, is put back by the clock.
      var wide = innerWidth, high = innerHeight, began = Date.now();
      (function frame() {
        if (window.__officeFloatLanding !== landing) return;
        if (innerWidth !== wide || innerHeight !== high || Date.now() - began > 400) return put();
        requestAnimationFrame(frame);
      })();
      setTimeout(put, 1000);
      return 'landing';
    })();
    """
    }
}
