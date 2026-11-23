import AppKit

/// In full screen, moving the pointer to the top of the screen brings macOS's
/// menu bar and the bar with the window's buttons down over the window. With
/// the content running under the title bar, as it does here, they lay over
/// the strip of tabs and the bookmarks bar and covered them (idea 854).
/// Safari and Chrome push their bars down instead, by exactly what came down.
///
/// What came down is measured, not inferred: the bottom of the title bar's
/// container (the buttons' bar and its accessories), on the screen, against
/// the top of the window's content. In 1.0.17 the window's
/// contentLayoutRect stood in for it, kept moving by an accessory that stayed
/// a point tall even with the menu bar away; the menu bar's reveal did not
/// carry that rect with it the whole way, so the bars stayed under what came
/// down, and the accessory kept in full screen gave the title bar a ground
/// and room of its own, the grey strip seen taller than in 1.0.16 (idea 926).
/// With tabs down the side, the window buttons use the same reveal to slide
/// into the sidebar header from the left. Only the header makes room.
/// The accessory hides with the menu bar and says, as it slides,
/// how far it is out (its revealAmount, which Chrome follows the same way),
/// and sits beside the window's buttons, where it adds no height to what
/// comes down (idea 934, see makeAccessory).
@MainActor
final class FullScreenReveal: NSObject {
    private weak var window: NSWindow?
    private weak var browser: Browser?
    private var watch: NSKeyValueObservation?
    private var accessory: NSTitlebarAccessoryViewController?
    private var sliding = false
    private var moves: [NSObjectProtocol] = []
    private weak var watched: NSWindow?
    private weak var watchedContainer: NSView?
    private var compact: FullScreenLights?
    private var mouseEvents: NSKeyValueObservation?
    private var measureQueued = false

    /// The accessory's own word for how far the title bar is out in full
    /// screen, 0 to 1, changed at every step of the slide. Not in AppKit's
    /// headers; read only where it answers.
    private nonisolated static let revealKey = "revealAmount"

    init(window: NSWindow, browser: Browser) {
        self.window = window
        self.browser = browser
        super.init()
        watch = window.observe(\.contentLayoutRect, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleMeasure() }
        }
    }

    /// Entering full screen: the accessory goes in, so there is something in
    /// the title bar to say how far the reveal is out.
    func entering() {
        guard let window, accessory == nil else { return }
        let bar = Self.makeAccessory()
        window.addTitlebarAccessoryViewController(bar)
        accessory = bar
        if bar.responds(to: NSSelectorFromString(Self.revealKey)) {
            bar.addObserver(self, forKeyPath: Self.revealKey, options: [.new], context: nil)
            sliding = true
        }
        measure()
    }

    /// The accessory: nothing to see, and no room taken. At the bottom of
    /// the title bar, as it was until 1.0.18, AppKit gives an accessory a
    /// row of its own at least 36 points tall whatever its view says (macOS
    /// 26, measured: the title bar went from 32 points to 68, and so did
    /// the full-screen title bar's most), so the strip with the window's
    /// buttons came down that much taller than the menu bar and Safari's
    /// (idea 934). Beside the buttons, at the trailing end of their own
    /// row, a view of no width adds nothing, and the accessory still says how
    /// far the reveal is out. Away with the menu bar: nothing of the title
    /// bar stays on screen.
    static func makeAccessory() -> NSTitlebarAccessoryViewController {
        let bar = NSTitlebarAccessoryViewController()
        bar.view = NSView(frame: .zero)
        bar.layoutAttribute = .trailing
        bar.fullScreenMinHeight = 0
        return bar
    }

    /// Leaving it: out again, and nothing is kept for the reveal.
    func leaving() {
        let accessory = self.accessory
        self.accessory = nil
        if let accessory, sliding { accessory.removeObserver(self, forKeyPath: Self.revealKey) }
        sliding = false
        follow(nil, container: nil)
        restoreBar()
        if let accessory, let window, let at = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
            window.removeTitlebarAccessoryViewController(at: at)
        }
        browser?.revealInset = 0
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == Self.revealKey else { return }
        MainActor.assumeIsolated { scheduleMeasure() }
    }

    /// The title bar's container: the buttons' bar's parent, which holds the
    /// accessories too. In full screen it lives in a window of its own.
    private var container: NSView? {
        // Once our buttons are in the browser window, AppKit's lookup can
        // return them. Keep following the native container we found first.
        let found = window?.standardWindowButton(.closeButton)?.superview?.superview
        if let host = found?.window, host !== window { return found }
        if let watchedContainer, let host = watchedContainer.window, host !== window {
            return watchedContainer
        }
        return found
    }

    /// The title bar can slide inside its window as that window moves.
    private func follow(_ bar: NSWindow?, container: NSView?) {
        guard bar !== watched || container !== watchedContainer else { return }
        for move in moves { NotificationCenter.default.removeObserver(move) }
        moves = []
        mouseEvents = nil
        watched = bar
        watchedContainer = container
        guard let bar else { return }
        mouseEvents = bar.observe(\.ignoresMouseEvents, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleMeasure() }
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            moves.append(NotificationCenter.default.addObserver(forName: name, object: bar, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleMeasure() }
            })
        }
        if let container {
            moves.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                               object: container, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleMeasure() }
            })
        }
    }

    // AppKit moves its container and updates its window's input handling
    // during the same reveal callback. Read the settled values together.
    private func scheduleMeasure() {
        guard !measureQueued else { return }
        measureQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measureQueued = false
            self.measure()
        }
    }

    private func restoreBar() {
        compact?.restore()
        compact = nil
        setSidebarReveal(.zero)
    }

    private func setSidebarReveal(_ reveal: SidebarLightsReveal) {
        guard let browser, browser.sidebarLightsReveal != reveal else { return }
        browser.sidebarLightsReveal = reveal
    }

    private func compactBar(_ bar: NSWindow, in content: NSView, window: NSWindow,
                            amount: CGFloat, menuInset: CGFloat) -> Bool {
        guard let frame = content.superview, let layer = bar.contentView?.superview?.layer else { return false }
        if compact?.nativeLayer !== layer {
            restoreBar()
            let originals = FullScreenLights.buttonTypes.compactMap { window.standardWindowButton($0) }
            guard originals.count == FullScreenLights.buttonTypes.count,
                  originals.allSatisfy({ $0.window === bar }) else { return false }
            compact = FullScreenLights(window: window, bar: bar, layer: layer, originals: originals)
        }
        guard let compact, let browser else { return false }
        compact.hideNativeBar()
        if amount == 0 {
            compact.removeFromSuperview()
            setSidebarReveal(.zero)
            return true
        }

        if compact.superview !== frame {
            frame.addSubview(compact, positioned: .above, relativeTo: content)
        }
        let inline = browser.prefs.sidePosition == .left && !browser.prefs.iconColumn
            && (!browser.folded || browser.peeking)
        let top = compact.show(amount: amount, menuInset: menuInset, over: content, floating: !inline)
        setSidebarReveal(inline ? SidebarLightsReveal(amount: amount, top: top) : .zero)
        return true
    }

    func measure() {
        guard let window, let browser else { return }
        if window.styleMask.contains(.fullScreen),
           let content = window.contentView, let bar = container, let barWindow = bar.window {
            let separate = barWindow !== window
            follow(separate ? barWindow : nil, container: separate ? bar : nil)
            let contentTop = window.convertToScreen(content.convert(content.bounds, to: nil)).maxY
            let barBottom = barWindow.convertToScreen(bar.convert(bar.bounds, to: nil)).minY
            let amount = sliding ? (accessory?.value(forKey: Self.revealKey) as? NSNumber).map { CGFloat($0.doubleValue) } : nil
            let shown = barWindow.isVisible && barWindow.alphaValue > 0.01 && !bar.isHiddenOrHasHiddenAncestor
            let inset = Self.inset(fullScreen: separate, shown: shown, revealAmount: amount,
                                   contentTop: contentTop, barBottom: barBottom)
            let progress = barWindow.isVisible ? min(1, max(0, amount ?? (inset > 0 ? 1 : 0))) : 0
            let menuInset = max(0, contentTop - barWindow.frame.maxY).rounded()
            if separate, accessory != nil, browser.prefs.sidebar,
               compactBar(barWindow, in: content, window: window, amount: progress, menuInset: menuInset) {
                if browser.revealInset != 0 { browser.revealInset = 0 }
                return
            }
            restoreBar()
            // Each set redraws the whole window and rebuilds its menus.
            if browser.revealInset != inset { browser.revealInset = inset }
        } else {
            follow(nil, container: nil)
            restoreBar()
            if browser.revealInset != 0 { browser.revealInset = 0 }
        }
    }

    /// How far down from the top of the window's content the bars start:
    /// what of the title bar macOS brought down lies over it, once and only
    /// once, whatever room the window already left for it, and nothing
    /// outside full screen (where the buttons' own room is kept by the bars
    /// themselves), with the title bar away, or before it has begun to slide.
    nonisolated static func inset(fullScreen: Bool, shown: Bool, revealAmount: CGFloat?,
                                  contentTop: CGFloat, barBottom: CGFloat) -> CGFloat {
        guard fullScreen, shown else { return 0 }
        if let revealAmount, revealAmount <= 0 { return 0 }
        return max(0, (contentTop - barBottom).rounded())
    }
}


/// The space opened by the left sidebar's header, in step with AppKit.
struct SidebarLightsReveal: Equatable {
    let amount: CGFloat
    let top: CGFloat
    static let zero = SidebarLightsReveal(amount: 0, top: 0)
}

/// AppKit decides when to reveal and retract. The wide title-bar window
/// keeps that job, while its visual and mouse surfaces give way to a row
/// of standard AppKit buttons on Search's own window.
@MainActor
private final class FullScreenLights: NSView {
    static let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    private weak var bar: NSWindow?
    private(set) weak var nativeLayer: CALayer?
    private let blank = CALayer()
    private let backing = CALayer()
    private let originalMask: CALayer?
    private let background: NSColor
    private let originalOpaque: Bool
    private let originalShadow: Bool
    private let ignoredMouse: Bool
    private let buttons: [NSButton]
    private let originals: [NSButton]

    init?(window: NSWindow, bar: NSWindow, layer: CALayer, originals: [NSButton]) {
        let style = window.styleMask.subtracting(.fullScreen)
        let buttons = Self.buttonTypes.compactMap { NSWindow.standardWindowButton($0, for: style) }
        guard buttons.count == Self.buttonTypes.count else { return nil }
        self.buttons = buttons
        self.originals = originals
        self.bar = bar
        nativeLayer = layer
        originalMask = layer.mask
        background = bar.backgroundColor
        originalOpaque = bar.isOpaque
        originalShadow = bar.hasShadow
        ignoredMouse = bar.ignoresMouseEvents
        super.init(frame: .zero)
        wantsLayer = true
        self.layer?.zPosition = 10
        backing.borderWidth = 1
        backing.isHidden = true
        self.layer?.addSublayer(backing)
        updateBackingColors()
        isHidden = true
        for button in buttons { addSubview(button) }
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackingColors()
    }

    private func updateBackingColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            backing.backgroundColor = Palette.NS.ground.cgColor
            backing.borderColor = Palette.NS.faint.cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func hideNativeBar() {
        guard let bar, let nativeLayer else { return }
        if nativeLayer.mask !== blank { nativeLayer.mask = blank }
        if bar.backgroundColor != .clear { bar.backgroundColor = .clear }
        if bar.isOpaque { bar.isOpaque = false }
        if bar.hasShadow { bar.hasShadow = false }
        if !bar.ignoresMouseEvents { bar.ignoresMouseEvents = true }
    }

    /// Return the small downward correction needed when the menu bar
    /// overlaps the header. The rest of the slide is horizontal.
    func show(amount: CGFloat, menuInset: CGFloat, over content: NSView, floating: Bool) -> CGFloat {
        guard let parent = superview, let window else { return 0 }
        let strip = Metrics.strip
        let top = max(0, menuInset - (strip - 26) / 2)
        let first = originals[0].frame
        let last = originals[originals.count - 1].frame
        let leading = Lights.centre.x - first.width / 2
        let padding: CGFloat = floating ? 10 : 0
        let reach = leading + last.maxX - first.minX + padding
        let x = (reach + 2) * (amount - 1)
        let y = content.isFlipped ? content.bounds.minY + top : content.bounds.maxY - strip - top
        let next = parent.convert(NSRect(x: content.bounds.minX + x, y: y, width: reach, height: strip), from: content)
        if frame != next { frame = next }
        // Over a page, an opaque surface keeps the lights legible even
        // when the site has buttons or text in the same corner.
        if floating {
            let height = originals.map { $0.frame.height }.max() ?? first.height
            let box = CGRect(x: leading - padding, y: (strip - height) / 2 - 8,
                             width: reach - leading + padding, height: height + 16)
            if backing.frame != box {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                backing.frame = box
                backing.cornerRadius = box.height / 2
                CATransaction.commit()
            }
        }
        backing.isHidden = !floating
        for (button, original) in zip(buttons, originals) {
            let size = original.frame.size
            let origin = NSPoint(x: leading + original.frame.minX - first.minX,
                                 y: (strip - size.height) / 2)
            button.frame = NSRect(origin: origin, size: size)
            button.target = original.target ?? window
            button.action = original.action
            button.isEnabled = original.isEnabled
        }
        isHidden = false
        return top
    }

    func restore() {
        removeFromSuperview()
        if nativeLayer?.mask === blank { nativeLayer?.mask = originalMask }
        bar?.backgroundColor = background
        bar?.isOpaque = originalOpaque
        bar?.hasShadow = originalShadow
        bar?.ignoresMouseEvents = ignoredMouse
    }
}
