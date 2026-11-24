import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DeveloperToolsDock<Page: View>: View {
    @ObservedObject private var tools = DeveloperTools.shared
    let browser: Browser
    let visible: Bool
    var pageCard = false
    var protectedTopInset: CGFloat = 0
    @ViewBuilder let page: (Bool) -> Page
    @State private var height: CGFloat = DeveloperDockLayout.savedExtent(vertical: true) ?? 338
    @State private var width: CGFloat = DeveloperDockLayout.savedExtent(vertical: false) ?? 485
    @State private var dragStart: CGFloat?
    /// The pointer on the divider: its grip lit, as the sidebar's edge does.
    @State private var onDivider = false
    /// Device mode and its settings, kept across DevTools sessions and launches.
    @ObservedObject private var deviceMode = DeveloperDeviceMode.shared
    @State private var touchLink = DeveloperTouchLink()

    private var position: DeveloperDockPosition { tools.dockPosition }

    var body: some View {
        GeometryReader { space in
            let session = visible && tools.session?.tab === browser.active ? tools.session : nil
            let responsive = deviceMode.on && session != nil
            let vertical = position.vertical
            let available = vertical ? space.size.height : space.size.width
            let size = DeveloperDockLayout.extent(vertical ? height : width, in: available, vertical: vertical)
            // Undocked, DevTools is in a window of its own and the page has the whole room.
            let docked = session != nil && position != .window
            let layout = DeveloperDockLayout(in: space.size, position: position, extent: docked ? size : nil)
            let pageFrame = responsive ? excludingProtectedTopBand(layout.page) : layout.page
            ZStack(alignment: .topLeading) {
                DeveloperViewportCanvas(web: session?.web, room: pageFrame.size,
                                        responsive: responsive, dock: position, settings: $deviceMode.settings) {
                    page(session != nil)
                }
                    .overlay { if let session { DeveloperPausedOverlay(debugger: session.debugger) } }
                    .offset(x: pageFrame.minX, y: pageFrame.minY)
                    .onChange(of: DeveloperTouchLink.Key(session: session.map(ObjectIdentifier.init),
                                                         on: responsive && deviceMode.settings.touch), initial: true) { _, key in
                        touchLink.update(session, on: key.on)
                    }
                if let session {
                    // One container for docked and undocked alike, so moving
                    // between them doesn't read as DevTools going away.
                    ZStack(alignment: .topLeading) {
                        let context = DeveloperToolsContext(
                            session: session, tools: tools, shell: DeveloperToolsShell.shared, browser: browser,
                            viewportEnabled: responsive,
                            toggleViewport: { deviceMode.toggle() })
                        let content = {
                            DeveloperToolsView(
                                session: session, tools: tools,
                                browser: browser, viewportEnabled: responsive,
                                toggleViewport: context.toggleViewport,
                                retry: { tools.open(in: browser, panel: session.panel) }
                            )
                        }
                        if position == .window {
                            DeveloperToolsWindowAnchor(context: context, content: content)
                                .frame(width: 0, height: 0)
                        } else if let dividerFrame = layout.divider, let inspectorFrame = layout.inspector {
                            let divider = vertical ? dividerFrame : excludingProtectedTopBand(dividerFrame)
                            let inspector = vertical ? inspectorFrame : excludingProtectedTopBand(inspectorFrame)
                            DeveloperToolsHost(context: context, content: content)
                                .frame(width: inspector.width, height: inspector.height)
                                .clipped()
                                .offset(x: inspector.minX, y: inspector.minY)

                            // A thin seam with a wider grab area over both panes, as
                            // wide as the sidebar's edge.
                            let hitWidth = vertical ? divider.width : max(DeveloperDockLayout.gripWidth, divider.width)
                            let hitHeight = vertical ? max(DeveloperDockLayout.gripWidth, divider.height) : divider.height
                            resizeHandle(size: size, available: available)
                                .frame(width: hitWidth, height: hitHeight)
                                .offset(x: divider.midX - hitWidth / 2, y: divider.midY - hitHeight / 2)
                        }
                    }
                    .id(ObjectIdentifier(session))
                    .onDisappear { tools.close(ifCurrent: session) }
                }
            }
            .frame(width: space.size.width, height: space.size.height, alignment: .topLeading)
            .modifier(CardEdge(on: pageCard && !docked))
        }
        .onChange(of: position) { _, _ in dragStart = nil }
    }

    /// Installed web apps can reserve space for their native title bar controls.
    private func excludingProtectedTopBand(_ frame: CGRect) -> CGRect {
        let inset = min(max(0, protectedTopInset - frame.minY), frame.height)
        return CGRect(x: frame.minX, y: frame.minY + inset, width: frame.width, height: frame.height - inset)
    }

    private func resizeHandle(size: CGFloat, available: CGFloat) -> some View {
        Color.clear
            .overlay {
                Rectangle().fill(DeveloperToolsStyle.rule)
                    .frame(width: position.vertical ? nil : 1, height: position.vertical ? 1 : nil)
            }
            // The sidebar's grip (EdgeGrip): a pill in the middle of the
            // seam that lights under the pointer and while held, turned
            // across for a panel docked at the bottom.
            .overlay {
                EdgeGrip(lit: onDivider || dragStart != nil)
                    .rotationEffect(.degrees(position.vertical ? 90 : 0))
            }
            .contentShape(Rectangle())
            .onHover { over in
                onDivider = over
                if over {
                    (position.vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart == nil { dragStart = size }
                    let start = dragStart ?? size
                    switch position {
                    case .left: resize(start + value.translation.width, available: available)
                    case .right: resize(start - value.translation.width, available: available)
                    case .bottom: resize(start - value.translation.height, available: available)
                    case .window: break
                    }
                }
                .onEnded { _ in
                    dragStart = nil
                    DeveloperDockLayout.saveExtent(position.vertical ? height : width, vertical: position.vertical)
                })
            .accessibilityLabel("Resize Developer Tools")
            .accessibilityAdjustableAction { direction in
                resize(size + (direction == .increment ? 28 : -28), available: available)
                DeveloperDockLayout.saveExtent(position.vertical ? height : width, vertical: position.vertical)
            }
    }

    private func resize(_ proposed: CGFloat, available: CGFloat) {
        let size = DeveloperDockLayout.extent(proposed, in: available, vertical: position.vertical)
        if position.vertical { height = size } else { width = size }
    }
}

/// Exact frames prevent a hosted web stage from holding onto its previous size.
struct DeveloperDockLayout {
    let page: CGRect
    let divider: CGRect?
    let inspector: CGRect?

    /// As in Chrome DevTools: the panel can take almost the whole window,
    /// leaving the page a strip it can still be dragged back from.
    static let pageMinimum: CGFloat = 50
    static let gripWidth: CGFloat = 9

    static func extent(_ proposed: CGFloat, in available: CGFloat, vertical: Bool) -> CGFloat {
        min(max(vertical ? 182 : 270, proposed), max(0, available - pageMinimum))
    }

    /// The size last dragged to, kept for each orientation as Chrome keeps
    /// the bottom dock's height apart from the side docks' width.
    static func savedExtent(vertical: Bool) -> CGFloat? {
        let value = Store.settings.double(forKey: extentKey(vertical: vertical))
        return value > 0 ? CGFloat(value) : nil
    }

    static func saveExtent(_ extent: CGFloat, vertical: Bool) {
        Store.settings.set(Double(extent), forKey: extentKey(vertical: vertical))
    }

    private static func extentKey(vertical: Bool) -> String {
        vertical ? "developerTools.dock.height" : "developerTools.dock.width"
    }

    init(in room: CGSize, position: DeveloperDockPosition, extent: CGFloat?) {
        // Undocked, the page has the whole room.
        guard let requestedExtent = extent, position != .window else {
            page = CGRect(origin: .zero, size: room)
            divider = nil
            inspector = nil
            return
        }
        let width = room.width, height = room.height
        let full = position.vertical ? height : width
        let extent = min(full, max(0, requestedExtent))
        let gap = min(1, full - extent)
        let stage = full - extent - gap
        switch position {
        case .bottom:
            page = CGRect(x: 0, y: 0, width: width, height: stage)
            divider = CGRect(x: 0, y: stage, width: width, height: gap)
            inspector = CGRect(x: 0, y: stage + gap, width: width, height: extent)
        case .left:
            page = CGRect(x: extent + gap, y: 0, width: stage, height: height)
            divider = CGRect(x: extent, y: 0, width: gap, height: height)
            inspector = CGRect(x: 0, y: 0, width: extent, height: height)
        case .right, .window: // .window returned above
            page = CGRect(x: 0, y: 0, width: stage, height: height)
            divider = CGRect(x: stage, y: 0, width: gap, height: height)
            inspector = CGRect(x: stage + gap, y: 0, width: extent, height: height)
        }
    }
}

enum DeveloperToolsStyle {
    static let gutter: CGFloat = 8
    static let controlHeight: CGFloat = 22
    static let controlSpacing: CGFloat = 4
    static let controlRadius: CGFloat = 5
    static let rowHeight: CGFloat = 22
    static let toolbarHeight: CGFloat = 28
    /// Where a sidebar pane's content starts: in line with its header's
    /// title, past the disclosure chevron (gutter + 10pt chevron + 4pt gap).
    static let paneInset: CGFloat = gutter + 14
    /// The gap between stacked controls (checkboxes, pickers, fields) that
    /// don't sit on fixed-height rows, so they never touch.
    static let stackSpacing: CGFloat = 5

    static let chrome = Palette.frame
    static let surface = Palette.ground
    static let rule = Palette.hairline
    static let tint = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.55, green: 0.75, blue: 0.71, alpha: 1)
            : NSColor(srgbRed: 0.19, green: 0.38, blue: 0.35, alpha: 1)
    })
    static let selected = Palette.ink.opacity(0.085)
    static let raised = Palette.ink.opacity(0.045)
    static let code = Font.system(size: 11, design: .monospaced)
}

extension View {
    /// A row of tabs that scrolls sideways, without a scroller, when it is
    /// wider than its room, as the Sources navigator's does, rather than
    /// clipping or truncating its labels.
    func developerTabStrip() -> some View {
        ScrollView(.horizontal) { self.fixedSize(horizontal: true, vertical: false) }
            .scrollIndicators(.never)
    }

    func developerToolsField() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 6)
            .frame(height: DeveloperToolsStyle.controlHeight)
            .background(DeveloperToolsStyle.raised, in: RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius))
    }
}

private struct DeveloperToolsView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var tools: DeveloperTools
    /// The window DevTools inspects a tab of, for the command menu's screenshots.
    weak var browser: Browser?
    var viewportEnabled = false
    var toggleViewport: () -> Void = {}
    let retry: () -> Void
    @ObservedObject var shell = DeveloperToolsShell.shared
    @State private var filter = ""
    @State private var networkOptions = DeveloperNetworkView.Options()
    /// Each tab's width, measured, for what fits before the » menu.
    @State private var tabWidths: [DeveloperPanel: CGFloat] = [:]
    @State private var stripWidth: CGFloat = 10_000
    /// The tab being dragged to a new place in the strip.
    @State private var dragging: DeveloperPanel?
    @State private var drawerDragStart: CGFloat?

    private var context: DeveloperToolsContext {
        DeveloperToolsContext(session: session, tools: tools, shell: shell, browser: browser,
                              viewportEnabled: viewportEnabled, toggleViewport: toggleViewport)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if session.ready {
                GeometryReader { space in
                    VStack(spacing: 0) {
                        Panels(owner: self)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if shell.drawerOpen {
                            drawer(available: space.size.height)
                        }
                    }
                }
            } else {
                VStack(spacing: 8) {
                    if !session.connectionFailed {
                        ProgressView().controlSize(.small)
                        Text("Connecting to the page")
                    } else {
                        Text("Developer Tools couldn’t connect.")
                        // What went wrong, so a failure can be reported.
                        if let message = session.message {
                            Text(message)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .lineLimit(4)
                                .textSelection(.enabled)
                                .padding(.horizontal, 24)
                        }
                        Button("Retry", action: retry)
                            .buttonStyle(.bordered)
                    }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let message = session.message, session.ready {
                Divider()
                HStack {
                    Image(systemName: "exclamationmark.circle")
                    Text(message).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    icon("xmark", "Dismiss message") { session.message = nil }
                }
                .padding(.horizontal, DeveloperToolsStyle.gutter).padding(.vertical, 3)
                .foregroundStyle(.secondary)
                .background(DeveloperToolsStyle.chrome)
            }
        }
        .font(.system(size: 11))
        .controlSize(.small)
        // DevTools' own accent, not the browser's, for any control that
        // takes one (DeveloperCheckboxStyle draws checkboxes in ink).
        .tint(DeveloperToolsStyle.tint)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DeveloperToolsStyle.surface)
        .background(DeveloperCompactScrollers(panel: session.panel, drawer: shell.drawerOpen))
        .overlay(alignment: .top) {
            if shell.commandMenu != nil, session.ready {
                DeveloperCommandMenuView(context: context, shell: shell)
            }
        }
        // Undocked, DevTools' window draws its own sheets; docked, the
        // browser's window does (ContentView).
        .overlay { DeveloperSheetLayer(browser: nil) }
        .developerSheet(isPresented: $shell.settingsShown) {
            DeveloperSettingsView(session: session, tools: tools, shell: shell)
        }
        .onChange(of: session.panel, initial: true) { _, _ in filter = "" }
        .onDisappear { shell.commandMenu = nil }
        // An Issues resource's request link.
        .onReceive(NotificationCenter.default.publisher(for: DeveloperIssuesModel.revealRequestNotification)) { note in
            guard note.object as AnyObject? === session, let id = note.userInfo?["id"] as? String else { return }
            networkOptions.selection = id
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            icon("cursorarrow.rays", session.picking ? "Stop picking an element" : "Select an element in the page to inspect it",
                 active: session.picking) {
                session.select(.elements)
                session.togglePicker()
            }
            icon("iphone", viewportEnabled ? "Hide device toolbar (⇧⌘M)" : "Toggle device toolbar (⇧⌘M)",
                 active: viewportEnabled, action: toggleViewport)
            Divider().frame(height: 15)
            tabStrip
                .frame(maxWidth: .infinity, alignment: .leading)
            issueCounters
            DeveloperIssuesBadge(session: session)
            icon("gearshape", "Settings (F1)") { shell.showSettings(.preferences) }
            customizeMenu
            icon("xmark", "Close Developer Tools") { tools.close() }
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: 30)
        .background(DeveloperToolsStyle.chrome)
    }

    /// Chrome's ⋮ "Customize and control DevTools": dock side, the drawer,
    /// Search, Focus page, More tools, Settings, Shortcuts and Help.
    private var customizeMenu: some View {
        Menu {
            Picker("Dock side", selection: $tools.dockPosition) {
                ForEach(DeveloperDockPosition.allCases) { position in
                    Label(position.title, systemImage: position.icon).tag(position)
                }
            }.pickerStyle(.inline)
            Divider()
            Button("Run command  ⇧⌘P") { shell.showCommandMenu(">") }
            Button("Open file  ⌘P") { context.perform(.commandMenu("")) }
            Button(shell.drawerOpen ? "Hide console drawer  Esc" : "Show console drawer  Esc") { shell.toggleDrawer() }
            Button("Search  ⌥⌘F") { shell.showDrawer(.tool(.search)) }
            // As Chrome's: the page takes the keyboard, DevTools staying open.
            Button("Focus page") {
                if let web = session.web { web.window?.makeKeyAndOrderFront(nil); web.window?.makeFirstResponder(web) }
            }
            .disabled(session.web == nil)
            Menu("More tools") { DeveloperMoreToolsItems(session: session, shell: shell) }
            Divider()
            Button("Settings  F1") { shell.showSettings(.preferences) }
            Button("Shortcuts") { shell.showSettings(.shortcuts) }
            Menu("Help") {
                // Search's DevTools follow Chrome's, so its documentation applies.
                Button("Documentation") {
                    if let url = URL(string: "https://developer.chrome.com/docs/devtools") {
                        _ = Browsers.acting.open(url, foreground: true)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .font(.system(size: 13))
                .frame(width: DeveloperToolsStyle.controlHeight, height: DeveloperToolsStyle.controlHeight)
                .accessibilityLabel("Customize and control DevTools")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Customize and control DevTools")
    }

    // MARK: Tab strip

    /// As in Chrome's TabbedPane: every tab with its name, the ones that
    /// don't fit under », the selected one always in the strip. Tabs drag
    /// to a new place; optional panels close or move to the drawer from
    /// their context menu.
    private var tabStrip: some View {
        let tabs = context.strip
        let selected = tabs.firstIndex(of: context.currentTab)
        let widths = tabs.map { tabWidths[$0] ?? 80 }
        let split = DeveloperTabStrip.overflow(widths: widths, available: stripWidth, selected: selected,
                                               chevron: DeveloperToolsStyle.controlHeight)
        return HStack(spacing: 2) {
            ForEach(split.shown.sorted().map { tabs[$0] }, id: \.self) { tab in tabButton(tab) }
            if !split.hidden.isEmpty { overflowMenu(split.hidden.map { tabs[$0] }) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { space in
                Color.clear
                    .onAppear { stripWidth = space.size.width }
                    .onChange(of: space.size.width) { _, width in stripWidth = width }
            }
        }
        // Every tab, laid out unseen at its natural width, to measure it.
        .background(alignment: .leading) {
            HStack(spacing: 2) {
                ForEach(tabs, id: \.self) { tab in
                    tabLabel(tab, text: true, selected: true)
                        .developerTab(selected: true)
                        .fixedSize()
                        .background {
                            GeometryReader { size in
                                Color.clear.preference(key: DeveloperTabWidths.self, value: [tab: size.size.width])
                            }
                        }
                }
            }
            .fixedSize()
            .hidden()
            .accessibilityHidden(true)
        }
        .onPreferenceChange(DeveloperTabWidths.self) { widths in tabWidths = widths }
    }

    private func tabButton(_ panel: DeveloperPanel) -> some View {
        let selected = context.currentTab == panel
        return Button { session.select(panel) } label: { tabLabel(panel, text: true, selected: selected).developerTab(selected: selected) }
            .buttonStyle(.plain)
            .accessibilityLabel(panel.rawValue)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(panel.rawValue)
            .onDrag {
                dragging = panel
                return NSItemProvider(object: panel.rawValue as NSString)
            }
            .onDrop(of: [.text], delegate: DeveloperTabDrop(target: panel, dragging: $dragging, shell: shell))
            .contextMenu {
                if panel.closeable {
                    Button("Close") {
                        if session.panel == panel { session.select(.elements) }
                        shell.closePanel(panel)
                    }
                    Button("Move to bottom") {
                        if session.panel == panel { session.select(.elements) }
                        shell.movePanelToDrawer(panel)
                    }
                }
            }
    }

    /// Chrome's » button: the tabs that didn't fit.
    private func overflowMenu(_ hidden: [DeveloperPanel]) -> some View {
        Menu {
            ForEach(hidden, id: \.self) { panel in
                Button { session.select(panel) } label: { Label(panel.rawValue, systemImage: panel.icon) }
            }
        } label: {
            Image(systemName: "chevron.right.2")
                .font(.system(size: 11, weight: .medium))
                .frame(width: DeveloperToolsStyle.controlHeight, height: DeveloperToolsStyle.controlHeight)
                .accessibilityLabel("More tabs")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More tabs")
    }

    private func tabLabel(_ panel: DeveloperPanel, text: Bool, selected: Bool) -> some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            Image(systemName: panel.icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 14)
            if text { Text(panel.rawValue) }
        }
    }

    // MARK: Errors and warnings

    /// Chrome's counters at the strip's end: the Console's errors and
    /// warnings since it was last cleared or the page navigated. A click
    /// shows the Console at that level.
    @ViewBuilder
    private var issueCounters: some View {
        // Counted again only when the messages change.
        let counts = session.consoleStore.layout.issueCounts(session.console)
        if counts.errors > 0 || counts.warnings > 0 {
            HStack(spacing: 6) {
                if counts.errors > 0 {
                    counter("xmark.circle.fill", counts.errors, ConsoleTheme.errorText,
                            counts.errors == 1 ? "1 error" : "\(counts.errors) errors", level: .errors)
                }
                if counts.warnings > 0 {
                    counter("exclamationmark.triangle.fill", counts.warnings, ConsoleTheme.warningIcon,
                            counts.warnings == 1 ? "1 warning" : "\(counts.warnings) warnings", level: .warnings)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func counter(_ symbol: String, _ count: Int, _ color: Color, _ label: String, level: ConsoleLevel) -> some View {
        Button {
            session.consoleStore.levels = [level]
            session.select(.console)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(count > 999 ? "999+" : "\(count)").monospacedDigit()
            }
            .frame(height: DeveloperToolsStyle.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label + ". Open the Console to view them.")
        .accessibilityLabel(label)
    }

    // MARK: Drawer

    private func drawer(available: CGFloat) -> some View {
        let height = DeveloperDrawerLayout.height(shell.drawerHeight, in: available)
        return VStack(spacing: 0) {
            Rectangle().fill(DeveloperToolsStyle.rule).frame(height: 1)
                .frame(maxWidth: .infinity)
                .frame(height: 5)
                .contentShape(Rectangle())
                .onHover { over in
                    if over { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if drawerDragStart == nil { drawerDragStart = height }
                        shell.drawerHeight = DeveloperDrawerLayout.height((drawerDragStart ?? height) - value.translation.height,
                                                                          in: available)
                    }
                    .onEnded { _ in drawerDragStart = nil })
                .accessibilityLabel("Resize drawer")
            DeveloperDrawerView(session: session, shell: shell) { panel in builtInPanel(panel) }
                .frame(height: height - 5)
        }
    }

    /// The chosen panel as a view of its own type, so the inspector's type
    /// and every modifier on it name one short type instead of spelling out
    /// all nine panels at each step (__swift5_typeref size). It watches
    /// what the panels read, as the inspector does.
    private struct Panels: View {
        let owner: DeveloperToolsView
        @ObservedObject private var session: DeveloperToolsSession
        @ObservedObject private var tools: DeveloperTools

        init(owner: DeveloperToolsView) {
            self.owner = owner
            session = owner.session
            tools = owner.tools
        }

        var body: some View { owner.panels }
    }

    private var panels: some View { builtInPanel(session.panel) }

    /// Each panel erased on its own, rather than one twelve-way
    /// @ViewBuilder switch whose nested conditional type was slow to check.
    /// A switch between panels gives them fresh state either way.
    private func builtInPanel(_ panel: DeveloperPanel) -> AnyView {
        switch panel {
        case .elements: return AnyView(DeveloperElementsView(session: session))
        case .console: return AnyView(DeveloperConsoleView(session: session))
        case .network: return AnyView(DeveloperNetworkView(session: session, options: $networkOptions))
        case .sources: return AnyView(sources)
        case .storage: return AnyView(DeveloperApplicationView(session: session))
        case .performance: return AnyView(DeveloperPerformanceView(session: session))
        case .memory: return AnyView(DeveloperMemoryView(session: session, memory: .store(for: session)))
        case .lighthouse: return AnyView(DeveloperLighthouseView(session: session))
        case .recorder: return AnyView(DeveloperRecorderView(session: session))
        case .sensors: return AnyView(DeveloperSensorsView(session: session))
        case .rendering: return AnyView(DeveloperRenderingView(session: session))
        case .security: return AnyView(security)
        }
    }

    // MARK: Sources

    private var sources: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                    // Chrome's navigator and debugger toggles (⇧⌘Y, ⇧⌘H).
                    icon("sidebar.left", shell.sourcesNavigatorHidden ? "Show navigator (⇧⌘Y)" : "Hide navigator (⇧⌘Y)",
                         active: !shell.sourcesNavigatorHidden) { shell.sourcesNavigatorHidden.toggle() }
                    icon("arrow.clockwise", "Refresh loaded sources", action: session.refresh)
                    HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Filter sources", text: $filter)
                    }
                    .developerToolsField()
                    .frame(minWidth: 90, idealWidth: 155, maxWidth: 210)
                    Divider().frame(height: 14)
                    icon(session.paused ? "play.fill" : "pause.fill", session.paused ? "Resume script execution (F8, ⌘\\)" : "Pause script execution (F8, ⌘\\)", active: session.paused) {
                        session.debug(session.paused ? "resume" : "pause")
                    }
                    icon("arrow.turn.down.right", "Step over next function call (F10, ⌘')") { session.debug("stepOver") }.disabled(!session.paused)
                    icon("arrow.down.to.line", "Step into next function call (F11, ⌘;)") { session.debug("stepInto") }.disabled(!session.paused)
                    icon("arrow.up.to.line", "Step out of current function (⇧F11, ⇧⌘;)") { session.debug("stepOut") }.disabled(!session.paused)
                    icon("arrow.right.to.line", "Step (F9)") { session.debug("stepNext") }.disabled(!session.paused)
                    DeveloperDeactivateBreakpointsButton(debugger: session.debugger)
                    Spacer()
                    if session.paused { Text("Paused").foregroundStyle(DeveloperToolsStyle.tint) }
                    icon("sidebar.right", shell.sourcesDebuggerHidden ? "Show debugger (⇧⌘H)" : "Hide debugger (⇧⌘H)",
                         active: !shell.sourcesDebuggerHidden) { shell.sourcesDebuggerHidden.toggle() }
                }
                .padding(.horizontal, DeveloperToolsStyle.gutter)
                .frame(height: DeveloperToolsStyle.toolbarHeight)
            }
            .scrollIndicators(.never)
            .background(DeveloperToolsStyle.chrome)
            Divider()
            GeometryReader { space in
                let wide = space.size.width >= 640
                if space.size.width >= 900 {
                    // ⇧⌘Y and ⇧⌘H put the navigator and the debugger away.
                    HSplitView {
                        if !shell.sourcesNavigatorHidden {
                            sourceList.frame(minWidth: 125, idealWidth: 167, maxWidth: 230)
                        }
                        sourceEditor.frame(minWidth: 200)
                        if !shell.sourcesDebuggerHidden {
                            debuggerSidebar.frame(minWidth: 160, idealWidth: 240, maxWidth: 360)
                        }
                    }
                } else if wide || !shell.sourcesNavigatorHidden {
                    // As Chrome's auto layout at this width: the debugger
                    // goes under the navigator and editor, across the full
                    // width; narrower, the navigator still stays beside the editor.
                    VSplitView {
                        HSplitView {
                            if !shell.sourcesNavigatorHidden {
                                sourceList.frame(minWidth: wide ? 125 : 110, idealWidth: wide ? 167 : 150,
                                                 maxWidth: wide ? 230 : 200)
                            }
                            sourceEditor.frame(minWidth: wide ? 200 : 160)
                        }
                        .frame(minHeight: 120)
                        if !shell.sourcesDebuggerHidden {
                            debuggerSidebar.frame(minHeight: 60, idealHeight: wide ? 200 : 170)
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                            Menu {
                                ForEach(session.resources.filter { matches($0.url) }) { resource in
                                    Button(resource.name) { session.openSource(resource) }
                                }
                            } label: {
                                Label(session.sourceResource?.name ?? "Open file", systemImage: "folder")
                                    .lineLimit(1)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if session.paused {
                                Menu("Call Stack") {
                                    ForEach(Array(session.callStack.enumerated()), id: \.offset) { _, name in Text(name) }
                                }.fixedSize()
                            }
                        }
                        .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.toolbarHeight)
                        .background(DeveloperToolsStyle.chrome)
                        Divider()
                        VSplitView {
                            sourceEditor
                            if !shell.sourcesDebuggerHidden {
                                debuggerSidebar.frame(minHeight: 60, idealHeight: 170)
                            }
                        }
                    }
                }
            }
        }
    }

    private var sourceList: some View {
        // Page, Content scripts and Snippets, as Chrome's navigator: DeveloperSourcesNavigator.swift.
        DeveloperSourcesNavigator(session: session, filter: filter)
    }

    private var sourceEditor: some View {
        // Open-file tabs, each file's kept place, and Search: DeveloperSourcesTabs.swift.
        DeveloperSourceEditor(session: session) { label in
            Text(label).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var debuggerSidebar: some View {
        DeveloperDebuggerSidebar(session: session)
    }

    // MARK: Security

    /// Chrome's Security panel: DeveloperSecurityView.swift. Its links set
    /// Network's filter and open Network.
    private var security: some View {
        DeveloperSecurityView(session: session) { query in
            networkOptions.query = query
            session.select(.network)
        }
    }

    private func matches(_ string: String) -> Bool {
        filter.isEmpty || string.localizedCaseInsensitiveContains(filter)
    }


    private func icon(_ image: String, _ label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        DeveloperPanelIcon(symbol: image, title: label, active: active, action: action)
    }
}

/// The strip's tabs' natural widths, measured for the » menu.
private struct DeveloperTabWidths: PreferenceKey {
    static let defaultValue: [DeveloperPanel: CGFloat] = [:]
    static func reduce(value: inout [DeveloperPanel: CGFloat], nextValue: () -> [DeveloperPanel: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A panel tab dragged over another takes its place, as in Chrome's strip.
private struct DeveloperTabDrop: DropDelegate {
    let target: DeveloperPanel
    @Binding var dragging: DeveloperPanel?
    let shell: DeveloperToolsShell

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.easeOut(duration: 0.15)) { shell.panels.move(dragging, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Which session device mode's touch emulation is on in, so a tab left
/// behind (or Developer Tools closed) gets its mouse back.
@MainActor
final class DeveloperTouchLink {
    struct Key: Equatable {
        let session: ObjectIdentifier?
        let on: Bool
    }

    private weak var session: DeveloperToolsSession?

    func update(_ next: DeveloperToolsSession?, on: Bool) {
        if let session, session !== next || !on { session.rendering.setTouch(false, web: session.web) }
        session = on ? next : nil
        if on, let next { next.rendering.setTouch(true, web: next.web) }
    }
}
