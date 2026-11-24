import AppKit
import SwiftUI

/// The sections of Chrome DevTools' Settings (the gear, F1), as far as
/// Search has them.
enum DeveloperSettingsSection: String, CaseIterable, Identifiable {
    case preferences = "Preferences"
    case workspace = "Workspace"
    case ignoreList = "Ignore list"
    case throttling = "Throttling"
    case shortcuts = "Shortcuts"

    var id: Self { self }

    var icon: String {
        switch self {
        case .preferences: return "gearshape"
        case .workspace: return "folder"
        case .throttling: return "speedometer"
        case .ignoreList: return "eye.slash"
        case .shortcuts: return "keyboard"
        }
    }
}

/// DevTools' keyboard shortcuts, as Settings › Shortcuts lists them: the
/// ones DevTools' key routing answers can be given other keys
/// (DeveloperShortcutBindings); the rest are listed as they are.
enum DeveloperToolsShortcuts {
    struct ShortcutGroup {
        let group: String
        let items: [Item]
        init(_ group: String, _ items: [Item]) {
            self.group = group
            self.items = items
        }
    }

    struct Item {
        let title: String
        /// The keys, written out, for a shortcut that can't be changed.
        let keys: String
        /// The action, for one the user can give other keys.
        let action: DeveloperShortcutAction?

        static func fixed(_ title: String, _ keys: String) -> Item { Item(title: title, keys: keys, action: nil) }

        static func editable(_ action: DeveloperShortcutAction) -> Item {
            Item(title: action.title, keys: action.defaults.map(\.display).joined(separator: ", "), action: action)
        }
    }

    static let list: [ShortcutGroup] = [
        ShortcutGroup("All panels", [
            .editable(.commandMenu),
            .editable(.openFile),
            .editable(.goToSymbol),
            .editable(.settings),
            .editable(.toggleDrawer),
            .editable(.previousPanel),
            .editable(.nextPanel),
            .fixed("Switch to panel 1–9 (when on in Preferences)", "⌘1 … ⌘9"),
            .editable(.toggleDockSide),
            .editable(.toggleDeviceToolbar),
            .fixed("Search in panel", "⌘F"),
            .editable(.searchAllFiles),
            .editable(.zoomIn),
            .editable(.zoomOut),
            .editable(.resetZoom),
            .fixed("Reload page", "⌘R"),
            .fixed("Hard reload page", "⇧⌘R"),
            .fixed("Toggle Developer Tools", "⌥⌘I, F12"),
            .fixed("Show Console", "⌥⌘J"),
            .editable(.focusConsole),
            .fixed("Select an element in the page to inspect it", "⇧⌘C, ⌥⌘C"),
        ]),
        ShortcutGroup("Elements", [
            .fixed("Undo or redo change", "⌘Z, ⇧⌘Z"),
            .fixed("Select element above or below", "↑, ↓"),
            .fixed("Expand or collapse node", "→, ←"),
            .fixed("Expand or collapse node and its children", "⌥→, ⌥←"),
            .fixed("Edit attribute", "↩"),
            .fixed("Hide element", "H"),
            .fixed("Edit as HTML", "F2"),
            .fixed("Delete element", "⌫"),
            .fixed("Copy, cut or paste element", "⌘C, ⌘X, ⌘V"),
            .fixed("Find next or previous match", "⌘G, ⇧⌘G"),
        ]),
        ShortcutGroup("Styles", [
            .fixed("Increment or decrement value by 1", "↑, ↓"),
            .fixed("… by 10", "⇧↑, ⇧↓"),
            .fixed("… by 0.1", "⌥↑, ⌥↓"),
            .fixed("… by 100", "⌘↑, ⌘↓"),
            .fixed("… by 10 or 100", "Page Up, Page Down, with ⇧ for 100"),
            .fixed("Edit next or previous property", "⇥, ⇧⇥"),
            .fixed("Previous or next declaration (name not edited)", "↑, ↓"),
            .fixed("Color picker or CSS function tooltip", "⌥↓ with no number at the caret"),
            .fixed("Go to the rule in its style sheet", "⌘-click name or value"),
            .fixed("Change color format", "⇧-click swatch"),
        ]),
        ShortcutGroup("Debugger", [
            .editable(.pauseResume),
            .editable(.stepOver),
            .editable(.stepInto),
            .editable(.stepOut),
            .editable(.step),
            .editable(.nextCallFrame),
            .editable(.previousCallFrame),
            .fixed("Continue to here", "⌘-click a line"),
            .editable(.toggleBreakpoints),
        ]),
        ShortcutGroup("Sources", [
            .editable(.goToLine),
            .fixed("Find in file", "⌘F"),
            .fixed("Find next or previous", "⌘G, ⇧⌘G"),
            .fixed("Use selection for find", "⌘E"),
            .fixed("Save", "⌘S"),
            .editable(.saveAll),
            .fixed("Run snippet", "⌘↩"),
            .fixed("Close the active tab", "⌥W"),
            .editable(.nextTab),
            .editable(.previousTab),
            .editable(.toggleNavigator),
            .editable(.toggleDebuggerSidebar),
            .fixed("Evaluate selection in Console", "⌃⇧E"),
            .fixed("Add selection to watch", "⌃⇧A"),
            .editable(.expandSearchResults),
            .editable(.collapseSearchResults),
        ]),
        ShortcutGroup("Code editor", [
            .fixed("Toggle breakpoint", "⌘B"),
            .fixed("Edit breakpoint", "⌥⌘B"),
            .fixed("Conditional breakpoint", "⌘-click line number"),
            .fixed("Logpoint", "⇧⌘-click line number"),
            .fixed("Toggle comment", "⌘/"),
            .fixed("Select next occurrence", "⌘D"),
            .fixed("Undo last selection", "⌘U"),
            .fixed("More selections", "⌘-drag, ⌥-drag for a column"),
            .fixed("Back to one selection", "Esc"),
            .fixed("Go to matching bracket", "⌃M"),
            .fixed("Delete word before caret", "⌥⌫"),
        ]),
        ShortcutGroup("Console", [
            .editable(.clearConsole),
            .fixed("Accept suggestion", "⇥, →"),
            .fixed("Reject suggestion", "Esc"),
            .fixed("Previous or next suggestion", "↑, ↓, ⌃P, ⌃N"),
            .fixed("Previous or next command", "↑, ↓"),
            .fixed("New line", "⇧↩"),
            .fixed("Run", "↩"),
            .editable(.searchConsole),
            .fixed("Expand all sub-properties", "⌥-click ▸"),
        ]),
        ShortcutGroup("Network", [
            .editable(.recordNetwork),
            .fixed("Record a reload", "⌘R"),
            .editable(.searchNetwork),
            .fixed("Hide the request's details", "Esc"),
        ]),
        ShortcutGroup("Performance", [
            .editable(.recordPerformance),
            .editable(.recordReload),
            .editable(.saveProfile),
            .editable(.loadProfile),
            .editable(.searchPerformance),
        ]),
    ]

    /// Every action the list lets the user give other keys.
    static var actions: [DeveloperShortcutAction] { list.flatMap { $0.items.compactMap(\.action) } }
}

/// Chrome DevTools' Settings, shown over DevTools.
struct DeveloperSettingsView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var tools: DeveloperTools
    @ObservedObject var shell: DeveloperToolsShell
    @Environment(\.developerDismiss) private var dismiss

    /// The chosen section's white, slid from one to the next as in the
    /// browser's Settings.
    @Namespace private var chosen

    /// The browser's Settings, in DevTools' sections: the rail on the left,
    /// the section's icon and title over its settings, and a cross to close.
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                ForEach(DeveloperSettingsSection.allCases) { item in
                    SettingsRailRow(icon: item.icon, title: item.rawValue, on: shell.settingsSection == item,
                                    count: nil, chosen: chosen) { shell.settingsSection = item }
                }
                Spacer(minLength: 0)
            }
            .animation(Motion.reduced ? nil : .spring(response: 0.45, dampingFraction: 0.72), value: shell.settingsSection)
            .padding(8)
            .frame(width: 180, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Palette.wash.opacity(0.45), in: Rectangle())
            Rectangle().fill(Palette.hairline).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: shell.settingsSection.icon).font(.system(size: 15, weight: .medium))
                    Text(shell.settingsSection.rawValue).font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Door(icon: "xmark", help: "Done   esc") { dismiss() }
                }
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        section(shell.settingsSection)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(shell.settingsSection)
            }
            .padding(.top, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Palette.ink)
        .toggleStyle(.developerCheckbox)
        .buttonStyle(PillStyle())
        .tint(DeveloperToolsStyle.tint)
        .background(Palette.ground)
        // Esc closes it, as Done did.
        .background { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).opacity(0).allowsHitTesting(false) }
        .frame(width: 720, height: 520)
        // Drawn by the window, outside DevTools' host view: the theme comes with it.
        .developerToolsThemed()
    }

    @ViewBuilder
    private func section(_ section: DeveloperSettingsSection) -> some View {
        switch section {
        case .preferences:
            DeveloperPreferencesSettings(session: session, store: session.consoleStore, debugger: session.debugger,
                                         tools: tools, shell: shell)
        case .workspace: DeveloperWorkspaceSettings(session: session)
        case .throttling: DeveloperThrottlingSettings(tools: session.networkTools)
        case .ignoreList: DeveloperIgnoreListSettings(debugger: session.debugger)
        case .shortcuts: DeveloperShortcutsSettings()
        }
    }
}

/// Settings › Shortcuts: each action's keys, which a click records anew,
/// and the preset they match. Drawn as the browser's own Settings ›
/// Shortcuts is: a card a group, a line an action, its keys in a box.
private struct DeveloperShortcutsSettings: View {
    @ObservedObject private var store = DeveloperShortcutStore.shared
    @StateObject private var recorder = DeveloperShortcutRecorder()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line("Match shortcuts from preset", "Click a shortcut to record a new one; Esc cancels.") {
                    Picker("Match shortcuts from preset", selection: Binding(
                        get: { store.bindings.preset },
                        set: { preset in
                            recorder.stop()
                            store.apply(preset)
                        })) {
                        ForEach(DeveloperShortcutPreset.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            ForEach(DeveloperToolsShortcuts.list, id: \.group) { group in
                DeveloperSettingsGroup(group.group) {
                    ForEach(Array(group.items.enumerated()), id: \.element.title) { index, item in
                        if index > 0 { Rule() }
                        if let action = item.action {
                            editableLine(action)
                        } else {
                            Line(item.title) { DeveloperShortcutKeyCap(text: item.keys) }
                        }
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                DeveloperSettingsNote("Inside DevTools these keys are DevTools’, as in Chrome; elsewhere they keep the browser’s meaning.")
                Spacer(minLength: 0)
                Button("Restore default shortcuts") {
                    recorder.stop()
                    store.apply(.devTools)
                }
                .disabled(store.bindings == DeveloperShortcutBindings())
            }
        }
        .onDisappear { recorder.stop() }
    }

    private func editableLine(_ action: DeveloperShortcutAction) -> some View {
        let shortcuts = store.bindings.shortcuts(for: action)
        let recording = recorder.action == action
        let overridden = store.bindings.isOverridden(action)
        let conflicts = overridden ? store.bindings.conflicts(for: action) : []
        return Line(action.title,
                    conflicts.isEmpty ? nil : "Also the shortcut for \(conflicts.map(\.title).joined(separator: ", ")).") {
            HStack(spacing: 8) {
                if overridden {
                    Button("Reset") {
                        recorder.stop()
                        store.reset(action)
                    }
                    .help("Put back the default shortcut")
                }
                Button {
                    recorder.toggle(action, store: store)
                } label: {
                    DeveloperShortcutKeyCap(
                        text: recording ? "Press a shortcut…"
                            : shortcuts.isEmpty ? "None" : shortcuts.map(\.display).joined(separator: ", "),
                        editable: true, recording: recording, changed: overridden, empty: shortcuts.isEmpty
                    )
                }
                .buttonStyle(.plain)
                .help("Click to record a new shortcut for \(action.title)")
                .accessibilityLabel("Shortcut for \(action.title)")
            }
        }
    }
}

private struct DeveloperShortcutKeyCap: View {
    let text: String
    var editable = false
    var recording = false
    var changed = false
    var empty = false
    @State private var hovering = false

    var body: some View {
        let outline = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Text(text)
            .font(.system(size: 12, weight: changed ? .semibold : .regular))
            .foregroundStyle(editable && (recording || !empty) ? Palette.ink : Palette.muted)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minWidth: 64, minHeight: 24)
            .background {
                if editable { outline.fill(recording || hovering ? Palette.hover : Palette.ground) }
            }
            .overlay(outline.strokeBorder(recording ? Palette.ink.opacity(0.4) : Palette.hairline, lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { hovering = editable && $0 }
    }
}

private struct DeveloperPreferencesSettings: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var store: DeveloperConsoleStore
    @ObservedObject var debugger: DeveloperDebugger
    @ObservedObject var tools: DeveloperTools
    @ObservedObject var shell: DeveloperToolsShell
    /// Chrome's Sources preferences; DeveloperSourceMaps reads them.
    @AppStorage(DeveloperSourceMaps.javaScriptKey, store: DevDefaults.store) private var javaScriptSourceMaps = true
    @AppStorage(DeveloperSourceMaps.cssKey, store: DevDefaults.store) private var cssSourceMaps = true
    @AppStorage(DeveloperElementsSettings.userAgentShadowDOMKey, store: DevDefaults.store) private var userAgentShadowDOM = false
    @AppStorage(DeveloperElementsSettings.wordWrapKey, store: DevDefaults.store) private var wordWrap = false
    @AppStorage(DeveloperElementsSettings.commentsKey, store: DevDefaults.store) private var comments = true
    @AppStorage(DeveloperElementsSettings.rulersKey, store: DevDefaults.store) private var rulers = true
    @AppStorage(DeveloperElementsSettings.detailedTooltipKey, store: DevDefaults.store) private var detailedTooltip = true
    @AppStorage(DeveloperSourcesPreferences.codeFoldingKey, store: DevDefaults.store) private var codeFolding = false
    @AppStorage(DeveloperSourcesPreferences.searchContentScriptsKey, store: DevDefaults.store) private var searchContentScripts = false
    @AppStorage(DeveloperSourcesPreferences.autoRevealKey, store: DevDefaults.store) private var autoReveal = true
    @AppStorage(DeveloperSourcesPreferences.inlineValuesKey, store: DevDefaults.store) private var inlineValues = true
    @AppStorage(DeveloperSourcesPreferences.tabMovesFocusKey, store: DevDefaults.store) private var tabMovesFocus = false
    @AppStorage(DeveloperSourcesPreferences.detectIndentationKey, store: DevDefaults.store) private var detectIndentation = true
    @AppStorage(DeveloperSourcesPreferences.defaultIndentationKey, store: DevDefaults.store) private var defaultIndentation = DeveloperSourcesPreferences.defaultIndentation
    @AppStorage(DeveloperSourcesPreferences.scrollPastEndKey, store: DevDefaults.store) private var scrollPastEnd = true
    /// Chrome's AI assistance, answered here by the on-device model.
    @AppStorage(DeveloperDebugger.asyncStackTracesDisabledKey, store: DevDefaults.store) private var asyncStacksDisabled = false
    @AppStorage(DeveloperNetworkTypeColors.key, store: DevDefaults.store) private var colorCodeTypes = true
    @AppStorage(DeveloperFlameChartNavigation.key, store: DevDefaults.store)
    private var flameNavigation = DeveloperFlameChartNavigation.modern
    @ObservedObject private var theme = DeveloperToolsThemeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("Appearance") {
                dropdown("Theme", selection: $theme.theme,
                         options: DeveloperToolsTheme.allCases.map { ($0, $0.title) })
                    .help("System preference follows the browser’s light or dark appearance.")
                dropdown("Panel layout", selection: $tools.dockPosition,
                         options: DeveloperDockPosition.allCases.map { ($0, $0.title) })
                row("Zoom") {
                    HStack(spacing: 4) {
                        Button("−") { shell.zoom(by: -1) }
                            .accessibilityLabel("Zoom out")
                        Text("\(Int((shell.scale * 100).rounded()))%").monospacedDigit()
                            .frame(minWidth: 40)
                        Button("+") { shell.zoom(by: 1) }
                            .accessibilityLabel("Zoom in")
                        Spacer(minLength: 0)
                        Button("Reset") { shell.zoom(by: 0) }.disabled(shell.scale == 1)
                            .accessibilityLabel("Reset zoom")
                    }
                }
            }
            group("Global") {
                Toggle("Enable ⌘ + 1-9 shortcut to switch panels", isOn: $shell.numberKeysSwitchPanels)
            }
            group("Elements") {
                Toggle("Show user agent shadow DOM", isOn: $userAgentShadowDOM)
                Toggle("Word wrap", isOn: $wordWrap)
                Toggle("Show HTML comments", isOn: $comments)
                Toggle("Show rulers on hover", isOn: $rulers)
                Toggle("Show detailed inspect tooltip", isOn: $detailedTooltip)
            }
            .onChange(of: userAgentShadowDOM) { _, _ in session.elementsSettingsChanged() }
            .onChange(of: comments) { _, _ in session.elementsSettingsChanged() }
            .onChange(of: rulers) { _, on in
                if !on { Task { await session.showRulers(false, target: session.domTargetID) } }
            }
            group("Console") {
                Toggle("Preserve log upon navigation", isOn: $session.preserveConsoleLog)
                Toggle("Log XMLHttpRequests", isOn: $store.settings.logXMLHttpRequests)
                Toggle("Show network messages", isOn: $store.settings.networkMessages)
                Toggle("Show CORS errors in console", isOn: $store.settings.corsErrors)
                Toggle("Eager evaluation", isOn: $store.settings.eagerEvaluation)
                Toggle("Autocomplete from history", isOn: $store.settings.historyAutocomplete)
                Toggle("Group similar messages in console", isOn: $store.settings.groupSimilar)
                Toggle("Treat code evaluation as user action", isOn: $store.settings.userActivation)
                Toggle("Enable custom formatters", isOn: $store.settings.customFormatters)
            }
            group("Sources") {
                Toggle("Search in anonymous and content scripts", isOn: $searchContentScripts)
                Toggle("Automatically reveal files in sidebar", isOn: $autoReveal)
                Toggle("Show ignore-listed sources", isOn: $debugger.showIgnoreListed)
                Toggle("Enable JavaScript source maps", isOn: $javaScriptSourceMaps)
                Toggle("Tab moves focus", isOn: $tabMovesFocus)
                Toggle("Detect indentation", isOn: $detectIndentation)
                Toggle("Code folding", isOn: $codeFolding)
                Toggle("Display variable values inline while debugging", isOn: $inlineValues)
                Toggle("Enable CSS source maps", isOn: $cssSourceMaps)
                Toggle("Allow scrolling past end of file", isOn: $scrollPastEnd)
                dropdown("Default indentation", selection: $defaultIndentation,
                         options: DeveloperSourcesPreferences.indentationChoices.map { ($0.value, $0.title) })
            }
            .onChange(of: javaScriptSourceMaps) { _, _ in session.sourceMaps.settingsChanged() }
            .onChange(of: cssSourceMaps) { _, _ in session.sourceMaps.settingsChanged() }
            group("Debugger") {
                Toggle("Disable async stack traces", isOn: $asyncStacksDisabled)
            }
            .onChange(of: asyncStacksDisabled) { _, _ in debugger.asyncStackTracesSettingChanged() }
            group("Network") {
                Toggle("Preserve log", isOn: $session.preserveNetworkLog)
                Toggle("Record network log", isOn: $session.recordNetwork)
                Toggle("Disable cache (while DevTools is open)", isOn: Binding(
                    get: { session.cacheDisabled }, set: { session.setCacheDisabled($0) }))
                Toggle("Color-code resource types", isOn: $colorCodeTypes)
            }
            group("Performance") {
                dropdown("Flamechart mouse wheel action", selection: $flameNavigation,
                         options: DeveloperFlameChartNavigation.allCases.map { ($0, $0.title) })
                    .help("Modern: scroll moves, ⌘-scroll zooms. Classic: scroll zooms, Shift-scroll moves up and down.")
            }
        }
        .toggleStyle(.developerCheckbox)
    }

    /// A titled section of preferences, as Chrome's Settings lays them out.
    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DeveloperSettingsHeading(title)
            content()
        }
    }

    private func dropdown<Value: Hashable>(_ label: String, selection: Binding<Value>,
                                           options: [(Value, String)]) -> some View {
        row(label) {
            DeveloperSettingsDropdown(label: label, selection: selection, options: options)
        }
    }

    /// Keep controls on one trailing edge across the Preferences groups.
    private func row<Control: View>(_ label: String, @ViewBuilder _ control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(label)
            Spacer(minLength: 12)
            control()
                .frame(maxWidth: .infinity)
                .frame(width: 180, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A menu whose label fills its column and marks exactly one item as selected.
struct DeveloperSettingsDropdown<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(Value, String)]

    private var selectedTitle: String { options.first { $0.0 == selection }?.1 ?? "" }

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Toggle(option.1, isOn: isOn(option.0))
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.wash))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(label)
        .accessibilityValue(selectedTitle)
    }

    func isOn(_ value: Value) -> Binding<Bool> {
        Binding(get: { selection == value }, set: { if $0 { selection = value } })
    }
}

/// Settings › Workspace: the folders in the workspace, and the pattern of
/// the files and folders left out of them.
private struct DeveloperWorkspaceSettings: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject private var workspace = DeveloperWorkspace.shared
    @State private var pattern = ""
    @AppStorage(DeveloperWorkspace.automaticFoldersKey, store: DevDefaults.store) private var automaticFolders = true

    private var page: String? { session.address?.absoluteString }

    var body: some View {
        let valid = DeveloperWorkspace.isValidExcludePattern(pattern)
        VStack(alignment: .leading, spacing: 18) {
            DeveloperSettingsGroup("Workspace folders") {
                if workspace.folders.isEmpty {
                    Line("No folders are in the workspace", "Add one to edit the inspected page’s files on disk.") { EmptyView() }
                }
                ForEach(Array(workspace.folders.enumerated()), id: \.element.id) { index, folder in
                    if index > 0 { Rule() }
                    Line(folder.name, folder.path) {
                        HStack(spacing: 8) {
                            Text(folder.origin).font(.system(size: 11.5)).foregroundStyle(Palette.muted).lineLimit(1)
                            Button("Remove") { workspace.remove(folder) }
                        }
                    }
                    .help(folder.path)
                }
                Rule()
                DeveloperSettingsFoot {
                    Button("Add folder…") { workspace.chooseFolder(for: page, session: session) }
                        .disabled(page.flatMap(DeveloperWorkspace.origin(of:)) == nil)
                        .help("Add folder to workspace for the inspected page’s origin")
                }
            }
            DeveloperSettingsGroup("Folder exclude pattern") {
                DeveloperSettingsFoot {
                    TextField("", text: $pattern)
                        .font(DeveloperToolsStyle.code)
                        .foregroundStyle(valid ? Color.primary : Color.red)
                        .onSubmit(commitPattern)
                        .accessibilityLabel("Folder exclude pattern")
                    Button("Restore default") {
                        pattern = DeveloperWorkspace.defaultExcludePattern
                        commitPattern()
                    }
                    .disabled(pattern == DeveloperWorkspace.defaultExcludePattern)
                }
            }
            DeveloperSettingsNote(valid
                ? "Files and folders whose paths match this regular expression are left out of the workspace. Press Return to apply it."
                : "This pattern is not a valid regular expression, so it is ignored.")
            Card {
                Line("Automatic workspace folders",
                     "Offers to connect the folder a local development server names in com.chrome.devtools.json.") {
                    Toggle(isOn: $automaticFolders) { EmptyView() }
                        .accessibilityLabel("Automatic workspace folders")
                }
            }
        }
        .onAppear { pattern = workspace.excludePattern }
        .onDisappear(perform: commitPattern)
    }

    private func commitPattern() {
        workspace.setExcludePattern(pattern)
    }
}


/// Settings › Throttling: the custom network profiles the throttling
/// menus offer, and a new one added in place.
private struct DeveloperThrottlingSettings: View {
    @ObservedObject var tools: DeveloperNetworkTools
    @State private var name = ""
    @State private var download = ""
    @State private var upload = ""
    @State private var latency = "0"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DeveloperSettingsGroup("Network throttling profiles") {
                if tools.profiles.isEmpty {
                    Line("No custom profiles", "A profile added below is offered in Network’s throttling menu.") { EmptyView() }
                }
                ForEach(Array(tools.profiles.enumerated()), id: \.element.id) { index, profile in
                    if index > 0 { Rule() }
                    Line(profile.name, detail(profile)) {
                        Button("Remove") { tools.profiles.removeAll { $0.id == profile.id } }
                    }
                }
            }
            DeveloperSettingsGroup("Add profile") {
                DeveloperSettingsFieldLine("Profile name") { TextField("", text: $name) }
                Rule()
                DeveloperSettingsFieldLine("Download (kbit/s)") { TextField("No limit", text: $download) }
                Rule()
                DeveloperSettingsFieldLine("Upload (kbit/s)") { TextField("No limit", text: $upload) }
                Rule()
                DeveloperSettingsFieldLine("Latency (ms)") { TextField("", text: $latency) }
                Rule()
                DeveloperSettingsFoot {
                    Spacer()
                    Button("Add profile", action: add)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || Double(latency) == nil)
                }
            }
            DeveloperSettingsNote(tools.bandwidthThrottling
                ? "Download is applied with WebKit’s network emulation; WebKit has one limit for both directions."
                : "This version of WebKit can’t limit bandwidth, so only the latency applies.")
        }
    }

    private func add() {
        tools.profiles.append(.init(name: name.trimmingCharacters(in: .whitespaces), download: Double(download) ?? 0,
                                    upload: Double(upload) ?? 0, latency: min(5_000, max(0, Double(latency) ?? 0))))
        name = ""
        download = ""
        upload = ""
        latency = "0"
    }

    private func detail(_ profile: DeveloperNetworkTools.ThrottlingProfile) -> String {
        func rate(_ value: Double) -> String { value > 0 ? "\(Int(value)) kbit/s" : "no limit" }
        return "↓ \(rate(profile.download))  ↑ \(rate(profile.upload))  \(Int(profile.latency)) ms"
    }
}


/// Settings › Ignore list: the scripts the debugger steps over and never
/// pauses in, for this page (WebKit's blackboxing).
private struct DeveloperIgnoreListSettings: View {
    @ObservedObject var debugger: DeveloperDebugger
    @State private var draft = ""
    @State private var patternDraft = ""
    @State private var patternInvalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DeveloperSettingsNote("Scripts on the ignore list are skipped when stepping, and the debugger doesn’t pause in them.")
            Card {
                Line("Automatically add known third-party scripts to ignore list",
                     "Sources a source map lists in its ignoreList.") {
                    Toggle(isOn: $debugger.ignoreThirdParty) { EmptyView() }
                        .accessibilityLabel("Automatically add known third-party scripts to ignore list")
                }
                Rule()
                Line("Ignore anonymous scripts from eval or console") {
                    Toggle(isOn: $debugger.ignoreAnonymous) { EmptyView() }
                        .accessibilityLabel("Ignore anonymous scripts from eval or console")
                }
            }
            DeveloperSettingsGroup("Custom exclusion rules") {
                ForEach(debugger.ignorePatterns) { item in
                    DeveloperIgnorePatternRow(debugger: debugger, item: item)
                    Rule()
                }
                DeveloperSettingsFoot {
                    TextField("/framework\\.js$", text: $patternDraft)
                        .font(DeveloperToolsStyle.code)
                        .onSubmit(addPattern)
                        .onChange(of: patternDraft) { _, _ in patternInvalid = false }
                        .accessibilityLabel("Pattern")
                    Button("Add pattern", action: addPattern)
                        .disabled(patternDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if patternInvalid {
                Text("This pattern is not a valid regular expression, or is already on the list.")
                    .font(.system(size: 11.5)).foregroundStyle(.red)
            }
            DeveloperSettingsGroup("Scripts") {
                ForEach(debugger.ignoredScripts.sorted(), id: \.self) { url in
                    Line(url) {
                        Button("Remove") { debugger.setIgnored(url, false) }
                    }
                    .textSelection(.enabled)
                    Rule()
                }
                DeveloperSettingsFoot {
                    TextField("Script URL", text: $draft).onSubmit(add)
                    Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func add() {
        let url = draft.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        debugger.setIgnored(url, true)
        draft = ""
    }

    private func addPattern() {
        guard !patternDraft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if debugger.addIgnorePattern(patternDraft) { patternDraft = "" } else { patternInvalid = true }
    }
}

/// One custom exclusion rule: its checkbox, the pattern (edited in
/// place, kept on Return), and Remove, on a line of its card.
private struct DeveloperIgnorePatternRow: View {
    @ObservedObject var debugger: DeveloperDebugger
    let item: DeveloperDebugger.IgnorePattern
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { item.enabled }, set: { debugger.setIgnorePattern(item.pattern, enabled: $0) })) {
                EmptyView()
            }
            .accessibilityLabel("Ignore scripts matching \(item.pattern)")
            TextField("Pattern", text: $text)
                .textFieldStyle(.plain)
                .font(DeveloperToolsStyle.code)
                .foregroundStyle(invalid ? Color.red : Palette.ink)
                .onSubmit(commit)
                .onChange(of: text) { _, _ in invalid = false }
            Button("Remove") { debugger.removeIgnorePattern(item.pattern) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .onAppear { text = item.pattern }
        .onChange(of: item.pattern) { _, pattern in text = pattern }
        .help(invalid ? "This pattern is not a valid regular expression." : item.pattern)
    }

    private func commit() {
        if !debugger.replaceIgnorePattern(item.pattern, with: text) { invalid = true }
    }
}
