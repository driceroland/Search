import AppKit
import SwiftUI
import WebKit
import Combine

// MARK: - the buttons in the row

/// The extensions, behind one puzzle button — a list to press them from,
/// pin them out of, reload or remove them. The pinned ones also sit in the
/// row beside it, the way Chrome does it. Nothing at all below macOS 15.4
/// or with nothing installed.
struct ExtensionSlot: View {
    /// The side the list opens toward: down from the top row, out to the
    /// right from the sidebar.
    var edge: Edge = .bottom
    /// How many pinned ones the row has room for; the rest are only in the
    /// list. Nil: all of them.
    var room: Int? = nil

    var body: some View {
        if #available(macOS 15.4, *) {
            ExtensionButtons(extensions: .shared, edge: edge, room: room)
        }
    }
}

@available(macOS 15.4, *)
struct ExtensionButtons: View {
    @ObservedObject var extensions: Extensions
    let edge: Edge
    var room: Int?

    var body: some View {
        if !extensions.installed.isEmpty {
            HStack(spacing: 2) {
                ForEach(extensions.buttons.filter(\.pinned).prefix(room ?? .max)) { button in
                    ActionButton(button: button) { extensions.press(button.id) }
                        .background(Anchor(id: button.id))
                        .contextMenu { ExtensionActions(id: button.id, name: button.name, extensions: extensions) }
                }
                Door(icon: "puzzlepiece.extension", on: extensions.menuOpen, help: "Extensions") {
                    extensions.menuOpen.toggle()
                }
                .background(Anchor(id: Extensions.menuAnchor))
                .popover(isPresented: $extensions.menuOpen, arrowEdge: edge) {
                    ExtensionMenu(extensions: extensions)
                }
            }
        }
    }

    private struct ActionButton: View {
        let button: Extensions.Button
        let press: () -> Void
        @State private var hovering = false

        var body: some View {
            SwiftUI.Button(action: press) {
                ExtensionIcon(button: button, size: 15)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(hovering ? Palette.hover : .clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(button.label)
        }
    }

    /// A real view under the button, so the popup has something to hang from.
    private struct Anchor: NSViewRepresentable {
        let id: String
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            Extensions.shared.anchors[id] = WeakView(view)
            return view
        }
        // The outgoing layout can still update during a transition. It must
        // not replace the new layout's anchor with a view about to disappear.
        func updateNSView(_ view: NSView, context: Context) {}
    }
}

/// An extension's icon with its badge in the corner.
@available(macOS 15.4, *)
struct ExtensionIcon: View {
    let button: Extensions.Button
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let icon = button.icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
                } else {
                    // Its initial, rather than a puzzle piece that would
                    // pass for the button the list opens from.
                    Text(button.name.first.map { String($0).uppercased() } ?? "?")
                        .font(.system(size: size * 0.62, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: size, height: size)
                        .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Palette.wash))
                }
            }
            .frame(width: size + 4, height: size + 4)
            .opacity(button.enabled ? 1 : 0.4)
            if !button.badge.isEmpty {
                Text(button.badge)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.ground)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 12, minHeight: 11)
                    .background(Palette.ink, in: Capsule())
                    .fixedSize()
                    .offset(x: 5, y: 3)
            }
        }
    }
}

/// What a right-click on an extension offers, in the row and in the list.
@available(macOS 15.4, *)
struct ExtensionActions: View {
    let id: String
    let name: String
    let extensions: Extensions

    var body: some View {
        let pinned = extensions.installed.first { $0.id == id }?.pinned ?? false
        SwiftUI.Button(pinned ? "Unpin" : "Pin to Toolbar") { extensions.setPinned(id, !pinned) }
        if extensions.contexts[id]?.optionsPageURL != nil {
            SwiftUI.Button("Options…") { extensions.openOptions(id) }
        }
        SwiftUI.Button("Reload") { extensions.reload(id) }
        Divider()
        SwiftUI.Button("Remove “\(name)”…") { ExtensionActions.confirmRemove(id, name: name, extensions) }
    }

    static func confirmRemove(_ id: String, name: String, _ extensions: Extensions) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(name)”?"
        alert.informativeText = "Its settings and data go with it."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { extensions.remove(id) }
    }
}

/// The list, drawn off screen — for the bench, which can't keep a popover
/// open in a browser that isn't in front.
@available(macOS 15.4, *)
@MainActor
func extensionMenuPicture() -> NSBitmapImageRep? {
    let host = NSHostingView(rootView: ExtensionMenu(extensions: .shared))
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSApp.effectiveAppearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: picture)
    return picture
}

/// The list behind the puzzle button: every running extension, a pin for
/// each, and the way to Settings.
@available(macOS 15.4, *)
struct ExtensionMenu: View {
    @ObservedObject var extensions: Extensions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let buttons = extensions.buttons
            if buttons.isEmpty {
                Text("None of your extensions is on")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(buttons) { button in
                            Row(button: button, extensions: extensions)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(Palette.hairline)
            VStack(spacing: 1) {
                Foot("storefront", "Chrome Web Store…") {
                    extensions.menuOpen = false
                    extensions.browser?.open(Browser.webStore, foreground: true)
                }
                Foot("folder", "Load Unpacked…") {
                    extensions.menuOpen = false
                    DispatchQueue.main.async { extensions.installFolder() }
                }
                Foot("gearshape", "Manage Extensions…") {
                    extensions.menuOpen = false
                    Store.settings.set("extensions", forKey: "settings.page")
                    extensions.browser?.tuning = true
                }
            }
            .padding(6)
        }
        .frame(width: 280)
        .popoverGround()
    }

    private struct Row: View {
        let button: Extensions.Button
        @ObservedObject var extensions: Extensions
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 9) {
                ExtensionIcon(button: button, size: 16)
                Text(button.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(button.enabled ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hovering, extensions.installed.first(where: { $0.id == button.id })?.source != nil {
                    Tool(symbol: "arrow.clockwise", help: "Reload from its folder") { extensions.reload(button.id) }
                }
                if hovering || button.pinned {
                    Tool(symbol: button.pinned ? "pin.fill" : "pin", help: button.pinned ? "Unpin" : "Pin to toolbar", on: button.pinned) {
                        extensions.setPinned(button.id, !button.pinned)
                    }
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .onTapGesture {
                // The list goes first; the popup, if there is one, then
                // hangs from the puzzle button it came out of.
                extensions.menuOpen = false
                let id = button.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { extensions.press(id) }
            }
            .onHover { hovering = $0 }
            .help(button.label)
            .contextMenu { ExtensionActions(id: button.id, name: button.name, extensions: extensions) }
        }
    }

    /// A small icon button at the end of a row.
    private struct Tool: View {
        let symbol: String
        let help: String
        var on = false
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            SwiftUI.Button(action: act) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(on || hovering ? Palette.ink : Palette.muted)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Palette.hover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
        }
    }

    private struct Foot: View {
        let symbol: String
        let title: String
        let act: () -> Void
        @State private var hovering = false

        init(_ symbol: String, _ title: String, act: @escaping () -> Void) {
            self.symbol = symbol
            self.title = title
            self.act = act
        }

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 14)
                Text(title).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
        }
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// A page nobody sees, loaded for one job.
@MainActor
final class HiddenPage: NSObject, WKNavigationDelegate {
    let web: WKWebView
    private var loaded: CheckedContinuation<Bool, Never>?

    init(_ configuration: WKWebViewConfiguration) {
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        web.navigationDelegate = self
    }

    /// Whether an empty page at `base` loaded within `limit` seconds.
    func loadBlank(at base: URL, within limit: TimeInterval = 10) async -> Bool {
        await withCheckedContinuation { done in
            loaded = done
            web.loadHTMLString("<!doctype html>", baseURL: base)
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self] in
                MainActor.assumeIsolated { self?.finish(false) }
            }
        }
    }

    private func finish(_ ok: Bool) {
        loaded?.resume(returning: ok)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
}
