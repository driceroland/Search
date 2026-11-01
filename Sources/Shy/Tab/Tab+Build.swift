import Combine
import ImageIO
import SwiftUI
import WebKit

// The web view, built when the tab is first shown: its configuration, scripts and relays.
extension Tab {
    func build() -> PageView {
        // Here rather than in Web.configuration: a tab's configuration is
        // made with the tab, often long before its page, and a site or an
        // extension can hand over one of its own.
        FrameRate.apply(to: configuration.preferences)
        let web = PageView(frame: .zero, configuration: configuration)
        // The trackpad pinch is WebKit's own: it magnifies what is on screen
        // and lets you move around inside it, the way pinching does everywhere
        // else on a Mac. ⌘+ and ⌘- are the other thing — they lay the page out
        // again at a bigger size — and both are worth having.
        web.allowsMagnification = true
        // WebKit's own two-finger swipe stays off. It drags the page across
        // the window with a picture of the last one behind it; ours is in
        // PageView, and it moves nothing but a disc.
        web.allowsBackForwardNavigationGestures = false
        Swipe.calm(web)
        web.onPull = { [weak self] pull in self?.pull = pull }
        web.leave = leave
        web.onTouch = { [weak self] in self?.uncover() }
        web.onMenuClosed = { [weak self] in self?.popupGesture.menuClosed() }
        web.onKeys = { [weak self] in if let self { self.onKeys?(self) } }
        web.searchName = { [weak self] in self?.searchName?() }
        web.translating = { [weak self] in self.map { $0.translator != nil && $0.translation?.failed != true } ?? false }
        web.onTranslate = { [weak self] in self?.toggleTranslation() }
        web.onSearch = { [weak self] text in
            guard let self else { return }
            self.onSearch?(self, text)
        }
        web.onFirstFrame = { [weak self] in self?.painted = true }
        web.holdForFirstFrame()
        painted = !web.unpainted
        // Pages follow the appearance of the window they are drawn in, and the
        // window follows Settings › Appearance — so a site that honours
        // prefers-color-scheme goes dark with the frame, and not otherwise.
        // Safari's Develop menu can reach it, and so can the page's own
        // Inspect Element — a configuration handed over by an opener included.
        Web.inspectable(web)
        Web.pages.add(web)
        NativePiP.allow(web.configuration.preferences)
        web.navigationDelegate = delegate
        web.uiDelegate = uiDelegate(delegate)
        if #available(macOS 15.4, *) { ExtensionCapture.shared.watchScreen(web) }
        if !shy { PageNotifications.provide(web) }

        // Each name is cleared before being claimed — registering one twice is
        // a hard crash rather than an error. A tab opened by a link gets a
        // controller of its own (Browser's createWebViewWith), never its
        // opener's.
        let controller = web.configuration.userContentController
        Web.release(controller)
        controller.add(relay, contentWorld: Web.world, name: ScrollRelay.name)
        controller.add(veils_, contentWorld: Web.world, name: VeilRelay.name)
        controller.add(images, contentWorld: Web.world, name: ImageRelay.name)
        controller.add(media, contentWorld: Web.world, name: MediaKeys.name)
        controller.add(shop, contentWorld: Web.world, name: StoreRelay.name)
        controller.add(iconChanges, contentWorld: Web.world, name: IconRelay.name)
        controller.add(forms, contentWorld: Web.world, name: FormRelay.name)
        controller.addScriptMessageHandler(passkeyRelay, contentWorld: Web.world, name: PasskeyRelay.name)
        hovered.tab = self
        controller.add(hovered, contentWorld: .defaultClient, name: HoveredLink.name)
        controller.add(middles, contentWorld: Web.world, name: MiddleRelay.name)
        controller.add(translateRelay, contentWorld: Web.world, name: TranslateRelay.name)
        PopupGestureRelay.install(on: controller)
        Shield.shared.protect(controller)
        built = web
        // A tab muted before it went to sleep wakes muted.
        if muted { Muter.set(true, on: web) }
        arm(hiding: veils)

        watch = [
            web.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.title = self?.built?.title ?? "" }
            },
            web.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let fresh = self.built?.url else { return }
                    // about:blank is never a destination. Putting a pinned tab
                    // to sleep loads it deliberately to make WebKit give the
                    // page back — and letting that overwrite the address is how
                    // a pinned tab lost the only thing that could bring it
                    // back, and vanished from the session altogether.
                    guard fresh.absoluteString != "about:blank" else { return }
                    if self.held != nil {
                        if fresh == self.heldOver { return }
                        self.held = nil
                    }
                    // By site, port included: localhost:3000 to localhost:5173
                    // is another project, with another icon. Another path on
                    // the same host may be another app, with one of its own.
                    let moved = Favicons.site(fresh) != self.address.flatMap(Favicons.site)
                        || fresh.path() != self.address?.path()
                    self.address = fresh
                    // Within the same origin — history.pushState, a fragment —
                    // the page on screen is the one at the new address.
                    if let now = self.committed, now.scheme == fresh.scheme, now.host() == fresh.host(), now.port == fresh.port {
                        self.committed = fresh
                    }
                    if moved { self.adoptIcon() }
                }
            },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.progress = self?.built?.estimatedProgress ?? 0 }
            },
            web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.loading = self?.built?.isLoading ?? false }
            },
            web.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.steps() }
            },
            web.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.steps() }
            },
            // A page's full screen, as WebKit has it. In once its own window
            // has the page (a placeholder is left in ours, so the chrome going
            // away resizes nothing the page sees); back as soon as it starts
            // to give it back, while that window still covers ours: the
            // chrome is then in place before the page returns, and the page
            // is laid out once, at the size it had, where WebKit's animation
            // lands it. The page's own fullscreenchange (Forms.swift) comes
            // after each and changes nothing.
            web.observe(\.fullscreenState, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let state = self.built?.fullscreenState else { return }
                    let on = state == .enteringFullscreen || state == .inFullscreen
                    if self.immersed != on { self.immersed = on }
                }
            },
        ]

        relay.tab = self
        veils_.tab = self
        forms.tab = self
        images.tab = self
        media.tab = self
        shop.tab = self
        iconChanges.tab = self
        middles.tab = self
        translateRelay.tab = self
        ears.watch(web) { [weak self] on in self?.heard(on) }
        return web
    }
}
