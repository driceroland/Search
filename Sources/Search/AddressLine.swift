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

    /// The room after it, before the tabs across the top.
    static let after: CGFloat = 8

    /// The bench pictures the line as it is under the pointer.
    @MainActor static var benchHovering = false

    var body: some View {
        // The tab says when its address changes; the browser only which tab.
        if let tab = browser.active {
            Shown(browser: browser, tab: tab, height: height).id(tab.id)
        }
    }

    private struct Shown: View {
        @ObservedObject var browser: Browser
        @ObservedObject var tab: Tab
        let height: CGFloat
        @Environment(\.greys) private var greys
        @State private var frame: CGRect = .zero
        @State private var clicks: Any?
        /// The line and its site button, for the site card to hang under.
        @State private var line = ViewAnchor.Box()
        @State private var options = ViewAnchor.Box()

        @State private var hovering = false
        /// How tall the suggestions under it are, for the card to take them in.
        @State private var below: CGFloat = 0

        private var url: URL? { tab.page?.url ?? tab.address }
        private var rest: AtRest? { AtRest.of(url) }
        private var lit: Bool { hovering || AddressLine.benchHovering }
        private var editing: Bool { browser.editingInline }

        var body: some View {
            HStack(spacing: 6) {
                if editing {
                    AddressField(browser: browser, size: 12)
                } else {
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
            }
            .font(.system(size: 12.5))
            .padding(.leading, 10)
            .padding(.trailing, editing || !tab.isWeb ? 10 : 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            // Typed in, it opens into one card with its suggestions, the
            // field at the top and the rows under it, as a command bar is.
            .background(alignment: .top) {
                let open = editing ? below : 0
                RoundedRectangle(cornerRadius: editing ? 12 : 10, style: .continuous)
                    .fill(editing ? Palette.ground : lit ? greys.wash : greys.hover)
                    .overlay {
                        RoundedRectangle(cornerRadius: editing ? 12 : 10, style: .continuous)
                            .strokeBorder(Palette.hairline, lineWidth: editing ? 1 : 0)
                    }
                    .shadow(color: .black.opacity(editing ? 0.12 : 0), radius: open > 0 ? 18 : 8, y: open > 0 ? 6 : 2)
                    .frame(height: height + open)
                    .frame(height: height, alignment: .top)
            }
            .animation(.easeOut(duration: 0.12), value: lit)
            .animation(.easeOut(duration: 0.15), value: editing)
            .animation(.easeOut(duration: 0.12), value: below)
            .background(ViewAnchor(box: line))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { if !browser.editing { browser.edit(); browser.inlineEdit = true } }
            .shortcutHelp("Type an address or a search", "file.openAddress")
            // ⌘L's suggestions, hanging under the line at its width.
            .overlay(alignment: .topLeading) {
                if editing {
                    Omnibox(browser: browser, over: false, listOnly: frame.width)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { below = $0 }
                        .offset(y: height)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            // Closed, the card forgets how tall it was, so the next opening
            // starts from the field alone.
            .onChange(of: browser.editingInline, initial: true) { _, on in watch(on); if !on { below = 0 } }
            .onDisappear { watch(false) }
        }

        /// While it is being typed in, a click anywhere but the line and its
        /// suggestions puts it away, as Escape does; the click goes on to
        /// whatever it was for.
        private func watch(_ on: Bool) {
            if let clicks { NSEvent.removeMonitor(clicks) }
            clicks = nil
            guard on else { return }
            clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                MainActor.assumeIsolated {
                    guard browser.editingInline, let view = event.window?.contentView else { return }
                    let at = event.locationInWindow
                    let point = CGPoint(x: at.x, y: view.bounds.height - at.y)
                    // The line, and the room under it its suggestions take.
                    let room = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height + below)
                    guard !room.contains(point) else { return }
                    browser.dismiss()
                }
                return event
            }
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
