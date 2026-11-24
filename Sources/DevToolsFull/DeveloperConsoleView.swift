import AppKit
import SwiftUI

/// Chrome's Console panel: the toolbar (clear, filter, levels, preserve
/// log), the message list with object trees, tables, groups and stack
/// traces, and the prompt with history, completions and eager preview.
struct DeveloperConsoleView: View {
    @ObservedObject var session: DeveloperToolsSession

    var body: some View {
        DeveloperConsoleContent(session: session, store: session.consoleStore)
    }
}

enum ConsoleTheme {
    private static func dynamic(_ light: (Double, Double, Double), _ dark: (Double, Double, Double), alpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: alpha)
        })
    }

    static let warningBackground = dynamic((254, 247, 224), (65, 56, 26))
    static let warningBorder = dynamic((253, 226, 154), (102, 86, 31))
    static let warningText = dynamic((94, 59, 0), (253, 214, 99))
    static let warningIcon = dynamic((227, 163, 0), (253, 214, 99))
    static let errorBackground = dynamic((252, 235, 235), (78, 23, 23))
    static let errorBorder = dynamic((248, 203, 199), (115, 36, 36))
    static let errorText = dynamic((197, 34, 31), (242, 139, 130))
    static let property = dynamic((136, 19, 145), (227, 110, 236))
    static let string = dynamic((196, 26, 22), (242, 139, 84))
    static let number = dynamic((26, 26, 166), (153, 128, 255))
    static let keyword = dynamic((13, 34, 170), (153, 128, 255))
    static let null = dynamic((128, 134, 139), (154, 160, 166))
    static let node = dynamic((136, 18, 128), (93, 176, 215))
    static let verbose = dynamic((26, 115, 232), (138, 180, 248))
    static let badge = dynamic((95, 99, 104), (154, 160, 166))
    /// Chrome's search highlights: every match, and the current one.
    static let findMatch = dynamic((255, 240, 136), (102, 90, 20))
    static let findCurrent = dynamic((255, 176, 64), (176, 110, 20))
    /// Chrome's element tree colours (tag, attribute name and value).
    static let tag = dynamic((136, 18, 128), (93, 176, 215))
    static let attribute = dynamic((153, 69, 0), (155, 187, 220))
    static let attributeValue = dynamic((26, 26, 166), (242, 151, 102))
    static let selection = dynamic((207, 232, 252), (45, 72, 104))

    static func color(for object: ConsoleRemoteObject) -> Color? {
        switch object.type {
        case "string": return string
        case "number", "bigint": return number
        case "boolean": return keyword
        case "undefined": return null
        case "symbol": return string
        default: return object.subtype == "null" ? null : object.isNode ? node : object.subtype == "regexp" ? string : nil
        }
    }
}

private struct DeveloperConsoleContent: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var store: DeveloperConsoleStore
    @ObservedObject var debugger: DeveloperDebugger
    @FocusState private var findFocused: Bool

    init(session: DeveloperToolsSession, store: DeveloperConsoleStore) {
        self.session = session
        self.store = store
        self.debugger = session.debugger
    }

    var body: some View {
        // Laid out again only when the messages or a filter change, not on
        // every publish of the session.
        let layout = store.layout.layout(session.console, levels: store.levels, filter: store.filter, toggled: store.toggledGroups,
                                         settings: store.settings, sidebar: store.sidebar)
        let rows = layout.rows
        let hidden = layout.hidden
        let matches = store.findShown ? store.layout.matches(store.findQuery) : []
        VStack(spacing: 0) {
            toolbar(hidden: hidden, rows: rows)
            if store.showsSettings { settingsPane }
            if store.findShown { findBar(matches) }
            HStack(spacing: 0) {
                if store.showsSidebar {
                    ConsoleSidebarView(session: session, store: store)
                        .frame(width: 190)
                    Rectangle().fill(DeveloperToolsStyle.rule).frame(width: 1)
                }
                VStack(spacing: 0) {
                    if !store.liveExpressions.isEmpty { ConsoleLiveExpressionsView(session: session, store: store) }
                    ScrollViewReader { scroll in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(rows) { row in
                                    ConsoleMessageRow(session: session, store: store, row: row,
                                                      find: findContext(row, matches))
                                        .id(row.id)
                                }
                                ConsolePrompt(session: session, store: store)
                                    .id("console-prompt")
                            }
                            .background(ConsoleListMonitor(
                                pinned: { store.pinnedToBottom = $0 },
                                mouseDown: { inside in
                                    store.listActive = inside
                                    if store.allSelected { store.allSelected = false }
                                },
                                key: { handleKey($0, rows: rows) }))
                        }
                        .background(DeveloperToolsStyle.surface)
                        // As in Chrome DevTools: a new message keeps the
                        // list at the bottom only while it is there already.
                        .onChange(of: session.console.last?.id) { _, id in
                            if id != nil, ConsoleScrollPin.shouldFollow(pinned: store.pinnedToBottom, ranCommand: false) {
                                scroll.scrollTo("console-prompt", anchor: .bottom)
                            }
                        }
                        // Running a command always shows it and its result.
                        .onChange(of: store.followRequest) { _, _ in
                            DispatchQueue.main.async { scroll.scrollTo("console-prompt", anchor: .bottom) }
                        }
                        .onChange(of: store.findIndex) { _, index in
                            if let index, matches.indices.contains(index) { scroll.scrollTo(matches[index].row, anchor: .center) }
                        }
                        .onChange(of: store.findQuery) { _, _ in
                            store.findIndex = matches.isEmpty ? nil : 0
                            if let first = matches.first { scroll.scrollTo(first.row, anchor: .center) }
                        }
                        // ⌃` brings the prompt into view as it takes the keyboard.
                        .onChange(of: store.promptFocus) { _, _ in
                            DispatchQueue.main.async { scroll.scrollTo("console-prompt", anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .task {
            // The context selector's list, kept current while the Console
            // shows, as Chrome's follows contexts coming and going.
            while !Task.isCancelled {
                session.refreshConsoleContexts()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .accessibilityIdentifier("developer-tools-console")
    }

    /// The current find match, when it is in this row, and the text to mark.
    private func findContext(_ row: ConsoleRow, _ matches: [ConsoleFindMatch]) -> ConsoleRowFind? {
        guard store.findShown, !store.findQuery.isEmpty else { return nil }
        var current: Int?
        if let index = store.findIndex, matches.indices.contains(index), matches[index].row == row.id { current = matches[index].occurrence }
        return ConsoleRowFind(query: store.findQuery, current: current)
    }

    /// ⌘A selects every message shown and ⌘C then copies them, as in
    /// Chrome, while the last click was in the list and no field edits.
    private func handleKey(_ event: NSEvent, rows: [ConsoleRow]) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        guard store.listActive, !ConsoleListMonitor.editingText(in: event.window) else { return false }
        if flags == .command, key == "a" {
            store.allSelected = true
            return true
        }
        if flags == .command, key == "c", store.allSelected {
            DeveloperToolsSession.copyToPasteboard(session.consoleText(rows))
            return true
        }
        if event.keyCode == 53, store.allSelected {
            store.allSelected = false
            return true
        }
        return false
    }

    /// Chrome's console search bar: matches, the current one of them,
    /// and arrows (or Return and ⇧Return) to step through.
    private func findBar(_ matches: [ConsoleFindMatch]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find", text: $store.findQuery)
                        .textFieldStyle(.plain)
                        .focused($findFocused)
                        .onSubmit {
                            step(matches, backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                            findFocused = true
                        }
                        .onExitCommand { closeFind() }
                        .accessibilityLabel("Find in console")
                    if !store.findQuery.isEmpty {
                        Text(matches.isEmpty ? "No matches" : "\((store.findIndex ?? 0) + 1) of \(matches.count)")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .developerToolsField()
                .frame(maxWidth: 360)
                DeveloperPanelIcon(symbol: "chevron.up", title: "Search previous (⇧Return)") { step(matches, backwards: true) }
                    .disabled(matches.isEmpty)
                DeveloperPanelIcon(symbol: "chevron.down", title: "Search next (Return)") { step(matches, backwards: false) }
                    .disabled(matches.isEmpty)
                Spacer(minLength: 0)
                Button("Cancel") { closeFind() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.toolbarHeight)
            .background(DeveloperToolsStyle.chrome)
            Divider()
        }
        .onAppear { findFocused = true }
        // ⌘F again, the bar already up (DeveloperToolsKeys).
        .onChange(of: store.findFocus) { _, _ in findFocused = true }
    }

    private func step(_ matches: [ConsoleFindMatch], backwards: Bool) {
        store.findIndex = ConsoleFind.step(store.findIndex, count: matches.count, backwards: backwards)
    }

    private func closeFind() {
        store.findShown = false
        store.findIndex = nil
    }

    /// Chrome's context selector: `top`, then each frame and extension
    /// content script. While paused, the prompt runs in the selected call
    /// frame instead, as in Chrome.
    private var contextSelector: some View {
        let chosen = store.context
        let others = store.contexts.filter { !$0.isTop && !$0.isWorker }
        let workers = store.contexts.filter(\.isWorker)
        let title = chosen?.title ?? "top"
        return Menu {
            Toggle("top", isOn: Binding(get: { chosen == nil }, set: { _ in store.context = nil }))
            ForEach(others) { context in
                Toggle(String(repeating: "    ", count: min(context.depth, 6)) + context.title,
                       isOn: Binding(get: { chosen?.id == context.id }, set: { _ in store.context = context }))
            }
            // Dedicated workers, each its own context, as Chrome lists them.
            if !workers.isEmpty { Divider() }
            ForEach(workers) { context in
                Toggle(isOn: Binding(get: { chosen?.id == context.id }, set: { _ in store.context = context })) {
                    Label(context.title, systemImage: "gearshape")
                }
                .help(context.url)
            }
        } label: {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(debugger.frame.map { "JavaScript context: paused in \($0.functionName); the prompt evaluates in this call frame" }
              ?? "JavaScript context: " + title)
        .accessibilityLabel("JavaScript context")
        .accessibilityValue(title)
    }

    /// Chrome's order: sidebar, clear | context | live expression | filter,
    /// levels, hidden count, settings.
    private func toolbar(hidden: Int, rows: [ConsoleRow]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                DeveloperPanelIcon(symbol: "sidebar.left", title: store.showsSidebar ? "Hide Console sidebar" : "Show Console sidebar",
                                   active: store.showsSidebar) { store.showsSidebar.toggle() }
                DeveloperPanelIcon(symbol: "nosign", title: "Clear console (⌘K)", action: session.clearConsole)
                Divider().frame(height: 14)
                contextSelector
                // ⌘F opens the search bar over the messages, as in Chrome.
                Button("") {
                    store.findShown = true
                    findFocused = true
                }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
                DeveloperPanelIcon(symbol: "eye", title: "Create live expression") {
                    store.liveExpressions.append(ConsoleLiveExpression(expression: ""))
                }
                Divider().frame(height: 14)
                HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                    TextField("Filter", text: $store.filter).textFieldStyle(.plain)
                        .help("e.g. /event\\d/ -cdn url:a.com")
                    if !store.filter.isEmpty {
                        DeveloperPanelIcon(symbol: "xmark.circle.fill", title: "Clear filter", size: 16) { store.filter = "" }
                    }
                }
                .developerToolsField()
                .frame(minWidth: 90, idealWidth: 180, maxWidth: 260)
                levelsMenu
                Spacer(minLength: DeveloperToolsStyle.controlSpacing)
                DeveloperIssuesBadge(session: session, labelled: true)
                if hidden > 0 {
                    Text("\(hidden) hidden").foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                DeveloperPanelIcon(symbol: "gearshape", title: "Console settings", active: store.showsSettings) {
                    store.showsSettings.toggle()
                }
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.toolbarHeight)
            .background(DeveloperToolsStyle.chrome)
            Divider()
        }
    }

    private var levelsMenu: some View {
        let controlledBySidebar = store.showsSidebar && store.sidebar.group.levels != nil
        return Menu {
            ForEach(ConsoleLevel.allCases) { level in
                Toggle(level.rawValue, isOn: Binding(
                    get: { store.levels.contains(level) },
                    set: { on in if on { store.levels.insert(level) } else { store.levels.remove(level) } }))
            }
            Divider()
            Button("Default") { store.levels = ConsoleLevel.defaults }
        } label: {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                Text(ConsoleLevel.label(store.levels))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(controlledBySidebar)
        .help(controlledBySidebar ? "Log levels are controlled by the Console sidebar" : "Log level: " + ConsoleLevel.label(store.levels))
        .accessibilityLabel("Log levels")
        .accessibilityValue(ConsoleLevel.label(store.levels))
    }

    /// renderSettingsPane in Chrome's ConsoleView.ts, in its order and words.
    private var settingsPane: some View {
        VStack(spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow {
                    Toggle("Hide network", isOn: Binding(get: { !store.settings.networkMessages },
                                                         set: { store.settings.networkMessages = !$0 }))
                        .toggleStyle(.developerCheckbox)
                        .help("Hide network messages")
                    setting("Log XMLHttpRequests", "Log XMLHttpRequests", \.logXMLHttpRequests)
                }
                GridRow {
                    Toggle("Preserve log", isOn: $session.preserveConsoleLog)
                        .toggleStyle(.developerCheckbox)
                        .help("Don’t clear log on page reload / navigation")
                    setting("Eager evaluation", "Eagerly evaluate text in the prompt", \.eagerEvaluation)
                }
                GridRow {
                    Toggle("Selected context only", isOn: .constant(false))
                        .toggleStyle(.developerCheckbox)
                        .disabled(true)
                        .help("Only show messages from the current context (top, iframe, worker, extension). "
                              + "WebKit doesn’t tell the console which context a message came from.")
                    setting("Autocomplete from history", "Accept autocompletion suggestions from history", \.historyAutocomplete)
                }
                GridRow {
                    setting("Group similar messages in console", "Group similar messages in console", \.groupSimilar)
                    setting("Evaluate triggers user activation", "Treat code evaluation as user action", \.userActivation)
                }
                GridRow {
                    setting("Show CORS errors in console", "Show CORS errors in console", \.corsErrors)
                    setting("Show timestamps", "Show timestamps", \.showTimestamps)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, DeveloperToolsStyle.gutter + 4)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DeveloperToolsStyle.chrome)
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Console settings")
    }

    private func setting(_ title: String, _ help: String, _ key: WritableKeyPath<ConsoleSettings, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { store.settings[keyPath: key] }, set: { store.settings[keyPath: key] = $0 }))
            .toggleStyle(.developerCheckbox)
            .help(help)
    }
}

/// Chrome's Console sidebar: message counts by kind, each split by file.
private struct ConsoleSidebarView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var store: DeveloperConsoleStore
    @State private var open = Set<ConsoleSidebarGroup>()

    var body: some View {
        let tally = store.layout.tally(session.console)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ConsoleSidebarGroup.allCases) { group in
                    let entry = tally[group] ?? (0, [])
                    item(group: group, url: nil, title: group.title(entry.count), symbol: group.symbol,
                         disclosure: !entry.files.isEmpty, depth: 0)
                    if open.contains(group) {
                        ForEach(entry.files, id: \.url) { file in
                            item(group: group, url: file.url,
                                 title: file.url.isEmpty ? "<other>" : ConsoleFormat.location(file.url, line: nil),
                                 symbol: "doc", disclosure: false, depth: 1, count: file.count)
                                .help(file.url.isEmpty ? "Messages without a source file" : file.url)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .background(DeveloperToolsStyle.chrome)
    }

    private func item(group: ConsoleSidebarGroup, url: String?, title: String, symbol: String,
                      disclosure: Bool, depth: Int, count: Int? = nil) -> some View {
        let selected = store.sidebar == ConsoleSidebarFilter(group: group, url: url)
        return HStack(spacing: 4) {
            if disclosure {
                Button {
                    open.formSymmetricDifference([group])
                } label: {
                    Image(systemName: open.contains(group) ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                        .font(.system(size: 7)).foregroundStyle(.secondary).frame(width: 11)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 11, height: 1)
            }
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(group == .errors ? ConsoleTheme.errorText : group == .warnings ? ConsoleTheme.warningIcon : .secondary)
                .frame(width: 14)
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
            if let count { Text("\(count)").foregroundStyle(.secondary) }
        }
        .padding(.leading, 6 + CGFloat(depth) * 14)
        .padding(.trailing, 6)
        .frame(height: DeveloperToolsStyle.rowHeight)
        .background(selected ? DeveloperToolsStyle.selected : .clear)
        .contentShape(Rectangle())
        .onTapGesture { store.sidebar = ConsoleSidebarFilter(group: group, url: url) }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Chrome's live expressions (ConsolePinPane.ts): pinned above the log,
/// evaluated again and again while the Console shows.
private struct ConsoleLiveExpressionsView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var store: DeveloperConsoleStore
    @FocusState private var focused: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach($store.liveExpressions) { $item in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        TextField("Expression", text: $item.expression)
                            .textFieldStyle(.plain)
                            .font(DeveloperToolsStyle.code)
                            .focused($focused, equals: item.id)
                            .accessibilityLabel("Live expression editor")
                        DeveloperPanelIcon(symbol: "xmark", title: "Remove expression: " + item.expression, size: 16) {
                            store.liveExpressions.removeAll { $0.id == item.id }
                        }
                    }
                    Text(item.failed || item.result == nil ? "not available" : item.result ?? "")
                        .font(DeveloperToolsStyle.code)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, DeveloperToolsStyle.gutter + 4)
                .padding(.vertical, 3)
                .onAppear { if item.expression.isEmpty { focused = item.id } }
                .onChange(of: focused) { _, id in store.editingLive = id }
                Divider()
            }
        }
        .background(DeveloperToolsStyle.chrome)
        .contextMenu {
            Button("Remove all expressions") { store.liveExpressions = [] }
        }
        .task {
            while !Task.isCancelled {
                await session.refreshLiveExpressions()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

// MARK: - Messages

/// What the Find bar marks in one row: its text, and which of the row's
/// matches is the current one.
struct ConsoleRowFind: Equatable {
    let query: String
    let current: Int?
}

/// A message's text as the list shows it, which Find searches too.
enum ConsoleRowContent {
    /// A message that is just one DOM node draws as Chrome's element tree.
    static func nodeRoot(_ line: DeveloperToolsSession.ConsoleLine) -> ConsoleRemoteObject? {
        let parts = Self.segments(line), type = line.details?.type
        guard type != "dir", type != "result" || line.level != "error", parts.count == 1,
              case .object(let object, _) = parts[0], object.isNode, object.objectId != nil else { return nil }
        return object
    }

    /// The logged objects a message opens under it.
    @MainActor static func objects(_ line: DeveloperToolsSession.ConsoleLine, store: DeveloperConsoleStore) -> [ConsoleRemoteObject] {
        guard nodeRoot(line) == nil else { return [] }
        return Self.segments(line).compactMap {
            // A custom formatter's header has its own triangle.
            if case .object(let object, _) = $0, object.expandable, store.customHeader(object) == nil { return object }
            return nil
        }
    }


    /// Worked out once per message: rows read these several times a pass.
    static func segments(_ line: DeveloperToolsSession.ConsoleLine) -> [ConsoleSegment] {
        ConsoleLineCache.shared.segments(line) { build(line) }
    }

    /// A JavaScript error as Chrome words it: an exception the page didn't
    /// catch is "Uncaught …", a rejection nothing handled "Uncaught (in
    /// promise) …". WebKit's own notices, such as a fetch blocked by
    /// access control, are neither: they have no stack and no error name.
    static func uncaught(_ line: DeveloperToolsSession.ConsoleLine) -> String {
        let text = line.text
        let rejection = "Unhandled Promise Rejection: "
        if text.hasPrefix(rejection) { return "Uncaught (in promise) " + text.dropFirst(rejection.count) }
        if text.hasPrefix("Uncaught") { return text }
        let named = text.range(of: #"^([A-Za-z_$][\w$]*)?(Error|Exception):"#, options: .regularExpression) != nil
        let thrown = line.details?.stackTrace.isEmpty == false
        return named || thrown ? "Uncaught " + text : text
    }

    private static func build(_ line: DeveloperToolsSession.ConsoleLine) -> [ConsoleSegment] {
        let isError = line.level == "error"
        guard let details = line.details, !details.parameters.isEmpty, !(details.source == "javascript" && isError) else {
            if line.details?.source == "javascript", isError { return [.text(uncaught(line), .plain)] }
            return [.text(line.text, .plain)]
        }
        if details.type == "result" {
            return isError ? [.text(line.text, .plain)] : [.object(details.parameters[0], .plain)]
        }
        if details.type == "table" { return [.object(details.parameters[0], .plain)] }
        return ConsoleFormat.segments(details.parameters)
    }

    static func displayText(_ line: DeveloperToolsSession.ConsoleLine) -> String {
        if line.details?.type == "clear" || line.details?.type == "navigation" { return line.text }
        return ConsoleLineCache.shared.displayText(line) { ConsoleFormat.plain(segments(line)) }
    }
}

private struct ConsoleMessageRow: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var store: DeveloperConsoleStore
    let row: ConsoleRow
    var find: ConsoleRowFind?
    /// The pointer is over the row, which shows Chrome's insight button.
    @State private var hovering = false

    private var line: DeveloperToolsSession.ConsoleLine { row.line }

    private var details: ConsoleMessageDetails? { line.details }
    private var isWarning: Bool { line.level == "warning" }
    private var isError: Bool { line.level == "error" }

    private var segments: [ConsoleSegment] { ConsoleRowContent.segments(line) }

    private var nodeRoot: ConsoleRemoteObject? { ConsoleRowContent.nodeRoot(line) }
    private var objects: [ConsoleRemoteObject] { ConsoleRowContent.objects(line, store: store) }

    /// Errors among the arguments (or a result that is one), whose stack
    /// Chrome prints in full under the message.
    private var errors: [ConsoleRemoteObject] {
        guard let details, details.source != "javascript" || !isError else { return [] }
        let candidates = details.type == "result" ? Array(details.parameters.prefix(1)) : details.parameters
        return candidates.filter { $0.subtype == "error" && $0.objectId != nil }
    }

    /// The first node among the arguments, which hovering the row
    /// highlights on the page, as Chrome does for a logged node.
    private var hoverNode: ConsoleRemoteObject? {
        details?.parameters.first { $0.isNode && $0.objectId != nil }
    }

    private var stack: [ConsoleCallFrame] {
        guard let details, !details.stackTrace.isEmpty else { return [] }
        let type = details.type ?? "log"
        guard type == "trace" || type == "assert" || isError || isWarning else { return [] }
        return details.stackTrace
    }

    /// console.trace opens its stack at once; errors and warnings wait for
    /// the triangle, as in Chrome.
    private var stackOpen: Bool {
        (details?.type == "trace") != store.expandedStacks.contains(line.id)
    }

    private var objectKey: String { line.id.uuidString }

    /// The worker the message came from, if it came from one.
    private var worker: DeveloperWorker? { session.worker(details?.targetID) }

    private var open: Bool {
        if row.opensGroup { return !row.collapsed }
        if !objects.isEmpty { return store.expanded.contains(objectKey) }
        return !stack.isEmpty && stackOpen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                leading
                if store.settings.showTimestamps, let stamp = details?.timestamp {
                    Text(ConsoleFormat.timestamp(stamp))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                messageColumn
                messageSource
            }
            if !objects.isEmpty, store.expanded.contains(objectKey) {
                expandedObjects
            }
            if !stack.isEmpty, stackOpen {
                ConsoleStackView(session: session, frames: stack)
                    .padding(.leading, 30)
            }
        }
        .font(DeveloperToolsStyle.code)
        .foregroundStyle(textColor)
        .padding(.leading, DeveloperToolsStyle.gutter + CGFloat(row.depth) * 14)
        .padding(.trailing, DeveloperToolsStyle.gutter)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
        .overlay(alignment: .top) {
            Rectangle().fill(borderColor).frame(height: 1)
        }
        .overlay(alignment: .topTrailing) {
            // Over the row's end, as Chrome floats it, so the message
            // doesn't reflow when the pointer comes and goes.
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if let hoverNode, nodeRoot == nil { session.highlightConsoleNode(inside ? hoverNode : nil, targetID: details?.targetID) }
        }
        .consoleMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLevel + ConsoleLayout.searchableText(line))
    }


    private var textColor: Color {
        if isError { return ConsoleTheme.errorText }
        if isWarning { return ConsoleTheme.warningText }
        return line.level == "debug" ? ConsoleTheme.verbose : Palette.ink
    }

    private var backgroundColor: Color {
        if store.allSelected { return ConsoleTheme.selection }
        if isError { return ConsoleTheme.errorBackground }
        return isWarning ? ConsoleTheme.warningBackground : Color.clear
    }

    private var borderColor: Color {
        if isError { return ConsoleTheme.errorBorder }
        return isWarning ? ConsoleTheme.warningBorder : DeveloperToolsStyle.rule.opacity(0.6)
    }

    /// The message itself, then any error stacks and a table under it.
    private var messageColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let nodeRoot {
                ConsoleNodeLine(session: session, store: store, object: nodeRoot, summary: nil,
                                targetID: details?.targetID, key: objectKey + "/node", depth: 0)
            } else if store.settings.customFormatters {
                ConsoleCustomFormattedMessage(session: session, store: store, segments: segments,
                                              targetID: details?.targetID, key: objectKey) { message }
            } else {
                message
            }
            ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                ConsoleErrorStackView(session: session, store: store, object: error, targetID: details?.targetID)
            }
            if let table {
                ConsoleTableView(table: table)
                    .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Where the message came from, at the right: its script, or its worker.
    @ViewBuilder
    private var messageSource: some View {
        if let link = shownLink {
            let workerLine: String = worker.map { "Worker: \($0.title)\n" } ?? ""
            let lineSuffix: String = link.line.map { ":\($0)" } ?? ""
            Button { session.revealConsoleSource(url: link.url, line: link.line) } label: {
                Text(ConsoleFormat.location(link.url, line: link.line))
                    .underline()
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 180, alignment: .trailing)
            .help(workerLine + link.url + lineSuffix)
        } else if let worker {
            // A message from a worker with no place of its own: the worker, as its source.
            Label(worker.title, systemImage: "gearshape")
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 180, alignment: .trailing)
                .help("Worker: " + worker.url)
        }
    }

    /// The logged objects, opened under the message.
    private var expandedObjects: some View {
        let objects: [ConsoleRemoteObject] = self.objects
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(objects.enumerated()), id: \.offset) { index, object in
                if objects.count > 1 {
                    ConsoleValueLine(session: session, store: store, name: nil, object: object,
                                     targetID: details?.targetID, key: objectKey + "/\(index)", depth: 0)
                } else {
                    ConsoleObjectChildren(session: session, store: store, object: object,
                                          targetID: details?.targetID, key: objectKey + "/0", depth: 0)
                }
            }
        }
        .padding(.leading, 18)
    }

    /// The items of Chrome's console context menu (ConsoleView.ts) and its
    /// object menu (ObjectPropertiesSection): store, copy, hide, save.
    @ViewBuilder
    private var menu: some View {
        if let object = details?.parameters.first(where: { $0.expandable }) {
            Button("Store as global variable") { session.storeConsoleObjectAsGlobal(object, targetID: details?.targetID) }
            Button("Copy object") { session.copyConsoleObject(object, targetID: details?.targetID) }
            if object.type == "function" {
                Button("Show function definition") { session.showConsoleFunctionDefinition(object, targetID: details?.targetID) }
            }
            Divider()
        } else if let string = details?.parameters.first(where: { $0.type == "string" }), details?.type == "result" {
            Button("Copy string contents") { copy(string.plainText) }
            Divider()
        }
        Button("Copy message") { copy(ConsoleLayout.searchableText(line).trimmingCharacters(in: .whitespaces)) }
        // The ⌘A selection, or this message, as rich text in its %c styles.
        Button("Copy visible styled selection") { ConsoleStyledCopy.copy(store.allSelected ? store.layout.rows : [row]) }
        if let link = locationLink {
            Button("Copy link address") { copy(link.url) }
            Button("Hide messages from " + ConsoleFormat.location(link.url, line: nil)) {
                let term = "-url:" + link.url
                store.filter = store.filter.isEmpty ? term : store.filter + " " + term
            }
        }
        if !stack.isEmpty {
            Button("Copy stack trace") { copy(stack.map { "\($0.name) @ \($0.url):\($0.lineNumber)" }.joined(separator: "\n")) }
        }
        Divider()
        Button("Expand all") { store.setAllExpanded(true, lines: session.console, load: { session.loadConsoleProperties($0, targetID: $1) }) }
        Button("Collapse all") { store.setAllExpanded(false, lines: session.console) }
        Divider()
        Button("Clear console", action: session.clearConsole)
        Button("Clear console history") { store.history = [] }
        Divider()
        // The rows as last laid out, read when chosen, so rows need not
        // each carry the whole list.
        Button("Copy all messages") { copy(session.consoleText(store.layout.rows)) }
        Button("Save as…") { session.saveConsole(store.layout.rows) }
    }

    private var accessibilityLevel: String {
        switch line.level {
        case "error": return "Error: "
        case "warning": return "Warning: "
        default: return ""
        }
    }

    @ViewBuilder
    private var leading: some View {
        let disclosure = hasDisclosure
        HStack(spacing: 2) {
            if row.count > 1 {
                Text("\(row.count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 15, minHeight: 13)
                    .background(isError ? ConsoleTheme.errorText : isWarning ? ConsoleTheme.warningIcon : ConsoleTheme.badge,
                                in: Capsule())
                    .accessibilityLabel("Repeated \(row.count) times")
            } else if let icon {
                Image(systemName: icon.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(icon.color)
                    .frame(width: 13)
            } else {
                Color.clear.frame(width: 13, height: 1)
            }
            if disclosure {
                ConsoleDisclosure(open: open) { toggle(recursively: NSEvent.modifierFlags.contains(.option)) }
            } else {
                Color.clear.frame(width: 11, height: 1)
            }
        }
    }

    private var icon: (symbol: String, color: Color)? {
        switch line.level {
        case "error": return ("xmark.circle.fill", ConsoleTheme.errorText)
        case "warning": return ("exclamationmark.triangle.fill", ConsoleTheme.warningIcon)
        case "command": return ("chevron.right", DeveloperToolsStyle.tint)
        case "result": return ("chevron.left", .secondary)
        default: return nil
        }
    }

    private var hasDisclosure: Bool { row.opensGroup || !objects.isEmpty || !stack.isEmpty }

    /// ⌥ opens the object and everything in it a few levels down, as
    /// Chrome's ⌥-click on a triangle does.
    private func toggle(recursively: Bool = false) {
        if row.opensGroup {
            store.toggledGroups.formSymmetricDifference([line.id])
        } else if !objects.isEmpty {
            if store.expanded.contains(objectKey) {
                store.collapse(objectKey, recursively: recursively)
            } else {
                store.expanded.insert(objectKey)
                if objects.count == 1 {
                    if recursively { store.deepExpansion[objectKey + "/0"] = 4 }
                    session.loadConsoleProperties(objects[0], targetID: details?.targetID)
                } else if recursively {
                    for index in objects.indices { store.expandRecursively(objectKey + "/\(index)") }
                }
            }
            if !stack.isEmpty { store.expandedStacks.formSymmetricDifference([line.id]) }
        } else {
            store.expandedStacks.formSymmetricDifference([line.id])
        }
    }

    /// As in Chrome DevTools, a click on the message text opens or closes
    /// it like its triangle; a drag still selects text.
    private func tapMessage() {
        guard hasDisclosure else { return }
        toggle(recursively: NSEvent.modifierFlags.contains(.option))
    }

    private var table: ConsoleTable? {
        guard details?.type == "table", let first = details?.parameters.first else { return nil }
        let columns = details?.parameters.dropFirst().first?.preview?.properties.compactMap { $0.type == "string" ? $0.value : nil }
        return ConsoleTable(first, columns: columns?.isEmpty == false ? columns : nil)
    }

    @ViewBuilder
    private var message: some View {
        if details?.type == "clear" || details?.type == "navigation" {
            Text(ConsoleText.marked(AttributedString(line.text), find))
                .italic().foregroundStyle(.secondary).textSelection(.enabled)
        } else {
            // A table draws its argument, then the grid, as Chrome does.
            Text(ConsoleText.attributed(segments, base: nil, find: find))
                .textSelection(.enabled)
                .fontWeight(row.opensGroup ? .semibold : .regular)
                .simultaneousGesture(TapGesture().onEnded { tapMessage() })
                .environment(\.openURL, OpenURLAction { url in
                    if let index = ConsoleText.nodeIndex(url), segments.indices.contains(index),
                       case .object(let object, _) = segments[index] {
                        session.revealConsoleNode(object, targetID: details?.targetID)
                    } else {
                        session.openConsoleLink(url)
                    }
                    return .handled
                })
        }
    }

    private var locationLink: (url: String, line: Int?)? {
        guard line.level != "command", line.level != "result", details?.type != "result" else { return nil }
        if let url = line.url, Self.isSource(url) { return (url, line.line) }
        if let frame = details?.stackTrace.first(where: { Self.isSource($0.url) }) { return (frame.url, frame.lineNumber) }
        // Code with no address, as Chrome links it: VM<script id>:line.
        if let frame = details?.stackTrace.first(where: { !$0.asyncBoundary }), frame.url.isEmpty,
           let id = frame.scriptID, !id.isEmpty {
            return (DeveloperToolsSession.anonymousScriptURL(id), frame.lineNumber)
        }
        return nil
    }

    /// WebKit gives some messages "undefined" or "[native code]" for a
    /// place, which is no file to link to.
    static func isSource(_ url: String) -> Bool {
        !url.isEmpty && url != "undefined" && url != "[native code]"
    }

    /// The link as the row shows it: in the authored file when the script
    /// has a source map, as Chrome's links read. Filters and Copy link
    /// address keep the compiled address the message came from.
    private var shownLink: (url: String, line: Int?)? {
        guard let link = locationLink else { return nil }
        let top = details?.stackTrace.first { Self.isSource($0.url) }
        let column = line.url.map(Self.isSource) == true ? details?.column
            : top.flatMap { $0.url == link.url && $0.lineNumber == link.line ? $0.columnNumber : nil }
        return session.sourceMaps.linked(url: link.url, line: link.line, column: column)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Builds a line's styled text: `%c` styles, value colours, links on
/// DOM nodes so a click reveals them in Elements, links on the URLs in
/// logged strings, and the Find bar's matches.
enum ConsoleText {
    static func attributed(_ segments: [ConsoleSegment], base: Color?, find: ConsoleRowFind? = nil) -> AttributedString {
        var output = AttributedString()
        for (index, segment) in segments.enumerated() {
            switch segment {
            case .text(let text, let style):
                var piece = linked(text)
                apply(style, to: &piece)
                output += piece
            case .object(let object, let style):
                let text = ConsoleFormat.inline(object)
                var piece = object.type == "string" ? linked(text) : AttributedString(text)
                if let color = ConsoleTheme.color(for: object) { piece.foregroundColor = color }
                if object.subtype == "error" { piece.foregroundColor = nil }
                if object.isNode, object.objectId != nil { piece.link = URL(string: "search-console://node/\(index)") }
                if object.type == "function" { piece.font = .system(size: 11, design: .monospaced).italic() }
                if !style.isPlain { apply(style, to: &piece) }
                output += piece
            }
        }
        return marked(output, find)
    }

    /// As in Chrome DevTools, every URL in a logged string is a link.
    static func linked(_ text: String) -> AttributedString {
        let links = ConsoleLinks.find(in: text)
        guard !links.isEmpty else { return AttributedString(text) }
        var output = AttributedString()
        var cursor = text.startIndex
        for link in links where link.range.lowerBound >= cursor {
            output += AttributedString(String(text[cursor..<link.range.lowerBound]))
            var piece = AttributedString(String(text[link.range]))
            piece.link = ConsoleLinks.target(link)
            piece.underlineStyle = .single
            output += piece
            cursor = link.range.upperBound
        }
        output += AttributedString(String(text[cursor...]))
        return output
    }

    /// The Find bar's matches in a row's text, the current one stronger.
    static func marked(_ text: AttributedString, _ find: ConsoleRowFind?) -> AttributedString {
        guard let find, !find.query.isEmpty else { return text }
        var output = text
        let plain = String(output.characters)
        for (number, range) in ConsoleFind.ranges(of: find.query, in: plain).enumerated() {
            let start = plain.distance(from: plain.startIndex, to: range.lowerBound)
            let length = plain.distance(from: range.lowerBound, to: range.upperBound)
            let lower = output.characters.index(output.startIndex, offsetBy: start)
            let upper = output.characters.index(lower, offsetBy: length)
            output[lower..<upper].backgroundColor = number == find.current ? ConsoleTheme.findCurrent : ConsoleTheme.findMatch
        }
        return output
    }

    static func nodeIndex(_ url: URL) -> Int? {
        guard url.scheme == "search-console", url.host() == "node" else { return nil }
        return Int(url.lastPathComponent)
    }

    private static func apply(_ style: ConsoleStyle, to piece: inout AttributedString) {
        guard !style.isPlain else { return }
        if let color = style.color { piece.foregroundColor = color.color }
        if let background = style.background { piece.backgroundColor = background.color }
        let size = style.fontSize ?? 11
        var font = style.monospaced ? Font.system(size: size, design: .monospaced) : Font.system(size: size)
        if style.bold { font = font.bold() }
        if style.italic { font = font.italic() }
        piece.font = font
        if style.underline { piece.underlineStyle = .single }
        if style.strikethrough { piece.strikethroughStyle = .single }
    }
}

// MARK: - Object trees

/// The properties of one expanded object.
/// The triangle that opens a message, an object or a node, as Chrome
/// draws it.
struct ConsoleDisclosure: View {
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: open ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                .font(.system(size: 7)).foregroundStyle(.secondary)
                .frame(width: 11, height: 13).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(open ? "Collapse" : "Expand")
    }
}

private struct ConsoleObjectChildren: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var store: DeveloperConsoleStore
    let object: ConsoleRemoteObject
    let targetID: String?
    let key: String
    let depth: Int
    /// The property names from the logged value down to this object, for
    /// "Copy property path".
    var path: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let id = object.objectId, let list = store.properties[id] {
                ForEach(list) { property in
                    if let entries = property.entries {
                        ConsoleEntriesLine(session: session, store: store, entries: entries, targetID: targetID,
                                           key: key + "/" + property.name, depth: depth)
                    } else if property.getter {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: 11, height: 1)
                            Text(property.name).foregroundStyle(ConsoleTheme.property)
                            Text(": ")
                            Button("(...)") { session.invokeConsoleGetter(property, of: object, targetID: targetID) }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Invoke property getter")
                        }
                    } else if let value = property.value {
                        ConsoleValueLine(session: session, store: store, name: property.name, object: value,
                                         targetID: targetID, key: key + "/" + property.name, depth: depth,
                                         dimmed: !property.enumerable || property.isInternal || property.name.hasPrefix("[["),
                                         thrown: property.wasThrown, path: path + [property.name], parent: object)
                    }
                }
                if store.truncated.contains(id) {
                    Text("…").foregroundStyle(.secondary).padding(.leading, 11)
                }
            } else {
                Text("Loading…").foregroundStyle(.secondary).padding(.leading, 11)
                    .onAppear { session.loadConsoleProperties(object, targetID: targetID) }
            }
        }
        .onAppear(perform: expandDeep)
        .onChange(of: object.objectId.flatMap { store.properties[$0]?.count }) { _, _ in expandDeep() }
    }

    /// After ⌥-click: once this object's properties are in, open each
    /// child object one level less deep, leaving out the prototype, as
    /// Chrome's "Expand recursively" does.
    private func expandDeep() {
        guard let remaining = store.deepExpansion[key], remaining > 0,
              let id = object.objectId, let list = store.properties[id] else { return }
        for property in list where property.name != "[[Prototype]]" && property.entries == nil {
            guard let value = property.value, value.expandable, !value.isNode else { continue }
            let child = key + "/" + property.name
            guard !store.expanded.contains(child) else { continue }
            store.expandRecursively(child, depth: remaining - 1)
            session.loadConsoleProperties(value, targetID: targetID)
        }
    }
}

/// `name: value`, with a triangle when the value opens.
struct ConsoleValueLine: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var store: DeveloperConsoleStore
    let name: String?
    let object: ConsoleRemoteObject
    let targetID: String?
    let key: String
    let depth: Int
    var dimmed = false
    var thrown = false
    var path: [String] = []
    /// The object holding this property, for storing a primitive value.
    var parent: ConsoleRemoteObject?

    private var open: Bool { store.expanded.contains(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if object.expandable, depth < 24 {
                    ConsoleDisclosure(open: open) { toggle(recursively: NSEvent.modifierFlags.contains(.option)) }
                } else {
                    Color.clear.frame(width: 11, height: 1)
                }
                Text(label)
                    .lineLimit(object.type == "string" ? 6 : 1)
                    .textSelection(.enabled)
                    // As in Chrome DevTools, clicking the preview opens it.
                    .simultaneousGesture(TapGesture().onEnded {
                        if object.expandable, depth < 24 { toggle(recursively: NSEvent.modifierFlags.contains(.option)) }
                    })
                    .environment(\.openURL, OpenURLAction { url in
                        if url.scheme == "search-console", url.host() == "node" { session.revealConsoleNode(object, targetID: targetID) }
                        else { session.openConsoleLink(url) }
                        return .handled
                    })
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if object.isNode { session.highlightConsoleNode(inside ? object : nil, targetID: targetID) }
            }
            .consoleMenu { menu }
            if open, object.expandable {
                ConsoleObjectChildren(session: session, store: store, object: object, targetID: targetID,
                                      key: key, depth: depth + 1, path: path)
                    .padding(.leading, 14)
            }
        }
    }

    private func toggle(recursively: Bool) {
        let wasOpen = open
        store.toggle(key, recursively: recursively)
        if !wasOpen { session.loadConsoleProperties(object, targetID: targetID) }
    }

    /// Chrome's menu on a property in an object tree.
    @ViewBuilder
    private var menu: some View {
        Button("Copy value") { session.copyConsoleObject(object, targetID: targetID) }
        if object.type == "function", object.objectId != nil {
            Button("Show function definition") { session.showConsoleFunctionDefinition(object, targetID: targetID) }
        }
        if !path.isEmpty {
            Button("Copy property path") { DeveloperToolsSession.copyToPasteboard(ConsolePropertyPath.format(path)) }
        }
        if object.objectId != nil || (parent?.objectId != nil && name != nil) {
            Button("Store as global variable") {
                session.storeConsolePropertyAsGlobal(object, name: name ?? "", parent: parent, targetID: targetID)
            }
        }
        if object.isNode {
            Divider()
            Button("Reveal in Elements panel") { session.revealConsoleNode(object, targetID: targetID) }
        }
        if object.expandable {
            Divider()
            Button("Expand recursively") {
                store.expandRecursively(key)
                session.loadConsoleProperties(object, targetID: targetID)
            }
            Button("Collapse children") {
                store.expanded = store.expanded.filter { !$0.hasPrefix(key + "/") }
                store.deepExpansion = store.deepExpansion.filter { $0.key != key && !$0.key.hasPrefix(key + "/") }
            }
        }
    }

    private var label: AttributedString {
        var output = AttributedString()
        if let name {
            var piece = AttributedString(name)
            piece.foregroundColor = dimmed ? ConsoleTheme.property.opacity(0.6) : ConsoleTheme.property
            output += piece
            output += AttributedString(": ")
        }
        var value = AttributedString(thrown ? "[Exception: \(object.description ?? "")]"
                                     : ConsoleFormat.inline(object, nested: name != nil))
        if let color = ConsoleTheme.color(for: object) { value.foregroundColor = color }
        if object.isNode, object.objectId != nil { value.link = URL(string: "search-console://node/0") }
        if object.type == "function" { value.font = .system(size: 11, design: .monospaced).italic() }
        output += value
        return output
    }
}

/// A Map's or Set's `[[Entries]]`, opened like Chrome's.
private struct ConsoleEntriesLine: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var store: DeveloperConsoleStore
    let entries: [ConsoleEntry]
    let targetID: String?
    let key: String
    let depth: Int

    var body: some View {
        let open = store.expanded.contains(key)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                store.expanded.formSymmetricDifference([key])
            } label: {
                HStack(spacing: 0) {
                    Image(systemName: open ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                        .font(.system(size: 7)).foregroundStyle(.secondary).frame(width: 11, height: 13)
                    Text("[[Entries]]").foregroundStyle(ConsoleTheme.property.opacity(0.6))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        if let entryKey = entry.key {
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                Color.clear.frame(width: 11, height: 1)
                                Text("\(index)").foregroundStyle(ConsoleTheme.property)
                                Text(": ")
                                Text(ConsoleFormat.inline(entryKey, nested: true)).foregroundStyle(ConsoleTheme.color(for: entryKey) ?? Palette.ink)
                                Text(" => ")
                                Text(ConsoleFormat.inline(entry.value, nested: true)).foregroundStyle(ConsoleTheme.color(for: entry.value) ?? Palette.ink)
                            }
                        } else {
                            ConsoleValueLine(session: session, store: store, name: "\(index)", object: entry.value,
                                             targetID: targetID, key: key + "/\(index)", depth: depth + 1)
                        }
                    }
                }
                .padding(.leading, 14)
            }
        }
    }
}

// MARK: - Tables and stacks

private struct ConsoleTableView: View {
    let table: ConsoleTable

    var body: some View {
        let columns = ["(index)"] + table.columns
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(columns, id: \.self) { column in
                        cell(Text(column).fontWeight(.semibold))
                            .background(DeveloperToolsStyle.raised)
                    }
                }
                ForEach(Array(table.rows.prefix(500).enumerated()), id: \.offset) { position, row in
                    GridRow {
                        cell(Text(row.index))
                        ForEach(table.columns, id: \.self) { column in
                            let value = row.cells[column]
                            cell(Text(value?.text ?? "").foregroundStyle(value.map(color) ?? Palette.ink))
                        }
                    }
                    .background(position % 2 == 1 ? DeveloperToolsStyle.raised.opacity(0.6) : .clear)
                }
            }
            .overlay(Rectangle().stroke(DeveloperToolsStyle.rule))
        }
        .scrollIndicators(.automatic)
        .accessibilityLabel("Table with \(table.rows.count) rows")
    }

    private func cell(_ content: Text) -> some View {
        content
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(minWidth: 60, maxWidth: 260, minHeight: 17, alignment: .leading)
            .overlay(alignment: .trailing) { Rectangle().fill(DeveloperToolsStyle.rule).frame(width: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(DeveloperToolsStyle.rule).frame(height: 1) }
    }

    private func color(_ cell: ConsoleTableCell) -> Color {
        switch cell.type {
        case "string": return ConsoleTheme.string
        case "number", "bigint": return ConsoleTheme.number
        case "boolean": return ConsoleTheme.keyword
        case "null", "undefined": return ConsoleTheme.null
        default: return Palette.ink
        }
    }
}

private struct ConsoleStackView: View {
    @ObservedObject var session: DeveloperToolsSession
    /// For the ignore list, whose changes redraw the stack.
    @ObservedObject private var debugger: DeveloperDebugger
    let frames: [ConsoleCallFrame]
    /// Chrome's "Show N more frames": the ignore-listed frames shown too.
    @State private var showIgnored = false

    init(session: DeveloperToolsSession, frames: [ConsoleCallFrame]) {
        self.session = session
        debugger = session.debugger
        self.frames = frames
    }

    /// A frame of an ignore-listed script, by its compiled or authored file.
    private func isIgnored(_ frame: ConsoleCallFrame) -> Bool {
        guard !frame.url.isEmpty else { return false }
        if debugger.isIgnored(frame.url) { return true }
        let link = session.sourceMaps.linked(url: frame.url, line: frame.lineNumber, column: frame.columnNumber)
        return link.url != frame.url && debugger.isIgnored(link.url)
    }

    var body: some View {
        let filtered = DeveloperIgnoredFrames.filter(frames, isBoundary: { $0.asyncBoundary }, isIgnored: isIgnored)
        let shown = showIgnored ? frames : filtered.frames
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, frame in
                if frame.asyncBoundary {
                    Text("--- async ---").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 0) {
                        Text(frame.name).lineLimit(1)
                        if !frame.url.isEmpty {
                            // In the authored file when the script has a source map.
                            let link = session.sourceMaps.linked(url: frame.url, line: frame.lineNumber, column: frame.columnNumber)
                            Text(" @ ").foregroundStyle(.secondary)
                            Button { session.revealConsoleSource(url: link.url, line: link.line) } label: {
                                Text(ConsoleFormat.location(link.url, line: link.line)).underline().foregroundStyle(.secondary).lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .help(link.url + ":\(link.line ?? frame.lineNumber)")
                        }
                    }
                    .opacity(showIgnored && isIgnored(frame) ? 0.55 : 1)
                }
            }
            if filtered.hidden > 0 {
                Button(DeveloperIgnoredFrames.toggleTitle(hidden: filtered.hidden, showing: showIgnored)) {
                    showIgnored.toggle()
                }
                .buttonStyle(.plain)
                .underline()
                .foregroundStyle(DeveloperToolsStyle.tint)
                .accessibilityIdentifier("developer-console-ignored-frames")
            }
        }
        .padding(.vertical, 2)
    }
}

/// As in Chrome DevTools: a logged Error prints its whole stack, each
/// frame linking to its file and line in Sources.
private struct ConsoleErrorStackView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var store: DeveloperConsoleStore
    let object: ConsoleRemoteObject
    let targetID: String?

    var body: some View {
        let stack = object.objectId.flatMap { store.errorStacks[$0] }
        let frames = ConsoleErrorStack.split(description: object.description ?? "", stack: stack).frames
        VStack(alignment: .leading, spacing: 0) {
            if !frames.isEmpty {
                ConsoleStackView(session: session, frames: frames)
                    .padding(.leading, 16)
            }
        }
        .onAppear { session.loadConsoleErrorStack(object, targetID: targetID) }
    }
}

/// A logged DOM node as Chrome's console draws it: an element tree that
/// opens child by child, highlights on the page while hovered, and
/// reveals in Elements from its menu.
private struct ConsoleNodeLine: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var store: DeveloperConsoleStore
    let object: ConsoleRemoteObject?
    let summary: ConsoleNodeSummary?
    let targetID: String?
    let key: String
    let depth: Int

    private var tree: ConsoleNodeTree? { object?.objectId.flatMap { store.nodeTrees[$0] } }
    private var info: ConsoleNodeSummary? { summary ?? tree?.summary }
    private var open: Bool { store.expanded.contains(key) }
    private var canOpen: Bool { object?.objectId != nil && (info?.children ?? 0) > 0 && depth < 40 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if canOpen {
                    ConsoleDisclosure(open: open, action: toggle)
                } else {
                    Color.clear.frame(width: 11, height: 1)
                }
                Text(markup(open: open && canOpen))
                    .lineLimit(info?.type == 3 ? 4 : 1)
                    .textSelection(.enabled)
                    .simultaneousGesture(TapGesture().onEnded { if canOpen { toggle() } })
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if let object { session.highlightConsoleNode(inside ? object : nil, targetID: targetID) }
            }
            .consoleMenu {
                if let object {
                    Button("Reveal in Elements panel") { session.revealConsoleNode(object, targetID: targetID) }
                    Button("Store as global variable") { session.storeConsoleObjectAsGlobal(object, targetID: targetID) }
                    Button("Copy element") { session.copyConsoleObject(object, targetID: targetID) }
                }
            }
            if open, canOpen {
                VStack(alignment: .leading, spacing: 0) {
                    if let tree {
                        ForEach(Array(tree.children.enumerated()), id: \.offset) { index, child in
                            ConsoleNodeLine(session: session, store: store, object: child.object, summary: child.summary,
                                            targetID: targetID, key: key + "/\(index)", depth: depth + 1)
                        }
                    } else {
                        Text("Loading…").foregroundStyle(.secondary).padding(.leading, 11)
                    }
                }
                .padding(.leading, 14)
                if let info, info.isElement {
                    Text(styled(ConsoleNodeMarkup.closing(info))).padding(.leading, 11)
                }
            }
        }
        .onAppear {
            if let object, summary == nil || open { session.loadConsoleNodeTree(object, targetID: targetID) }
        }
    }

    private func toggle() {
        let wasOpen = open
        store.toggle(key, recursively: false)
        if !wasOpen, let object { session.loadConsoleNodeTree(object, targetID: targetID) }
    }

    private func markup(open: Bool) -> AttributedString {
        guard let info else {
            var text = AttributedString(object?.description ?? "node")
            text.foregroundColor = ConsoleTheme.tag
            return text
        }
        return styled(ConsoleNodeMarkup.opening(info, open: open))
    }

    private func styled(_ pieces: [(String, ConsoleNodeMarkup.Kind)]) -> AttributedString {
        var output = AttributedString()
        for (text, kind) in pieces {
            var piece = AttributedString(text)
            switch kind {
            case .tag, .punctuation: piece.foregroundColor = ConsoleTheme.tag
            case .attribute: piece.foregroundColor = ConsoleTheme.attribute
            case .value: piece.foregroundColor = ConsoleTheme.attributeValue
            case .comment: piece.foregroundColor = ConsoleTheme.null
            case .text: break
            }
            output += piece
        }
        return output
    }
}

/// Watches the message list's scroll view and the window's events: it
/// tells whether the list sits at its bottom (only the user's scrolling
/// moves that), where clicks land, and the keys the list itself handles.
private struct ConsoleListMonitor: NSViewRepresentable {
    var pinned: (Bool) -> Void
    var mouseDown: (_ inside: Bool) -> Void
    var key: (NSEvent) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        update(view)
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) { update(view) }

    private func update(_ view: MonitorView) {
        view.pinned = pinned
        view.mouseDown = mouseDown
        view.key = key
    }

    /// A field or the prompt being edited keeps ⌘A and ⌘C for itself.
    static func editingText(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if let text = responder as? NSTextView { return text.isEditable }
        return responder is NSTextField
    }

    final class MonitorView: NSView {
        var pinned: (Bool) -> Void = { _ in }
        var mouseDown: (Bool) -> Void = { _ in }
        var key: (NSEvent) -> Bool = { _ in false }
        private var observer: NSObjectProtocol?
        private var monitor: Any?
        private var lastPinned = true
        private var menuShown = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            if let scroll = enclosingScrollView {
                scroll.contentView.postsBoundsChangedNotifications = true
                observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                  object: scroll.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .rightMouseUp, .keyDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return consumed ? nil : event
            }
        }

        private func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let monitor { NSEvent.removeMonitor(monitor) }
            observer = nil
            monitor = nil
        }

        private func report() {
            guard let scroll = enclosingScrollView, let document = scroll.documentView else { return }
            let visible = scroll.contentView.documentVisibleRect
            let height = document.bounds.height
            let bottom = document.isFlipped ? visible.maxY : height - visible.minY
            let atBottom = ConsoleScrollPin.isAtBottom(visibleMaxY: bottom, contentHeight: height)
            guard atBottom != lastPinned else { return }
            lastPinned = atBottom
            pinned(atBottom)
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            switch event.type {
            case .leftMouseDown:
                if let scroll = enclosingScrollView {
                    let point = scroll.convert(event.locationInWindow, from: nil)
                    mouseDown(scroll.bounds.contains(point))
                }
                return false
            case .rightMouseDown:
                menuShown = ConsoleMenuAnchor.popUp(for: event, in: window)
                return menuShown
            case .rightMouseUp:
                // The release of a click whose menu the console showed,
                // or the text under it opens its own menu after.
                defer { menuShown = false }
                return menuShown
            case .keyDown:
                return key(event)
            default:
                return false
            }
        }
    }
}

extension View {
    /// The console's menu on a row. A `.contextMenu` alone loses to the
    /// row's selectable text, which answers a right-click with macOS's
    /// text menu (Cut, Copy, Paste…); the anchor lets the list's monitor
    /// show the row's own menu there instead, as Chrome does.
    fileprivate func consoleMenu<Items: View>(@ViewBuilder _ items: @escaping () -> Items) -> some View {
        contextMenu(menuItems: items)
            .background(ConsoleMenuAnchor(items: AnyView(items())))
    }
}

/// Where a console row is, and its menu, for a right-click on its text.
struct ConsoleMenuAnchor: NSViewRepresentable {
    /// Built with the row, where its state reads true; built later, a
    /// row's @State would read as it began.
    var items: AnyView

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) { view.items = items }

    /// The innermost row's menu under a right-click, shown; false when no
    /// row is there (the prompt, an empty stretch) or before macOS 15.
    @MainActor
    static func popUp(for event: NSEvent, in window: NSWindow) -> Bool {
        guard #available(macOS 15, *) else { return false }
        guard let anchor = innermost(at: event.locationInWindow, in: window), let items = anchor.items else { return false }
        let menu = NSHostingMenu(rootView: items)
        NSMenu.popUpContextMenu(menu, with: event, for: anchor)
        // The system still opens the selectable text's own menu once this
        // one closes, from outside the app's event monitors; it is closed
        // a turn after it starts (closed while starting, menus wedge).
        let until = Date().addingTimeInterval(0.5)
        let menuID = ObjectIdentifier(menu)
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if Date() < until, let other = note.object as? NSMenu, ObjectIdentifier(other) != menuID {
                    DispatchQueue.main.async { other.cancelTracking() }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
        return true
    }

    /// The smallest row under a point in the window: a property inside
    /// an object inside a message gets its own menu.
    @MainActor
    static func innermost(at point: NSPoint, in window: NSWindow) -> AnchorView? {
        AnchorView.live.allObjects.filter { anchor in
            guard anchor.window === window, !anchor.isHiddenOrHasHiddenAncestor else { return false }
            let local = anchor.convert(point, from: nil)
            // SwiftUI's hosted views can report a visible rect past their
            // bounds, so both are asked.
            return anchor.bounds.contains(local) && anchor.visibleRect.contains(local)
        }
        .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    final class AnchorView: NSView {
        @MainActor static let live = NSHashTable<AnchorView>.weakObjects()
        var items: AnyView?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { Self.live.remove(self) } else { Self.live.add(self) }
        }
    }
}

// MARK: - Prompt

/// The prompt's place in its history: the draft, and edits made to recalled
/// entries, kept while moving through it until a command runs, as in Chrome.
struct DeveloperConsoleHistoryCursor: Equatable {
    var index: Int?
    var draft = ""
    var edits: [Int: String] = [:]

    /// Keeps `text` and moves `offset` entries; the text to show, or nil
    /// when there is no history.
    mutating func move(_ offset: Int, from text: String, in history: [String]) -> String? {
        guard !history.isEmpty else { return nil }
        if let index, history.indices.contains(index) { edits[index] = text == history[index] ? nil : text }
        else { draft = text }
        let next = min(history.count, max(0, (index ?? history.count) + offset))
        index = next == history.count ? nil : next
        return index.map { edits[$0] ?? history[$0] } ?? draft
    }
}


private struct ConsolePrompt: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var store: DeveloperConsoleStore
    @State private var text = ""
    @State private var height: CGFloat = 15
    @State private var historyCursor = DeveloperConsoleHistoryCursor()
    @State private var eager: String?
    @State private var suggestions: [String] = []
    @State private var prefix = ""
    @State private var selection = 0
    @State private var lookup: Task<Void, Never>?
    @State private var focusToken = 0
    @State private var accept: String?
    @State private var caretAtEnd = true
    /// Counts the prompt's text being set from outside the editor
    /// (submitting, history, a completion), which always goes into it.
    @State private var externalEdits = 0

    /// As in Chrome DevTools, the list holds up to 50 names and scrolls.
    static let listLimit = 50
    private static let visibleRows = 8
    private static let rowHeight: CGFloat = 17

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DeveloperToolsStyle.tint)
                    .frame(width: 13, height: 15)
                Color.clear.frame(width: 11, height: 1)
                ConsolePromptEditor(text: $text, height: $height, focusToken: focusToken, externalEdits: externalEdits,
                                    accept: $accept, ghost: ghost,
                                    keys: handle, changed: changed, clear: session.clearConsole)
                    .frame(height: max(15, height))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Evaluate JavaScript").font(DeveloperToolsStyle.code).foregroundStyle(.tertiary)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Console prompt")
            }
            if !suggestions.isEmpty {
                suggestionList.padding(.leading, 28)
            }
            if let eager, !text.isEmpty {
                Text(eager)
                    .font(DeveloperToolsStyle.code)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 28)
                    .padding(.top, 2)
                    .accessibilityLabel("Preview: " + eager)
            }
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
        // A click in the blank space around the prompt focuses it. The tap
        // is on a layer behind the editor, not over it: a tap recognizer
        // over the text view holds its mouse-down back until the tap is
        // decided, and the late click then moved the caret under keys
        // already typed, scrambling them.
        .background {
            Color.clear.contentShape(Rectangle()).onTapGesture { focusToken += 1 }
        }
        .onAppear { focusToken += 1 }
        // ⌃` from any panel (DeveloperToolsKeys).
        .onChange(of: store.promptFocus) { _, _ in focusToken += 1 }
    }

    /// Chrome's grey text after the caret: the rest of the selected
    /// suggestion, shown while the caret is at the end of the prompt.
    private var ghost: String {
        guard caretAtEnd, suggestions.indices.contains(selection) else { return "" }
        let name = suggestions[selection]
        if name.hasPrefix(Self.historyMark) {
            let entry = String(name.dropFirst())
            return entry.hasPrefix(text) ? String(entry.dropFirst(text.count)) : ""
        }
        guard name.hasPrefix(prefix) else { return "" }
        return String(name.dropFirst(prefix.count))
    }

    private var shown: [String] { Array(suggestions.prefix(Self.listLimit)) }

    private var suggestionList: some View {
        let list = self.shown
        return ScrollViewReader { scroll in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.offset) { index, name in
                        suggestionRow(name, at: index)
                    }
                }
                .padding(.vertical, 2)
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: CGFloat(min(shown.count, Self.visibleRows)) * Self.rowHeight + 4)
            .onChange(of: selection) { _, index in scroll.scrollTo(index) }
        }
        .background(DeveloperToolsStyle.chrome, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DeveloperToolsStyle.rule))
        .fixedSize(horizontal: true, vertical: false)
    }

    private func suggestionRow(_ name: String, at index: Int) -> some View {
        let fill: Color = index == selection ? DeveloperToolsStyle.tint.opacity(0.25) : Color.clear
        return HStack(spacing: 0) {
            if name.hasPrefix(Self.historyMark) {
                Text(name.dropFirst()).lineLimit(1)
            } else {
                Text(name.prefix(prefix.count)).fontWeight(.semibold)
                Text(name.dropFirst(prefix.count))
            }
        }
        .font(DeveloperToolsStyle.code)
        .padding(.horizontal, 6)
        .frame(minWidth: 160, alignment: .leading)
        .frame(height: Self.rowHeight)
        .background(fill)
        .contentShape(Rectangle())
        .onTapGesture { complete(name) }
        .id(index)
    }

    /// Return runs, ⇧Return or an unfinished block adds a line, ↑/↓ walk
    /// history from the first and last lines, Tab or → takes a completion,
    /// Page Up / Page Down move through the list a page at a time, and
    /// ⌃Space asks for completions, as in Chrome.
    private func handle(_ key: ConsolePromptEditor.Key) -> Bool {
        let count = shown.count
        switch key {
        case .submit:
            if !suggestions.isEmpty { complete(suggestions[selection]); return true }
            if ConsoleInput.isIncomplete(text) { return false }
            run()
            return true
        case .up(let firstLine):
            if !suggestions.isEmpty { selection = selection == 0 ? count - 1 : selection - 1; return true }
            guard firstLine else { return false }
            moveHistory(-1)
            return true
        case .down(let lastLine):
            if !suggestions.isEmpty { selection = selection >= count - 1 ? 0 : selection + 1; return true }
            guard lastLine else { return false }
            moveHistory(1)
            return true
        case .pageUp:
            guard !suggestions.isEmpty else { return false }
            selection = max(0, selection - Self.visibleRows)
            return true
        case .pageDown:
            guard !suggestions.isEmpty else { return false }
            selection = min(count - 1, selection + Self.visibleRows)
            return true
        case .tab, .right:
            guard !suggestions.isEmpty else { return false }
            complete(suggestions[selection])
            return true
        case .escape:
            guard !suggestions.isEmpty else { return false }
            suggestions = []
            return true
        }
    }

    private func run() {
        let expression = text
        guard !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.evaluateInConsole(expression)
        historyCursor = DeveloperConsoleHistoryCursor()
        text = ""
        externalEdits += 1
        eager = nil
        suggestions = []
    }

    private func moveHistory(_ offset: Int) {
        guard let shown = historyCursor.move(offset, from: text, in: store.history) else { return }
        text = shown
        externalEdits += 1
        suggestions = []
    }

    private func complete(_ name: String) {
        if name.hasPrefix(Self.historyMark) {
            text = String(name.dropFirst())
            externalEdits += 1
            suggestions = []
            return
        }
        accept = String(name.dropFirst(min(prefix.count, name.count)))
        if !name.hasPrefix(prefix) { accept = "\u{0}" + String(prefix.count) + "\u{0}" + name }
        suggestions = []
    }

    /// Completions follow the word before the caret, wherever it is on
    /// the line, as Chrome's do.
    private func changed(_ beforeCaret: String, atEnd: Bool, force: Bool) {
        lookup?.cancel()
        caretAtEnd = atEnd
        let current = text
        lookup = Task {
            if !force { try? await Task.sleep(for: .milliseconds(110)) }
            guard !Task.isCancelled else { return }
            let preview = store.settings.eagerEvaluation ? await session.consoleEagerPreview(current) : nil
            guard !Task.isCancelled else { return }
            if let preview {
                let shown = ConsoleFormat.inline(preview, nested: true)
                eager = shown == current.trimmingCharacters(in: .whitespacesAndNewlines) ? nil : shown
            } else {
                eager = nil
            }
            let wordEnd = beforeCaret.last.map { $0.isLetter || $0.isNumber || "_$.".contains($0) } ?? false
            guard force || wordEnd else {
                suggestions = []
                return
            }
            let result = await session.consoleCompletions(beforeCaret, force: force)
            guard !Task.isCancelled else { return }
            prefix = result.prefix
            // Earlier commands that start the same way come first.
            let earlier = store.settings.historyAutocomplete && atEnd && !current.isEmpty && !current.contains("\n")
                ? Array(store.history.reversed().filter { $0 != current && $0.hasPrefix(current) && !$0.contains("\n") }.prefix(3))
                : []
            suggestions = earlier.map { Self.historyMark + $0 } + result.names
            selection = 0
        }
    }

    static let historyMark = "\u{1}"
}

/// A plain NSTextView, since SwiftUI's fields cannot tell ⇧Return from
/// Return or say where the caret is.
private struct ConsolePromptEditor: NSViewRepresentable {
    enum Key { case submit, up(firstLine: Bool), down(lastLine: Bool), tab, right, escape, pageUp, pageDown }

    @Binding var text: String
    @Binding var height: CGFloat
    var focusToken: Int
    var externalEdits = 0
    @Binding var accept: String?
    var ghost: String = ""
    var keys: (Key) -> Bool
    var changed: (_ beforeCaret: String, _ atEnd: Bool, _ force: Bool) -> Void
    var clear: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let view = PromptTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.drawsBackground = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textColor = .labelColor
        view.insertionPointColor = .labelColor
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.setAccessibilityIdentifier("developer-console-prompt")
        view.requestCompletions = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.report(view, force: true)
        }
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.parent = self
        if let prompt = view as? PromptTextView {
            prompt.clear = clear
            if prompt.ghost != ghost {
                prompt.ghost = ghost
                prompt.needsDisplay = true
            }
        }
        // A text the view itself reported earlier is SwiftUI reading the
        // binding a keystroke or two behind while typing runs ahead; put
        // into the view, it would undo keys and throw the caret to the end.
        // Only a text set from outside (history, a clear) goes in.
        let outside = context.coordinator.externalEdits != externalEdits
        context.coordinator.externalEdits = externalEdits
        if view.string == text {
            context.coordinator.reported.removeAll()
        } else if outside || !context.coordinator.reported.contains(text) {
            context.coordinator.reported.removeAll()
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.measure(view)
        }
        if let accept {
            DispatchQueue.main.async { self.accept = nil }
            context.coordinator.insertCompletion(accept, in: view)
        }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    final class PromptTextView: NSTextView {
        var clear: () -> Void = {}
        var requestCompletions: () -> Void = {}
        /// The grey rest of the selected completion, drawn after the text.
        var ghost = ""

        /// Chrome clears the console with ⌘K or ⌃L while it has focus.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()
            if window?.firstResponder === self, (flags == .command && key == "k") || (flags == .control && key == "l") {
                clear()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        /// When the last key came (its event's time).
        private var lastKey: TimeInterval = 0

        /// A click AppKit held back (a gesture recognizer above deciding)
        /// can arrive after keys typed since: it only focuses the prompt,
        /// rather than moving the caret under what was already typed.
        override func mouseDown(with event: NSEvent) {
            if event.timestamp < lastKey {
                window?.makeFirstResponder(self)
                return
            }
            super.mouseDown(with: event)
        }

        override func keyDown(with event: NSEvent) {
            lastKey = max(lastKey, event.timestamp)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .control, event.charactersIgnoringModifiers?.lowercased() == "l" { clear(); return }
            // ⌃Space opens the completions on demand, as in Chrome.
            if flags == .control, event.keyCode == 49 { requestCompletions(); return }
            super.keyDown(with: event)
        }

        /// ⌥Esc and F5, AppKit's own "complete", do the same.
        override func complete(_ sender: Any?) { requestCompletions() }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let length = (string as NSString).length
            guard !ghost.isEmpty, selectedRange().length == 0, selectedRange().location == length,
                  let layout = layoutManager, let container = textContainer else { return }
            let origin = textContainerOrigin
            var point = NSPoint(x: origin.x, y: origin.y)
            if length > 0 {
                if (string as NSString).character(at: length - 1) == 10 {
                    let extra = layout.extraLineFragmentRect
                    point = NSPoint(x: origin.x + extra.minX, y: origin.y + extra.minY)
                } else {
                    let glyph = layout.glyphIndexForCharacter(at: length - 1)
                    let box = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                    let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    point = NSPoint(x: origin.x + box.maxX, y: origin.y + line.minY)
                }
            }
            let shown = ghost.prefix(while: { $0 != "\n" })
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            (String(shown) as NSString).draw(at: point, withAttributes: attributes)
        }

        override var intrinsicContentSize: NSSize {
            guard let container = textContainer, let layout = layoutManager else { return super.intrinsicContentSize }
            layout.ensureLayout(for: container)
            return NSSize(width: NSView.noIntrinsicMetric, height: layout.usedRect(for: container).height)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ConsolePromptEditor
        var focusToken = -1
        /// What the view reported into the binding since the two last
        /// agreed (updateNSView).
        var reported: Set<String> = []
        var externalEdits = 0

        init(_ parent: ConsolePromptEditor) { self.parent = parent }

        func measure(_ view: NSTextView) {
            guard let container = view.textContainer, let layout = view.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = max(15, ceil(layout.usedRect(for: container).height))
            if abs(parent.height - used) > 0.5 { DispatchQueue.main.async { self.parent.height = used } }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if reported.count > 64 { reported.removeAll() }
            reported.insert(parent.text)
            reported.insert(view.string)
            parent.text = view.string
            measure(view)
            report(view)
        }

        /// The ghost text belongs at the caret, so moving it redraws.
        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? NSView)?.needsDisplay = true
        }

        func report(_ view: NSTextView, force: Bool = false) {
            let caret = view.selectedRange().location
            let string = view.string as NSString
            let before = string.substring(to: min(caret, string.length))
            parent.changed(before, caret >= string.length, force)
        }

        func insertCompletion(_ value: String, in view: NSTextView) {
            let caret = view.selectedRange().location
            if value.hasPrefix("\u{0}") {
                let parts = value.split(separator: "\u{0}", omittingEmptySubsequences: true)
                guard parts.count == 2, let count = Int(parts[0]) else { return }
                let start = max(0, caret - count)
                view.insertText(String(parts[1]), replacementRange: NSRange(location: start, length: caret - start))
            } else {
                view.insertText(value, replacementRange: NSRange(location: caret, length: 0))
            }
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            let string = view.string as NSString
            let caret = view.selectedRange().location
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
                return parent.keys(.submit)
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                view.insertText("\n", replacementRange: view.selectedRange())
                return true
            case #selector(NSResponder.moveUp(_:)):
                let firstLine = !string.substring(to: min(caret, string.length)).contains("\n")
                return parent.keys(.up(firstLine: firstLine))
            case #selector(NSResponder.moveDown(_:)):
                let lastLine = !string.substring(from: min(caret, string.length)).contains("\n")
                return parent.keys(.down(lastLine: lastLine))
            case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
                return parent.keys(.pageUp)
            case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
                return parent.keys(.pageDown)
            case #selector(NSResponder.insertTab(_:)):
                return parent.keys(.tab)
            case #selector(NSResponder.moveRight(_:)):
                return caret >= string.length && parent.keys(.right)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.keys(.escape)
            default:
                return false
            }
        }
    }
}
