import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

struct DeveloperToolsView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var tools: DeveloperTools
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
        DeveloperToolsContext(session: session, tools: tools, shell: shell)
    }
    private var viewportEnabled: Bool { context.viewportEnabled }
    private func toggleViewport() { context.toggleViewport() }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Lighthouse and the Recorder don't need WebKit's inspector.
            if session.ready || session.panel == .lighthouse || session.panel == .recorder {
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
            icon("iphone", viewportEnabled ? "Hide device toolbar (⌃⇧⌘M)" : "Toggle device toolbar (⌃⇧⌘M)",
                 active: viewportEnabled, action: toggleViewport)
            Divider().frame(height: 15)
            tabStrip
                .frame(maxWidth: .infinity, alignment: .leading)
            issueCounters
            DeveloperIssuesBadge(session: session)
            icon("gearshape", "Settings (F1)") {
                shell.settingsSection = .preferences
                shell.settingsShown = true
            }
            customizeMenu
            icon("xmark", "Close Developer Tools") { tools.close() }
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: 30)
        .background(DeveloperToolsStyle.chrome)
    }

    /// Chrome's ⋮ "Customize and control DevTools": dock side, the drawer,
    /// More tools, Settings and Shortcuts.
    private var customizeMenu: some View {
        Menu {
            Picker("Dock side", selection: $tools.dockPosition) {
                ForEach(DeveloperDockPosition.allCases) { position in
                    Label(position.title, systemImage: position.icon).tag(position)
                }
            }.pickerStyle(.inline)
            Divider()
            Button("Run command  ⌥⇧⌘P") { shell.showCommandMenu(">") }
            Button("Open file  ⌥⌘O") { context.perform(.commandMenu("")) }
            Button(shell.drawerOpen ? "Hide console drawer  Esc" : "Show console drawer  Esc") { shell.toggleDrawer() }
            Menu("More tools") {
                ForEach(DeveloperDrawerTool.allCases) { tool in
                    Button { shell.showDrawer(.tool(tool)) } label: { Label(tool.title, systemImage: tool.icon) }
                }
                let closed = shell.panels.order.filter { shell.panels.closed.contains($0) }
                if !closed.isEmpty {
                    Divider()
                    ForEach(closed) { panel in
                        Button { shell.panels.closed.remove(panel); session.select(panel) } label: {
                            Label(panel.rawValue, systemImage: panel.icon)
                        }
                    }
                }
            }
            Divider()
            Button("Settings  F1") { shell.settingsSection = .preferences; shell.settingsShown = true }
            Button("Shortcuts") { shell.settingsSection = .shortcuts; shell.settingsShown = true }
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
        return Button { session.select(panel) } label: { selectedBackground(tabLabel(panel, text: true, selected: selected), selected) }
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

    private func selectedBackground(_ label: some View, _ selected: Bool) -> some View {
        label.developerTab(selected: selected)
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
        // Lite's, the same code in both packages (Shared/).
        case .lighthouse:
            guard let web = session.web, let tools = FullPlugin.current?.sharedSession(web) else { return AnyView(EmptyView()) }
            return AnyView(LighthousePanel(model: tools.lighthouse))
        case .recorder:
            guard let web = session.web, let tools = FullPlugin.current?.sharedSession(web) else { return AnyView(EmptyView()) }
            return AnyView(RecorderPanel(recorder: tools.recorder))
        }
    }

    // MARK: Sources

    private var sources: some View {
        VStack(spacing: 0) {
            toolbar {
                icon("arrow.clockwise", "Refresh loaded sources", action: session.refresh)
                search("Filter sources")
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
            }
            GeometryReader { space in
                if space.size.width >= 640, space.size.width < 900 {
                    // As Chrome's auto layout at this width: the debugger
                    // goes under the editor, which keeps a readable width.
                    HSplitView {
                        if !shell.sourcesNavigatorHidden {
                            sourceList.frame(minWidth: 125, idealWidth: 167, maxWidth: 230)
                        }
                        VSplitView {
                            sourceEditor.frame(minWidth: 200, minHeight: 120)
                            if !shell.sourcesDebuggerHidden {
                                debuggerSidebar.frame(minHeight: 60, idealHeight: 200)
                            }
                        }
                    }
                } else if space.size.width >= 900 {
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
        DeveloperSourceEditor(session: session) { empty($0) }
    }

    private var debuggerSidebar: some View {
        DeveloperDebuggerSidebar(session: session)
    }

    // MARK: Security

    /// Chrome's Security panel: DeveloperSecurityView.swift. Its links set
    /// Network's filter and open Network.
    private func matches(_ string: String) -> Bool {
        filter.isEmpty || string.localizedCaseInsensitiveContains(filter)
    }

    private func search(_ hint: String) -> some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(hint, text: $filter)
        }
        .developerToolsField()
        .frame(minWidth: 90, idealWidth: 155, maxWidth: 210)
    }

    private func toolbar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: DeveloperToolsStyle.controlSpacing, content: content)
                    .padding(.horizontal, DeveloperToolsStyle.gutter)
                    .frame(height: DeveloperToolsStyle.toolbarHeight)
            }.scrollIndicators(.never)
            .background(DeveloperToolsStyle.chrome)
            Divider()
        }
    }

    private func empty(_ label: String, action: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 7) {
            Text(label).foregroundStyle(.secondary)
            if let (name, perform) = action { Button(name, action: perform) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
