import AppKit
import SwiftUI

// The address of the page in front, always in sight, for whoever wants it
// (Settings › Appearance › Window › Always show the address bar, #1227,
// #1240), with the site card's button at its end. Off unless asked for:
// Search shows the address when you go to change it, with ⌘L. On, it sits
// at the top of the column, as tall as a tab and in line with them, or
// before the tabs across the top, Small or Medium.
//
// A click there is ⌘L's editing, in place: the same field, the address in
// it to type over, and the same suggestions hanging under the line rather
// than in the middle of the page (Browser.inlineEdit). ⌘L itself still
// raises its field over the page. A click anywhere else puts it away, as
// Escape does. Search's own pages show their own address, and a tab with
// nothing in it what to type.

struct AddressLine: View {
    @ObservedObject var browser: Browser
    /// A tab's height in the sidebar.
    var height: CGFloat = 28


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

        private var address: String { tab.page?.url.absoluteString ?? tab.address?.absoluteString ?? "" }

        var body: some View {
            HStack(spacing: 6) {
                if browser.editingInline {
                    AddressField(browser: browser, size: 12)
                } else {
                    Text(address.isEmpty ? "Search or enter address" : address)
                        .foregroundStyle(address.isEmpty ? Palette.faint : Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    // The site card (#1240), for a page on the web.
                    if tab.isWeb {
                        button("slider.horizontal.3", help: "Site Settings") {
                            guard let under = line.view, let from = options.view else { return }
                            SiteCardPanel.toggle(for: tab, in: browser, under: under, button: from)
                        }
                        .background(ViewAnchor(box: options))
                    }
                }
            }
            .font(.system(size: 12))
            .padding(.leading, 10)
            .padding(.trailing, browser.editingInline || !tab.isWeb ? 10 : 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(greys.hover, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background(ViewAnchor(box: line))
            .contentShape(Rectangle())
            .onTapGesture { if !browser.editing { browser.edit(); browser.inlineEdit = true } }
            .shortcutHelp("Type an address or a search", "file.openAddress")
            // ⌘L's suggestions, hanging under the line at its width.
            .overlay(alignment: .topLeading) {
                if browser.editingInline {
                    Omnibox(browser: browser, over: false, listOnly: frame.width)
                        .offset(y: height + 4)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .onChange(of: browser.editingInline, initial: true) { _, on in watch(on) }
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
                    // The line, and the room under it its suggestions take:
                    // a row is about 44 points, the list's edge 12 more.
                    let below = browser.offers.isEmpty ? 0 : CGFloat(browser.offers.count) * 44 + 16
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
