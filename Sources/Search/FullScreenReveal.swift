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
/// The accessory now hides with the menu bar and only says, as it slides,
/// how far it is out (its revealAmount, which Chrome follows the same way).
@MainActor
final class FullScreenReveal: NSObject {
    private weak var window: NSWindow?
    private weak var browser: Browser?
    private var watch: NSKeyValueObservation?
    private var accessory: NSTitlebarAccessoryViewController?
    private var sliding = false
    private var moves: [NSObjectProtocol] = []
    private weak var watched: NSWindow?

    /// The accessory's own word for how far the title bar is out in full
    /// screen, 0 to 1, changed at every step of the slide. Not in AppKit's
    /// headers; read only where it answers.
    private static let revealKey = "revealAmount"

    init(window: NSWindow, browser: Browser) {
        self.window = window
        self.browser = browser
        super.init()
        watch = window.observe(\.contentLayoutRect, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.measure() }
        }
    }

    /// Entering full screen: the accessory goes in, so there is something in
    /// the title bar to say how far the reveal is out.
    func entering() {
        guard let window, accessory == nil else { return }
        let bar = NSTitlebarAccessoryViewController()
        bar.view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 1))
        bar.layoutAttribute = .bottom
        // Away with the menu bar: nothing of the title bar stays on screen,
        // and it takes no room of its own (see above).
        bar.fullScreenMinHeight = 0
        window.addTitlebarAccessoryViewController(bar)
        accessory = bar
        if bar.responds(to: NSSelectorFromString(Self.revealKey)) {
            bar.addObserver(self, forKeyPath: Self.revealKey, options: [.new], context: nil)
            sliding = true
        }
        measure()
    }

    /// Leaving it: out again, and nothing is kept for the reveal.
    func leaving() {
        if let accessory, sliding { accessory.removeObserver(self, forKeyPath: Self.revealKey) }
        sliding = false
        if let accessory, let window, let at = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
            window.removeTitlebarAccessoryViewController(at: at)
        }
        accessory = nil
        follow(nil)
        browser?.revealInset = 0
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == Self.revealKey else { return }
        MainActor.assumeIsolated { measure() }
    }

    /// The title bar's container: the buttons' bar's parent, which holds the
    /// accessories too. In full screen it lives in a window of its own.
    private var container: NSView? {
        window?.standardWindowButton(.closeButton)?.superview?.superview
    }

    /// The window the title bar slides in, followed as it moves.
    private func follow(_ bar: NSWindow?) {
        guard bar !== watched else { return }
        for move in moves { NotificationCenter.default.removeObserver(move) }
        moves = []
        watched = bar
        guard let bar else { return }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            moves.append(NotificationCenter.default.addObserver(forName: name, object: bar, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.measure() }
            })
        }
    }

    func measure() {
        guard let window, let browser else { return }
        let full = window.styleMask.contains(.fullScreen)
        var inset: CGFloat = 0
        if full, let content = window.contentView, let bar = container, let barWindow = bar.window {
            if barWindow !== window { follow(barWindow) }
            let contentTop = window.convertToScreen(content.convert(content.bounds, to: nil)).maxY
            let barBottom = barWindow.convertToScreen(bar.convert(bar.bounds, to: nil)).minY
            let amount = sliding ? (accessory?.value(forKey: Self.revealKey) as? NSNumber).map { CGFloat($0.doubleValue) } : nil
            inset = FullScreenReveal.inset(
                fullScreen: true,
                shown: barWindow.isVisible && barWindow.alphaValue > 0.01 && !bar.isHiddenOrHasHiddenAncestor,
                revealAmount: amount,
                contentTop: contentTop,
                barBottom: barBottom)
        }
        // Set only when it moves: each set redraws the whole window and
        // rebuilds its menus, and the layout rect changes at every step of
        // a resize.
        if browser.revealInset != inset { browser.revealInset = inset }
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
