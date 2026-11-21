import AppKit
import SwiftUI
import WebKit

// A page asking for the pointer (element.requestPointerLock), as browser
// games do to turn the mouse into a camera (#1305). WebKit has pointer lock
// on, but on the Mac it only grants it through a UI-delegate method that
// isn't public; unanswered, every request was refused and the cursor stayed.
//
// Granted as Safari grants it: to the tab in front only, never to a coding
// agent's tab, and only right after a real click or key in that page (the
// page's own trusted input, PopupGesture) — a page can't take the pointer
// from someone just moving across it. While it is held a pill over the page
// says "Press Esc to show your pointer" for a few seconds; Escape always
// reaches the page then, ahead of Search's own Escape jobs, and WebKit lets
// the pointer go on it (WebCore unlocks on Escape itself).
//
// A test run never locks the pointer: that would take the mouse of whoever
// is working beside it. The answer is kept for the bench instead, the lock
// is held here as if granted, and Escape lets it go here; the pill is never
// put on a screen, `showing` is what is tested (Tests/pointer_lock.py).

@MainActor
final class PointerLock {
    static let shared = PointerLock()

    /// How long the pill stays up once the pointer is taken.
    static let shown: TimeInterval = 3

    /// The page holding the pointer.
    private(set) weak var page: PageView?
    /// What the last request was answered, for the bench: "granted", or
    /// "denied" and why.
    private(set) var answered = ""
    /// How many requests reached Search, for the bench.
    private(set) var asked = 0
    /// Whether the pill is up, for the bench. Not while it fades.
    private(set) var showing = false
    private var panel: PointerLockPanel?
    private var expiry: DispatchWorkItem?

    /// Why a page is refused the pointer, or nil when it may have it: never
    /// in a coding agent's tab, only in the tab in front, and only right
    /// after a real click or key in the page.
    nonisolated static func refusal(agent: Bool, front: Bool, input: Bool) -> String? {
        if agent { return "agent" }
        if !front { return "not in front" }
        if !input { return "no gesture" }
        return nil
    }

    /// A page asking for the pointer: yes only for the front tab, not an
    /// agent's, right after its own real input.
    func request(_ webView: WKWebView, in browser: Browser, answer: @escaping (Bool) -> Void) {
        let refuse = { (why: String) in
            self.answered = "denied: " + why
            answer(false)
        }
        asked += 1
        guard let page = webView as? PageView, let tab = browser.tab(for: webView) else { return refuse("not a tab") }
        if let why = Self.refusal(agent: tab.agent, front: tab.id == browser.activeID, input: tab.popupGesture.recent()) {
            return refuse(why)
        }
        answered = "granted"
        self.page = page
        show(over: page)
        answer(!Store.testing)
    }

    /// WebKit's word that the page no longer has the pointer: Escape, the
    /// page letting go, the tab or window losing focus.
    func lost(_ webView: WKWebView) {
        guard page === webView else { return }
        release()
    }

    /// An Escape on its way through a browser window (ContentView.watchKeys):
    /// with the pointer held by a page there, the key is the page's — WebKit
    /// lets the pointer go on it — and none of Search's own Escape jobs.
    /// True when it goes on to the page.
    func escape(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53, let page, let window = page.window, event.window === window else { return false }
        if window.firstResponder !== page { window.makeFirstResponder(page) }
        // A test run held it only here: Escape lets it go here.
        if Store.testing { release() } else { hide() }
        return true
    }

    private func release() {
        page = nil
        hide()
    }

    // MARK: - the pill

    private func show(over page: PageView) {
        showing = true
        expiry?.cancel()
        let expiry = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        self.expiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shown, execute: expiry)
        // A test run never puts a window up: `showing` is what it reads.
        guard !Store.testing, let window = page.window else { return }
        let panel = self.panel ?? PointerLockPanel()
        self.panel = panel
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.place(over: page.convert(page.bounds, to: nil), in: window)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.reduced ? 0 : 0.15
            panel.animator().alphaValue = 1
        }
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: PointerLockHint.words,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private func hide() {
        expiry?.cancel()
        expiry = nil
        showing = false
        guard let panel, panel.parent != nil else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.reduced ? 0 : 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard !self.showing else { return }
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
        })
    }
}

/// The pill's window: borderless, never key, and nothing the pointer can
/// catch, near the top of the page it is over.
private final class PointerLockPanel: NSPanel {
    private let content = NSHostingView(rootView: PointerLockHint())

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 36),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
        alphaValue = 0
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Centred across the page, a little below its top; `area` is the
    /// page's frame in the window.
    func place(over area: NSRect, in window: NSWindow) {
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let page = window.convertToScreen(area)
        content.frame = NSRect(origin: .zero, size: size)
        setFrame(NSRect(x: (page.midX - size.width / 2).rounded(), y: page.maxY - 24 - size.height,
                        width: size.width, height: size.height), display: false)
    }
}

/// "Press Esc to show your pointer", the key as a key, light on dark
/// whatever the page is.
private struct PointerLockHint: View {
    static let words = "Press Esc to show your pointer"

    var body: some View {
        HStack(spacing: 6) {
            Text("Press")
            Text("Esc")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 6)
                .frame(height: 20)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
            Text("to show your pointer")
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(Color.white)
        .padding(.horizontal, 18)
        .frame(height: 36)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.words)
    }
}

extension Browser {
    /// WebKit asking whether a page may have the pointer (see PointerLock).
    @objc(_webViewDidRequestPointerLock:completionHandler:)
    func askedForPointerLock(_ webView: WKWebView, completionHandler: @escaping (Bool) -> Void) {
        PointerLock.shared.request(webView, in: self, answer: completionHandler)
    }

    /// The page no longer has the pointer.
    @objc(_webViewDidLosePointerLock:)
    func lostPointerLock(_ webView: WKWebView) {
        PointerLock.shared.lost(webView)
    }
}
