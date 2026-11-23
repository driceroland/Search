import SwiftUI
import UniformTypeIdentifiers

struct DeveloperNetworkView: View {
    @ObservedObject var session: DeveloperToolsSession
    @Binding var options: Options

    struct Options {
        var query = ""
        var invert = false
        var hideDataURLs = false
        var hideExtensionURLs = false
        var blockedOnly = false
        var thirdPartyOnly = false
        var kinds = Set<DeveloperRequestKind>()
        var selection: String?
        var detailTab: DeveloperRequestTab = .headers
        var columns = Options.savedColumns() {
            didSet { Store.settings.set(columns.map(\.rawValue), forKey: Self.columnsKey) }
        }
        var sort: DeveloperNetworkListColumn?
        var ascending = true
        /// What the Waterfall column sorts by, from the header menu's
        /// Waterfall submenu.
        var waterfallSort = DeveloperNetworkWaterfallSort.startTime
        /// Response headers shown as columns, by lowercased name, in the
        /// order they were added.
        var headerColumns = Store.settings.stringArray(forKey: Options.headerColumnsKey) ?? [] {
            didSet { Store.settings.set(headerColumns, forKey: Self.headerColumnsKey) }
        }
        /// Headers added through Manage Header Columns…, offered after
        /// Chrome's own in Response Headers.
        var customHeaders = Store.settings.stringArray(forKey: Options.customHeadersKey) ?? [] {
            didSet { Store.settings.set(customHeaders, forKey: Self.customHeadersKey) }
        }
        /// Widths dragged at the header's dividers, by column key.
        var columnWidths = Options.savedWidths() {
            didSet { Store.settings.set(columnWidths.mapValues { Double($0) }, forKey: Self.widthsKey) }
        }
        /// The names list's width beside a request's tabs, once dragged.
        var listWidth = Options.savedListWidth() {
            didSet {
                if let listWidth { Store.settings.set(Double(listWidth), forKey: Self.listWidthKey) }
                else { Store.settings.removeObject(forKey: Self.listWidthKey) }
            }
        }
        /// Network settings › Big request rows.
        var bigRows = Store.settings.bool(forKey: Options.bigRowsKey) {
            didSet { Store.settings.set(bigRows, forKey: Self.bigRowsKey) }
        }
        /// Network settings › Show overview.
        var showOverview = Store.settings.object(forKey: Options.overviewKey) as? Bool ?? true {
            didSet { Store.settings.set(showOverview, forKey: Self.overviewKey) }
        }
        /// Network settings › Group by frame.
        var groupByFrame = Store.settings.bool(forKey: Options.groupByFrameKey) {
            didSet { Store.settings.set(groupByFrame, forKey: Self.groupByFrameKey) }
        }
        /// The frames whose rows are open while grouped by frame.
        var expandedFrames = Set<String>()
        /// Network settings › Capture screenshots.
        var captureScreenshots = Store.settings.bool(forKey: Options.screenshotsKey) {
            didSet { Store.settings.set(captureScreenshots, forKey: Self.screenshotsKey) }
        }
        /// The moment of the screenshot clicked in the filmstrip, in WebKit's
        /// seconds: the list shows what had finished by then.
        var filmstripTime: Double?
        var settingsShown = false
        var searchShown = false
        var blockingShown = false
        /// The span of time chosen on the overview, in WebKit's seconds;
        /// nil for the whole recording.
        var window: ClosedRange<Double>?

        private static let columnsKey = "developerTools.network.columns"
        private static let headerColumnsKey = "developerTools.network.headerColumns"
        private static let customHeadersKey = "developerTools.network.customHeaders"
        private static let widthsKey = "developerTools.network.columnWidths"
        private static let listWidthKey = "developerTools.network.listWidth"
        private static let bigRowsKey = "developerTools.network.bigRows"
        private static let overviewKey = "developerTools.network.showOverview"
        private static let groupByFrameKey = "developerTools.network.groupByFrame"
        private static let screenshotsKey = "developerTools.network.captureScreenshots"

        static func savedColumns() -> Set<DeveloperNetworkColumn> {
            guard let names = Store.settings.stringArray(forKey: columnsKey) else { return Set(DeveloperNetworkColumn.defaults) }
            return Set(names.compactMap(DeveloperNetworkColumn.init) + [.name])
        }

        static func savedWidths() -> [String: CGFloat] {
            let saved = Store.settings.dictionary(forKey: widthsKey) as? [String: Double] ?? [:]
            return saved.mapValues { CGFloat($0) }
        }

        static func savedListWidth() -> CGFloat? {
            (Store.settings.object(forKey: listWidthKey) as? Double).map { CGFloat($0) }
        }

        /// The headers Response Headers offers: Chrome's, then custom ones.
        var headerChoices: [String] {
            DeveloperNetworkListColumn.responseHeaders + customHeaders.filter {
                !DeveloperNetworkListColumn.responseHeaders.contains($0)
            }
        }

        mutating func showHeaderColumn(_ name: String, _ on: Bool) {
            if on {
                if !headerColumns.contains(name) { headerColumns.append(name) }
            } else {
                headerColumns.removeAll { $0 == name }
                if sort == .header(name) { sort = nil }
            }
        }

        /// Reset Columns: Chrome's columns at their own widths.
        mutating func resetColumns() {
            columns = Set(DeveloperNetworkColumn.defaults)
            headerColumns = []
            columnWidths = [:]
            if case .header = sort { sort = nil }
            if let sort, case .standard(let column) = sort, !columns.contains(column) { self.sort = nil }
        }
    }

    var body: some View {
        DeveloperNetworkPanel(session: session, tools: session.networkTools, options: $options)
    }
}

private struct DeveloperNetworkPanel: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var tools: DeveloperNetworkTools
    @Binding var options: DeveloperNetworkView.Options
    @State private var addingProfile = false
    /// The panel's width, which decides what the toolbar and filter bar
    /// show in full and what folds into their menus.
    @State private var width: CGFloat = 800
    /// Whether the request list has the keyboard, which a click on a row
    /// gives it, as in Chrome.
    @FocusState private var listFocused: Bool
    /// The list's visible height, which makes a page for Page Up and Down.
    @State private var listHeight: CGFloat = 400
    /// The last request chosen, which the list scrolls back to when it is
    /// rebuilt beside a request's tabs or without them.
    @State private var lastSelection: String?
    @State private var hovered: String?
    @StateObject private var shift = DeveloperShiftKey()
    @State private var resizing: Resize?
    @State private var card: HoverCard?
    @State private var pendingCard: HoverCard?
    @State private var managingHeaders = false
    @State private var searchFocus = 0
    @State private var dropping = false
    /// The filtered rows and the ruler, rebuilt only when what they read changes.
    @State private var cache = DeveloperNetworkRowsCache()
    /// Settings › Preferences › Network › Color-code resource types.
    @AppStorage(DeveloperNetworkTypeColors.key, store: Store.settings) private var colorCodeTypes = true

    /// A column edge being dragged, with the width it started at.
    private struct Resize: Equatable {
        let key: String
        let start: CGFloat
    }

    /// The hover card shown: the waterfall bar's timing, or the initiator's
    /// call stack.
    private enum HoverCard: Equatable {
        case timing(String)
        case initiator(String)
    }

    /// Shift-hover's colours, as Chrome's network-node-on-initiator-path
    /// and network-node-on-initiated-path rows.
    private static let initiatorTint = Color(.sRGB, red: 0.23, green: 0.85, blue: 0.23, opacity: 0.2)
    private static let initiatedTint = Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 0.2)

    var body: some View {
        let requests: [DeveloperToolsSession.Request] = session.requests
        let shown: [DeveloperToolsSession.Request] = visible(requests)
        // The overview keeps every request the filters let through; the list
        // only those in the span chosen on it, as in Chrome.
        let windowed: [DeveloperToolsSession.Request] = cache.rows(shown, window: options.window)
        // A screenshot clicked in the filmstrip: what had finished by then.
        let rows: [DeveloperToolsSession.Request] = options.filmstripTime
            .map { DeveloperNetworkFilmstrip.finished(by: $0, windowed) } ?? windowed
        let marks: [Double] = [tools.domContentLoaded, tools.load].compactMap { $0 }
        let whole: DeveloperNetworkTiming = cache.timing(requests, marks: marks)
        let timing: DeveloperNetworkTiming = whole.zoomed(to: options.window)
        VStack(spacing: 0) {
            controls(rows)
            if options.settingsShown { settings }
            filters.zIndex(1)
            if options.showOverview { overview(shown, timing: whole) }
            if options.captureScreenshots {
                DeveloperNetworkFilmstripView(filmstrip: tools.filmstrip, origin: whole.origin,
                                              selected: $options.filmstripTime)
            }
            HStack(spacing: 0) {
                if options.searchShown { searchPane(requests) }
                listAndDetails(rows, timing: timing, origin: whole.origin)
            }
            .onDrop(of: [.fileURL], isTargeted: $dropping, perform: importDropped)
            .overlay {
                if dropping {
                    Rectangle().strokeBorder(DeveloperToolsStyle.tint, lineWidth: 2).allowsHitTesting(false)
                }
            }
            if options.blockingShown {
                Rectangle().fill(DeveloperToolsStyle.rule.opacity(0.55)).frame(height: 1)
                DeveloperNetworkBlockingView(tools: tools, requests: requests) { options.blockingShown = false }
                    .frame(height: 150)
            }
            status(rows, all: requests, timing: whole)
        }
        // Cleared or started again: the chosen span no longer means anything.
        .onChange(of: requests.first?.id) { _, _ in
            options.window = nil
            options.filmstripTime = nil
            tools.filmstrip.clear()
        }
        .onChange(of: options.captureScreenshots) { _, on in
            if !on {
                tools.filmstrip.clear()
                options.filmstripTime = nil
            }
        }
        // Off, nothing runs; on, a screenshot is taken while requests load.
        .task(id: options.captureScreenshots && session.recordNetwork && session.ready) {
            guard options.captureScreenshots && session.recordNetwork && session.ready else { return }
            while !Task.isCancelled {
                await tools.filmstrip.captureIfDue(session)
                try? await Task.sleep(for: .milliseconds(Int(DeveloperNetworkFilmstrip.interval * 1_000)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: session.requestInterception) { await tools.probeBandwidth() }
        .task(id: frameKey) {
            if options.groupByFrame { await tools.loadFrames() }
        }
        .accessibilityIdentifier("developer-tools-network")
        .task(id: session.ready) {
            while !Task.isCancelled && session.ready {
                await tools.poll()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .developerSheet(isPresented: $addingProfile) {
            DeveloperThrottlingProfileForm(bandwidth: tools.bandwidthThrottling) { profile in
                tools.profiles.append(profile)
                tools.apply(profile)
            }
        }
        .developerSheet(isPresented: $managingHeaders) {
            DeveloperNetworkHeaderColumnsSheet(options: $options)
        }
        .onAppear {
            shift.start()
            lendKeys()
        }
        .onDisappear {
            shift.stop()
            DeveloperPanelKeys.network = nil
        }
        .onChange(of: options.selection) { _, id in
            if let id { lastSelection = id }
        }
    }

    /// Search across every request's headers and bodies, at the left.
    @ViewBuilder
    private func searchPane(_ requests: [DeveloperToolsSession.Request]) -> some View {
        DeveloperNetworkSearchView(session: session, tools: tools, requests: requests,
                                   focusRequest: searchFocus) { id, tab in
            options.selection = id
            options.detailTab = tab
        } close: {
            options.searchShown = false
        }
        .frame(width: 260)
        Rectangle().fill(DeveloperToolsStyle.rule.opacity(0.55)).frame(width: 1)
    }

    private func listAndDetails(_ rows: [DeveloperToolsSession.Request], timing: DeveloperNetworkTiming,
                                origin: Double) -> some View {
        GeometryReader { (space: GeometryProxy) in
            // As in DevTools: a chosen request narrows the list to its
            // names and the request's tabs take the rest of the room.
            if let selection = options.selection, let request = chosen(selection, in: rows) {
                let listWidth: CGFloat = namesWidth(space.size.width)
                HStack(spacing: 0) {
                    grid(rows, timing: timing, origin: origin, width: listWidth, namesOnly: true)
                        .frame(width: listWidth)
                    listDivider(listWidth, total: space.size.width)
                    DeveloperRequestDetailsView(session: session, request: request, tab: $options.detailTab) {
                        options.selection = nil
                    }
                    .id(request.id)
                }
            } else {
                grid(rows, timing: timing, origin: origin, width: space.size.width)
            }
        }
    }

    /// The chosen request among the rows shown.
    private func chosen(_ selection: String, in rows: [DeveloperToolsSession.Request]) -> DeveloperToolsSession.Request? {
        options.filmstripTime == nil ? cache.selected(selection, in: rows) : rows.first(where: { $0.id == selection })
    }

    // MARK: Files

    /// A .har file dropped on the panel is read in, as in Chrome.
    private func importDropped(_ providers: [NSItemProvider]) -> Bool {
        let type = UTType.fileURL.identifier
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type) }) else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: type) { [tools] data, _ in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil),
                  let contents = try? Data(contentsOf: url) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    do {
                        try tools.importHAR(contents)
                    } catch {
                        tools.message = "This file isn’t a HAR log: " + error.localizedDescription
                    }
                }
            }
        }
        options.selection = nil
        return true
    }

    /// The registrable part of a host, approximated by its last two labels.
    static func site(_ url: String) -> String { DeveloperNetworkRowsCache.site(url) }

    private func visible(_ requests: [DeveloperToolsSession.Request]) -> [DeveloperToolsSession.Request] {
        cache.shown(requests, options: options, extras: tools.extras, extrasRevision: tools.extrasRevision,
                    page: session.address?.absoluteString ?? "")
    }

    // MARK: Toolbar

    private var conditionLabel: String { tools.activeProfileName ?? session.throttle.rawValue }

    private func controls(_ rows: [DeveloperToolsSession.Request]) -> some View {
        let shown = DeveloperNetworkToolbar.shown(width: width, conditionLabel: conditionLabel)
        let hidden = DeveloperNetworkToolbar.Item.allCases.filter { !shown.contains($0) }
        return HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            icon(session.recordNetwork ? "record.circle.fill" : "record.circle",
                 session.recordNetwork ? "Stop recording network log (⌘E)" : "Record network log (⌘E)",
                 color: session.recordNetwork ? .red : .secondary) { session.recordNetwork.toggle() }
                .keyboardShortcut("e", modifiers: .command)
            icon("nosign", "Clear network log", action: clear)
            toolbarRule
            icon("magnifyingglass", "Search (⌘F)", color: options.searchShown ? DeveloperToolsStyle.tint : .secondary) {
                options.searchShown.toggle()
            }
            .background {
                // ⌘F opens the search pane, or gives its field the keyboard
                // when it is open; it never closes it, as in Chrome.
                Button("", action: openSearch).keyboardShortcut("f", modifiers: .command)
                    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
            icon("arrow.clockwise", "Reload inspected page", action: session.reload)
            ForEach(shown, id: \.self) { item in
                switch item {
                case .keepLog:
                    checkbox("Keep log", isOn: $session.preserveNetworkLog)
                        .help("Do not clear log on page reload / navigation")
                case .disableCache:
                    checkbox("Disable cache", isOn: cacheDisabled)
                case .conditions:
                    conditions
                case .files:
                    HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                        toolbarRule
                        icon("square.and.arrow.down", "Import HAR file…", action: importHAR)
                        icon("square.and.arrow.up", "Export HAR (sanitized)…") {
                            tools.exportHAR(rows, sanitize: true, host: session.host)
                        }
                        .contextMenu {
                            Button("Export HAR (sanitized)…") { tools.exportHAR(rows, sanitize: true, host: session.host) }
                            Button("Export HAR (with sensitive data)…") { tools.exportHAR(rows, sanitize: false, host: session.host) }
                        }
                        blockingIcon
                    }
                }
            }
            if let message = tools.message {
                Text(message).foregroundStyle(.red).lineLimit(1).truncationMode(.tail)
                    .onTapGesture { tools.message = nil }
                    .layoutPriority(-1)
            }
            Spacer(minLength: 0)
            if !hidden.isEmpty { overflowMenu(hidden, rows: rows) }
            icon("gearshape", "Network settings",
                 color: options.settingsShown ? DeveloperToolsStyle.tint : .secondary) { options.settingsShown.toggle() }
                .accessibilityIdentifier("developer-network-settings")
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(maxWidth: .infinity, minHeight: DeveloperToolsStyle.toolbarHeight,
               maxHeight: DeveloperToolsStyle.toolbarHeight, alignment: .leading)
        .clipped()
        .background(DeveloperToolsStyle.chrome)
    }

    private var cacheDisabled: Binding<Bool> {
        Binding(get: { session.cacheDisabled }, set: session.setCacheDisabled)
    }

    private func openSearch() {
        options.searchShown = true
        searchFocus += 1
    }

    /// ⌘F and Esc from DevTools' keys, which hear them before this view's
    /// own shortcuts and the browser's (DeveloperToolsKeys).
    private func lendKeys() {
        let binding = $options
        DeveloperPanelKeys.network = DeveloperPanelKeys.Network(
            find: { openSearch() },
            detailsOpen: { binding.wrappedValue.selection != nil },
            closeDetails: { binding.wrappedValue.selection = nil })
    }

    /// Chrome's Network settings pane, under the toolbar while the gear is on.
    private var settings: some View {
        HStack(spacing: DeveloperToolsStyle.gutter * 2) {
            checkbox("Big request rows", isOn: $options.bigRows)
                .help("Show more detail in each row: the path under the name, the status text, the resource size and the latency")
            checkbox("Group by frame", isOn: $options.groupByFrame)
                .help("Group requests by the frame that made them")
            checkbox("Show overview", isOn: $options.showOverview)
                .help("Show the timeline overview above the request list")
            checkbox("Capture screenshots", isOn: $options.captureScreenshots)
                .help("Capture screenshots when loading a page")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(maxWidth: .infinity, minHeight: DeveloperToolsStyle.toolbarHeight,
               maxHeight: DeveloperToolsStyle.toolbarHeight, alignment: .leading)
        .background(DeveloperToolsStyle.chrome)
        .overlay(alignment: .top) { horizontalRule.opacity(0.6) }
        .accessibilityIdentifier("developer-network-settings-pane")
    }

    private func clear() {
        session.clearNetwork()
        tools.clear()
        tools.filmstrip.clear()
        options.filmstripTime = nil
        options.selection = nil
    }

    private func importHAR() {
        tools.importHAR()
        options.selection = nil
    }

    private var blockingIcon: some View {
        icon("hand.raised", "Request conditions",
             color: options.blockingShown || tools.blockingActive ? DeveloperToolsStyle.tint : .secondary) {
            options.blockingShown.toggle()
        }
    }

    private var toolbarRule: some View {
        Rectangle().fill(DeveloperToolsStyle.rule.opacity(0.55)).frame(width: 1, height: 14)
    }

    /// Chrome's »: what no longer fits, in toolbar order.
    private func overflowMenu(_ hidden: [DeveloperNetworkToolbar.Item], rows: [DeveloperToolsSession.Request]) -> some View {
        Menu {
            ForEach(hidden, id: \.self) { item in
                switch item {
                case .keepLog:
                    Toggle("Keep log", isOn: $session.preserveNetworkLog)
                case .disableCache:
                    Toggle("Disable cache", isOn: cacheDisabled)
                case .conditions:
                    Menu("Network conditions: " + conditionLabel) { conditionItems }
                        .disabled(!session.requestInterception)
                case .files:
                    Divider()
                    Button("Import HAR file…", action: importHAR)
                    Button("Export HAR (sanitized)…") { tools.exportHAR(rows, sanitize: true, host: session.host) }
                    Button("Export HAR (with sensitive data)…") { tools.exportHAR(rows, sanitize: false, host: session.host) }
                    Toggle("Request conditions", isOn: $options.blockingShown)
                }
            }
        } label: {
            Image(systemName: "chevron.right.2").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: DeveloperToolsStyle.controlHeight, height: DeveloperToolsStyle.controlHeight)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More tools")
        .accessibilityLabel("More tools")
        .accessibilityIdentifier("developer-network-overflow")
    }

    private var throttleHelp: String {
        tools.bandwidthThrottling
            ? "Presets limit bandwidth through WebKit’s network emulation and add their latency to HTTP and HTTPS requests."
            : "This version of WebKit can’t limit bandwidth. Presets add only their latency, to intercepted HTTP and HTTPS requests; cached responses and service workers can bypass it."
    }

    private var conditions: some View {
        let label = conditionLabel
        return Menu {
            conditionItems
        } label: {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                Text(label).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, DeveloperToolsStyle.controlSpacing)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(height: DeveloperToolsStyle.controlHeight)
        .disabled(!session.requestInterception)
        .help((tools.activeProfile == nil ? session.throttle.detail : label) + "\n" + throttleHelp)
        .accessibilityLabel("Network conditions")
        .accessibilityValue(label)
    }

    @ViewBuilder
    private var conditionItems: some View {
            Section("Disabled") { conditionButton(.unrestricted) }
            Section("Presets") {
                ForEach([DeveloperToolsSession.NetworkCondition.fast4G, .slow4G, .threeG, .offline]) { conditionButton($0) }
            }
            Section("Custom") {
                ForEach(tools.profiles) { profile in
                    Button {
                        tools.apply(profile)
                    } label: {
                        if tools.activeProfile == profile.id { Label(profile.name, systemImage: "checkmark") }
                        else { Text(profile.name) }
                    }
                    .help(Self.describe(profile))
                }
                Button("Add…") { addingProfile = true }
                if !tools.profiles.isEmpty {
                    Menu("Remove") {
                        ForEach(tools.profiles) { profile in
                            Button(profile.name) {
                                if tools.activeProfile == profile.id { tools.apply(.unrestricted) }
                                tools.profiles.removeAll { $0.id == profile.id }
                            }
                        }
                    }
                }
            }
            Divider()
            Text(tools.bandwidthThrottling ? "Bandwidth limits: WebKit network emulation" : "Latency only: WebKit can’t limit bandwidth here")
    }

    private func conditionButton(_ condition: DeveloperToolsSession.NetworkCondition) -> some View {
        Button {
            tools.apply(condition)
        } label: {
            if tools.activeProfile == nil && session.throttle == condition { Label(condition.rawValue, systemImage: "checkmark") }
            else { Text(condition.rawValue) }
        }
        .help(condition.detail)
    }

    static func describe(_ profile: DeveloperNetworkTools.ThrottlingProfile) -> String {
        func rate(_ kbps: Double) -> String { kbps <= 0 ? "no limit" : kbps >= 1_000 ? "\(kbps / 1_000) Mbps" : "\(Int(kbps)) kbps" }
        return "\(profile.name): \(Int(profile.latency)) ms latency, \(rate(profile.download)) down, \(rate(profile.upload)) up"
    }

    private func checkbox(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.developerCheckbox)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            .fixedSize()
            .frame(height: DeveloperToolsStyle.controlHeight)
    }

    private var filters: some View {
        let compact = width < DeveloperNetworkToolbar.compactFilterWidth
        let filterRow = HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                DeveloperNetworkFilterField(query: $options.query, requests: session.requests, extras: tools.extras)
                if !options.query.isEmpty {
                    icon("xmark.circle.fill", "Clear request filter") { options.query = "" }
                }
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(minWidth: 90, idealWidth: 240, maxWidth: 280)
            .frame(height: DeveloperToolsStyle.controlHeight)
            .background(DeveloperToolsStyle.raised, in: RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius))
            if !compact {
                checkbox("Invert", isOn: $options.invert)
                    .help("Inverts the search filter")
            }
            moreFilters(includesInvert: compact)
        }
        let chips = ScrollView(.horizontal) {
            HStack(spacing: 1) {
                chip("All", active: options.kinds.isEmpty) { options.kinds.removeAll() }
                Rectangle().fill(DeveloperToolsStyle.rule.opacity(0.55)).frame(width: 1, height: 12)
                    .padding(.horizontal, 3)
                ForEach(DeveloperRequestKind.allCases) { kind in
                    chip(kind.rawValue, active: options.kinds.contains(kind)) { select(kind) }
                }
            }
            .frame(height: DeveloperToolsStyle.toolbarHeight)
        }
        .scrollIndicators(.never)
        .frame(height: DeveloperToolsStyle.toolbarHeight)
        return Group {
            if DeveloperNetworkToolbar.chipsShareFilterRow(width: width) {
                HStack(spacing: DeveloperToolsStyle.gutter) {
                    // Over its neighbours: the filter's suggestions hang below it.
                    filterRow.frame(width: 240 + 160, alignment: .leading).zIndex(1)
                    Rectangle().fill(DeveloperToolsStyle.rule.opacity(0.55)).frame(width: 1, height: 14)
                    chips
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    filterRow
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: DeveloperToolsStyle.toolbarHeight)
                        .zIndex(1)
                    chips
                }
            }
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeveloperToolsStyle.chrome)
        .overlay(alignment: .top) { horizontalRule.opacity(0.6) }
    }

    /// Chrome's "More filters" dropdown. Blocked response cookies is left
    /// out: WebKit doesn't report why a cookie was refused.
    private func moreFilters(includesInvert: Bool) -> some View {
        let count = [options.hideDataURLs, options.hideExtensionURLs, options.blockedOnly, options.thirdPartyOnly,
                     includesInvert && options.invert]
            .filter { $0 }.count
        return Menu {
            if includesInvert {
                Toggle("Invert", isOn: $options.invert)
                Divider()
            }
            Toggle("Hide data URLs", isOn: $options.hideDataURLs)
            Toggle("Hide extension URLs", isOn: $options.hideExtensionURLs)
            Toggle("Blocked requests", isOn: $options.blockedOnly)
            Toggle("3rd-party requests", isOn: $options.thirdPartyOnly)
        } label: {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                Text(count == 0 ? "More filters" : "\(count) more filter\(count == 1 ? "" : "s")")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(height: DeveloperToolsStyle.controlHeight)
        .help("Show only/hide requests")
    }

    private func select(_ kind: DeveloperRequestKind) {
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            if !options.kinds.insert(kind).inserted { options.kinds.remove(kind) }
        } else {
            options.kinds = [kind]
        }
    }

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? Palette.ink : Color.secondary)
                .fixedSize()
                .padding(.horizontal, 6)
                .frame(height: DeveloperToolsStyle.controlHeight - 4)
                .background(active ? DeveloperToolsStyle.selected : .clear,
                            in: RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
        .help(title == "All" ? "Show all requests" : title + " (⌘-click to combine types)")
    }

    // MARK: Overview and list

    private func overview(_ rows: [DeveloperToolsSession.Request], timing: DeveloperNetworkTiming) -> some View {
        Canvas { context, size in
            let inset = DeveloperToolsStyle.gutter
            let chartWidth = max(0, size.width - inset * 2)
            let labels = timing.ticks(width: chartWidth)
            for (offset, fraction) in labels {
                let x = inset + fraction * chartWidth
                var line = Path()
                line.move(to: CGPoint(x: x, y: 17))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(DeveloperToolsStyle.rule.opacity(0.45)), lineWidth: 0.5)
                if x + 42 <= size.width {
                    let label = Text(Self.duration(offset * 1_000)).font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                    context.draw(label, at: CGPoint(x: x, y: 8), anchor: .leading)
                }
            }
            for (index, row) in rows.enumerated() {
                let segments = DeveloperNetworkTiming.segments(for: row)
                let lane = CGFloat(index % 8)
                draw(segments, timing: timing, context: context,
                     area: CGRect(x: inset, y: 20 + lane * 5, width: chartWidth, height: 3), failed: row.failed)
            }
            marks(timing: timing, context: context, area: CGRect(x: inset, y: 17, width: chartWidth, height: size.height - 17))
        }
        .frame(height: 62)
        .overlay {
            DeveloperNetworkOverviewWindow(window: $options.window, timing: timing,
                                           inset: DeveloperToolsStyle.gutter, top: 17)
        }
        .background(DeveloperToolsStyle.surface)
        .overlay(alignment: .top) { horizontalRule }
        .overlay(alignment: .bottom) { horizontalRule }
        .accessibilityLabel("Network timeline overview")
    }

    /// DOMContentLoaded in blue and load in red, as DevTools draws them.
    private func marks(timing: DeveloperNetworkTiming, context: GraphicsContext, area: CGRect) {
        for (time, color) in [(tools.domContentLoaded, Color.blue), (tools.load, Color.red)] {
            guard let time, time >= timing.origin, time <= timing.end else { continue }
            let x = area.minX + timing.fraction(time) * area.width
            var line = Path()
            line.move(to: CGPoint(x: x, y: area.minY))
            line.addLine(to: CGPoint(x: x, y: area.maxY))
            context.stroke(line, with: .color(color.opacity(0.8)), lineWidth: 1)
        }
    }

    /// `origin` is the whole recording's start, which a request's timing
    /// card counts from while the waterfall shows only part of it.
    private func grid(_ rows: [DeveloperToolsSession.Request], timing: DeveloperNetworkTiming, origin: Double,
                      width: CGFloat, namesOnly: Bool = false) -> some View {
        let columns: [DeveloperNetworkListColumn] = namesOnly
            ? [DeveloperNetworkListColumn.standard(.name)] : fitted(width: width)
        let graph: (initiators: Set<String>, initiated: Set<String>)? = shiftGraph()
        let entries: [DeveloperNetworkFrameGroups.Entry] = groupedEntries(rows)
        // What the keyboard moves through: the rows a collapsed frame hides aren't.
        let listed: [DeveloperToolsSession.Request] = options.groupByFrame
            ? DeveloperNetworkFrameGroups.requests(in: entries) : rows
        return ScrollViewReader { (reader: ScrollViewProxy) in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            switch entry {
                            case .request(let row):
                                requestRow(row, index: index, columns: columns, timing: timing, origin: origin,
                                           rows: rows, graph: graph)
                                    .id(row.id)
                            case .frame(let group):
                                frameRow(group)
                                    .id(entry.id)
                            }
                        }
                    } header: {
                        headerRow(columns, namesOnly: namesOnly)
                    }
                }
            }
            // A clicked row gives the list the keyboard, as in Chrome.
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(phases: [.down, .repeat]) { press in key(press, rows: listed, reader: reader) }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            .onAppear {
                // Rebuilt beside a request's tabs, or back without them: the
                // request in view again, as the list was.
                guard let id = options.selection ?? lastSelection else { return }
                DispatchQueue.main.async { reader.scrollTo(id, anchor: .center) }
            }
            .onChange(of: options.selection) { _, id in
                if let id { reader.scrollTo(id) }
            }
        }
        .overlay {
            if rows.isEmpty { emptyList }
        }
    }

    private func headerRow(_ columns: [DeveloperNetworkListColumn], namesOnly: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                header(column)
                    .overlay(alignment: .trailing) {
                        if !namesOnly && index < columns.count - 1 {
                            resizeHandle(column, next: columns[index + 1])
                        }
                    }
            }
        }
        .background(DeveloperToolsStyle.chrome)
        .overlay(alignment: .bottom) { horizontalRule }
        .contextMenu { DeveloperNetworkColumnMenu(options: $options) { managingHeaders = true } }
    }

    /// What the list says when it has no rows.
    private var emptyList: some View {
        VStack(spacing: 6) {
            if session.requests.isEmpty {
                Text(session.recordNetwork ? "Recording network activity…" : "Network recording is paused")
                if session.recordNetwork {
                    Text("Perform a request or hit ⌘R to record the reload.").font(.system(size: 10.5))
                    Button("Reload page", action: session.reload)
                }
            } else {
                Text("No matching requests")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.top, DeveloperToolsStyle.rowHeight * 2)
    }

    /// The chosen columns, response headers after Chrome's own and the
    /// waterfall last, narrowed from the right when the dock is small.
    private func fitted(width: CGFloat) -> [DeveloperNetworkListColumn] {
        var columns = DeveloperNetworkColumn.allCases
            .filter { (options.columns.contains($0) || $0 == .name) && $0 != .waterfall }
            .map(DeveloperNetworkListColumn.standard)
        columns += options.headerColumns.map(DeveloperNetworkListColumn.header)
        if options.columns.contains(.waterfall) { columns.append(.standard(.waterfall)) }
        func used() -> CGFloat { columns.compactMap(columnWidth).reduce(0, +) + 150 }
        while used() > width,
              let drop = columns.lastIndex(where: { $0 != .standard(.name) && $0 != .standard(.waterfall) }) {
            columns.remove(at: drop)
        }
        if used() > width { columns.removeAll { $0 == .standard(.waterfall) } }
        return columns
    }

    /// A column's width: as dragged, else its own; nil for Name, which
    /// takes the room the others leave.
    private func columnWidth(_ column: DeveloperNetworkListColumn) -> CGFloat? {
        guard let width = column.defaultWidth else { return nil }
        return options.columnWidths[column.key] ?? width
    }

    private var rowHeight: CGFloat {
        options.bigRows ? DeveloperToolsStyle.rowHeight * 2 - 2 : DeveloperToolsStyle.rowHeight
    }

    private func header(_ column: DeveloperNetworkListColumn) -> some View {
        Button {
            if options.sort == column {
                if options.ascending { options.ascending = false } else { options.sort = nil; options.ascending = true }
            } else {
                options.sort = column
                options.ascending = true
            }
        } label: {
            tableCell(column, height: DeveloperToolsStyle.rowHeight) {
                HStack(spacing: 3) {
                    Text(column.title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if options.sort == column {
                        Image(systemName: options.ascending ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(column == .standard(.waterfall) ? "Sort by " + options.waterfallSort.rawValue : "Sort by " + column.title)
        .accessibilityIdentifier("developer-network-column-\(column.title.lowercased())")
    }

    /// The divider at a header's right edge: dragging it resizes the
    /// column, as in Chrome. Name takes what the others leave, so its edge
    /// moves the column after it instead.
    private func resizeHandle(_ column: DeveloperNetworkListColumn, next: DeveloperNetworkListColumn) -> some View {
        let target = column.defaultWidth == nil ? next : column
        let sign: CGFloat = column.defaultWidth == nil ? -1 : 1
        return Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start: CGFloat
                    if let resizing, resizing.key == target.key {
                        start = resizing.start
                    } else {
                        start = columnWidth(target) ?? 0
                        resizing = Resize(key: target.key, start: start)
                    }
                    let range = DeveloperNetworkListColumn.widths
                    options.columnWidths[target.key] = min(range.upperBound,
                                                           max(range.lowerBound, start + sign * value.translation.width))
                }
                .onEnded { _ in resizing = nil })
            .accessibilityLabel("Resize " + target.title)
    }

    /// The names list's width beside a request's tabs: as dragged, else
    /// DevTools' share of the room.
    private func namesWidth(_ total: CGFloat) -> CGFloat {
        let fallback = min(max(160, total * 0.3), 320)
        return min(max(120, options.listWidth ?? fallback), max(120, total - 200))
    }

    /// The rule between the names list and the request's tabs, which
    /// drags to share the room differently.
    private func listDivider(_ current: CGFloat, total: CGFloat) -> some View {
        Rectangle().fill(DeveloperToolsStyle.rule.opacity(0.55)).frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start: CGFloat
                            if let resizing, resizing.key == "list" {
                                start = resizing.start
                            } else {
                                start = current
                                resizing = Resize(key: "list", start: start)
                            }
                            options.listWidth = min(max(120, start + value.translation.width), max(120, total - 200))
                        }
                        .onEnded { _ in resizing = nil })
            }
            .zIndex(1)
            .accessibilityLabel("Resize request list")
    }

    // MARK: Keyboard and hover

    /// Up and Down, Page Up and Down, Home and End in the list, as in
    /// Chrome: the selection moves, its tabs follow on the same tab, and
    /// the list scrolls to keep it in view.
    private func key(_ press: KeyPress, rows: [DeveloperToolsSession.Request], reader: ScrollViewProxy) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        let move: DeveloperNetworkKeyboard.Move
        switch press.key {
        case .upArrow: move = .up
        case .downArrow: move = .down
        case .pageUp: move = .pageUp
        case .pageDown: move = .pageDown
        case .home: move = .home
        case .end: move = .end
        default: return .ignored
        }
        let current = options.selection.flatMap { id in rows.firstIndex { $0.id == id } }
        let page = Int(listHeight / rowHeight) - 1
        guard let next = DeveloperNetworkKeyboard.index(after: move, from: current, count: rows.count, page: page)
        else { return .handled }
        let id = rows[next].id
        let opening = options.selection == nil
        options.selection = id
        lastSelection = id
        reader.scrollTo(id)
        // The first choice opens the request's tabs and rebuilds the list
        // beside them: the keyboard stays with it.
        if opening { DispatchQueue.main.async { listFocused = true } }
        return .handled
    }

    private func select(_ id: String, tab: DeveloperRequestTab? = nil) {
        options.selection = id
        lastSelection = id
        if let tab { options.detailTab = tab }
        DispatchQueue.main.async { listFocused = true }
    }

    /// While Shift is held over a row: its initiators and what it
    /// initiated, as Chrome tints them.
    private func shiftGraph() -> (initiators: Set<String>, initiated: Set<String>)? {
        guard shift.held, let hovered, let request = session.requests.first(where: { $0.id == hovered }) else { return nil }
        return DeveloperNetworkInitiators.graph(for: request, in: session.requests)
    }

    private func rowBackground(_ row: DeveloperToolsSession.Request, index: Int, selected: Bool,
                               graph: (initiators: Set<String>, initiated: Set<String>)?) -> Color {
        if selected { return DeveloperToolsStyle.selected }
        if graph?.initiators.contains(row.id) == true { return Self.initiatorTint }
        if graph?.initiated.contains(row.id) == true { return Self.initiatedTint }
        if hovered == row.id { return Palette.hover }
        return index.isMultiple(of: 2) ? Palette.ink.opacity(0.022) : .clear
    }

    /// A hover card opens after the pointer rests a moment, as a tooltip.
    private func enter(_ next: HoverCard) {
        guard pendingCard != next else { return }
        pendingCard = next
        if card != nil && card != next { card = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if pendingCard == next { card = next }
        }
    }

    private func leave(_ current: HoverCard) {
        if pendingCard == current { pendingCard = nil }
        if card == current { card = nil }
    }

    private func showing(_ current: HoverCard) -> Binding<Bool> {
        Binding(get: { card == current }, set: { shown in
            if !shown && card == current {
                card = nil
                pendingCard = nil
            }
        })
    }

    private func requestRow(_ row: DeveloperToolsSession.Request, index: Int, columns: [DeveloperNetworkListColumn],
                            timing: DeveloperNetworkTiming, origin: Double, rows: [DeveloperToolsSession.Request],
                            graph: (initiators: Set<String>, initiated: Set<String>)?) -> some View {
        let selected = row.id == options.selection
        let extra = tools.extras[row.id]
        let height = rowHeight
        return HStack(spacing: 0) {
            ForEach(columns) { column in
                tableCell(column, height: height) {
                    cell(column, row: row, extra: extra, timing: timing, origin: origin)
                }
            }
        }
        .foregroundStyle(row.failed || extra?.blocked == true ? Color.red : Palette.ink)
        .background(rowBackground(row, index: index, selected: selected, graph: graph))
        .contentShape(Rectangle())
        .onTapGesture { select(row.id) }
        .onHover { inside in
            if inside { hovered = row.id } else if hovered == row.id { hovered = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { select(row.id) }
        .help(row.url)
        .contextMenu {
            DeveloperNetworkRowMenu(session: session, tools: tools, options: $options, request: row, rows: rows,
                                    filtered: rows.count != session.requests.count, columns: columns) {
                managingHeaders = true
            }
        }
    }

    // MARK: Group by frame

    /// The list's rows, under their frames while Group by frame is on.
    private func groupedEntries(_ rows: [DeveloperToolsSession.Request]) -> [DeveloperNetworkFrameGroups.Entry] {
        guard options.groupByFrame else { return rows.map { .request($0) } }
        let main = DeveloperNetworkFrameGroups.mainFrame(tools.frames, requests: session.requests)
        return DeveloperNetworkFrameGroups.entries(rows, frames: tools.frames, main: main, expanded: options.expandedFrames)
    }

    /// What the frame names are read again for: the frames requests came from.
    private var frameKey: Set<String> {
        options.groupByFrame ? Set(session.requests.compactMap(\.frameId)) : []
    }

    /// A frame's row, which a click opens or closes, as Chrome's group rows.
    private func frameRow(_ group: DeveloperNetworkFrameGroups.Group) -> some View {
        Button {
            if group.expanded { options.expandedFrames.remove(group.id) } else { options.expandedFrames.insert(group.id) }
        } label: {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                Image(systemName: group.expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Image(systemName: "rectangle.on.rectangle").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(group.title).truncationMode(.middle)
                Text("\(group.count) request\(group.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
            .background(Palette.ink.opacity(0.045))
            .overlay(alignment: .bottom) { Rectangle().fill(DeveloperToolsStyle.rule.opacity(0.32)).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.ink)
        .help(group.title)
        .accessibilityLabel("Frame " + group.title)
        .accessibilityValue(group.expanded ? "Expanded" : "Collapsed")
    }

    private func tableCell<Content: View>(_ column: DeveloperNetworkListColumn, height: CGFloat,
                                          @ViewBuilder content: () -> Content) -> some View {
        let width = columnWidth(column)
        return content()
            .lineLimit(1)
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(minWidth: width ?? 0, maxWidth: width ?? .infinity, minHeight: height, maxHeight: height,
                   alignment: column.numeric ? .trailing : .leading)
            .overlay(alignment: .trailing) { verticalRule }
    }

    /// A cell's text, with the second line Chrome's big rows add under it.
    @ViewBuilder
    private func lines<Primary: View>(_ primary: Primary, _ secondary: String?, trailing: Bool = false) -> some View {
        if options.bigRows {
            VStack(alignment: trailing ? .trailing : .leading, spacing: 1) {
                primary
                Text(secondary ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
            }
        } else {
            primary
        }
    }

    @ViewBuilder
    private func cell(_ column: DeveloperNetworkListColumn, row: DeveloperToolsSession.Request,
                      extra: DeveloperNetworkTools.Extra?, timing: DeveloperNetworkTiming, origin: Double) -> some View {
        switch column {
        case .header:
            Text(DeveloperNetworkListColumn.value(column, row, extra)).foregroundStyle(.secondary).truncationMode(.middle)
        case .standard(let standard):
            switch standard {
            case .name:
                HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                    Image(systemName: extra?.blocked == true ? "nosign" : "doc").font(.system(size: 10)).foregroundStyle(.secondary)
                        .overlay(alignment: .bottomTrailing) {
                            // Chrome's purple dot: served with Local Overrides.
                            if extra?.servedWithOverrides == true {
                                Circle().fill(Color.purple).frame(width: 6, height: 6).offset(x: 2, y: 2)
                                    .help("Served from Local Overrides")
                                    .accessibilityLabel("Overridden")
                            }
                        }
                    lines(Text(row.name).truncationMode(.middle), DeveloperNetworkColumn.folder(row.url))
                }
            case .size:
                lines(Text(size(row, extra: extra)).monospacedDigit(),
                      extra?.resourceSize.map(Self.byteCount), trailing: true)
            case .time:
                lines(Text(row.time.map(Self.duration) ?? (row.failure == nil ? "(pending)" : "—")).monospacedDigit(),
                      DeveloperNetworkColumn.latency(row).map(Self.duration), trailing: true)
            case .status:
                lines(Text(DeveloperNetworkColumn.value(.status, row, extra)).monospacedDigit(),
                      row.failure ?? row.statusText, trailing: true)
                    .help(row.failure ?? row.statusText ?? "")
            case .initiator:
                lines(initiator(row, extra: extra), row.initiatorType.map { $0.prefix(1).uppercased() + $0.dropFirst() })
            case .path, .domain, .remoteAddress:
                Text(DeveloperNetworkColumn.value(standard, row, extra)).foregroundStyle(.secondary).truncationMode(.middle)
            case .waterfall:
                waterfall(row, extra: extra, timing: timing, origin: origin)
            default:
                Text(DeveloperNetworkColumn.value(standard, row, extra)).monospacedDigit()
            }
        }
    }

    /// The waterfall bar. Resting on it shows the request's timing, and a
    /// click opens its Timing tab, as in Chrome.
    private func waterfall(_ row: DeveloperToolsSession.Request, extra: DeveloperNetworkTools.Extra?,
                           timing: DeveloperNetworkTiming, origin: Double) -> some View {
        let segments = DeveloperNetworkTiming.segments(for: row)
        let timingCard = HoverCard.timing(row.id)
        return GeometryReader { space in
            Canvas { context, size in
                for (_, fraction) in timing.ticks(width: size.width) {
                    let x = fraction * size.width
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(DeveloperToolsStyle.rule.opacity(0.35)), lineWidth: 0.5)
                }
                marks(timing: timing, context: context, area: CGRect(origin: .zero, size: size))
                draw(segments, timing: timing, context: context,
                     area: CGRect(x: 0, y: (size.height - 6) / 2, width: size.width, height: 6), failed: row.failed,
                     kind: colorCodeTypes ? DeveloperRequestKind(row) : nil)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    if Self.bar(segments, timing: timing, width: space.size.width, contains: point.x) { enter(timingCard) }
                    else { leave(timingCard) }
                case .ended:
                    leave(timingCard)
                }
            }
        }
        .onTapGesture { select(row.id, tab: .timing) }
        .popover(isPresented: showing(timingCard), arrowEdge: .bottom) {
            DeveloperNetworkTimingPopover(request: row, timing: extra?.timing ?? [:], origin: origin)
        }
        .accessibilityElement()
        .accessibilityLabel("Waterfall")
        .accessibilityValue(row.time.map(Self.duration) ?? "Pending")
        .accessibilityAction(named: "Show timing") { select(row.id, tab: .timing) }
    }

    /// Whether `x` is on the request's bar, give or take a few points.
    private static func bar(_ segments: [DeveloperNetworkTiming.Segment], timing: DeveloperNetworkTiming,
                            width: CGFloat, contains x: CGFloat) -> Bool {
        guard let first = segments.map(\.start).min(), let last = segments.map(\.end).max(),
              last >= timing.origin, first <= timing.end else { return false }
        let low = timing.fraction(first) * width
        let high = max(low + 2, timing.fraction(last) * width)
        return x >= low - 3 && x <= high + 3
    }

    /// The Initiator column: where the request was started from, as a
    /// file:line link that opens Sources there, with the call stack on
    /// hover when a script made it; otherwise the initiator's kind.
    @ViewBuilder
    private func initiator(_ row: DeveloperToolsSession.Request, extra: DeveloperNetworkTools.Extra?) -> some View {
        if let url = row.initiatorURL, !url.isEmpty {
            initiatorLink(row, url: url, extra: extra)
        } else {
            Text(row.initiator).foregroundStyle(.secondary).truncationMode(.middle)
        }
    }

    private func initiatorLink(_ row: DeveloperToolsSession.Request, url: String,
                               extra: DeveloperNetworkTools.Extra?) -> some View {
        typealias Frame = DeveloperRequestDetails.StackFrame
        let frames: [Frame] = extra?.initiatorStack ?? []
        // In the authored file when the script has a source map, as Chrome's column reads.
        let top: Frame? = frames.first { !$0.url.isEmpty }?.mapped(session.sourceMaps)
        let target: String = top?.url ?? url
        let line: Int? = top?.line ?? extra?.initiatorLine
        let suffix: String = line.map { ":\($0)" } ?? ""
        let title: String = top?.location ?? row.initiator + suffix
        let stackCard = HoverCard.initiator(row.id)
        let stack: [Frame] = frames.map { $0.mapped(session.sourceMaps) }
        return Button {
            session.revealSource(url: target, line: line ?? 1, column: top?.column)
        } label: {
            Text(title)
                .underline()
                .foregroundStyle(DeveloperToolsStyle.tint)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .help("Open \(target)" + suffix + " in Sources")
        .onHover { (inside: Bool) in
            if inside {
                NSCursor.pointingHand.push()
                if !stack.isEmpty { enter(stackCard) }
            } else {
                NSCursor.pop()
                leave(stackCard)
            }
        }
        .popover(isPresented: showing(stackCard), arrowEdge: .bottom) {
            DeveloperNetworkInitiatorPopover(frames: stack) { (frame: Frame) in
                leave(stackCard)
                session.revealSource(url: frame.url, line: frame.line ?? 1, column: frame.column)
            }
        }
        .accessibilityIdentifier("developer-network-initiator-link")
    }

    // MARK: Summary

    private func status(_ rows: [DeveloperToolsSession.Request], all: [DeveloperToolsSession.Request],
                        timing: DeveloperNetworkTiming) -> some View {
        func transferred(_ list: [DeveloperToolsSession.Request]) -> Int {
            list.reduce(0) { $0 + ($1.cached ? 0 : max(0, $1.bytes ?? 0)) }
        }
        func resources(_ list: [DeveloperToolsSession.Request]) -> Int {
            list.reduce(0) { $0 + max(0, tools.extras[$1.id]?.resourceSize ?? ($1.cached ? 0 : $1.bytes ?? 0)) }
        }
        let filtered = rows.count != all.count
        let finish = all.compactMap(\.ended).max().map { ($0 - timing.origin) * 1_000 }
        return HStack(spacing: DeveloperToolsStyle.gutter) {
            Text(filtered ? "\(rows.count) / \(all.count) requests" : "\(all.count) requests")
            verticalRule.frame(height: 10)
            Text(filtered ? "\(Self.byteCount(transferred(rows))) / \(Self.byteCount(transferred(all))) transferred"
                 : "\(Self.byteCount(transferred(all))) transferred")
            verticalRule.frame(height: 10)
            Text(filtered ? "\(Self.byteCount(resources(rows))) / \(Self.byteCount(resources(all))) resources"
                 : "\(Self.byteCount(resources(all))) resources")
            if let finish, finish >= 0 {
                verticalRule.frame(height: 10)
                Text("Finish: " + Self.seconds(finish))
            }
            if let ready = tools.domContentLoaded, ready >= timing.origin, !all.isEmpty {
                verticalRule.frame(height: 10)
                Text("DOMContentLoaded: " + Self.seconds((ready - timing.origin) * 1_000)).foregroundStyle(.blue)
            }
            if let load = tools.load, load >= timing.origin, !all.isEmpty {
                verticalRule.frame(height: 10)
                Text("Load: " + Self.seconds((load - timing.origin) * 1_000)).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
            if session.throttle != .unrestricted || tools.activeProfile != nil {
                Image(systemName: "speedometer")
                    .help(throttleHelp)
                    .accessibilityLabel("Network conditions active")
            }
            if tools.blockingActive {
                Image(systemName: "hand.raised")
                    .help("Request conditions are on")
                    .accessibilityLabel("Request conditions active")
            }
        }
        .lineLimit(1)
        .font(.system(size: 10.5))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.rowHeight)
        .background(DeveloperToolsStyle.chrome)
        .overlay(alignment: .top) { horizontalRule }
        .accessibilityIdentifier("developer-network-summary")
    }

    private func size(_ row: DeveloperToolsSession.Request, extra: DeveloperNetworkTools.Extra?) -> String {
        if extra?.source == "service-worker" { return "(ServiceWorker)" }
        if extra?.source == "memory-cache" { return "(memory cache)" }
        if row.cached { return "(disk cache)" }
        return row.bytes.map(Self.byteCount) ?? "—"
    }

    static func byteCount(_ bytes: Int) -> String {
        if bytes < 1_000 { return "\(bytes) B" }
        return bytes.formatted(.byteCount(style: .file))
    }

    static func duration(_ milliseconds: Double) -> String {
        milliseconds.formatted(.number.precision(.fractionLength(milliseconds < 10 && milliseconds > 0 ? 1 : 0))) + " ms"
    }

    /// As DevTools' summary writes times: milliseconds, then seconds.
    static func seconds(_ milliseconds: Double) -> String {
        milliseconds < 1_000 ? "\(Int(milliseconds.rounded())) ms"
            : (milliseconds / 1_000).formatted(.number.precision(.fractionLength(2))) + " s"
    }

    private func icon(_ symbol: String, _ label: String, color: Color = .secondary,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
                .frame(width: DeveloperToolsStyle.controlHeight, height: DeveloperToolsStyle.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var horizontalRule: some View {
        Rectangle().fill(DeveloperToolsStyle.rule.opacity(0.55)).frame(height: 1)
    }

    private var verticalRule: some View {
        Rectangle().fill(DeveloperToolsStyle.rule.opacity(0.32)).frame(width: 1)
    }

    private func barColor(_ phase: DeveloperNetworkTiming.Phase, kind: DeveloperRequestKind?) -> Color {
        if let kind, phase == .receiving || phase == .total {
            return DeveloperNetworkTypeColors.color(for: kind)
        }
        return phaseColor(phase).opacity(0.86)
    }

    private func phaseColor(_ phase: DeveloperNetworkTiming.Phase) -> Color {
        switch phase {
        case .beforeSend: .secondary
        case .waiting: DeveloperToolsStyle.tint
        case .receiving: .indigo
        case .total: DeveloperToolsStyle.tint.opacity(0.70)
        }
    }

    /// A request's bar. With `kind`, the download part (or the whole bar,
    /// when only its recorded time is known) takes the type's colour.
    private func draw(_ segments: [DeveloperNetworkTiming.Segment], timing: DeveloperNetworkTiming,
                      context: GraphicsContext, area: CGRect, failed: Bool, kind: DeveloperRequestKind? = nil) {
        for segment in segments {
            // Outside the span the ruler shows, as when part of the overview
            // is chosen: not drawn, rather than piled at an edge.
            guard segment.end >= timing.origin, segment.start <= timing.end else { continue }
            let x = min(max(0, area.width - 2), timing.fraction(segment.start) * area.width)
            let end = timing.fraction(segment.end) * area.width
            let rect = CGRect(x: area.minX + x, y: area.minY, width: max(2, end - x), height: area.height)
            context.fill(Path(roundedRect: rect, cornerRadius: 1),
                         with: .color(failed ? .red.opacity(0.76) : barColor(segment.phase, kind: kind)))
        }
    }
}

/// Whether Shift is held, for Shift-hover in the request list: a local
/// monitor of modifier changes while the panel is up, so pressing or
/// letting go of Shift over a row redraws its initiator chain.
@MainActor
final class DeveloperShiftKey: ObservableObject {
    @Published private(set) var held = false
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        held = NSEvent.modifierFlags.contains(.shift)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let shift = event.modifierFlags.contains(.shift)
            MainActor.assumeIsolated {
                if self?.held != shift { self?.held = shift }
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        held = false
    }
}

/// A request row's context menu, laid out as Chrome's.
private struct DeveloperNetworkRowMenu: View {
    let session: DeveloperToolsSession
    let tools: DeveloperNetworkTools
    @Binding var options: DeveloperNetworkView.Options
    let request: DeveloperToolsSession.Request
    let rows: [DeveloperToolsSession.Request]
    let filtered: Bool
    /// The list's columns, which Sort By offers.
    let columns: [DeveloperNetworkListColumn]
    let manageHeaders: () -> Void

    /// Documents, scripts and style sheets open in Sources, as in Chrome.
    private var opensInSources: Bool {
        [.document, .script, .stylesheet].contains(DeveloperRequestKind(request))
    }

    var body: some View {
        if DeveloperAIAssistance.enabled {
            // Chrome's first item: AI assistance, about this request.
            Button("Ask AI") { session.aiAssistance.askAboutRequest(request) }
            Divider()
        }
        if opensInSources {
            Button("Open in Sources panel") { session.revealSource(url: request.url, line: 1) }
        }
        Button("Open in new tab") { tools.openInNewTab(request) }
            .disabled(URL(string: request.url)?.scheme.map { ["http", "https"].contains($0) } != true)
        if DeveloperHeaderOverrides.target(for: request.url) != nil {
            Divider()
            Button("Override headers") { DeveloperHeaderOverridesEditor.open(for: request, session: session) }
            Button("Override content") { DeveloperHeaderOverridesEditor.overrideContent(of: request, session: session) }
                .disabled(request.ended == nil || request.failure != nil)
        }
        Divider()
        Button("Clear browser cache") { tools.clearBrowserCache() }
        Button("Clear browser cookies") { tools.clearBrowserCookies() }
        Divider()
        Menu("Copy") {
            Button("Copy URL") { DeveloperNetworkTools.copy(request.url) }
            Button("Copy as cURL") { tools.copy(request, as: { DeveloperRequestCopy.curl($0) }) }
                .disabled(request.url.hasPrefix("blob:"))
            Button("Copy as PowerShell") { tools.copy(request, as: { DeveloperRequestCopy.powerShell($0) }) }
                .disabled(request.url.hasPrefix("blob:"))
            Button("Copy as fetch") { tools.copy(request, as: { DeveloperRequestCopy.fetch($0) }) }
                .disabled(request.url.hasPrefix("blob:"))
            Button("Copy as fetch (Node.js)") { tools.copy(request, as: { DeveloperRequestCopy.fetch($0, node: true) }) }
                .disabled(request.url.hasPrefix("blob:"))
            Divider()
            Button("Copy request headers") { tools.copy(request, as: DeveloperRequestCopy.requestHeaders) }
            if request.status != nil {
                Button("Copy response headers") { tools.copy(request, as: DeveloperRequestCopy.responseHeaders) }
            }
            if request.ended != nil && request.failure == nil {
                Button("Copy response") { tools.copyResponse(request) }
            }
            Button("Copy stack trace") { tools.copy(request, as: { $0.stack.joined(separator: "\n") }) }
            Divider()
            Button(filtered ? "Copy all listed URLs" : "Copy all URLs") {
                DeveloperNetworkTools.copy(rows.filter { !$0.url.hasPrefix("blob:") }.map(\.url).joined(separator: "\n"))
            }
            Button(filtered ? "Copy all listed as cURL" : "Copy all as cURL") {
                tools.copyAll(rows, separator: " ;\n") { DeveloperRequestCopy.curl($0) }
            }
            Button(filtered ? "Copy all listed as PowerShell" : "Copy all as PowerShell") {
                tools.copyAll(rows, separator: ";\r\n") { DeveloperRequestCopy.powerShell($0) }
            }
            Button(filtered ? "Copy all listed as fetch" : "Copy all as fetch") {
                tools.copyAll(rows, separator: " ;\n") { DeveloperRequestCopy.fetch($0) }
            }
            Button(filtered ? "Copy all listed as fetch (Node.js)" : "Copy all as fetch (Node.js)") {
                tools.copyAll(rows, separator: " ;\n") { DeveloperRequestCopy.fetch($0, node: true) }
            }
            Button(filtered ? "Copy all listed as HAR (sanitized)" : "Copy all as HAR (sanitized)") {
                tools.copyHAR(rows, sanitize: true)
            }
            Button(filtered ? "Copy all listed as HAR (with sensitive data)" : "Copy all as HAR (with sensitive data)") {
                tools.copyHAR(rows, sanitize: false)
            }
        }
        Divider()
        Menu("Block requests") {
            if let pattern = DeveloperNetworkTools.urlPattern(for: request.url) {
                Button(tools.pattern(pattern) == nil ? "Block request URL" : "Unblock " + Self.trimmed(pattern)) {
                    tools.toggleBlock(pattern)
                }
            }
            if let pattern = DeveloperNetworkTools.domainPattern(for: request.url) {
                Button(tools.pattern(pattern) == nil ? "Block request domain" : "Unblock " + Self.trimmed(pattern)) {
                    tools.toggleBlock(pattern)
                }
            }
        }
        .disabled(DeveloperNetworkTools.domainPattern(for: request.url) == nil)
        if ["xhr", "fetch"].contains(request.type.lowercased()) {
            Button("Replay XHR") { tools.replay(request) }
        }
        Divider()
        Menu("Sort By") {
            ForEach(columns) { column in
                Button {
                    options.sort = column
                    options.ascending = true
                } label: {
                    if options.sort == column { Label(column.title, systemImage: "checkmark") } else { Text(column.title) }
                }
            }
        }
        Menu("Header Options") {
            DeveloperNetworkColumnMenu(options: $options, manageHeaders: manageHeaders)
        }
        Divider()
        let host = session.host
        Button(filtered ? "Save all listed as HAR (sanitized)…" : "Save all as HAR (sanitized)…") {
            tools.exportHAR(rows, sanitize: true, host: host)
        }
        Button(filtered ? "Save all listed as HAR (with sensitive data)…" : "Save all as HAR (with sensitive data)…") {
            tools.exportHAR(rows, sanitize: false, host: host)
        }
        Button("Save as…") { tools.saveResponse(request) }
            .disabled(request.ended == nil || request.failure != nil)
    }

    private static func trimmed(_ text: String) -> String {
        guard text.count > 20 else { return text }
        return String(text.prefix(10)) + "…" + String(text.suffix(9))
    }
}
