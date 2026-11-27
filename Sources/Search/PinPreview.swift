import AppKit
import SwiftUI

// A glance at a pin (idea 1205): rest the pointer on a pinned Gmail, Calendar
// or any other pin in the column and, after a moment, a small card beside it
// shows a picture of its page, its title and, for a mailbox, how many are
// unread — the way Chrome's tab hover cards and Arc's previews do, without
// going to it. Moving along the pins while one is up shows the next at once.
//
// Only what is already there is shown: a page that is loaded is pictured as
// it is, one asleep by the picture kept for its waking, and one never opened
// since launch by its name alone. Nothing is loaded or woken to be shown.
//
// The card is drawn only: clicks go through it, and it goes as the pointer
// leaves the pin, at a click, or as Search goes to the back. Settings ›
// Spaces › Pins › Preview pins on hover; on unless turned off.

/// What a page's title says is waiting, beyond the "(3) …" at its front
/// that Unread reads: a mailbox's own way of saying it, "Inbox (3) – … –
/// Gmail".
enum Glance {
    /// Webmail that says its unread count inside its title.
    static let mailHosts: Set<String> = ["mail.google.com", "outlook.live.com", "outlook.office.com",
                                         "outlook.office365.com", "mail.proton.me", "app.fastmail.com",
                                         "mail.yahoo.com", "mail.zoho.com", "app.hey.com"]

    /// The unread count, as the pin's badge shows one: "3", "99+"; nil for none.
    static func unread(title: String, host: String?) -> String? {
        if let front = Unread.count(in: title) { return front }
        guard let host = host?.lowercased(), mailHosts.contains(host) else { return nil }
        // The mailbox's own part, before the account and the site's name.
        let first = title.components(separatedBy: " - ").first ?? title
        let part = first.components(separatedBy: " – ").first ?? first
        guard let open = part.firstIndex(of: "("), let close = part[open...].firstIndex(of: ")") else { return nil }
        let inside = part[part.index(after: open)..<close].replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: " ", with: "")
        return Unread.count(in: "(\(inside))")
    }
}

@MainActor
enum PinPreview {
    /// How long the pointer rests before the first card; the next pin's
    /// while one is up.
    static let firstDelay: TimeInterval = 0.6
    static let nextDelay: TimeInterval = 0.08

    private static var panel: NSPanel?
    private static weak var shownTab: Tab?
    private static var waiting: DispatchWorkItem?
    private static var leaving: DispatchWorkItem?
    private static var monitor: Any?
    private static var resign: Any?
    /// For the bench: the last card asked for, shown or not, and why not.
    private(set) static var last: [String: Any] = [:]

    static var isShown: Bool { panel != nil }

    /// The pointer onto a pin's square (`on`) or off it.
    static func hover(_ on: Bool, tab: Tab, in browser: Browser) {
        waiting?.cancel()
        waiting = nil
        guard on else {
            // A moment's grace, for the pointer going from one pin to the
            // next: the card is taken by the next one, not put away first.
            let away = DispatchWorkItem { MainActor.assumeIsolated { hide() } }
            leaving = away
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: away)
            return
        }
        guard browser.prefs.pinPreviews else { return }
        leaving?.cancel()
        leaving = nil
        let delay = panel == nil ? firstDelay : nextDelay
        let work = DispatchWorkItem { [weak tab, weak browser] in
            MainActor.assumeIsolated {
                guard let tab, let browser else { return }
                show(tab, in: browser)
            }
        }
        waiting = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Why a card for `tab` would not be shown now, nil when it would.
    static func refusal(_ tab: Tab, in browser: Browser) -> String? {
        if !browser.prefs.pinPreviews { return "off" }
        if tab.pin == nil { return "not a pin" }
        if browser.active === tab { return "the pin in front" }
        if browser.editingPin == tab.id { return "being renamed" }
        if NSEvent.pressedMouseButtons != 0 { return "a button is down" }
        guard let window = browser.window, window.isVisible, window.isKeyWindow, NSApp.isActive else {
            return "window not in front"
        }
        if SiteCardPanel.square(for: tab.id, in: window) == nil { return "no square" }
        return nil
    }

    private static func show(_ tab: Tab, in browser: Browser) {
        let why = refusal(tab, in: browser)
        last = ["tab": tab.id.uuidString, "shown": why == nil, "why": why ?? "",
                "unread": glance(tab) ?? "", "picture": tab.keptPicture != nil || !tab.asleep]
        guard why == nil else { return }
        if shownTab === tab, panel != nil { return }
        // The picture first, so the card comes in at its size: the one
        // kept for a sleeping page, or the page as it is. A private tab's
        // page is never pictured outside it.
        asked = tab.id
        guard !tab.shy else { return present(tab, picture: nil, in: browser) }
        tab.preview(width: PinPreviewCard.width) { [weak tab, weak browser] image in
            MainActor.assumeIsolated {
                guard let tab, let browser, asked == tab.id else { return }
                present(tab, picture: image, in: browser)
            }
        }
    }

    /// The pin a picture is on its way for.
    private static var asked: UUID?

    private static func present(_ tab: Tab, picture: NSImage?, in browser: Browser) {
        // Still on it, and still nothing in the way.
        guard refusal(tab, in: browser) == nil, let window = browser.window,
              let square = SiteCardPanel.square(for: tab.id, in: window) else { return }
        hide()
        shownTab = tab
        last["pictured"] = picture != nil

        let card = PinPreviewCard(tab: tab, unread: glance(tab), picture: picture)
        let host = NSHostingView(rootView: card)
        if #available(macOS 13, *) { host.sizingOptions = [.intrinsicContentSize] }
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.appearance = window.appearance

        // Beside the square, on the page's side of it, its top in line with
        // the square's; kept on the screen.
        let rect = square.window.map { _ in square.convert(square.bounds, to: nil) } ?? .zero
        let onScreen = window.convertToScreen(rect)
        let pageOnRight = onScreen.midX < window.frame.midX
        var origin = NSPoint(x: pageOnRight ? onScreen.maxX + 10 : onScreen.minX - 10 - size.width,
                             y: onScreen.maxY - size.height + 4)
        if let visible = window.screen?.visibleFrame {
            origin.y = max(visible.minY + 4, min(origin.y, visible.maxY - size.height - 4))
            origin.x = max(visible.minX + 4, min(origin.x, visible.maxX - size.width - 4))
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        window.addChildWindow(panel, ordered: .above)
        if Motion.reduced {
            panel.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        self.panel = panel

        // Away at any click or key, and as Search goes to the back.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { event in
            MainActor.assumeIsolated { hide() }
            return event
        }
        resign = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                        queue: .main) { _ in MainActor.assumeIsolated { hide() } }
    }

    static func hide() {
        waiting?.cancel()
        waiting = nil
        asked = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resign { NotificationCenter.default.removeObserver(resign) }
        resign = nil
        shownTab = nil
        guard let panel else { return }
        self.panel = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// What the pin's page says is waiting, awake: asleep, the title it last
    /// had may be long out of date (as Tab.unread).
    static func glance(_ tab: Tab) -> String? {
        tab.asleep ? nil : Glance.unread(title: tab.title, host: tab.pageAddress?.hostCompat())
    }
}

/// The card: the page's picture when there is one, then its title, and
/// what is waiting.
struct PinPreviewCard: View {
    let tab: Tab
    let unread: String?
    let picture: NSImage?

    static let width: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let picture {
                Image(nsImage: picture)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.width, height: Self.width * 0.62, alignment: .top)
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(tab.title.isEmpty ? tab.label : tab.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let host = tab.pageAddress.map(SiteCard.site) {
                        Text(host).lineLimit(1)
                    }
                    if let unread {
                        Text("·")
                        Text("\(unread) unread").foregroundStyle(Palette.ink)
                    } else if tab.asleep {
                        Text("·")
                        Text("Asleep")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(width: Self.width, alignment: .leading)
        }
        .background(Palette.ground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .padding(1)
    }
}
