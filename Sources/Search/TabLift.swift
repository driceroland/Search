import AppKit
import SwiftUI

/// A tab carried off its row. The row can't follow the hand there: it is
/// drawn inside the tabs' own run and window, and a drag that left them
/// showed nothing until it was let go (see Browser.dragOut). This is a small
/// window of its own that goes with the pointer instead, the tab's icon and
/// title.
@MainActor
final class TabLift {
    static let shared = TabLift()

    private let model = Model()
    private var panel: Panel?
    /// The pointer's place on the tab, from the panel's top left corner.
    private static let hold = CGPoint(x: Panel.margin + 30, y: Panel.margin + 15)

    private init() {}

    /// Under way, for the tests.
    var carrying: Bool { model.tab != nil }
    /// Which tab it shows, for the tests.
    var shown: Tab.ID? { model.tab?.id }
    /// What it draws, for the tests.
    var content: NSView? { panel?.contentView }

    func carry(_ tab: Tab, browser: Browser, at point: NSPoint) {
        if model.tab?.id != tab.id {
            model.tab = tab
            model.icons = browser.prefs.glyph == .icons
        }
        let panel = panel ?? Panel(model: model)
        self.panel = panel
        panel.setFrameOrigin(NSPoint(x: point.x - TabLift.hold.x,
                                     y: point.y + TabLift.hold.y - Panel.size.height))
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func put() {
        guard carrying else { return }
        panel?.orderOut(nil)
        model.tab = nil
    }

    fileprivate final class Model: ObservableObject {
        @Published var tab: Tab?
        @Published var icons = true
    }

    /// With room for the tab's shadow.
    private final class Panel: NSPanel {
        static let margin: CGFloat = 24
        static let size = CGSize(width: Lifted.width + margin * 2, height: Lifted.line + margin * 2)

        init(model: Model) {
            super.init(contentRect: NSRect(origin: .zero, size: Panel.size),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            becomesKeyOnlyIfNeeded = true
            hidesOnDeactivate = false
            ignoresMouseEvents = true
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
            isReleasedWhenClosed = false
            animationBehavior = .none
            level = .floating
            collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
            let host = NSHostingView(rootView: Lifted(model: model).padding(Panel.margin)
                .frame(width: Panel.size.width, height: Panel.size.height, alignment: .topLeading))
            host.sizingOptions = []
            contentView = host
        }

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
}

private struct Lifted: View {
    static let width: CGFloat = 180
    static let line: CGFloat = 30

    @ObservedObject var model: TabLift.Model

    var body: some View {
        if let tab = model.tab {
            Face(tab: tab, icons: model.icons)
        }
    }

    private struct Face: View {
        @ObservedObject var tab: Tab
        let icons: Bool

        var body: some View {
            HStack(spacing: 7) {
                Mark(icon: icons ? tab.icon : nil, letter: tab.monogram, size: 15, dim: tab.asleep)
                Text(tab.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(width: Lifted.width, height: Lifted.line, alignment: .leading)
            .background(Palette.ground)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        }
    }
}
