import SwiftUI
import WebKit

// A peek at a link, Arc's way: shift-click it and its page opens in a panel
// over the one you are reading, which stays where it was underneath. Escape,
// a click beside the panel or its cross puts it away; its other button keeps
// it, as a tab beside this one, loaded as it is.
//
// Off unless asked for, in Settings › General: shift-click means other
// things to some pages, and nobody who doesn't want this should meet it.
//
// The page is a tab of its own, only not in the row: keeping it is moving
// it there, with nothing loaded twice.

extension Browser {
    /// Shift-click on a link, from a tab in the row.
    func peek(_ url: URL, from tab: Tab) {
        if tab.pin != nil, let host = url.host()?.lowercased() { tab.peeked = (Vault.registrable(host), Date()) }
        let page = Tab(shy: tab.shy)
        prepare(page)
        page.go(to: url)
        withAnimation(Motion.settle) {
            peekTab = page
            peekFrom = tab.id
        }
    }

    /// A plain click in a pin, on a link to another site, with Settings ›
    /// Tabs › Open links from pins in a peek on: Arc's way, the link opens
    /// in a peek and the pin stays the page it was pinned for. Links within
    /// the site go as they always have, so moving about Gmail or Notion
    /// stays in the pin.
    func peeksFromPin(_ url: URL, in tab: Tab, on page: URL?) -> Bool {
        guard prefs.pinsPeek, tab.pin != nil, peekTab == nil,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let there = url.host()?.lowercased(),
              let here = page?.host()?.lowercased()
        else { return false }
        return there != here && Vault.registrable(there) != Vault.registrable(here)
    }

    /// A new window asked for by a pin's page, in the peek: built on the
    /// configuration WebKit hands over and given back to it, so the page
    /// loads into it and the one that asked keeps it as its opener.
    func peekWindow(_ configuration: WKWebViewConfiguration, from tab: Tab, going url: URL?) -> WKWebView {
        let page = Tab(shy: tab.shy, configuration: configuration)
        prepare(page)
        page.opener = tab.id
        if let url {
            page.setAddressOptimistically(url)
            if let host = url.host()?.lowercased() { tab.peeked = (Vault.registrable(host), Date()) }
        }
        withAnimation(Motion.settle) {
            peekTab = page
            peekFrom = tab.id
        }
        return page.web
    }

    /// A pin's page going after a link it just peeked at, by script: Google's
    /// results do, when the click didn't take the page away by itself. The
    /// peek already has it, and the pin stays.
    func followsPeek(_ url: URL, in tab: Tab) -> Bool {
        guard prefs.pinsPeek, tab.pin != nil, let peeked = tab.peeked,
              Date().timeIntervalSince(peeked.at) < 3,
              let host = url.host()?.lowercased()
        else { return false }
        return Vault.registrable(host) == peeked.site
    }

    /// Put away: the page goes with the panel.
    func closePeek() {
        guard let page = peekTab else { return }
        withAnimation(Motion.quick) {
            peekTab = nil
            peekFrom = nil
        }
        page.close()
    }

    /// Kept: a tab beside the one it was opened from, and in front. With
    /// Split View on, `beside` keeps it in a pair with that page instead —
    /// the page and what it linked to, side by side.
    func keepPeek(beside: Bool = false) {
        guard let page = peekTab else { return }
        let from = active
        let place = placeForNew()
        // Kept from a grouped tab, it joins that group, as a link opened
        // from there does (see open).
        if prefs.usesTabGroups, !page.shy, let from = active { page.groupID = from.groupID }
        withAnimation(Motion.quick) {
            peekTab = nil
            peekFrom = nil
        }
        insert(page, at: place)
        if beside, prefs.splitView, let from, canSplit(page, with: from) {
            pair(page, with: from, onLeft: false)
        } else {
            select(page)
        }
    }
}

/// The peek over the page: the page dimmed around it, and the panel.
struct PeekLayer: View {
    @ObservedObject var browser: Browser

    var body: some View {
        ZStack {
            // The dimming only fades. Grown and shrunk with the panel, its
            // edges travelled across the window as it came (Drice, 24 Sep 2026).
            if browser.peekTab != nil {
                Color.black.opacity(0.22)
                    .contentShape(Rectangle())
                    .onTapGesture { browser.closePeek() }
                    .transition(.opacity)
            }
            if let tab = browser.peekTab {
                PeekPanel(browser: browser, tab: tab)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
    }
}

/// The panel itself, in the middle of the page.
struct PeekPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab

    var body: some View {
        GeometryReader { geo in
            ZStack {
                HStack(alignment: .top, spacing: 10) {
                    // Solid underneath, as the page in the window is (see
                    // Stage): until the page draws its first frame, the
                    // panel was only its border over the page behind.
                    Page(tab: tab)
                        .background(Palette.ground)
                        .overlay {
                            if !tab.painted && tab.failure == nil {
                                PeekSkeleton().transition(.opacity.animation(Motion.quick))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Palette.hairline, lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
                    VStack(spacing: 8) {
                        Knob("xmark", help: "Close (esc)") { browser.closePeek() }
                        // ⌥ on it keeps the page beside this one, with Split
                        // View on, as the button under it does.
                        Knob("arrow.up.left.and.arrow.down.right", help: "Open as a tab (⌘↩)") {
                            browser.keepPeek(beside: NSEvent.modifierFlags.contains(.option))
                        }
                        if browser.prefs.splitView {
                            Knob("rectangle.split.2x1", help: "Keep beside this page (⌥⌘↩)") { browser.keepPeek(beside: true) }
                        }
                    }
                }
                .frame(width: geo.size.width * 0.82, height: geo.size.height * 0.86)
                .offset(x: 21)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private struct Knob: View {
        let symbol: String
        let help: String
        let act: () -> Void
        @State private var hovering = false

        init(_ symbol: String, help: String, act: @escaping () -> Void) {
            self.symbol = symbol
            self.help = help
            self.act = act
        }

        var body: some View {
            Button(action: act) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 28, height: 28)
                    .background(hovering ? Palette.hover : Palette.ground, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(help)
            .onHover { hovering = $0 }
        }
    }
}

/// The peek's icon, worn by the pin it was opened from while it is up: on
/// a square's corner, at the end of a row. The letter of its site until
/// the icon comes in.
struct PeekBadge: View {
    @ObservedObject var page: Tab
    var size: CGFloat = 16

    var body: some View {
        Mark(icon: page.icon, letter: page.monogram, size: size * 0.7)
            .frame(width: size, height: size)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
            .allowsHitTesting(false)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

/// What the peek shows until its page draws: the shape of a page — a bar
/// along the top, a heading, a picture, lines of text — in the faintest of
/// the window's own greys, with a light passing over it. Quick pages never
/// show it: it comes in only after a moment.
///
/// Cheap on purpose. The shapes are drawn once into a single layer, and the
/// light is one gradient sliding across it under a mask, so each frame of
/// the animation moves a layer and redraws nothing. Without motion, as the
/// Mac's accessibility settings can ask, it is still.
struct PeekSkeleton: View {
    /// The light: a step above the shapes' grey toward the ground in light,
    /// and away from it in dark, so it reads as a sheen in both.
    static let light = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor(white: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.225 : 0.975, alpha: 1)
    })

    @State private var shown = false
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width - 64, 760)
            ZStack {
                Palette.ground
                if shown {
                    ZStack {
                        Bones(width: width).foregroundStyle(Palette.wash)
                        if !Motion.reduced {
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: PeekSkeleton.light, location: 0.5),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: (sweep ? 1 : -1) * geo.size.width * 0.8)
                            .mask(Bones(width: width))
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    .drawingGroup()
                    .transition(.opacity)
                }
            }
        }
        .allowsHitTesting(false)
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeOut(duration: 0.2)) { shown = true }
            guard !Motion.reduced else { return }
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false)) { sweep = true }
        }
    }

    /// The shapes, filled with whatever is in front: a page laid out at
    /// `width`, centred, from the top.
    private struct Bones: View {
        let width: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Circle().frame(width: 22, height: 22)
                    bar(96, 10)
                    Spacer(minLength: 0)
                    bar(44, 8); bar(52, 8); bar(36, 8)
                }
                .padding(.bottom, 44)
                bar(width * 0.72, 22).padding(.bottom, 12)
                bar(width * 0.46, 22).padding(.bottom, 18)
                HStack(spacing: 8) {
                    Circle().frame(width: 16, height: 16)
                    bar(120, 8)
                }
                .padding(.bottom, 26)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .frame(width: width, height: width * 0.36)
                    .padding(.bottom, 28)
                ForEach(Array([1, 0.97, 0.93, 0.98, 0.62].enumerated()), id: \.offset) { _, part in
                    bar(width * part, 9).padding(.bottom, 14)
                }
                Color.clear.frame(height: 14)
                ForEach(Array([0.95, 1, 0.84].enumerated()), id: \.offset) { _, part in
                    bar(width * part, 9).padding(.bottom, 14)
                }
            }
            .frame(width: width, alignment: .leading)
            .padding(.top, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }

        private func bar(_ length: CGFloat, _ height: CGFloat) -> some View {
            Capsule().frame(width: max(0, length), height: height)
        }
    }
}
