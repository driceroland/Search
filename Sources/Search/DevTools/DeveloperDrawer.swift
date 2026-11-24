import AppKit
import SwiftUI

/// Drawer tools another part of DevTools provides, by tool: Sources'
/// Search across all files registers itself here, so the drawer hosts it
/// without depending on it.
@MainActor
enum DeveloperDrawerTools {
    private static var builders: [DeveloperDrawerTool: (DeveloperToolsSession) -> AnyView] = [:]

    static func register(_ tool: DeveloperDrawerTool, _ build: @escaping (DeveloperToolsSession) -> AnyView) {
        builders[tool] = build
    }

    static func view(_ tool: DeveloperDrawerTool, for session: DeveloperToolsSession) -> AnyView? {
        builders[tool]?(session)
    }
}

/// Chrome DevTools' drawer (Esc): a second tab strip under whichever panel
/// is shown, with the Console, Search, Rendering, Sensors, Network
/// conditions and request blocking, and More tools for the rest.
struct DeveloperDrawerView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var shell: DeveloperToolsShell
    /// A panel moved down from the main strip, drawn as the strip draws it.
    let panel: (DeveloperPanel) -> AnyView

    var body: some View {
        VStack(spacing: 0) {
            strip
            Divider()
            // A tool wider than the drawer is cut off at its edge rather
            // than widening the DevTools column (which pushed every panel
            // off both sides).
            content(shell.drawerSelection)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
        .background(DeveloperToolsStyle.surface)
    }

    private var strip: some View {
        HStack(spacing: 2) {
            // The chosen tool stays in view, as Chrome keeps the selected
            // tab out of its overflow menu.
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(shell.drawerTabs) { item in tab(item).id(item) }
                    }
                }
                .scrollIndicators(.never)
                .onAppear { reader.scrollTo(shell.drawerSelection) }
                .onChange(of: shell.drawerSelection) { _, item in
                    withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo(item) }
                }
                .onChange(of: shell.drawerTabs) { _, _ in reader.scrollTo(shell.drawerSelection) }
            }
            moreTools
            Spacer(minLength: 0)
            DeveloperPanelIcon(symbol: "xmark", title: "Close drawer (Esc)") { shell.drawerOpen = false }
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.toolbarHeight)
        .background(DeveloperToolsStyle.chrome)
    }

    private func tab(_ item: DeveloperDrawerItem) -> some View {
        let selected = shell.drawerSelection == item
        return HStack(spacing: 3) {
            Button { shell.drawerSelection = item } label: {
                Text(item.title)
            }
            .buttonStyle(.plain)
            if item != .tool(.console) {
                Button { shell.closeDrawerTab(item) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close " + item.title)
            }
        }
        .developerTab(selected: selected)
        .contextMenu {
            if case .panel(let panel) = item {
                Button("Move to top") { shell.movePanelToTop(panel) }
            }
            if item != .tool(.console) {
                Button("Close") { shell.closeDrawerTab(item) }
            }
        }
    }

    private var moreTools: some View {
        Menu {
            DeveloperMoreToolsItems(session: session, shell: shell)
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .frame(width: DeveloperToolsStyle.controlHeight, height: DeveloperToolsStyle.controlHeight)
                .accessibilityLabel("More tools")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More tools")
    }

    @ViewBuilder
    private func content(_ item: DeveloperDrawerItem) -> some View {
        switch item {
        case .tool(.console):
            // As in Chrome: with the Console panel itself in front, the
            // drawer doesn't show the same console a second time.
            if session.panel == .console {
                Text("The Console is shown in the main panel.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DeveloperConsoleView(session: session)
            }
        case .tool(.search):
            if let view = DeveloperDrawerTools.view(.search, for: session) {
                view
            } else {
                DeveloperSourcesSearchView(session: session) { shell.closeDrawerTab(.tool(.search)) }
            }
        case .tool(.rendering): DeveloperRenderingView(session: session)
        case .tool(.sensors): DeveloperSensorsView(session: session)
        case .tool(.networkConditions): DeveloperNetworkConditionsView(session: session, tools: session.networkTools)
        case .tool(.requestBlocking):
            DeveloperNetworkBlockingView(tools: session.networkTools, requests: session.requests) {
                shell.closeDrawerTab(.tool(.requestBlocking))
            }
        case .tool(.animations): DeveloperAnimationsView(session: session)
        case .tool(.coverage): DeveloperCoverageView(session: session, coverage: session.coverage)
        case .tool(.changes): DeveloperChangesView(session: session)
        case .tool(.layers): DeveloperLayersView(session: session)
        case .tool(.cssOverview): DeveloperCSSOverviewView(session: session)
        case .tool(.issues): DeveloperIssuesView(session: session)
        case .tool(.performanceMonitor): DeveloperPerformanceMonitorView(session: session)
        case .tool(.developerResources): DeveloperResourcesView(session: session)
        case .tool(.quickSource): DeveloperQuickSourceView(session: session)
        case .tool(.media): DeveloperMediaView(session: session)
        case .tool(.webAudio): DeveloperWebAudioView(session: session)
        case .tool(.memoryInspector): DeveloperMemoryInspectorView(session: session)
        case .tool(.webAuthn): DeveloperWebAuthnView(session: session)
        case .tool(.protocolMonitor): DeveloperProtocolMonitorView(session: session)
        case .tool(.aiAssistance): DeveloperAIAssistanceView(session: session, assistance: session.aiAssistance)
        case .panel(let shown): panel(shown)
        }
    }
}

/// Chrome's ⋮ › More tools, in the main strip's menu and the drawer's:
/// every drawer tool, and the panels closed from the main strip.
struct DeveloperMoreToolsItems: View {
    let session: DeveloperToolsSession
    let shell: DeveloperToolsShell

    var body: some View {
        ForEach(DeveloperDrawerTool.offered) { tool in
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
}

/// Chrome's Network conditions drawer tool: caching, throttling and the
/// user agent for the inspected tab.
struct DeveloperNetworkConditionsView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var tools: DeveloperNetworkTools
    @State private var draft = ""

    /// A few of Chrome's built-in user agents.
    static let presets: [(name: String, agent: String)] = [
        ("Chrome — Mac", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"),
        ("Chrome — Windows", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"),
        ("Chrome — Android Mobile", "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"),
        ("Safari — iPhone", "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"),
        ("Safari — iPad", "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"),
        ("Firefox — Mac", "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.7; rv:132.0) Gecko/20100101 Firefox/132.0"),
        ("Firefox — Windows", "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:132.0) Gecko/20100101 Firefox/132.0"),
        ("Googlebot", "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section("Caching") {
                    Toggle("Disable cache", isOn: Binding(get: { session.cacheDisabled },
                                                          set: { session.setCacheDisabled($0) }))
                        .toggleStyle(.developerCheckbox)
                }
                section("Network throttling") {
                    Menu(tools.activeProfileName ?? session.throttle.rawValue) {
                        ForEach(DeveloperToolsSession.NetworkCondition.allCases) { condition in
                            Button(condition.rawValue) { tools.apply(condition) }
                        }
                        if !tools.profiles.isEmpty {
                            Divider()
                            ForEach(tools.profiles) { profile in Button(profile.name) { tools.apply(profile) } }
                        }
                    }
                    .fixedSize()
                    Text(session.throttle.detail).foregroundStyle(.secondary)
                    Text("Add custom profiles in Settings › Throttling.").foregroundStyle(.secondary)
                }
                section("User agent") {
                    Toggle("Use browser default", isOn: Binding(
                        get: { session.userAgentOverride == nil },
                        set: { session.setUserAgentOverride($0 ? nil : (draft.isEmpty ? Self.presets[0].agent : draft)) }))
                        .toggleStyle(.developerCheckbox)
                    if session.userAgentOverride != nil {
                        Menu(Self.presets.first { $0.agent == session.userAgentOverride }?.name ?? "Custom…") {
                            ForEach(Self.presets, id: \.name) { preset in
                                Button(preset.name) { draft = preset.agent; session.setUserAgentOverride(preset.agent) }
                            }
                        }
                        .fixedSize()
                        TextField("Enter a custom user agent", text: $draft)
                            .developerToolsField()
                            .onSubmit { session.setUserAgentOverride(draft) }
                        Text("Used for what the tab loads next; reload to apply it to this page.")
                            .foregroundStyle(.secondary)
                    }
                }
                .onAppear { draft = session.userAgentOverride ?? "" }
                section("Accepted Content-Encodings") {
                    Toggle("Use browser default", isOn: Binding(
                        get: { tools.acceptedEncodings == nil },
                        set: { tools.acceptedEncodings = $0 ? nil : Set(DeveloperNetworkTools.ContentEncoding.allCases) }))
                        .toggleStyle(.developerCheckbox)
                    if let accepted = tools.acceptedEncodings {
                        HStack(spacing: DeveloperToolsStyle.gutter) {
                            ForEach(DeveloperNetworkTools.ContentEncoding.allCases) { encoding in
                                Toggle(encoding.rawValue, isOn: Binding(
                                    get: { accepted.contains(encoding) },
                                    set: { on in
                                        var next = tools.acceptedEncodings ?? []
                                        if on { next.insert(encoding) } else { next.remove(encoding) }
                                        tools.acceptedEncodings = next
                                    }))
                                    .toggleStyle(.developerCheckbox)
                            }
                        }
                        Text("Requests offer only these; the server picks among them.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(DeveloperToolsStyle.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DeveloperToolsStyle.stackSpacing) {
            Text(title).fontWeight(.semibold)
            content()
        }
    }
}
