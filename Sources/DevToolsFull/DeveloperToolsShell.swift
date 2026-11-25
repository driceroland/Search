import AppKit
import SwiftUI

// The DevTools window's own chrome, apart from any one panel: the tab
// strip's order, the drawer under the panels, the UI zoom, the command
// menu and the settings, as Chrome DevTools keeps them.

/// A tool Chrome keeps in the drawer (Esc) and under More tools, rather
/// than in the main tab strip.
enum DeveloperDrawerTool: String, CaseIterable, Identifiable {
    case console = "Console"
    case search = "Search"
    case networkConditions = "Network conditions"
    case requestBlocking = "Network request blocking"
    case coverage = "Coverage"
    case cssOverview = "CSS overview"
    case issues = "Issues"
    case developerResources = "Developer resources"
    case quickSource = "Quick source"

    var id: Self { self }

    /// The name shown. Chrome renamed Network request blocking to Request
    /// conditions when it added per-pattern throttling; the raw value
    /// stays because saved drawer tabs are stored by it.
    var title: String { self == .requestBlocking ? "Request conditions" : rawValue }

    var icon: String {
        switch self {
        case .console: "apple.terminal"
        case .search: "magnifyingglass"
        case .networkConditions: "wifi"
        case .requestBlocking: "hand.raised"
        case .coverage: "chart.bar.doc.horizontal"
        case .cssOverview: "paintpalette"
        case .issues: "exclamationmark.bubble"
        case .developerResources: "doc.on.doc"
        case .quickSource: "doc.plaintext"
        }
    }
}

/// A tab in the drawer: one of its tools, or a panel moved down from the
/// main strip (a tab's context menu › Move to bottom, in Chrome).
enum DeveloperDrawerItem: Hashable, Identifiable {
    case tool(DeveloperDrawerTool)
    case panel(DeveloperPanel)

    var id: String {
        switch self {
        case .tool(let tool): "tool:" + tool.rawValue
        case .panel(let panel): "panel:" + panel.rawValue
        }
    }

    init?(id: String) {
        if id.hasPrefix("tool:"), let tool = DeveloperDrawerTool(rawValue: String(id.dropFirst(5))) {
            self = .tool(tool)
        } else if id.hasPrefix("panel:"), let panel = DeveloperPanel(rawValue: String(id.dropFirst(6))),
                  panel.drawerTool == nil {
            self = .panel(panel)
        } else {
            return nil
        }
    }

    var title: String {
        switch self {
        case .tool(let tool): tool.title
        case .panel(let panel): panel.rawValue
        }
    }

    var icon: String {
        switch self {
        case .tool(let tool): tool.icon
        case .panel(let panel): panel.icon
        }
    }
}

extension DeveloperPanel {
    /// A drawer tool rather than a panel: none since the device toolbar
    /// took Rendering and Sensors.
    var drawerTool: DeveloperDrawerTool? { nil }

    /// The main strip's panels in Chrome's order.
    static let strip: [DeveloperPanel] = [.elements, .console, .sources, .network, .performance, .memory, .storage,
                                          .lighthouse, .recorder]

    /// Chrome's permanent panels (Elements, Console, Sources, Network) can't
    /// be closed or moved to the drawer; the others can.
    var closeable: Bool { ![.elements, .console, .sources, .network].contains(self) }
}

/// The main strip: which panels it shows, in the order dragged to.
struct DeveloperPanelLayout: Equatable {
    var order: [DeveloperPanel] = DeveloperPanel.strip
    /// Closed panels, reopened from More tools or the command menu.
    var closed = Set<DeveloperPanel>()
    /// Panels moved to the drawer.
    var inDrawer = Set<DeveloperPanel>()

    var shown: [DeveloperPanel] { order.filter { !closed.contains($0) && !inDrawer.contains($0) } }

    /// The saved order, with unknown names dropped and panels added since
    /// put back where Chrome's order has them.
    static func normalized(_ names: [String]) -> [DeveloperPanel] {
        var order: [DeveloperPanel] = []
        for name in names {
            if let panel = DeveloperPanel(rawValue: name), DeveloperPanel.strip.contains(panel), !order.contains(panel) {
                order.append(panel)
            }
        }
        for (index, panel) in DeveloperPanel.strip.enumerated() where !order.contains(panel) {
            // After the panel that comes before it in Chrome's order, if shown.
            let previous = DeveloperPanel.strip[..<index].last { order.contains($0) }
            let at = previous.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            order.insert(panel, at: at)
        }
        return order
    }

    /// A tab dropped on another takes its place, as dragging a tab does in Chrome.
    mutating func move(_ panel: DeveloperPanel, to target: DeveloperPanel) {
        guard panel != target, let from = order.firstIndex(of: panel), let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(panel, at: to)
    }
}

/// Where the tab strip's keys and » menu go: pure, for the tests.
enum DeveloperTabStrip {
    /// The tab before or after the current one, wrapping round, as ⌘[ and
    /// ⌘] step through the panels in Chrome. No current tab starts at the first.
    static func step<Item: Equatable>(_ tabs: [Item], from current: Item?, by offset: Int) -> Item? {
        guard !tabs.isEmpty else { return nil }
        guard let current, let index = tabs.firstIndex(of: current) else { return tabs.first }
        let count = tabs.count
        return tabs[((index + offset) % count + count) % count]
    }

    /// Which tabs fit in the strip and which go under », as in Chrome's
    /// TabbedPane: tabs in order until the room runs out, and the selected
    /// tab always shown, in place of the last one that fit if need be.
    static func overflow(widths: [CGFloat], available: CGFloat, selected: Int?, chevron: CGFloat,
                         spacing: CGFloat = 2) -> (shown: [Int], hidden: [Int]) {
        let all = Array(widths.indices)
        let total = widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
        if total <= available { return (all, []) }
        let room = max(0, available - chevron - spacing)
        var shown: [Int] = []
        var used: CGFloat = 0
        for index in all {
            let width = widths[index] + (shown.isEmpty ? 0 : spacing)
            guard used + width <= room else { break }
            shown.append(index)
            used += width
        }
        if let selected, widths.indices.contains(selected), !shown.contains(selected) {
            // Make room for the selected tab by dropping tabs from the end.
            while let last = shown.last, used + widths[selected] + (shown.isEmpty ? 0 : spacing) > room {
                used -= widths[last] + (shown.count > 1 ? spacing : 0)
                shown.removeLast()
            }
            shown.append(selected)
        }
        let set = Set(shown)
        return (shown, all.filter { !set.contains($0) })
    }
}

/// The drawer's height, kept between a toolbar's height and almost all
/// of the panel above it.
enum DeveloperDrawerLayout {
    static let minimum: CGFloat = 60
    /// The main panel keeps at least this much above the drawer.
    static let panelMinimum: CGFloat = 60

    static func height(_ proposed: CGFloat, in available: CGFloat) -> CGFloat {
        min(max(minimum, proposed), max(minimum, available - panelMinimum))
    }
}

/// The counters at the strip's end: errors and warnings in the Console,
/// counted as Chrome's ErrorWarningCounter does, repeats included.
enum DeveloperIssueCounts {
    static func count(_ lines: [DeveloperToolsSession.ConsoleLine]) -> (errors: Int, warnings: Int) {
        var errors = 0, warnings = 0
        for line in lines {
            switch line.level {
            case "error": errors += max(1, line.repeatCount)
            case "warning": warnings += max(1, line.repeatCount)
            default: break
            }
        }
        return (errors, warnings)
    }
}

/// DevTools' own zoom (⌘+, ⌘−, ⌘0 with the keyboard in DevTools), in
/// Chrome's zoom steps.
enum DeveloperToolsZoom {
    static let levels: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// The next level in, or out, from the one nearest `scale`; 0 is 100%.
    static func zoomed(_ scale: CGFloat, by step: Int) -> CGFloat {
        guard step != 0 else { return 1 }
        let nearest = levels.indices.min { abs(levels[$0] - scale) < abs(levels[$1] - scale) } ?? 5
        let index = min(max(0, nearest + (step > 0 ? 1 : -1)), levels.count - 1)
        return levels[index]
    }
}

/// The command menu's open state: what is typed and which row is chosen.
struct DeveloperCommandMenuState: Equatable {
    var query: String
    var selection = 0
}

/// The shell's state, shared by every session and kept across launches.
@MainActor
final class DeveloperToolsShell: ObservableObject {
    static let shared = DeveloperToolsShell()

    private static let drawerOpenKey = "developerTools.drawer.open"
    private static let drawerTabsKey = "developerTools.drawer.tabs"
    private static let drawerSelectionKey = "developerTools.drawer.selection"
    private static let drawerHeightKey = "developerTools.drawer.height"
    private static let scaleKey = "developerTools.zoom"
    private static let orderKey = "developerTools.panels.order"
    private static let closedKey = "developerTools.panels.closed"
    private static let inDrawerKey = "developerTools.panels.inDrawer"
    private static let numberKeysKey = "developerTools.numberKeysSwitchPanels"

    @Published var drawerOpen = DevDefaults.store.bool(forKey: DeveloperToolsShell.drawerOpenKey) {
        didSet { DevDefaults.store.set(drawerOpen, forKey: Self.drawerOpenKey) }
    }
    /// The drawer's tabs, Console first, as Chrome opens it.
    @Published private(set) var drawerTabs: [DeveloperDrawerItem] = {
        let saved = (DevDefaults.store.stringArray(forKey: DeveloperToolsShell.drawerTabsKey) ?? []).compactMap(DeveloperDrawerItem.init(id:))
        return saved.contains(.tool(.console)) ? saved : [.tool(.console)] + saved
    }() {
        didSet { DevDefaults.store.set(drawerTabs.map(\.id), forKey: Self.drawerTabsKey) }
    }
    @Published var drawerSelection: DeveloperDrawerItem = DevDefaults.store.string(forKey: DeveloperToolsShell.drawerSelectionKey)
        .flatMap(DeveloperDrawerItem.init(id:)) ?? .tool(.console) {
        didSet { DevDefaults.store.set(drawerSelection.id, forKey: Self.drawerSelectionKey) }
    }
    @Published var drawerHeight: CGFloat = {
        let saved = DevDefaults.store.double(forKey: DeveloperToolsShell.drawerHeightKey)
        return saved > 0 ? CGFloat(saved) : 180
    }() {
        didSet { DevDefaults.store.set(Double(drawerHeight), forKey: Self.drawerHeightKey) }
    }
    @Published var scale: CGFloat = {
        let saved = DevDefaults.store.double(forKey: DeveloperToolsShell.scaleKey)
        return saved > 0 ? CGFloat(saved) : 1
    }() {
        didSet { DevDefaults.store.set(Double(scale), forKey: Self.scaleKey) }
    }
    @Published var panels = DeveloperPanelLayout(
        order: DeveloperPanelLayout.normalized(DevDefaults.store.stringArray(forKey: DeveloperToolsShell.orderKey) ?? []),
        closed: Set((DevDefaults.store.stringArray(forKey: DeveloperToolsShell.closedKey) ?? []).compactMap(DeveloperPanel.init).filter(\.closeable)),
        inDrawer: Set((DevDefaults.store.stringArray(forKey: DeveloperToolsShell.inDrawerKey) ?? []).compactMap(DeveloperPanel.init).filter(\.closeable))
    ) {
        didSet {
            DevDefaults.store.set(panels.order.map(\.rawValue), forKey: Self.orderKey)
            DevDefaults.store.set(panels.closed.map(\.rawValue).sorted(), forKey: Self.closedKey)
            DevDefaults.store.set(panels.inDrawer.map(\.rawValue).sorted(), forKey: Self.inDrawerKey)
        }
    }
    /// Chrome's "Enable Ctrl/⌘ + 1-9 shortcut to switch panels", off at
    /// first as in Chrome: ⌘1–⌘9 stay the browser's tab keys until it's on.
    @Published var numberKeysSwitchPanels = DevDefaults.store.bool(forKey: DeveloperToolsShell.numberKeysKey) {
        didSet { DevDefaults.store.set(numberKeysSwitchPanels, forKey: Self.numberKeysKey) }
    }
    /// Sources' navigator (⇧⌘Y) and debugger sidebar (⇧⌘H), put away.
    @Published var sourcesNavigatorHidden = false
    @Published var sourcesDebuggerHidden = false
    /// The command menu (⇧⌘P, ⌘P), when open.
    @Published var commandMenu: DeveloperCommandMenuState?
    /// DevTools Settings (the gear, F1), and the section it shows.
    @Published var settingsShown = false
    @Published var settingsSection = DeveloperSettingsSection.preferences

    /// Settings open at one of its sections, as Chrome's Sensors › Manage
    /// and the device toolbar's Edit… open theirs.
    func showSettings(_ section: DeveloperSettingsSection) {
        settingsSection = section
        settingsShown = true
    }

    // MARK: Drawer

    /// Esc: the drawer up, or put away.
    func toggleDrawer() { drawerOpen.toggle() }

    /// Opens the drawer at a tab, adding it after the others if new.
    func showDrawer(_ item: DeveloperDrawerItem) {
        if !drawerTabs.contains(item) { drawerTabs.append(item) }
        drawerSelection = item
        drawerOpen = true
    }

    /// A drawer tab's ×. The Console stays, as in Chrome; a panel goes back
    /// to the main strip.
    func closeDrawerTab(_ item: DeveloperDrawerItem) {
        guard item != .tool(.console), let index = drawerTabs.firstIndex(of: item) else { return }
        drawerTabs.remove(at: index)
        if case .panel(let panel) = item { panels.inDrawer.remove(panel) }
        if drawerSelection == item { drawerSelection = drawerTabs[max(0, index - 1)] }
    }

    // MARK: Panels

    /// Where a panel opens when asked for by name (the Develop menu, the
    /// command menu): drawer tools and panels moved there in the drawer,
    /// a closed panel back in the strip. True when it went to the drawer.
    func openInDrawer(_ panel: DeveloperPanel) -> Bool {
        if let tool = panel.drawerTool {
            showDrawer(.tool(tool))
            return true
        }
        if panels.inDrawer.contains(panel) {
            showDrawer(.panel(panel))
            return true
        }
        if panels.closed.contains(panel) { panels.closed.remove(panel) }
        return false
    }

    /// A tab's context menu › Close.
    func closePanel(_ panel: DeveloperPanel) {
        guard panel.closeable else { return }
        panels.closed.insert(panel)
    }

    /// A tab's context menu › Move to bottom.
    func movePanelToDrawer(_ panel: DeveloperPanel) {
        guard panel.closeable else { return }
        panels.inDrawer.insert(panel)
        panels.closed.remove(panel)
        showDrawer(.panel(panel))
    }

    /// A drawer tab's context menu › Move to top.
    func movePanelToTop(_ panel: DeveloperPanel) {
        panels.inDrawer.remove(panel)
        panels.closed.remove(panel)
        if let index = drawerTabs.firstIndex(of: .panel(panel)) {
            drawerTabs.remove(at: index)
            if drawerSelection == .panel(panel) { drawerSelection = drawerTabs[max(0, index - 1)] }
        }
    }

    // MARK: Zoom

    func zoom(by step: Int) { scale = DeveloperToolsZoom.zoomed(scale, by: step) }

    // MARK: Command menu

    /// ⇧⌘P (">"), ⌘P (no prefix): the menu, or the prefix typed into it.
    func showCommandMenu(_ prefix: String) {
        commandMenu = DeveloperCommandMenuState(query: prefix)
    }
}
