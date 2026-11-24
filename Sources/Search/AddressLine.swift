import AppKit
import SwiftUI

// The address of the page in front, always in sight, for whoever wants it
// (Settings › Appearance › Window › Always show the address bar, #1227,
// #1240), with the site card's button at its end. Off unless asked for:
// Search shows the address when you go to change it, with ⌘L. On, it sits
// at the top of the column, as tall as a tab and in line with them, or
// before the tabs across the top, Small or Medium.
//
// At rest it says where the page is from, as the tab at rest does
// (AtRestLine): the site in ink, not the whole address in grey, which read
// as a text box nobody meant you to touch. It answers the pointer as a
// button does: a little brighter under it, and lifted off the column once
// clicked.
//
// A click there is ⌘L's editing, in place: the same field, the address in
// it to type over, and the same suggestions hanging under the line rather
// than in the middle of the page (Browser.inlineEdit). The line lifts off
// the column while it is typed in. ⌘L itself still raises its field over
// the page. A click anywhere else puts it away, as Escape does. Search's own
// pages show their own address, and a tab with nothing in it what to type.

enum AddressWidth: String, CaseIterable, Identifiable {
    case small, medium

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        }
    }

    var width: CGFloat {
        switch self {
        case .small: return 220
        case .medium: return 340
        }
    }
}

struct AddressLine: View {
    @ObservedObject var browser: Browser
    /// A tab's height in the column; the row's across the top.
    var height: CGFloat = 28
    /// In the column, which cuts off whatever passes its edge: typed in, the
    /// card is drawn by the column instead (AddressCard.Place), out over the
    /// page.
    var inColumn = false

    /// The room after it, before the tabs across the top.
    static let after: CGFloat = 8

    /// The bench pictures the line as it is under the pointer.
    @MainActor static var benchHovering = false

    var body: some View {
        // The tab says when its address changes; the browser only which tab.
        if let tab = browser.active {
            Shown(browser: browser, tab: tab, height: height, inColumn: inColumn).id(tab.id)
        }
    }

    private struct Shown: View {
        @ObservedObject var browser: Browser
        @ObservedObject var tab: Tab
        let height: CGFloat
        let inColumn: Bool
        @Environment(\.greys) private var greys
        /// The line and its site button, for the site card to hang under.
        @State private var line = ViewAnchor.Box()
        @State private var options = ViewAnchor.Box()
        @State private var hovering = false
        @State private var width: CGFloat = 0

        private var url: URL? { tab.page?.url ?? tab.address }
        private var rest: AtRest? { AtRest.of(url) }
        private var lit: Bool { hovering || AddressLine.benchHovering }
        private var editing: Bool { browser.editingInline }

        var body: some View {
            HStack(spacing: 6) {
                if let rest {
                    AtRestLine(rest: rest, size: 12.5, ink: Palette.ink, dim: Palette.muted)
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                    Text("Search or enter address")
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if tab.isWeb {
                    // The site card (#1240), for a page on the web.
                    button("slider.horizontal.3", help: "Site Settings") {
                        guard let under = line.view, let from = options.view else { return }
                        SiteCardPanel.toggle(for: tab, in: browser, under: under, button: from)
                    }
                    .background(ViewAnchor(box: options))
                }
            }
            .font(.system(size: 12.5))
            .padding(.leading, 10)
            .padding(.trailing, tab.isWeb ? 4 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(lit ? greys.wash : greys.hover, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            // Under the card while it is open, which takes its place.
            .opacity(editing ? 0 : 1)
            .animation(.easeOut(duration: 0.12), value: lit)
            .background(ViewAnchor(box: line))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { if !browser.editing { browser.edit(); browser.inlineEdit = true } }
            .shortcutHelp("Type an address or a search", "file.openAddress")
            // Where the column is to draw the card.
            .anchorPreference(key: AddressCard.Place.self, value: .bounds) { editing && inColumn ? $0 : nil }
            // Across the top nothing cuts it off: it opens where it is.
            .overlay(alignment: .topLeading) {
                if editing && !inColumn {
                    AddressCard(browser: browser, height: height, width: AddressCard.width(for: width))
                }
            }
            .animation(.easeOut(duration: 0.15), value: editing)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }

        private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }
}

/// The address bar typed in: the field and its suggestions in one card, as
/// a command bar is, wider than the line, a third of the column's width out
/// over the page as Arc's is.
/// Each row a title over its site (Omnibox.Row, stacked).
struct AddressCard: View {
    @ObservedObject var browser: Browser
    /// The line's height, which the card's field row is a little taller than.
    let height: CGFloat
    let width: CGFloat

    /// The card's width for a line this wide: in the column, about a third
    /// of the column's width past its edge.
    static func width(for line: CGFloat) -> CGFloat { (line * 1.4).rounded() }

    @State private var frame: CGRect = .zero
    @State private var clicks: Any?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.muted)
                AddressField(browser: browser, size: 13.5)
            }
            .padding(.horizontal, 14)
            .frame(height: max(height, 28) + 12)
            Omnibox(browser: browser, over: false, listOnly: width)
        }
        .frame(width: width, alignment: .top)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
        .fixedSize(horizontal: false, vertical: true)
        .transition(.scale(scale: 0.98, anchor: .topLeading).combined(with: .opacity))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .onAppear { watch(true) }
        .onDisappear { watch(false) }
    }

    /// While it is open, a click anywhere but the card puts it away, as
    /// Escape does; the click goes on to whatever it was for.
    private func watch(_ on: Bool) {
        if let clicks { NSEvent.removeMonitor(clicks) }
        clicks = nil
        guard on else { return }
        clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                guard browser.editingInline, let view = event.window?.contentView else { return }
                let at = event.locationInWindow
                let point = CGPoint(x: at.x, y: view.bounds.height - at.y)
                guard !frame.contains(point) else { return }
                browser.dismiss()
            }
            return event
        }
    }

    /// Where the line is in the column, for the column to draw the card over
    /// it past its own edge (see SideBar).
    struct Place: PreferenceKey {
        static let defaultValue: Anchor<CGRect>? = nil
        static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
            value = value ?? nextValue()
        }
    }
}

/// The AppKit view under a SwiftUI one, for a window to hang beside it.
private struct ViewAnchor: NSViewRepresentable {
    final class Box { weak var view: NSView? }
    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { box.view = view }
}
