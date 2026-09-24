import AppKit
import Combine
import SecurityInterface
import SwiftUI

// The site card: what a click on the tab you are on shows under its address,
// in the column and in the bar across the top alike — whether the connection
// is private, and the few things that belong to the page (copy its address,
// print it, its zoom). Right-click › Site Information… opens the same. It
// goes as soon as you type, when the address is left, or when one of its
// lines is used. From #56, whose bar it came with; the bar itself stayed out,
// since Search has the column or the strip, never a second row over the page.

/// The card's own small window, under the tab's address. It never takes the
/// keys: the address stays in the tab being edited, the caret where it was,
/// and a click on the card is only a click.
@MainActor
enum SiteCardPanel {
    private static var panel: Panel?
    private static var resign: Any?

    static var isShown: Bool { panel != nil }

    // MARK: - when

    /// The field the address is being edited in. SwiftUI can make it and
    /// throw it away several times as the edit begins, so the card follows
    /// the browser's edit rather than any one field, and stands under the one
    /// with the caret.
    private static weak var anchor: NSView?
    private static var watching: [ObjectIdentifier: AnyCancellable] = [:]
    /// The address as the edit began with it.
    private static var original: String?

    static func follow(_ browser: Browser, anchor field: NSView) {
        anchor = field
        let key = ObjectIdentifier(browser)
        guard watching[key] == nil else { return }
        watching[key] = browser.$editingTab.combineLatest(browser.$tabDraft)
            .receive(on: DispatchQueue.main)
            .sink { [weak browser] editing, draft in
                MainActor.assumeIsolated {
                    guard let browser else { return }
                    guard let id = editing, !browser.renamingTab,
                          let tab = browser.tabs.first(where: { $0.id == id }), !tab.isBlank
                    else { original = nil; hide(); return }
                    if original == nil {
                        // The edit began: the card comes up under the field once it
                        // is in its window.
                        original = draft
                        place(tab, browser, tries: 0)
                    } else if draft != original {
                        // Typing somewhere else: the card was about the page you are on.
                        hide()
                    }
                }
            }
    }

    private static func place(_ tab: Tab, _ browser: Browser, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            guard original != nil, browser.editingTab == tab.id, browser.tabDraft == original else { return }
            // The field with the caret in it is the one on screen; failing
            // that, the latest one made.
            let focused = (Links.window?.firstResponder as? NSTextView)?.delegate as? NSTextField
            guard let field = focused ?? anchor, field.window != nil else {
                if tries < 15 { place(tab, browser, tries: tries + 1) }
                return
            }
            show(for: tab, in: browser, under: field)
        }
    }

    /// Under `field`, the tab's address, in `browser`'s window.
    private static func show(for tab: Tab, in browser: Browser, under field: NSView) {
        guard let window = field.window else { return }
        hide()
        let card = SiteCard(browser: browser, tab: tab) {
            SiteCardPanel.hide()
            browser.cancelTabEdit()
        }
        let host = FirstClick(rootView: AnyView(card.fixedSize()))
        let size = host.fittingSize
        let glass = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        glass.material = .menu
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = MenuMetrics.corner
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 0.5
        glass.layer?.borderColor = MenuMetrics.edge.cgColor
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)

        let panel = Panel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = glass
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        // Under the address, lined up with the tab's own edge.
        let spot = window.convertToScreen(field.convert(field.bounds, to: nil))
        var origin = NSPoint(x: spot.minX - 12, y: spot.minY - 12 - size.height)
        if let screen = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
            origin.y = max(origin.y, screen.minY + 8)
        }
        panel.setFrameOrigin(origin)
        window.addChildWindow(panel, ordered: .above)
        // Its height follows the card: one step in on the connection is taller.
        host.onResize = { [weak panel] fitted in
            guard let panel, fitted.height > 0 else { return }
            var frame = panel.frame
            frame.origin.y += frame.height - fitted.height
            frame.size = fitted
            panel.setFrame(frame, display: true)
        }
        self.panel = panel
        resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SiteCardPanel.hide() }
        }
    }

    static func hide() {
        if let resign { NotificationCenter.default.removeObserver(resign) }
        resign = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Takes the first click even though its window never becomes key, and
    /// says when what it shows changes size.
    private final class FirstClick: NSHostingView<AnyView> {
        var onResize: ((NSSize) -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            let fitted = fittingSize
            DispatchQueue.main.async { [weak self] in self?.onResize?(fitted) }
        }
    }
}

/// The site the tab is on: how private the connection is, and the few things
/// that belong to this page rather than to the browser. The connection's line
/// goes a step further in, to what it means and the certificate behind it.
struct SiteCard: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    let close: () -> Void

    /// One step in: the connection, said in full.
    @State private var deeper: Bool
    /// Whether this Mac trusts the site's certificate. Unknown until it has
    /// been asked, off the main thread: asking can go to the network.
    @State private var certified: Bool?

    init(browser: Browser, tab: Tab, deeper: Bool = false, close: @escaping () -> Void) {
        self.browser = browser
        self.tab = tab
        self.close = close
        _deeper = State(initialValue: deeper)
    }

    var body: some View {
        Group {
            if deeper, let safety {
                security(safety)
            } else {
                front
            }
        }
        .padding(.vertical, MenuMetrics.pad)
        .frame(minWidth: 180)
        .fixedSize()
        .transition(.opacity)
        .animation(Motion.quick, value: deeper)
        .onAppear(perform: certify)
    }

    /// The host as a person says it, without the www. A page with no host —
    /// a file, about:blank — is named by what it is.
    static func site(_ url: URL) -> String {
        if let host = url.host(), !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        if url.isFileURL { return "File" }
        return url.scheme ?? url.absoluteString
    }

    // MARK: - the card, drawn as the system draws a menu

    private var front: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url = tab.address {
                Header(title: SiteCard.site(url))
            }
            if let safety {
                Row(safety.title, submenu: true) { deeper = true }
            }
            Row("Copy Address", keys: "⇧⌘C") { after { browser.copyAddress() } }
            Separator()
            Row("Print…", keys: "⌘P") { after { browser.printPage() } }
            zoom
        }
    }

    /// The page's size, remembered for the site (see Tab.rememberZoom), as a
    /// menu puts a control on one of its lines: the name, and the steps at
    /// its end. The number puts it back to 100%.
    private var zoom: some View {
        HStack(spacing: 0) {
            Text("Zoom")
                .font(MenuMetrics.font)
                .foregroundStyle(Color(nsColor: .labelColor))
            Spacer(minLength: 24)
            Step(symbol: "minus", help: "Zoom Out   ⌘-") { browser.zoom(by: 1 / 1.1) }
            Button { browser.resetZoom() } label: {
                Text("\(Int((tab.zoom * 100).rounded()))%")
                    .font(MenuMetrics.font)
                    .monospacedDigit()
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Actual Size   ⌘0")
            Step(symbol: "plus", help: "Zoom In   ⌘+") { browser.zoom(by: 1.1) }
        }
        .padding(.leading, MenuMetrics.text)
        .padding(.trailing, MenuMetrics.inset + 4)
        .frame(height: MenuMetrics.row)
    }

    // MARK: - one step in

    private func security(_ safety: Safety) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url = tab.address {
                Header(title: SiteCard.site(url))
            }
            Text(safety.title)
                .font(MenuMetrics.font)
                .foregroundStyle(Color(nsColor: .labelColor))
                .padding(.leading, MenuMetrics.text)
                .frame(height: MenuMetrics.row, alignment: .leading)
            Text(safety.detail)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 230, alignment: .leading)
                .padding(.leading, MenuMetrics.text)
                .padding(.trailing, MenuMetrics.trailing)
                .padding(.bottom, 6)
            Separator()
            if let trust = safety.trust {
                Row(certified == false ? "Show Certificate (Not Valid)…" : "Show Certificate…") {
                    after { SiteCard.show(trust) }
                }
            }
            Row("Back") { deeper = false }
        }
    }

    // MARK: - the connection

    /// What there is to say about the connection, from a page's own address
    /// and what WebKit knows of how it came.
    private struct Safety {
        let symbol: String
        let title: String
        let detail: String
        let tint: Color
        /// The certificate the page came with, for an https page.
        let trust: SecTrust?
    }

    /// Asked when the card opens: a page that pulls in something over plain
    /// http after that is not worth a card that changes under you.
    private var safety: Safety? {
        switch tab.address?.scheme {
        case "https":
            let trust = tab.built?.serverTrust
            // Only a certificate this Mac refused and you let through anyway
            // (see Dialogs.trust) gets this far untrusted.
            if certified == false {
                return Safety(
                    symbol: "lock.open", title: "Connection is not secure",
                    detail: "This site's certificate isn't trusted by this Mac. Someone could be reading what you send.",
                    tint: Palette.unsafe, trust: trust
                )
            }
            if tab.built?.hasOnlySecureContent == false {
                return Safety(
                    symbol: "lock.trianglebadge.exclamationmark", title: "Parts of this page are not secure",
                    detail: "The page came privately, but some of what it shows was fetched over plain http, where anyone on the network could read or change it.",
                    tint: Palette.unsafe, trust: trust
                )
            }
            return Safety(
                symbol: "lock", title: "Connection is secure",
                detail: "Your information (for example, passwords or credit card numbers) is private when it is sent to this site.",
                tint: Palette.safe, trust: trust
            )
        case "http":
            return Safety(
                symbol: "lock.open", title: "Connection is not secure",
                detail: "Don't enter passwords or credit card numbers here: anything sent to this site can be read on the way.",
                tint: Palette.unsafe, trust: nil
            )
        default:
            return nil
        }
    }

    /// Asks whether this Mac trusts the certificate, the way it would for
    /// any app. Off the main thread: the answer can need a revocation check.
    private func certify() {
        guard certified == nil, let trust = tab.built?.serverTrust else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = SecTrustEvaluateWithError(trust, nil)
            DispatchQueue.main.async { certified = ok }
        }
    }

    /// The system's own certificate sheet, over the window.
    private static func show(_ trust: SecTrust) {
        guard let window = Links.window else { return }
        SFCertificatePanel.shared().beginSheet(
            for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil, trust: trust, showGroup: false
        )
    }

    /// The card goes first, then the thing is done: a print panel or a sheet
    /// coming up under a popover still on its way out lands behind it.
    private func after(_ act: @escaping () -> Void) {
        close()
        DispatchQueue.main.async(execute: act)
    }

    /// One line, as a menu item draws it: its title in the menu's font where
    /// a menu puts its text, a key equivalent at the end, the accent colour
    /// behind it and white letters under the pointer. A line that opens more
    /// ends in the submenu's chevron.
    private struct Row: View {
        let title: String
        var keys = ""
        var submenu = false
        let act: () -> Void

        @State private var hovering = false

        init(_ title: String, keys: String = "", submenu: Bool = false, act: @escaping () -> Void) {
            self.title = title
            self.keys = keys
            self.submenu = submenu
            self.act = act
        }

        var body: some View {
            HStack(spacing: 0) {
                Text(title)
                    .font(MenuMetrics.font)
                    .foregroundStyle(hovering ? Color.white : Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: keys.isEmpty ? 24 : 26)
                if !keys.isEmpty {
                    Text(keys)
                        .font(MenuMetrics.font)
                        .foregroundStyle(hovering ? Color.white : Color(nsColor: .secondaryLabelColor))
                        .fixedSize()
                }
                if submenu {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovering ? Color.white : Color(nsColor: .secondaryLabelColor))
                }
            }
            .padding(.leading, MenuMetrics.text - MenuMetrics.inset)
            .padding(.trailing, MenuMetrics.trailing - MenuMetrics.inset)
            .frame(height: MenuMetrics.row)
            .background(
                RoundedRectangle(cornerRadius: MenuMetrics.highlight, style: .continuous)
                    .fill(hovering ? MenuMetrics.selection : .clear)
            )
            .padding(.horizontal, MenuMetrics.inset)
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
        }
    }

    /// The site's name over the lines, as a menu's section header is drawn.
    private struct Header: View {
        let title: String

        var body: some View {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(1)
                .padding(.leading, MenuMetrics.text)
                .padding(.trailing, MenuMetrics.trailing)
                .frame(height: MenuMetrics.row, alignment: .leading)
        }
    }

    /// A menu's separator: a hairline in its own band.
    private struct Separator: View {
        var body: some View {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
                .padding(.horizontal, MenuMetrics.rule)
                .frame(height: MenuMetrics.separator)
        }
    }

    /// A step of the zoom: the symbol alone, on the accent colour under the
    /// pointer as a menu's line would be.
    private struct Step: View {
        let symbol: String
        let help: String
        let act: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? Color.white : Color(nsColor: .labelColor))
                    .frame(width: 22, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(hovering ? MenuMetrics.selection : .clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
        }
    }
}

/// A menu's measurements, as macOS lays out an NSMenu (measured from one:
/// NSMenu.size with the same items), so the card sits beside the tab's
/// right-click menu as one of its own.
enum MenuMetrics {
    static let font = Font(NSFont.menuFont(ofSize: 0))
    /// One item.
    static let row: CGFloat = 24
    /// A separator's band.
    static let separator: CGFloat = 11
    /// Above the first item and under the last.
    static let pad: CGFloat = 5
    /// Where the highlight starts, from the menu's edge.
    static let inset: CGFloat = 5
    /// Where an item's text starts, from the menu's edge: a context menu
    /// without a checkmark column, as the tab's right-click is.
    static let text: CGFloat = 17
    /// From the end of the text, or of its key equivalent, to the menu's edge.
    static let trailing: CGFloat = 17
    /// A separator's line, in from either edge.
    static let rule: CGFloat = 16
    static let highlight: CGFloat = 6
    static let corner: CGFloat = 12
    /// The line under the pointer: the accent colour as a menu shows it over
    /// its glass, lighter than the accent itself (111, 162, 249 for blue).
    static let selection = Color(nsColor: NSColor(name: nil) { appearance in
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? accent.blended(withFraction: 0.15, of: .black) ?? accent
            : accent.blended(withFraction: 0.42, of: .white) ?? accent
    })
    /// The panel's hairline edge.
    static let edge = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.26)
    }
}
