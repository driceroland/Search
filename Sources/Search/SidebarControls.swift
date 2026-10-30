import SwiftUI

/// New tab belongs to the tab list, never to the configurable utility foot.
enum SidebarFooterItem: String, CaseIterable, Identifiable {
    case spaces, extensions, bookmarks, history, downloads, settings, back, forward, reload, tools
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spaces: return "Spaces"
        case .extensions: return "Extensions"
        case .bookmarks: return "Bookmarks"
        case .history: return "History"
        case .downloads: return "Downloads"
        case .settings: return "Settings"
        case .back: return "Back"
        case .forward: return "Forward"
        case .reload: return "Reload / Stop"
        case .tools: return "More tools (…)"
        }
    }
}

@MainActor
final class SidebarFooterPreferences: ObservableObject {
    static let shared = SidebarFooterPreferences()
    static let key = "sidebar.footer.items"
    private let store: UserDefaults
    @Published private(set) var items: Set<SidebarFooterItem> {
        didSet { store.set(SidebarFooterItem.allCases.filter { items.contains($0) }.map(\.rawValue), forKey: Self.key) }
    }
    init(store: UserDefaults? = nil) {
        let store = store ?? Store.settings
        self.store = store
        // A stored empty list is a choice, not a missing preference.
        if let saved = store.stringArray(forKey: Self.key) { items = Set(saved.compactMap(SidebarFooterItem.init)) }
        else { items = [.spaces, .extensions, .bookmarks, .downloads, .tools] }
    }
    func contains(_ item: SidebarFooterItem) -> Bool { items.contains(item) }
    func set(_ item: SidebarFooterItem, visible: Bool) {
        if visible { items.insert(item) } else { items.remove(item) }
    }
    func showAll() { items = Set(SidebarFooterItem.allCases) }
    func hideAll() { items = [] }
    func binding(for item: SidebarFooterItem) -> Binding<Bool> {
        Binding(get: { self.contains(item) }, set: { self.set(item, visible: $0) })
    }
}

enum IconRailInteraction {
    enum NewTabPlacement { case afterTabs }
    static let newTabPlacement = NewTabPlacement.afterTabs
    /// Helium's vertical-layout patch uses 250ms expand/collapse transitions.
    static let expandCollapseDuration = 0.25
    static func showsClose(active: Bool, hovering: Bool, pinned: Bool, editing: Bool, dragging: Bool) -> Bool {
        active && hovering && !pinned && !editing && !dragging
    }
    static var hover: Animation? { Motion.reduced ? nil : .easeOut(duration: 0.15) }
    static var movement: Animation? { Motion.reduced ? nil : .easeInOut(duration: expandCollapseDuration) }
}

/// Hover/press tint, not a scaling animation: the hit target never shifts.
struct RailButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration, enabled: enabled)
    }
    private struct Feedback: View {
        let configuration: ButtonStyleConfiguration
        let enabled: Bool
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? Palette.wash : (hovering && enabled ? Palette.hover : .clear)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.ink.opacity(configuration.isPressed ? 0.05 : 0)).allowsHitTesting(false))
                .onHover { hovering = $0 }
                .animation(IconRailInteraction.hover, value: hovering)
                .animation(Motion.quick, value: configuration.isPressed)
        }
    }
}

struct SidebarFooterCustomizationMenu: View {
    @ObservedObject private var footer = SidebarFooterPreferences.shared
    var body: some View {
        Menu("Bottom buttons") {
            Button("Show Everything") { footer.showAll() }
            Button("Hide Everything") { footer.hideAll() }
            Divider()
            ForEach(SidebarFooterItem.allCases) { item in
                Toggle(item.title, isOn: footer.binding(for: item))
            }
        }
    }
}

struct SidebarFooterSettingsButton: View {
    @State private var open = false
    var body: some View {
        Button("Customize…") { open = true }
            .popover(isPresented: $open) { SidebarFooterPicker() }
    }
}

private struct SidebarFooterPicker: View {
    @ObservedObject private var footer = SidebarFooterPreferences.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sidebar bottom buttons").font(.system(size: 13, weight: .semibold))
            HStack {
                Button("Show everything") { footer.showAll() }
                Button("Hide everything") { footer.hideAll() }
            }
            ForEach(SidebarFooterItem.allCases) { item in
                Toggle(item.title, isOn: footer.binding(for: item)).toggleStyle(.checkbox)
            }
            Text("New tab stays below the tabs. If every bottom button is hidden, right-click the sidebar or use ⌘, to customize it again.")
                .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18).frame(width: 300)
    }
}

struct SidebarFooter: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    var compact = false
    @ObservedObject private var footer = SidebarFooterPreferences.shared
    private var edge: Edge { prefs.sidePosition == .left ? .trailing : .leading }
    private var selected: [SidebarFooterItem] { SidebarFooterItem.allCases.filter { footer.contains($0) } }

    static func height(count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let columns = max(1, Int((width - 20 + 2) / 28))
        let rows = (count + columns - 1) / columns
        return CGFloat(rows * 26 + max(0, rows - 1) * 2 + 12)
    }

    var body: some View {
        if !selected.isEmpty {
            Group {
                if compact {
                    VStack(spacing: 2) { ForEach(selected) { item in control(item).frame(height: 26) } }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 26, maximum: 26), spacing: 2)], alignment: .leading, spacing: 2) {
                        ForEach(selected) { item in control(item).frame(width: 26, height: 26) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }
            }
            .background(Palette.ground)
        }
    }

    @ViewBuilder private func control(_ item: SidebarFooterItem) -> some View {
        switch item {
        case .spaces:
            if prefs.usesSpaces { SpaceDot(browser: browser) }
            else { Door(icon: "square.stack", help: "Spaces — enable in Settings") { browser.tuning = true } }
        case .extensions:
            ExtensionSlot(edge: edge, compact: true, alwaysShow: true)
        case .bookmarks:
            BookmarkDoor(browser: browser, arrowEdge: edge)
        case .history:
            Door(icon: "clock", on: browser.recalling, help: "History") { browser.recalling.toggle() }
        case .downloads:
            Door(icon: "arrow.down.circle", on: browser.hoarding, help: "Downloads") { browser.hoarding.toggle() }
        case .settings:
            Door(icon: "gearshape", on: browser.tuning, help: "Settings   ⌘,") { browser.tuning.toggle() }
        case .back:
            SidebarNavigationDoor(browser: browser, forward: false)
        case .forward:
            SidebarNavigationDoor(browser: browser, forward: true)
        case .reload:
            SidebarReloadDoor(browser: browser)
        case .tools:
            Menu {
                Button("Back") { browser.back() }.disabled(browser.active?.canGoBack != true)
                Button("Forward") { browser.forward() }.disabled(browser.active?.canGoForward != true)
                Button("Reload") { browser.reload() }.disabled(browser.active?.isBlank != false)
                Divider()
                Button("Bookmarks") { browser.bookmarking = true }
                Button("History") { browser.recalling = true }
                Button("Downloads") { browser.hoarding = true }
                Button("Settings") { browser.tuning = true }
                Divider()
                SidebarDetailsMenu()
                SidebarFooterCustomizationMenu()
                TopToolbarCustomizationMenu()
                Divider()
                Button(prefs.iconSidebar ? "Show Tab Titles" : "Favicons Only") {
                    withAnimation(IconRailInteraction.movement) { prefs.sidebarStyle = prefs.iconSidebar ? .titles : .icons }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.muted).frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Navigation and browser tools").accessibilityLabel("Navigation and browser tools")
        }
    }
}

private struct SidebarNavigationDoor: View {
    @ObservedObject var browser: Browser
    let forward: Bool
    var body: some View {
        if let tab = browser.active { Navigation(tab: tab, browser: browser, forward: forward) }
        else { Door(icon: forward ? "chevron.right" : "chevron.left") {}.disabled(true).opacity(0.3) }
    }
    private struct Navigation: View {
        @ObservedObject var tab: Tab
        let browser: Browser
        let forward: Bool
        private var enabled: Bool { forward ? tab.canGoForward : tab.canGoBack }
        var body: some View {
            Door(icon: forward ? "chevron.right" : "chevron.left", help: forward ? "Forward   ⌘]" : "Back   ⌘[") {
                if forward { browser.forward() } else { browser.back() }
            }
            .disabled(!enabled).opacity(enabled ? 1 : 0.3)
        }
    }
}

private struct SidebarReloadDoor: View {
    @ObservedObject var browser: Browser
    var body: some View {
        if let tab = browser.active { Reload(tab: tab, browser: browser) }
        else { Door(icon: "arrow.clockwise") {}.disabled(true).opacity(0.3) }
    }
    private struct Reload: View {
        @ObservedObject var tab: Tab
        let browser: Browser
        var body: some View {
            Door(icon: tab.loading ? "xmark" : "arrow.clockwise", help: tab.loading ? "Stop loading" : "Reload   ⌘R") {
                if tab.loading { tab.stop() } else { browser.reload() }
            }
            .disabled(tab.isBlank).opacity(tab.isBlank ? 0.3 : 1)
        }
    }
}

/// Closing is committed only by a release inside the target, with no drag.
struct RailClosePress {
    private var origin: CGPoint?
    private var cancelled = false
    mutating func begin(at point: CGPoint) { origin = point; cancelled = false }
    mutating func move(to point: CGPoint) {
        guard let origin else { return }
        if hypot(point.x - origin.x, point.y - origin.y) > 4 { cancelled = true }
    }
    mutating func finish(at point: CGPoint, inside: Bool) -> Bool {
        move(to: point)
        let close = origin != nil && !cancelled && inside
        origin = nil
        cancelled = false
        return close
    }
    static func hit(at point: CGPoint, size: CGSize, audio: Bool) -> Bool {
        let target = CGRect(x: (size.width - 18) / 2, y: max(0, (size.height - 18) / 2),
                            width: 18, height: min(18, size.height))
        let badge = CGRect(x: size.width - 14, y: size.height - 14, width: 14, height: 14)
        return target.contains(point) && (!audio || !badge.contains(point))
    }
}

struct RailCloseClick: NSViewRepresentable {
    let audio: Bool
    let act: () -> Void
    func makeNSView(context: Context) -> NSView { Target() }
    func updateNSView(_ view: NSView, context: Context) {
        (view as? Target)?.audio = audio
        (view as? Target)?.act = act
    }
    private final class Target: NSView {
        var audio = false
        var act: () -> Void = {}
        private var press = RailClosePress()
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.type == .leftMouseDown,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  RailClosePress.hit(at: convert(point, from: superview), size: bounds.size, audio: audio) else { return nil }
            return self
        }
        override func mouseDown(with event: NSEvent) { press.begin(at: convert(event.locationInWindow, from: nil)) }
        override func mouseDragged(with event: NSEvent) { press.move(to: convert(event.locationInWindow, from: nil)) }
        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if press.finish(at: point, inside: RailClosePress.hit(at: point, size: bounds.size, audio: audio)) { act() }
        }
    }
}

/// Render-test metadata; emitted only by isolated test runs.
struct SidebarRailFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
struct SidebarRailFrame: ViewModifier {
    let key: String
    func body(content: Content) -> some View {
        content.background {
            if Store.testing {
                GeometryReader { geometry in
                    Color.clear.preference(key: SidebarRailFrames.self, value: [key: geometry.frame(in: .named("icon-rail"))])
                }
            }
        }
    }
}
