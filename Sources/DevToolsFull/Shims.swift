import AppKit
import SearchPluginAPI
import SwiftUI
import WebKit

// What the panels took from Search when they were part of it, now that
// they are a package of their own: Search's colours and motion, its sheet
// and pill, and a settings store that is the package's (the host's
// `defaults`), never Search's DevDefaults.store.

/// The package's settings: the host's store for it, deleted with the
/// package. Until the host hands it over, a store kept in memory only.
enum DevDefaults {
    nonisolated(unsafe) static var store: UserDefaults = UserDefaults(suiteName: "com.officecommun.search.devtools.unset.\(UUID().uuidString)") ?? UserDefaults()
}

/// Search's colours (Design.swift), the ones the panels use.
enum Palette {
    static let ground = Color(nsColor: pair(1.0, 0.11))
    static let ink = Color(nsColor: pair(0.09, 0.93))
    static let muted = Color(nsColor: pair(0.55, 0.58))
    static let faint = Color(nsColor: pair(0.83, 0.32))
    static let hairline = Color(nsColor: pair(0.91, 0.20))
    static let wash = Color(nsColor: pair(0.937, 0.175))
    static let hover = Color(nsColor: pair(0.965, 0.15))
    static let frame = Color(nsColor: pair(0.955, 0.075))
    static let unsafe = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.98, green: 0.75, blue: 0.14, alpha: 1)
            : NSColor(srgbRed: 0.71, green: 0.33, blue: 0.04, alpha: 1)
    })

    private static func pair(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light, alpha: 1)
        }
    }
}

/// Search's quick spring, and the Mac's Reduce Motion.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var quick: Animation? { reduced ? nil : .easeOut(duration: 0.14) }
}

/// The arrow over a sheet's dimmed ground (Search's CursorGround).
struct CursorGround: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Ground() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Ground: NSView {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.invalidateCursorRects(for: self)
        }
        override func layout() {
            super.layout()
            window?.invalidateCursorRects(for: self)
        }
    }
}

/// Search, for the parts that only need to reach it (FullPlugin sets it).
@MainActor
enum DevHost {
    static weak var host: SearchDevToolsHost?

    /// An address in a new tab in front, http(s) only.
    static func open(_ url: URL) { host?.openURL(url) }

    /// The package's own content world: never the page's, never Search's.
    static var world: WKContentWorld { host?.isolatedWorld ?? .defaultClient }

    static func isPrivate(_ web: WKWebView?) -> Bool {
        guard let web else { return true }
        return host?.isPrivate(web) ?? !web.configuration.websiteDataStore.isPersistent
    }
}

/// A settings line, as Search's Settings draws one (Plate.swift).
struct Line<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: () -> Control

    init(_ title: String, _ detail: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13)).foregroundStyle(Palette.ink)
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.muted)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// A card of settings lines (Plate.swift).
struct Card<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(Palette.ground)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

/// The hairline between two lines of a card (Plate.swift).
struct Rule: View {
    var inset: CGFloat? = nil
    var body: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, inset ?? 0)
    }
}

/// A small symbol button, as Search's toolbar draws one (Side.swift).
struct Door: View {
    let icon: String
    var help = ""
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.muted)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.hover : .clear))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
