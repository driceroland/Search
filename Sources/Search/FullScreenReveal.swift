import AppKit

/// In full screen, moving the pointer to the top of the screen brings macOS's
/// menu bar and the bar with the window's buttons down over the window. With
/// the content running under the title bar, as it does here, they lay over
/// the strip of tabs and the bookmarks bar and covered them (idea 854).
/// Safari and Chrome push their bars down instead.
///
/// The window says how much of its top the reveal takes in its
/// contentLayoutRect, once the title bar holds something it has to make room
/// for: a titlebar accessory, which is added while in full screen, a single
/// clear point tall. The top bars then sit under that inset, moving with it.
@MainActor
final class FullScreenReveal: NSObject {
    private weak var window: NSWindow?
    private weak var browser: Browser?
    private var watch: NSKeyValueObservation?
    private var accessory: NSTitlebarAccessoryViewController?

    init(window: NSWindow, browser: Browser) {
        self.window = window
        self.browser = browser
        super.init()
        watch = window.observe(\.contentLayoutRect, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.measure() }
        }
    }

    /// Entering full screen: the accessory goes in, so the title bar has
    /// something to carry down with the menu bar.
    func entering() {
        guard let window, accessory == nil else { return }
        let bar = NSTitlebarAccessoryViewController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 1))
        bar.view = view
        bar.layoutAttribute = .bottom
        bar.fullScreenMinHeight = 1
        window.addTitlebarAccessoryViewController(bar)
        accessory = bar
        measure()
    }

    /// Leaving it: out again, and nothing is kept for the reveal.
    func leaving() {
        if let accessory, let window, let at = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
            window.removeTitlebarAccessoryViewController(at: at)
        }
        accessory = nil
        browser?.revealInset = 0
    }

    func measure() {
        guard let window, let browser else { return }
        browser.revealInset = FullScreenReveal.inset(
            fullScreen: window.styleMask.contains(.fullScreen),
            contentHeight: window.contentView?.frame.height ?? 0,
            layoutTop: window.contentLayoutRect.maxY)
    }

    /// How far down from the window's top edge the bars start: what the
    /// reveal takes, nothing outside full screen (where the buttons' own room
    /// is kept by the bars themselves) and never a negative.
    nonisolated static func inset(fullScreen: Bool, contentHeight: CGFloat, layoutTop: CGFloat) -> CGFloat {
        guard fullScreen, contentHeight > 0 else { return 0 }
        return max(0, (contentHeight - layoutTop).rounded())
    }
}
