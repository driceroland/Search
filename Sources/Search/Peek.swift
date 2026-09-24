import SwiftUI

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
        let page = Tab(shy: tab.shy)
        prepare(page)
        page.go(to: url)
        withAnimation(Motion.settle) { peekTab = page }
    }

    /// Put away: the page goes with the panel.
    func closePeek() {
        guard let page = peekTab else { return }
        withAnimation(Motion.quick) { peekTab = nil }
        page.close()
    }

    /// Kept: a tab beside the one it was opened from, and in front.
    func keepPeek() {
        guard let page = peekTab else { return }
        let here = tabs.firstIndex { $0.id == activeID }
        withAnimation(Motion.quick) { peekTab = nil }
        insert(page, at: here.map { $0 + 1 } ?? tabs.count)
        select(page)
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
                    Page(tab: tab)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Palette.hairline, lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
                    VStack(spacing: 8) {
                        Knob("xmark", help: "Close (esc)") { browser.closePeek() }
                        Knob("arrow.up.left.and.arrow.down.right", help: "Open as a tab") { browser.keepPeek() }
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
