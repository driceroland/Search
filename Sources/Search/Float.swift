import AppKit
import WebKit

// A video that keeps playing after you have gone somewhere else, in a small
// window that stays above everything — other tabs, and other apps.
//
// WebKit will not hand a video to the system's picture-in-picture without a
// real click on the page, and nothing the app does counts as one. Chromium is
// looser, which is why this works elsewhere and refused here.
//
// So the engine is not asked. The page itself is moved: everything but the
// video is made invisible, the video is stretched to fill the viewport, and the
// whole web view is lifted out of the window and into a small floating one. The
// video never stops, because it is the same page it always was — it has only
// changed windows.

@MainActor
final class Float {
    private var panel: NSPanel?
    private var controls: Controls?
    private weak var page: NSView?

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

    private var ticker: Timer?

    var showing: Bool { panel != nil }

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

    func lift(_ page: NSView) {
        guard panel == nil else { return }
        self.page = page

        let size = NSSize(width: 440, height: 247)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        // Where it was last, at the size it was, if a screen still shows it;
        // otherwise the bottom right of this one.
        let spot = Float.remembered ?? NSRect(
            x: screen.maxX - size.width - 24,
            y: screen.minY + 24,
            width: size.width,
            height: size.height
        )

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
        panel.aspectRatio = size
        // Kept once a move or a resize is over, not on each step of one: at
        // the end of a resize by its edges, as it closes (see drop), and as
        // the app quits with it open, which closes nothing.
        let keep: (Notification.Name, AnyObject) -> NSObjectProtocol = { name, object in
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak panel] _ in
                MainActor.assumeIsolated {
                    if let panel { Float.remembered = panel.frame }
                }
            }
        }
        keeping = [
            keep(NSWindow.didEndLiveResizeNotification, panel),
            keep(NSApplication.willTerminateNotification, NSApp),
        ]
        panel.minSize = NSSize(width: 260, height: 146)

        let ground = NSView(frame: NSRect(origin: .zero, size: size))
        ground.wantsLayer = true
        ground.layer?.backgroundColor = NSColor.black.cgColor
        ground.layer?.cornerRadius = 14
        ground.layer?.masksToBounds = true

        // WebKit puts its own pinch recogniser on a web view, and a gesture
        // recogniser is consulted before the responder chain is. With it left
        // on, every pinch aimed at this window went into zooming the page
        // inside it instead of sizing the window. It comes back on landing.
        (page as? WKWebView)?.allowsMagnification = false

        page.removeFromSuperview()
        page.frame = ground.bounds
        page.autoresizingMask = [.width, .height]
        ground.addSubview(page)

        let controls = Controls(frame: ground.bounds)
        controls.autoresizingMask = [.width, .height]
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
        panel.orderFrontRegardless()
        self.panel = panel

        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                // A window that no longer holds the page has nothing to show
                // and no reason to exist. Something else took the page back —
                // and rather than hunt every path that could, this makes it
                // impossible for the empty black rectangle to outlive it by
                // more than half a second.
                if self.page?.superview !== ground {
                    self.onClose?()
                    return
                }

                self.onProgress? { through, playing in
                    self.controls?.progress = through
                    self.controls?.playing = playing
                }
            }
        }
    }

    /// The window's last place and size, kept across closing it and quitting,
    /// and given back only while a screen still shows most of it.
    private static var remembered: NSRect? {
        get {
            guard let text = Store.settings.string(forKey: "float.frame") else { return nil }
            let frame = NSRectFromString(text)
            let shown = NSScreen.screens.contains {
                let seen = $0.visibleFrame.intersection(frame)
                return seen.width * seen.height > 0.6 * frame.width * frame.height
            }
            return frame.width > 100 && shown ? frame : nil
        }
        set { Store.settings.set(newValue.map(NSStringFromRect), forKey: "float.frame") }
    }

    private var keeping: [NSObjectProtocol] = []

    /// Puts the page down and closes. Whoever owns the page takes it back on
    /// their next layout.
    func drop() {
        guard let panel else { return }
        Float.remembered = panel.frame
        keeping.forEach(NotificationCenter.default.removeObserver)
        keeping = []
        ticker?.invalidate()
        ticker = nil
        (page as? WKWebView)?.allowsMagnification = true
        page?.removeFromSuperview()
        page = nil
        controls = nil
        panel.orderOut(nil)
        panel.close()
        self.panel = nil
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
            didSet { pause.image = glyph(playing ? "pause.fill" : "play.fill", 17) }
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
        private var near = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true

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

            dress(close, "xmark", 11, round: 15, action: #selector(pressedClose))
            dress(back, "arrow.up.forward", 12, round: 15, action: #selector(pressedReturn))
            dress(rewind, "gobackward.15", 15, round: 19, action: #selector(pressedRewind))
            dress(pause, "pause.fill", 17, round: 25, action: #selector(pressedPause))
            dress(forward, "goforward.15", 15, round: 19, action: #selector(pressedForward))

            line.alphaValue = 0
            addSubview(line)
            buttons.forEach { $0.alphaValue = 0 }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        private var buttons: [NSButton] { [close, back, rewind, pause, forward] }

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

        /// Everything reaches this layer.
        ///
        /// isMovableByWindowBackground never worked here: the window's whole
        /// background is a web view, and a web view swallows every drag before
        /// the window sees it. So every gesture is taken here, above it.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let inside = convert(point, from: superview)
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
            point.x > bounds.maxX - 22 && point.y < bounds.minY + 22
        }

        override func resetCursorRects() {
            addCursorRect(
                NSRect(x: bounds.maxX - 22, y: bounds.minY, width: 22, height: 22),
                cursor: .crosshair
            )
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            stopGlide()
            grab = NSEvent.mouseLocation
            origin = window.frame
            stretching = atCorner(convert(event.locationInWindow, from: nil))
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let now = NSEvent.mouseLocation
            let dx = now.x - grab.x
            let dy = now.y - grab.y

            guard stretching else {
                window.setFrameOrigin(NSPoint(x: origin.minX + dx, y: origin.minY + dy))
                return
            }
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
                flick(step)
                return
            }
            if event.phase.contains(.began) {
                swipe = .zero
                flicked = false
            }
            swipe.dx += step.dx
            swipe.dy += step.dy
            // Read from the whole swipe, as the fingers lift: a swipe often
            // sets off along one side before it turns diagonal, and read
            // early it went the wrong way. A long one doesn't wait.
            let lifted = event.phase.contains(.ended) || event.phase.contains(.cancelled)
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

        /// To the corner the swipe points at, a margin in from the edges of
        /// the screen's usable part.
        private func flick(_ way: CGVector) {
            guard let window, let area = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
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

        private func glide(to target: NSPoint) {
            guard let window else { return }
            glideFrom = window.frame.origin
            glideTo = target
            glideStart = CACurrentMediaTime()
            if gliding == nil {
                let link = displayLink(target: self, selector: #selector(glideStep))
                link.add(to: .main, forMode: .common)
                gliding = link
            }
        }

        @objc private func glideStep(_ link: CADisplayLink) {
            guard let window else { stopGlide(); return }
            let t = CGFloat(CACurrentMediaTime() - glideStart)
            let omega: CGFloat = 15
            let done = t > 0.6
            let p = done ? 1 : 1 - (1 + omega * t) * exp(-omega * t)
            window.setFrameOrigin(NSPoint(
                x: glideFrom.x + (glideTo.x - glideFrom.x) * p,
                y: glideFrom.y + (glideTo.y - glideFrom.y) * p
            ))
            if done { stopGlide() }
        }

        private func stopGlide() {
            gliding?.invalidate()
            gliding = nil
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
            let wide = min(max(window.minSize.width, width), limit * 0.85)
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
                didSet { needsDisplay = true }
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
    static let on = """
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

      best.setAttribute('data-office-float', '');
      var sheet = document.getElementById('office-float');
      if (!sheet) {
        sheet = document.createElement('style');
        sheet.id = 'office-float';
        (document.head || document.documentElement).appendChild(sheet);
      }
      sheet.textContent = [
        'html.office-floating, html.office-floating body {',
        'background:#000 !important; overflow:hidden !important; margin:0 !important}',
        'html.office-floating body > * { visibility:hidden !important }',
        'html.office-floating [data-office-float] {',
        'visibility:visible !important; position:fixed !important;',
        'left:0 !important; top:0 !important; right:0 !important; bottom:0 !important;',
        'width:100vw !important; height:100vh !important;',
        'max-width:none !important; max-height:none !important;',
        'object-fit:contain !important; z-index:2147483647 !important}',
        // Fixed or not, the video is still cut to the box of any ancestor
        // that clips — YouTube's player does — and in a window this small
        // that box sits partly or wholly off screen, more so on a page that
        // was scrolled. That was the black window.
        'html.office-floating body :has([data-office-float]) {',
        'overflow:visible !important}',
        // The player's own controls would sit under ours, and two sets of
        // buttons on one small window is one set too many.
        'html.office-floating [data-office-float]::-webkit-media-controls {',
        'display:none !important}'
      ].join('');
      document.documentElement.classList.add('office-floating');

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

      return 'floating';
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

    static let off = """
    (function () {
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

      clearInterval(window.__officeFloatWatch);
      window.__officeFloatWatch = null;
      document.documentElement.classList.remove('office-floating');
      var sheet = document.getElementById('office-float');
      if (sheet) sheet.textContent = '';
      var video = document.querySelector('[data-office-float]');
      if (video) video.removeAttribute('data-office-float');
      return 'landed';
    })();
    """
}
