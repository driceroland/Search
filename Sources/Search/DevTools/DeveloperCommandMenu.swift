import AppKit
import SwiftUI

/// What the command menu's text asks for, by its first character, as in
/// Chrome DevTools' QuickOpen: ">" commands, "!" snippets, ":" a line,
/// "@" a symbol, "?" the list of these, and anything else a file.
enum DeveloperCommandMenuMode: String, CaseIterable, Equatable {
    case files = ""
    case commands = ">"
    case snippets = "!"
    case line = ":"
    case symbols = "@"
    case help = "?"

    var title: String {
        switch self {
        case .files: "Open file"
        case .commands: "Run command"
        case .snippets: "Run snippet"
        case .line: "Go to line"
        case .symbols: "Go to symbol"
        case .help: "Show help"
        }
    }

    /// The mode and the text after its prefix.
    static func parse(_ text: String) -> (mode: DeveloperCommandMenuMode, query: String) {
        guard let first = text.first, let mode = DeveloperCommandMenuMode(rawValue: String(first)), mode != .files else {
            return (.files, text.trimmingCharacters(in: .whitespaces))
        }
        return (mode, String(text.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    /// ":12" or ":12:5": the line, and the column if given.
    static func line(_ query: String) -> (line: Int, column: Int?)? {
        let parts = query.split(separator: ":", omittingEmptySubsequences: false)
            .map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let line = parts.first ?? nil else { return nil }
        return (line, parts.count > 1 ? parts[1] : nil)
    }

    /// Items whose title matches the query, best first; all, in their own
    /// order, for no query. Ties keep their order.
    static func filter<Item>(_ items: [Item], _ query: String, title: (Item) -> String) -> [Item] {
        guard !query.isEmpty else { return items }
        // Named steps with their types spelled out: as one chain of tuple
        // closures this took the type checker seconds.
        var scored: [(item: Item, score: Int, index: Int)] = []
        for (index, item) in items.enumerated() {
            if let score: Int = QuickOpenMatch.score(query, title(item)) {
                scored.append((item: item, score: score, index: index))
            }
        }
        scored.sort { (a: (item: Item, score: Int, index: Int), b: (item: Item, score: Int, index: Int)) -> Bool in
            a.score != b.score ? a.score > b.score : a.index < b.index
        }
        return scored.map { (entry: (item: Item, score: Int, index: Int)) -> Item in entry.item }
    }
}

/// One row of the command menu.
struct DeveloperCommandItem: Identifiable {
    var id: String { category + "\n" + title }
    let title: String
    /// Chrome's badge on the row: Panel, Drawer, Rendering, Network…
    var category = ""
    var detail = ""
    var shortcut = ""
    /// A row that only changes what is typed (the "?" list) leaves the menu open.
    var keepsOpen = false
    /// A row that only says something (no file open, no results).
    var inert = false
    let run: @MainActor () -> Void
}

/// Chrome DevTools' command menu (⇧⌘P) and Open file (⌘P): the rows for
/// what is typed, and running the one chosen.
@MainActor
enum DeveloperCommandMenu {
    static func items(for text: String, in context: DeveloperToolsContext) -> [DeveloperCommandItem] {
        let (mode, query) = DeveloperCommandMenuMode.parse(text)
        let rows: [DeveloperCommandItem]
        switch mode {
        case .help:
            rows = DeveloperCommandMenuMode.allCases.filter { $0 != .help }.map { mode in
                DeveloperCommandItem(title: mode.title, category: mode == .files ? "…" : mode.rawValue, keepsOpen: true) {
                    context.shell.commandMenu = DeveloperCommandMenuState(query: mode.rawValue)
                }
            }
        case .commands:
            rows = DeveloperCommandMenuMode.filter(commands(in: context), query) { $0.title }
        case .snippets:
            let snippets = DeveloperSnippets.shared.snippets.map { snippet in
                DeveloperCommandItem(title: snippet.name, category: "Snippet") { run(snippet: snippet.text, in: context) }
            }
            rows = snippets.isEmpty
                ? [DeveloperCommandItem(title: "No snippets yet. Create one in Sources › Snippets.", inert: true) {}]
                : DeveloperCommandMenuMode.filter(snippets, query) { $0.title }
        case .line:
            rows = [lineItem(query, in: context)]
        case .symbols:
            rows = symbolItems(query, in: context)
        case .files:
            rows = DeveloperCommandMenuMode.filter(fileItems(in: context), query) { $0.title }
        }
        return rows.isEmpty ? [DeveloperCommandItem(title: "No results found", inert: true) {}] : Array(rows.prefix(500))
    }

    static func run(_ menu: DeveloperCommandMenuState, in context: DeveloperToolsContext) {
        let rows = items(for: menu.query, in: context)
        guard rows.indices.contains(menu.selection) else { return }
        run(rows[menu.selection], in: context)
    }

    static func run(_ item: DeveloperCommandItem, in context: DeveloperToolsContext) {
        guard !item.inert else { return }
        if !item.keepsOpen { context.shell.commandMenu = nil }
        item.run()
    }

    // MARK: Files, snippets, lines, symbols

    private static func fileItems(in context: DeveloperToolsContext) -> [DeveloperCommandItem] {
        let session = context.session
        var rows = (session.resources + session.contentScripts).map { resource in
            DeveloperCommandItem(title: SourceTree.fileName(resource.url), detail: resource.url) {
                session.select(.sources)
                session.openSource(resource)
            }
        }
        rows += DeveloperSnippets.shared.snippets.map { snippet in
            DeveloperCommandItem(title: snippet.name, detail: "Snippets") {
                session.select(.sources)
                session.openSnippet(snippet.name, text: snippet.text)
            }
        }
        return rows
    }

    /// As Chrome's "!" does: runs the snippet and shows its output.
    private static func run(snippet text: String, in context: DeveloperToolsContext) {
        context.session.evaluate(text)
        if context.session.panel != .console {
            context.shell.showDrawer(.tool(.console))
        }
    }

    private static func lineItem(_ query: String, in context: DeveloperToolsContext) -> DeveloperCommandItem {
        let session = context.session
        guard let source = session.source, let resource = session.sourceResource else {
            return DeveloperCommandItem(title: "No file is open", inert: true) {}
        }
        let lines = source.utf8.reduce(into: 1) { count, byte in if byte == 10 { count += 1 } }
        guard let asked = DeveloperCommandMenuMode.line(query) else {
            return DeveloperCommandItem(title: "Type a line number between 1 and \(lines) to navigate to.", inert: true) {}
        }
        let clamped = min(max(1, asked.line), lines)
        let column = asked.column
        let title = column.map { "Go to line \(clamped) and column \($0)." } ?? "Go to line \(clamped)."
        return DeveloperCommandItem(title: title) {
            session.revealSource(url: resource.url, line: clamped, column: column)
        }
    }

    private static func symbolItems(_ query: String, in context: DeveloperToolsContext) -> [DeveloperCommandItem] {
        let session = context.session
        guard let source = session.source, let resource = session.sourceResource else {
            return [DeveloperCommandItem(title: "No file is open", inert: true) {}]
        }
        let language = SourceLanguage.detect(url: resource.url, type: resource.type, text: source)
        let symbols = SourceOutline.symbols(source, language: language)
        guard !symbols.isEmpty else { return [DeveloperCommandItem(title: "No symbols in this file", inert: true) {}] }
        let units = Array(source.utf16)
        let rows = symbols.map { symbol in
            DeveloperCommandItem(title: symbol.name) {
                let (line, column) = position(of: symbol.offset, in: units)
                session.revealSource(url: resource.url, line: line, column: column)
            }
        }
        return DeveloperCommandMenuMode.filter(rows, query) { $0.title }
    }

    /// The 1-based line and column of a UTF-16 offset.
    static func position(of offset: Int, in units: [UInt16]) -> (line: Int, column: Int) {
        var line = 1, start = 0
        for index in 0..<min(offset, units.count) where units[index] == 10 {
            line += 1
            start = index + 1
        }
        return (line, offset - start + 1)
    }

    // MARK: Commands

    /// The ">" commands, grouped and named as Chrome's command menu has them.
    static func commands(in context: DeveloperToolsContext) -> [DeveloperCommandItem] {
        let session = context.session
        let shell = context.shell
        let tools = context.tools
        let rendering = session.rendering
        let debugger = session.debugger
        var rows: [DeveloperCommandItem] = []

        // Panels and drawer tools.
        for panel in DeveloperPanel.strip {
            rows.append(.init(title: "Show " + panel.rawValue, category: "Panel") {
                shell.panels.closed.remove(panel)
                session.select(panel)
            })
        }
        for tool in DeveloperDrawerTool.offered where tool != .console {
            rows.append(.init(title: "Show " + tool.title, category: "Drawer") { shell.showDrawer(.tool(tool)) })
        }
        rows.append(.init(title: "Toggle drawer", category: "Drawer", shortcut: "Esc") { shell.toggleDrawer() })

        // Elements and Sources.
        rows.append(.init(title: "Select an element in the page to inspect it", category: "Elements", shortcut: "⇧⌘C") {
            session.select(.elements)
            session.togglePicker()
        })
        rows.append(.init(title: "Create new snippet", category: "Sources") {
            let snippet = DeveloperSnippets.shared.create()
            session.select(.sources)
            session.openSnippet(snippet.name, text: snippet.text)
        })
        rows.append(.init(title: "Search in all files", category: "Sources", shortcut: "⌥⌘F") {
            shell.showDrawer(.tool(.search))
        })
        rows.append(.init(title: "Go to line", category: "Sources", shortcut: "⌃G", keepsOpen: true) {
            session.select(.sources)
            shell.commandMenu = DeveloperCommandMenuState(query: ":")
        })
        rows.append(.init(title: "Go to symbol", category: "Sources", shortcut: "⇧⌘O", keepsOpen: true) {
            session.select(.sources)
            shell.commandMenu = DeveloperCommandMenuState(query: "@")
        })
        rows.append(.init(title: shell.sourcesNavigatorHidden ? "Show navigator" : "Hide navigator",
                          category: "Sources", shortcut: "⇧⌘Y") {
            session.select(.sources)
            shell.sourcesNavigatorHidden.toggle()
        })
        rows.append(.init(title: shell.sourcesDebuggerHidden ? "Show debugger" : "Hide debugger",
                          category: "Sources", shortcut: "⇧⌘H") {
            session.select(.sources)
            shell.sourcesDebuggerHidden.toggle()
        })
        rows.append(.init(title: "Save all", category: "Sources", shortcut: "⌥⌘S") {
            DeveloperSourceTabs.of(session).saveAll()
        })

        // Console.
        rows.append(.init(title: "Clear console", category: "Console", shortcut: "⌘K") { session.clearConsole() })
        rows.append(.init(title: "Focus console", category: "Console", shortcut: "⌃`") {
            context.perform(.focusConsole)
        })
        rows.append(.init(title: session.preserveConsoleLog ? "Do not preserve log upon navigation" : "Preserve log upon navigation",
                          category: "Console") { session.preserveConsoleLog.toggle() })

        // Debugger.
        rows.append(.init(title: session.paused ? "Resume script execution" : "Pause script execution",
                          category: "Debugger", shortcut: "F8") {
            debugger.step(debugger.pause != nil ? "resume" : "pause")
        })
        if session.paused {
            rows.append(.init(title: "Step over next function call", category: "Debugger", shortcut: "F10") { debugger.step("stepOver") })
            rows.append(.init(title: "Step into next function call", category: "Debugger", shortcut: "F11") { debugger.step("stepInto") })
            rows.append(.init(title: "Step out of current function", category: "Debugger", shortcut: "⇧F11") { debugger.step("stepOut") })
            rows.append(.init(title: "Select next call frame", category: "Debugger", shortcut: "⌃.") { context.perform(.callFrame(1)) })
            rows.append(.init(title: "Select previous call frame", category: "Debugger", shortcut: "⌃,") { context.perform(.callFrame(-1)) })
        }
        rows.append(.init(title: debugger.breakpointsActive ? "Deactivate breakpoints" : "Activate breakpoints",
                          category: "Debugger", shortcut: "⌘F8") {
            debugger.setBreakpointsActive(!debugger.breakpointsActive)
        })
        rows.append(.init(title: rendering.options.javaScriptDisabled ? "Enable JavaScript" : "Disable JavaScript",
                          category: "Debugger") {
            rendering.update(in: session) { $0.javaScriptDisabled.toggle() }
        })

        // Network.
        rows.append(.init(title: session.recordNetwork ? "Stop recording network log" : "Record network log",
                          category: "Network", shortcut: "⌘E") { session.recordNetwork.toggle() })
        rows.append(.init(title: session.cacheDisabled ? "Enable cache" : "Disable cache (while DevTools is open)",
                          category: "Network") { session.setCacheDisabled(!session.cacheDisabled) })
        rows.append(.init(title: "Go offline", category: "Network") { session.networkTools.apply(.offline) })
        rows.append(.init(title: "Go online", category: "Network") { session.networkTools.apply(.unrestricted) })
        rows.append(.init(title: "Enable fast 4G throttling", category: "Network") { session.networkTools.apply(.fast4G) })
        rows.append(.init(title: "Enable slow 4G throttling", category: "Network") { session.networkTools.apply(.slow4G) })
        rows.append(.init(title: "Enable 3G throttling", category: "Network") { session.networkTools.apply(.threeG) })
        rows.append(.init(title: "Clear network log", category: "Network") { session.clearNetwork() })

        // Rendering.
        func render(_ title: String, _ change: @escaping (inout DeveloperRendering.Options) -> Void) {
            rows.append(.init(title: title, category: "Rendering") { rendering.update(in: session, change) })
        }
        let options = rendering.options
        render(options.paintFlashing ? "Hide paint flashing rectangles" : "Show paint flashing rectangles") { $0.paintFlashing.toggle() }
        render(options.layerBorders ? "Hide layer borders" : "Show layer borders") { $0.layerBorders.toggle() }
        render(options.layoutShifts ? "Hide layout shift regions" : "Show layout shift regions") { $0.layoutShifts.toggle() }
        render(options.frameStats ? "Hide frames per second (FPS) meter" : "Show frames per second (FPS) meter") { $0.frameStats.toggle() }
        render("Emulate CSS print media type") { $0.mediaType = "print" }
        render("Emulate CSS screen media type") { $0.mediaType = "screen" }
        render("Do not emulate CSS media type") { $0.mediaType = "" }
        render("Emulate CSS prefers-color-scheme: light") { $0.colorScheme = "Light" }
        render("Emulate CSS prefers-color-scheme: dark") { $0.colorScheme = "Dark" }
        render("Do not emulate CSS prefers-color-scheme") { $0.colorScheme = nil }
        render("Emulate CSS prefers-reduced-motion: reduce") { $0.reducedMotion = "Reduce" }
        render("Do not emulate CSS prefers-reduced-motion") { $0.reducedMotion = nil }
        // Every media feature the Rendering tool emulates, as Chrome lists them:
        // one command per value and one to stop.
        let features: [(name: String, values: [String], key: WritableKeyPath<DeveloperRendering.Options, String?>)] = [
            ("prefers-contrast", ["more", "less", "custom", "no-preference"], \.contrast),
            ("forced-colors", ["active", "none"], \.forcedColors),
            ("prefers-reduced-data", ["reduce"], \.reducedData),
            ("prefers-reduced-transparency", ["reduce", "no-preference"], \.reducedTransparency),
            ("color-gamut", ["srgb", "p3", "rec2020"], \.colorGamut),
        ]
        for feature in features {
            for value in feature.values {
                render("Emulate CSS \(feature.name): \(value)") { $0[keyPath: feature.key] = value }
            }
            render("Do not emulate CSS \(feature.name)") { $0[keyPath: feature.key] = nil }
        }
        render(options.focusedPage ? "Do not emulate a focused page" : "Emulate a focused page") { $0.focusedPage.toggle() }
        for deficiency in DeveloperRendering.VisionDeficiency.allCases {
            let title = deficiency == .none ? "Do not emulate any vision deficiency"
                : "Emulate " + deficiency.rawValue.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces).lowercased()
            rows.append(.init(title: title, category: "Rendering") { rendering.setVision(deficiency, in: session) })
        }

        // Performance.
        rows.append(.init(title: session.recordingTimeline ? "Stop recording" : "Start recording", category: "Performance",
                          shortcut: "⌘E") {
            session.select(.performance)
            session.toggleTimeline()
        })
        rows.append(.init(title: "Start profiling and reload page", category: "Performance", shortcut: "⇧⌘E") {
            session.select(.performance)
            session.toggleTimeline(reloading: true)
        })
        rows.append(.init(title: "Load profile…", category: "Performance", shortcut: "⌘O") {
            session.select(.performance)
            context.perform(.performanceProfile(save: false))
        })
        if !session.timeline.isEmpty {
            rows.append(.init(title: "Save profile…", category: "Performance", shortcut: "⌘S") {
                session.select(.performance)
                context.perform(.performanceProfile(save: true))
            })
        }

        // Screenshots.
        if let browser = context.browser {
            rows.append(.init(title: "Capture screenshot", category: "Screenshot") { browser.captureScreenshot() })
            rows.append(.init(title: "Capture full size screenshot", category: "Screenshot") { browser.captureFullSizeScreenshot() })
            rows.append(.init(title: "Capture node screenshot", category: "Screenshot") { browser.captureNodeScreenshot() })
            rows.append(.init(title: "Capture area screenshot", category: "Screenshot") { browser.captureAreaScreenshot() })
        }

        // Application.
        rows.append(.init(title: "Clear site data", category: "Application") { clearSiteData(in: context) })

        // Mobile, appearance and the window.
        rows.append(.init(title: context.viewportEnabled ? "Hide device toolbar" : "Toggle device toolbar",
                          category: "Mobile", shortcut: "⇧⌘M") { context.toggleViewport() })
        // The device toolbar's rulers, shown with Responsive as Chrome shows them.
        let deviceMode = DeveloperDeviceMode.shared
        rows.append(.init(title: deviceMode.settings.showRulers && context.viewportEnabled ? "Hide rulers" : "Show rulers",
                          category: "Mobile") {
            if context.viewportEnabled {
                deviceMode.settings.showRulers.toggle()
            } else {
                deviceMode.settings.showRulers = true
                context.toggleViewport()
            }
        })
        for position in DeveloperDockPosition.allCases {
            rows.append(.init(title: position.title, category: "Global") { tools.dockPosition = position })
        }
        rows.append(.init(title: "Toggle dock side", category: "Global", shortcut: "⇧⌘D") { tools.toggleDockSide() })
        rows.append(.init(title: "Zoom in", category: "Global", shortcut: "⌘+") { shell.zoom(by: 1) })
        rows.append(.init(title: "Zoom out", category: "Global", shortcut: "⌘−") { shell.zoom(by: -1) })
        rows.append(.init(title: "Reset zoom level", category: "Global", shortcut: "⌘0") { shell.zoom(by: 0) })
        rows.append(.init(title: "Reload page", category: "Global", shortcut: "⌘R") { session.reload() })
        rows.append(.init(title: shell.numberKeysSwitchPanels ? "Disable ⌘ + 1-9 shortcut to switch panels"
                                                              : "Enable ⌘ + 1-9 shortcut to switch panels",
                          category: "Global") { shell.numberKeysSwitchPanels.toggle() })

        // Settings.
        for section in DeveloperSettingsSection.allCases {
            rows.append(.init(title: "Show " + section.rawValue, category: "Settings",
                              shortcut: section == .preferences ? "F1" : "") {
                shell.settingsSection = section
                shell.settingsShown = true
            })
        }
        return rows
    }

    /// Clear site data, as Application › Storage clears it: everything
    /// stored for the inspected page's origin.
    private static func clearSiteData(in context: DeveloperToolsContext) {
        let session = context.session
        let browser = context.browser
        guard let page = session.web?.url, DeveloperApplication.origin(of: page) != nil else {
            browser?.announce("This page has no site data to clear")
            return
        }
        Task { @MainActor in
            do {
                let failed = try await DeveloperApplication.clearSiteData(Set(DeveloperSiteData.allCases), in: session,
                                                                          address: page)
                browser?.announce(failed.isEmpty ? "Site data cleared"
                                                 : "Could not clear: " + failed.joined(separator: ", "))
            } catch {
                browser?.announce("Could not clear site data")
            }
        }
    }
}

// MARK: View

/// The menu over DevTools: a field and the rows for what is typed. Its
/// arrows, Return and Esc are DeveloperToolsKeys', ahead of the field.
struct DeveloperCommandMenuView: View {
    let context: DeveloperToolsContext
    @ObservedObject var shell: DeveloperToolsShell
    @FocusState private var focused: Bool

    var body: some View {
        let menu = shell.commandMenu ?? DeveloperCommandMenuState(query: "")
        let rows = DeveloperCommandMenu.items(for: menu.query, in: context)
        let mode = DeveloperCommandMenuMode.parse(menu.query).mode
        ZStack(alignment: .top) {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { shell.commandMenu = nil }
            VStack(spacing: 0) {
                TextField(mode == .commands ? "Run a command" : "Search files or type ? for help", text: Binding(
                    get: { shell.commandMenu?.query ?? "" },
                    // The field hands its text back as it ends editing, after a
                    // command has closed the menu: that mustn't open it again
                    // (as Open file, its text gone).
                    set: { query in
                        guard shell.commandMenu != nil else { return }
                        shell.commandMenu = DeveloperCommandMenuState(query: query)
                    }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .accessibilityLabel("Command menu")
                Divider()
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                rowView(row, selected: index == menu.selection && !row.inert)
                                    .id(index)
                                    .onTapGesture { DeveloperCommandMenu.run(row, in: context) }
                            }
                        }
                    }
                    .frame(maxHeight: min(CGFloat(rows.count), 12) * 24)
                    .onChange(of: menu.selection) { _, selection in scroll.scrollTo(selection) }
                }
            }
            .background(DeveloperToolsStyle.surface)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(DeveloperToolsStyle.rule))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.top, 6)
        }
        .onAppear { focused = true }
        .onChange(of: shell.commandMenu == nil) { _, closed in if !closed { focused = true } }
    }

    private func rowView(_ row: DeveloperCommandItem, selected: Bool) -> some View {
        HStack(spacing: 8) {
            if !row.category.isEmpty {
                Text(row.category)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(DeveloperToolsStyle.raised, in: RoundedRectangle(cornerRadius: 3))
            }
            Text(row.title)
                .foregroundStyle(row.inert ? .secondary : Palette.ink)
                .lineLimit(1)
            if !row.detail.isEmpty {
                Text(row.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if !row.shortcut.isEmpty { Text(row.shortcut).foregroundStyle(.secondary) }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? DeveloperToolsStyle.selected : .clear)
        .contentShape(Rectangle())
    }
}
