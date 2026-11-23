import AppKit
import SwiftUI

/// The right-hand sidebar of Chrome's Sources panel: Watch, Breakpoints,
/// Scope, Call Stack, XHR/fetch, DOM and event listener breakpoints, under
/// the "Paused on …" message.
struct DeveloperDebuggerSidebar: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var debugger: DeveloperDebugger
    @State private var collapsed: Set<Pane> = [.watch, .xhr, .dom, .events, .csp]
    @State private var addingWatch = false
    @State private var newWatch = ""
    @State private var editingWatch: DeveloperDebugger.Watch.ID?
    @State private var editedWatch = ""
    @State private var addingURL = false
    @State private var newURL = ""
    @State private var editingBreakpoint: DeveloperDebugger.Breakpoint.ID?
    /// The Scope or Watch row whose value is being changed.
    @State private var editingValue: String?
    @State private var editedValue = ""
    @State private var eventFilter = ""
    @State private var openCategories = Set<String>()

    init(session: DeveloperToolsSession) {
        self.session = session
        debugger = session.debugger
    }

    enum Pane: String, CaseIterable {
        case watch = "Watch", breakpoints = "Breakpoints", scope = "Scope", threads = "Threads", callStack = "Call Stack"
        case xhr = "XHR/fetch breakpoints", dom = "DOM breakpoints", events = "Event listener breakpoints"
        case csp = "CSP violation breakpoints"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let pause = debugger.pause { pausedMessage(pause) }
                PaneView(sidebar: self, pane: .watch)
                PaneView(sidebar: self, pane: .breakpoints)
                PaneView(sidebar: self, pane: .scope)
                // Chrome shows Threads once the page has a worker.
                if !session.workers.isEmpty { PaneView(sidebar: self, pane: .threads) }
                PaneView(sidebar: self, pane: .callStack)
                PaneView(sidebar: self, pane: .xhr)
                PaneView(sidebar: self, pane: .dom)
                PaneView(sidebar: self, pane: .events)
                PaneView(sidebar: self, pane: .csp)
            }
        }
        .background(DeveloperDebuggerShortcuts(session: session, debugger: debugger))
        .onChange(of: debugger.pause != nil) { _, paused in
            // Chrome brings Scope and Call Stack forward on a pause.
            if paused { collapsed.subtract([.scope, .threads, .callStack]) }
        }
    }

    /// One pane as a view of its own type, so the sidebar's type (and the
    /// modifiers on it) names eight short types instead of spelling out
    /// every pane's contents again at each step (__swift5_typeref size).
    /// It watches what the panes read, as the sidebar does.
    private struct PaneView: View {
        let sidebar: DeveloperDebuggerSidebar
        let pane: Pane
        @ObservedObject private var session: DeveloperToolsSession
        @ObservedObject private var debugger: DeveloperDebugger

        init(sidebar: DeveloperDebuggerSidebar, pane: Pane) {
            self.sidebar = sidebar
            self.pane = pane
            session = sidebar.session
            debugger = sidebar.debugger
        }

        var body: some View {
            switch pane {
            case .watch: sidebar.pane(.watch, actions: { sidebar.watchActions }) { sidebar.watchPane }
            case .breakpoints: sidebar.pane(.breakpoints) { sidebar.breakpointsPane }
            case .scope: sidebar.pane(.scope) { sidebar.scopePane }
            case .threads: sidebar.pane(.threads) { sidebar.threadsPane }
            case .callStack: sidebar.pane(.callStack) { sidebar.callStackPane }
            case .xhr: sidebar.pane(.xhr, actions: { sidebar.xhrActions }) { sidebar.xhrPane }
            case .dom: sidebar.pane(.dom) { sidebar.domPane }
            case .events: sidebar.pane(.events) { sidebar.eventsPane }
            case .csp: sidebar.pane(.csp) { sidebar.cspPane }
            }
        }
    }

    // MARK: Paused message

    private func pausedMessage(_ pause: DeveloperDebugger.Pause) -> some View {
        let color: Color = pause.errorLike ? .red : .yellow
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: pause.errorLike ? "xmark.circle.fill" : "info.circle")
                .foregroundStyle(pause.errorLike ? Color.red : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(pause.message).fontWeight(.medium)
                if let detail = pause.detail, !detail.isEmpty {
                    Text(detail).font(DeveloperToolsStyle.code).lineLimit(2).foregroundStyle(.secondary).help(detail)
                        .textSelection(.enabled)
                }
                if debugger.recurring { escapeActions }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(pause.errorLike ? 0.12 : 0.18))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    /// Chrome's way out of a pause that keeps recurring at one place.
    @ViewBuilder private var escapeActions: some View {
        HStack(spacing: 6) {
            if let breakpoint = debugger.pausedBreakpoint {
                Button("Disable breakpoint") { debugger.setBreakpointEnabled(breakpoint.id, false) }
            } else if let frame = debugger.pause?.frames.first, !frame.url.isEmpty {
                Button("Never pause here") { debugger.neverPauseHere(url: frame.url, line: frame.line + 1) }
            }
            Button("Deactivate all") { debugger.deactivateBreakpointsAndResume() }.buttonStyle(.borderless)
        }
        .controlSize(.mini)
        .padding(.top, 3)
    }

    // MARK: Panes

    private func pane<Content: View, Actions: View>(_ pane: Pane, @ViewBuilder actions: () -> Actions,
                                                    @ViewBuilder content: () -> Content) -> some View {
        let open = !collapsed.contains(pane)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                Button {
                    if open { collapsed.insert(pane) } else { collapsed.remove(pane) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                        Text(pane.rawValue).fontWeight(.semibold).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pane.rawValue)
                .accessibilityValue(open ? "expanded" : "collapsed")
                if open { actions() }
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.toolbarHeight)
            .background(DeveloperToolsStyle.chrome)
            .overlay(alignment: .bottom) { Divider() }
            if open {
                content().frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
                Divider()
            }
        }
    }

    private func pane<Content: View>(_ pane: Pane, @ViewBuilder content: () -> Content) -> some View {
        self.pane(pane, actions: { EmptyView() }, content: content)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).italic()
            .padding(.horizontal, DeveloperToolsStyle.gutter + 14).frame(minHeight: DeveloperToolsStyle.rowHeight)
    }

    // MARK: Watch

    @ViewBuilder private var watchActions: some View {
        DeveloperPanelIcon(symbol: "plus", title: "Add watch expression", size: 18) {
            addingWatch = true
            newWatch = ""
        }
        DeveloperPanelIcon(symbol: "arrow.clockwise", title: "Refresh watch expressions", size: 18) {
            debugger.refreshWatches()
        }
    }

    @ViewBuilder private var watchPane: some View {
        if debugger.watches.isEmpty && !addingWatch { placeholder("No watch expressions") }
        ForEach(debugger.watches) { watch in
            if editingWatch == watch.id {
                expressionField($editedWatch) {
                    debugger.editWatch(watch.id, expression: editedWatch)
                    editingWatch = nil
                } cancel: { editingWatch = nil }
            } else {
                let path = "watch:\(watch.id.uuidString)"
                ForEach(debugger.objectRows(path: path, name: watch.expression, value: watch.value,
                                            missing: watch.evaluated ? "<not available>" : nil, depth: 0,
                                            root: .expression(watch.expression))) { row in
                    objectRow(row)
                        .onTapGesture(count: 2) {
                            if row.depth == 0 { editedWatch = watch.expression; editingWatch = watch.id }
                            else { startEditing(row) }
                        }
                        .contextMenu {
                            if row.depth == 0 {
                                Button("Delete watch expression") { debugger.removeWatch(watch.id) }
                                Button("Delete all watch expressions") { debugger.removeAllWatches() }
                                Divider()
                            }
                            DeveloperObjectMenu(debugger: debugger, row: row)
                        }
                        .overlay(alignment: .trailing) {
                            if row.depth == 0 {
                                DeveloperHoverButton(symbol: "xmark", title: "Delete watch expression") {
                                    debugger.removeWatch(watch.id)
                                }
                            }
                        }
                }
            }
        }
        if addingWatch {
            expressionField($newWatch) {
                debugger.addWatch(newWatch)
                addingWatch = false
            } cancel: { addingWatch = false }
        }
    }

    private func expressionField(_ text: Binding<String>, commit: @escaping () -> Void,
                                 cancel: @escaping () -> Void) -> some View {
        DeveloperFocusedField(text: text, placeholder: "Expression", commit: commit, cancel: cancel)
            .padding(.leading, DeveloperToolsStyle.gutter + 14).padding(.trailing, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.rowHeight)
    }

    // MARK: Breakpoints

    @ViewBuilder private var breakpointsPane: some View {
        VStack(alignment: .leading, spacing: DeveloperToolsStyle.stackSpacing) {
            Toggle("Pause on uncaught exceptions", isOn: Binding(
                get: { debugger.pauseOnUncaught },
                set: { debugger.setPauseOnExceptions(uncaught: $0, caught: debugger.pauseOnCaught) }))
            Toggle("Pause on caught exceptions", isOn: Binding(
                get: { debugger.pauseOnCaught },
                set: { debugger.setPauseOnExceptions(uncaught: debugger.pauseOnUncaught, caught: $0) }))
                .help("WebKit has no caught-only setting, so this pauses on every exception, caught or not.")
            if debugger.pauseOnCaught && !debugger.pauseOnUncaught {
                // Said on screen, not only in a tooltip: the state differs from Chrome's.
                Text("WebKit also pauses on uncaught exceptions while this is on.")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
            }
        }
        .toggleStyle(.developerCheckbox)
        .padding(.leading, DeveloperToolsStyle.paneInset).padding(.trailing, DeveloperToolsStyle.gutter)
        .padding(.vertical, DeveloperToolsStyle.stackSpacing)
        if !debugger.breakpointsActive {
            Text("Breakpoints are deactivated").foregroundStyle(.secondary)
                .padding(.leading, DeveloperToolsStyle.paneInset).padding(.trailing, DeveloperToolsStyle.gutter)
                .frame(height: DeveloperToolsStyle.rowHeight)
        }
        ForEach(breakpointFiles, id: \.self) { url in
            let items = debugger.breakpoints.filter { $0.url == url }
            breakpointFile(url, items: items)
            ForEach(items) { item in breakpointRow(item) }
        }
    }

    private var breakpointFiles: [String] {
        var seen = Set<String>()
        return debugger.breakpoints.map(\.url).filter { seen.insert($0).inserted }
    }

    private func breakpointFile(_ url: String, items: [DeveloperDebugger.Breakpoint]) -> some View {
        let on = items.allSatisfy(\.enabled)
        return Toggle(isOn: Binding(get: { on }, set: { debugger.setBreakpointsEnabled($0, in: url) })) {
            Label(items.first?.fileName ?? url, systemImage: "doc.text").lineLimit(1).truncationMode(.middle)
        }
        .toggleStyle(.developerCheckbox)
        .padding(.leading, DeveloperToolsStyle.paneInset).padding(.trailing, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.rowHeight)
        .help(url)
        .contextMenu {
            Button("Remove all breakpoints in file") { debugger.removeBreakpoints(in: url) }
            Button("Disable all breakpoints in file") { debugger.setBreakpointsEnabled(false, in: url) }
            Button("Enable all breakpoints in file") { debugger.setBreakpointsEnabled(true, in: url) }
            Divider()
            breakpointsMenu
        }
    }

    @ViewBuilder private var breakpointsMenu: some View {
        Button("Remove all breakpoints") { debugger.removeBreakpoints() }
        Button("Disable all breakpoints") { debugger.setBreakpointsEnabled(false) }
        Button("Enable all breakpoints") { debugger.setBreakpointsEnabled(true) }
    }

    private func breakpointRow(_ item: DeveloperDebugger.Breakpoint) -> some View {
        let hit = debugger.pause?.breakpointID != nil && debugger.pause?.breakpointID == item.protocolID
        return HStack(spacing: 5) {
            Toggle("", isOn: Binding(get: { item.enabled }, set: { debugger.setBreakpointEnabled(item.id, $0) }))
                .toggleStyle(.developerCheckbox).labelsHidden()
                .accessibilityLabel("Breakpoint on line \(item.line)")
            DeveloperBreakpointMarker(kind: item.kind, enabled: item.enabled && debugger.breakpointsActive)
            Text(item.kind == .regular ? (item.snippet.isEmpty ? "Line \(item.line)" : item.snippet) : item.expression)
                .font(DeveloperToolsStyle.code).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(item.enabled ? Palette.ink : .secondary)
            Spacer(minLength: 4)
            Text(item.line.formatted()).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.leading, DeveloperToolsStyle.gutter + 14).padding(.trailing, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.rowHeight)
        .background(hit ? Color.yellow.opacity(0.22) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { debugger.reveal(.init(url: item.url, line: item.line)) }
        .help(item.hover ?? item.url)
        .popover(isPresented: Binding(get: { editingBreakpoint == item.id },
                                      set: { if !$0 { editingBreakpoint = nil } }), arrowEdge: .leading) {
            DeveloperBreakpointEditor(debugger: debugger, url: item.url, line: item.line, column: item.column,
                                      kind: item.kind == .regular ? .conditional : item.kind,
                                      expression: item.expression) { editingBreakpoint = nil }
        }
        .contextMenu {
            Button(item.kind == .logpoint ? "Edit logpoint" : "Edit condition") { editingBreakpoint = item.id }
            Button("Reveal location") { debugger.reveal(.init(url: item.url, line: item.line)) }
            Divider()
            Button("Remove breakpoint") { debugger.removeBreakpoint(item.id) }
            Button("Remove other breakpoints") { debugger.removeBreakpoints(except: item.id) }
            breakpointsMenu
        }
    }

    // MARK: Scope

    @ViewBuilder private var scopePane: some View {
        if let frame = debugger.frame {
            ForEach(frame.scopes.filter { !$0.empty || $0.kind == .local }) { scope in
                let path = "scope:\(scope.id)"
                let open = debugger.expanded.contains(path)
                disclosureRow(title: scope.title, open: open, depth: 0) {
                    debugger.toggleExpanded(path, objectID: nil)
                }
                if open {
                    if let items = debugger.properties[path] {
                        if items.isEmpty { placeholder("No variables") }
                        ForEach(items) { property in
                            ForEach(debugger.objectRows(path: path + "/" + property.name, name: property.name,
                                                        value: property.value, missing: "(...)", depth: 1,
                                                        root: .scope(scope.id), names: [property.name])) { row in
                                objectRow(row)
                                    .onTapGesture(count: 2) { startEditing(row) }
                                    .contextMenu { DeveloperObjectMenu(debugger: debugger, row: row) }
                            }
                        }
                    } else {
                        placeholder("Loading…")
                    }
                }
            }
        } else {
            placeholder("Not paused")
        }
    }

    private func disclosureRow(title: String, open: Bool, depth: Int, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Image(systemName: open ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                    .font(.system(size: 7)).foregroundStyle(.secondary).frame(width: 10)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, DeveloperToolsStyle.gutter + CGFloat(depth) * 12)
            .frame(height: DeveloperToolsStyle.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "expanded" : "collapsed")
    }

    // MARK: Object trees (Scope and Watch)

    /// A row, or the field that changes its value (Chrome's double-click
    /// edit in Scope).
    @ViewBuilder private func objectRow(_ row: DeveloperDebugger.ObjectRow) -> some View {
        if editingValue == row.id {
            HStack(spacing: 4) {
                Color.clear.frame(width: 10)
                (Text(row.name).foregroundColor(.purple) + Text(": ").foregroundColor(.secondary))
                    .font(DeveloperToolsStyle.code).lineLimit(1).fixedSize()
                DeveloperFocusedField(text: $editedValue, placeholder: "Value", commit: {
                    debugger.setValue(row, to: editedValue)
                    editingValue = nil
                }, cancel: { editingValue = nil })
            }
            .padding(.leading, DeveloperToolsStyle.gutter + CGFloat(row.depth) * 12)
            .padding(.trailing, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.rowHeight - 4)
        } else {
            DeveloperObjectRowView(debugger: debugger, row: row)
        }
    }

    /// Double-click on a variable while paused, or on a property: edit it,
    /// starting from the value as written.
    private func startEditing(_ row: DeveloperDebugger.ObjectRow) {
        guard row.editable else { return }
        if case .scope = row.root, debugger.pause == nil { return }
        editedValue = row.value.flatMap(DeveloperDebugger.literal) ?? ""
        editingValue = row.id
    }

    // MARK: Threads

    private struct ThreadRow: Identifiable {
        let id: String
        let title: String
        let url: String
    }

    /// Chrome's Threads pane: Main, then each worker; the one the Call
    /// Stack shows has the arrow, and each paused one says so.
    private var threadsPane: some View {
        let paused = debugger.pausedThreads
        let current = debugger.pause == nil ? nil : debugger.currentThread
        let threads = [ThreadRow(id: "", title: "Main", url: session.address?.absoluteString ?? "")]
            + session.workers.map { ThreadRow(id: $0.id, title: $0.title, url: $0.url) }
        return ForEach(threads) { thread in
            let selected = current == thread.id
            let isPaused = paused.contains(thread.id)
            Button { debugger.selectThread(thread.id) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrowtriangle.right.fill").font(.system(size: 8))
                        .foregroundStyle(Color(nsColor: .systemBlue)).frame(width: 10).opacity(selected ? 1 : 0)
                    Image(systemName: thread.id.isEmpty ? "macwindow" : "gearshape")
                        .foregroundStyle(.secondary).frame(width: 14)
                    Text(thread.title).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(isPaused ? "paused" : "").foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.rowHeight)
                .background(selected ? DeveloperToolsStyle.selected : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(thread.url)
            .accessibilityLabel(thread.title)
            .accessibilityValue(isPaused ? "paused" : "running")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    // MARK: Call Stack

    @ViewBuilder private var callStackPane: some View {
        if let pause = debugger.pause {
            let hasHiddenFrames = pause.frames.contains { debugger.isIgnored($0) }
                || pause.asyncStacks.contains { $0.frames.contains { debugger.isIgnored($0) } }
            ForEach(visibleFrames(pause.frames)) { frame in
                callFrame(frame, in: pause)
            }
            ForEach(pause.asyncStacks) { stack in
                asyncStack(stack)
            }
            if pause.asyncStacks.last?.truncated == true {
                // WebKit's and Chrome's mark for an async chain cut short.
                Text("(truncated)")
                    .font(DeveloperToolsStyle.code).foregroundStyle(.secondary)
                    .padding(.horizontal, DeveloperToolsStyle.gutter)
                    .frame(maxWidth: .infinity, minHeight: DeveloperToolsStyle.rowHeight, alignment: .leading)
            }
            if pause.frames.isEmpty && pause.asyncStacks.isEmpty { placeholder("Not paused") }
            if hasHiddenFrames {
                Toggle("Show ignore-listed frames", isOn: $debugger.showIgnoreListed)
                    .toggleStyle(.developerCheckbox)
                    .padding(.leading, DeveloperToolsStyle.paneInset).padding(.trailing, DeveloperToolsStyle.gutter)
                    .frame(height: DeveloperToolsStyle.rowHeight)
            }
        } else {
            placeholder("Not paused")
        }
    }

    /// The frames the ignore list leaves shown.
    private func visibleFrames(_ frames: [DeveloperDebugger.CallFrame]) -> [DeveloperDebugger.CallFrame] {
        frames.filter { debugger.showIgnoreListed || !debugger.isIgnored($0) }
    }

    private func callFrame(_ frame: DeveloperDebugger.CallFrame, in pause: DeveloperDebugger.Pause) -> some View {
        let selected: Bool = debugger.selectedFrame == frame.index
        let ignored: Bool = debugger.isIgnored(frame)
        let original: String = frame.original.map { $0.url + ":\($0.line + 1)\n" } ?? ""
        let help: String = frame.url.isEmpty ? frame.functionName : original + frame.url + ":\(frame.line + 1)"
        return Button { debugger.selectFrame(frame.index) } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrowtriangle.right.fill").font(.system(size: 8))
                    .foregroundStyle(Color(nsColor: .systemBlue)).frame(width: 10).opacity(selected ? 1 : 0)
                Text(frame.functionName).font(DeveloperToolsStyle.code).lineLimit(1)
                Spacer(minLength: 4)
                Text(frame.location).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.rowHeight)
            .background(selected ? DeveloperToolsStyle.selected : .clear)
            .opacity(ignored ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(ignored ? "on ignore list" : "")
        .contextMenu { callFrameMenu(frame, in: pause, ignored: ignored) }
    }

    /// Chrome's call frame menu. WebKit has no Debugger.restartFrame.
    @ViewBuilder
    private func callFrameMenu(_ frame: DeveloperDebugger.CallFrame, in pause: DeveloperDebugger.Pause, ignored: Bool) -> some View {
        Button("Restart frame") {}.disabled(true)
            .help("WebKit can’t restart a call frame.")
        Button("Copy stack trace") {
            copy(pause.stackTrace)
        }
        if frame.original != nil {
            // The source-mapped frame's compiled place.
            Button("Show generated location (\(frame.generatedLocation))") { debugger.revealGenerated(frame) }
        }
        if !frame.url.isEmpty {
            Divider()
            if debugger.isListed(frame.url) {
                Button("Remove from ignore list") { debugger.setIgnored(frame.url, false) }
            } else if ignored {
                // Ignored by a rule or a source map: Settings › Ignore list.
                Button("Remove from ignore list") {}.disabled(true)
                    .help("A rule in Settings › Ignore list ignores this script.")
            } else {
                Button("Add script to ignore list") { debugger.setIgnored(frame.url, true) }
            }
        }
    }

    @ViewBuilder
    private func asyncStack(_ stack: DeveloperDebugger.AsyncStack) -> some View {
        let visible: [DeveloperDebugger.CallFrame] = visibleFrames(stack.frames)
        if !visible.isEmpty {
            Text(stack.boundary)
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, DeveloperToolsStyle.gutter)
                .frame(maxWidth: .infinity, minHeight: DeveloperToolsStyle.rowHeight, alignment: .leading)
                .overlay(alignment: .top) { Divider() }
                .accessibilityAddTraits(.isHeader)
            ForEach(visible) { frame in
                asyncCallFrame(frame)
            }
        }
    }

    private func asyncCallFrame(_ frame: DeveloperDebugger.CallFrame) -> some View {
        Button { debugger.revealAsync(frame) } label: {
            HStack(spacing: 4) {
                Text(frame.functionName).font(DeveloperToolsStyle.code).lineLimit(1)
                Spacer(minLength: 4)
                if !frame.url.isEmpty {
                    Text(frame.location).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            .padding(.leading, DeveloperToolsStyle.gutter + 14)
            .padding(.trailing, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.rowHeight)
            .opacity(debugger.isIgnored(frame) ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(frame.url.isEmpty)
        .help(frame.original?.url ?? frame.url)
    }

    // MARK: XHR/fetch

    @ViewBuilder private var xhrActions: some View {
        DeveloperPanelIcon(symbol: "plus", title: "Add XHR/fetch breakpoint", size: 18) {
            addingURL = true
            newURL = ""
        }
    }

    @ViewBuilder private var xhrPane: some View {
        if addingURL {
            VStack(alignment: .leading, spacing: DeveloperToolsStyle.stackSpacing) {
                Text("Break when URL contains:").foregroundStyle(.secondary)
                DeveloperFocusedField(text: $newURL, placeholder: "URL", commit: {
                    debugger.addURLBreakpoint(newURL)
                    addingURL = false
                }, cancel: { addingURL = false })
            }
            .padding(.leading, DeveloperToolsStyle.paneInset).padding(.trailing, DeveloperToolsStyle.gutter)
            .padding(.vertical, DeveloperToolsStyle.stackSpacing)
        }
        if debugger.urlBreakpoints.isEmpty && !addingURL { placeholder("No breakpoints") }
        ForEach(debugger.urlBreakpoints) { item in
            let hit = debugger.pause?.reason == "URL" && (debugger.pause?.detail ?? "").contains(item.url)
            Toggle(item.title, isOn: Binding(get: { item.enabled }, set: { debugger.setURLBreakpointEnabled(item.id, $0) }))
                .toggleStyle(.developerCheckbox).lineLimit(1)
                .padding(.leading, DeveloperToolsStyle.paneInset).padding(.trailing, DeveloperToolsStyle.gutter)
                .frame(height: DeveloperToolsStyle.rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hit ? Color.yellow.opacity(0.22) : .clear)
                .contextMenu {
                    Button("Remove breakpoint") { debugger.removeURLBreakpoint(item.id) }
                    Button("Remove all breakpoints") {
                        for each in debugger.urlBreakpoints { debugger.removeURLBreakpoint(each.id) }
                    }
                }
        }
    }

    // MARK: DOM

    @ViewBuilder private var domPane: some View {
        if debugger.domBreakpoints.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("No DOM breakpoints").italic()
                Text("DOM breakpoints pause on the code that changes a DOM node or its children")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, DeveloperToolsStyle.gutter + 14).padding(.vertical, 4)
        }
        ForEach(debugger.domBreakpoints) { item in
            Toggle(isOn: Binding(get: { item.enabled }, set: { debugger.setDOMBreakpointEnabled(item.id, $0) })) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.label).font(DeveloperToolsStyle.code).foregroundStyle(DeveloperToolsStyle.tint).lineLimit(1)
                    Text(item.type.title).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.developerCheckbox)
            .padding(.leading, DeveloperToolsStyle.paneInset).padding(.trailing, DeveloperToolsStyle.gutter)
            .padding(.vertical, DeveloperToolsStyle.stackSpacing / 2 + 1)
            .contextMenu {
                Button("Reveal DOM node in Elements panel") {
                    session.select(.elements)
                    session.selectNode(item.node)
                }
                Button("Remove breakpoint") { debugger.removeDOMBreakpoint(item.id) }
                Button("Remove all DOM breakpoints") {
                    for each in debugger.domBreakpoints { debugger.removeDOMBreakpoint(each.id) }
                }
            }
        }
    }

    // MARK: Event listener breakpoints

    @ViewBuilder private var eventsPane: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Filter", text: $eventFilter)
        }
        .developerToolsField()
        .padding(.leading, DeveloperToolsStyle.paneInset).padding(.trailing, DeveloperToolsStyle.gutter)
        .padding(.vertical, DeveloperToolsStyle.stackSpacing)
        ForEach(eventCategories) { category in
            let open = openCategories.contains(category.name) || !eventFilter.isEmpty
            let usable = category.items.filter(\.available)
            let on = usable.filter { debugger.eventBreakpoints.contains($0.id) }.count
            HStack(spacing: 4) {
                Button {
                    if openCategories.contains(category.name) { openCategories.remove(category.name) }
                    else { openCategories.insert(category.name) }
                } label: {
                    Image(systemName: open ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                        .font(.system(size: 7)).foregroundStyle(.secondary).frame(width: 10, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "Collapse \(category.name)" : "Expand \(category.name)")
                DeveloperMixedCheckbox(title: category.name, state: on == 0 ? .off : on == usable.count ? .on : .mixed,
                                       enabled: !usable.isEmpty) {
                    let enable = on != usable.count
                    for item in usable { debugger.setEventBreakpoint(item, enable) }
                }
                .help(usable.isEmpty ? "WebKit can’t break on these." : "")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.rowHeight)
            if open {
                ForEach(category.items, id: \.self) { item in
                    let hit = isHit(item)
                    Toggle(item.title, isOn: Binding(get: { debugger.eventBreakpoints.contains(item.id) },
                                                     set: { debugger.setEventBreakpoint(item, $0) }))
                        .toggleStyle(.developerCheckbox).lineLimit(1)
                        .padding(.leading, DeveloperToolsStyle.gutter + 28).padding(.trailing, DeveloperToolsStyle.gutter)
                        .frame(height: DeveloperToolsStyle.rowHeight - 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(hit ? Color.yellow.opacity(0.22) : .clear)
                        .disabled(!item.available)
                        .help(item.available ? "" : "WebKit can’t break on this.")
                }
            }
        }
        Text(DeveloperDebugger.EventBreakpoint.unavailable)
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DeveloperToolsStyle.gutter).padding(.vertical, 5)
    }

    // MARK: CSP violation breakpoints

    @ViewBuilder private var cspPane: some View {
        VStack(alignment: .leading, spacing: DeveloperToolsStyle.stackSpacing) {
            Toggle("Trusted Type violations", isOn: .constant(false)).disabled(true)
            VStack(alignment: .leading, spacing: DeveloperToolsStyle.stackSpacing) {
                Toggle("Sink violations", isOn: .constant(false))
                Toggle("Policy violations", isOn: .constant(false))
            }
            .disabled(true).padding(.leading, 20)
            Text(DeveloperDebugger.EventBreakpoint.cspUnavailable)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
        .toggleStyle(.developerCheckbox)
        .padding(.leading, DeveloperToolsStyle.paneInset).padding(.trailing, DeveloperToolsStyle.gutter)
        .padding(.vertical, DeveloperToolsStyle.stackSpacing)
    }

    private var eventCategories: [DeveloperDebugger.EventBreakpoint.Category] {
        guard !eventFilter.isEmpty else { return DeveloperDebugger.EventBreakpoint.categories }
        return DeveloperDebugger.EventBreakpoint.categories.compactMap { category in
            if category.name.localizedCaseInsensitiveContains(eventFilter) { return category }
            let items = category.items.filter { $0.title.localizedCaseInsensitiveContains(eventFilter) }
            return items.isEmpty ? nil : .init(name: category.name, items: items)
        }
    }

    private func isHit(_ item: DeveloperDebugger.EventBreakpoint) -> Bool {
        guard let pause = debugger.pause else { return false }
        switch pause.reason {
        case "Listener": return item.type == "listener" && item.eventName == pause.detail
        case "Timeout": return item.type == "timeout"
        case "Interval": return item.type == "interval"
        case "AnimationFrame": return item.type == "animation-frame"
        default: return false
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Pieces

/// One row of an object tree, as Chrome's ObjectPropertiesSection draws
/// it: a disclosure triangle for objects, the name in purple, the value
/// coloured by type. Shared by Scope, Watch and the editor's hover popover.
struct DeveloperObjectRowView: View {
    @ObservedObject var debugger: DeveloperDebugger
    let row: DeveloperDebugger.ObjectRow

    var body: some View {
        HStack(spacing: 4) {
            if row.value?.expandable == true {
                Image(systemName: row.open ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                    .font(.system(size: 7)).foregroundStyle(.secondary).frame(width: 10)
            } else {
                Color.clear.frame(width: 10)
            }
            (Text(row.name).foregroundColor(.purple) + Text(": ").foregroundColor(.secondary)
                + Self.valueText(row.value, missing: row.missing))
                .font(DeveloperToolsStyle.code).lineLimit(1).truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.leading, DeveloperToolsStyle.gutter + CGFloat(row.depth) * 12)
        .padding(.trailing, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.rowHeight - 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if row.value?.expandable == true { debugger.toggleExpanded(row.id, objectID: row.value?.objectID) }
        }
        .help(row.value.map { $0.primitive ?? $0.description } ?? "")
        .accessibilityElement(children: .combine)
    }

    static func valueText(_ value: DeveloperDebugger.RemoteValue?, missing: String?) -> Text {
        guard let value else { return Text(missing ?? "").foregroundColor(.secondary) }
        let text = Text(value.display.replacingOccurrences(of: "\n", with: "↵"))
        switch value.style {
        case .string: return text.foregroundColor(Color(nsColor: .systemRed))
        case .number: return text.foregroundColor(Color(nsColor: .systemBlue))
        case .null: return text.foregroundColor(.secondary)
        case .function: return text.italic()
        case .object: return text
        }
    }
}

/// The right-click menu Chrome gives Scope and Watch values: copy the
/// value or the way to it, keep it as a global, or watch it.
struct DeveloperObjectMenu: View {
    let debugger: DeveloperDebugger
    let row: DeveloperDebugger.ObjectRow

    var body: some View {
        if let value = row.value {
            Button("Copy value") { Self.copy(value.primitive ?? value.description) }
        }
        if let path = row.propertyPath {
            Button("Copy property path") { Self.copy(path) }
        }
        if let value = row.value, value.objectID != nil || DeveloperDebugger.literal(value) != nil {
            Button("Store as global variable") { debugger.storeAsGlobal(value) }
        }
        if let path = row.propertyPath {
            Button("Add property path to watch") { debugger.addWatch(path) }
        }
        if let value = row.value, let id = value.objectID, let session = debugger.session,
           DeveloperMemoryInspectable.inspectable(className: value.className, type: value.type, objectId: id) {
            Divider()
            Button("Reveal in Memory inspector panel") {
                DeveloperMemoryInspectorModel.reveal(session: session, objectId: id, targetID: debugger.pause?.targetID,
                                                     className: value.className, description: value.description)
            }
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The editor's hover popover while paused: the hovered expression's
/// value, and for an object its expandable properties, as in Chrome.
struct DeveloperHoverValueView: View {
    @ObservedObject var debugger: DeveloperDebugger
    let expression: String
    let value: DeveloperDebugger.RemoteValue
    /// The tree's expansion path, one per popover.
    let path: String

    var body: some View {
        let rows = debugger.objectRows(path: path, name: expression, value: value, missing: nil, depth: 0,
                                       root: .expression(expression))
        VStack(alignment: .leading, spacing: 0) {
            DeveloperObjectRowView.valueText(value, missing: nil)
                .font(DeveloperToolsStyle.code).lineLimit(value.expandable ? 1 : 6)
                .textSelection(.enabled)
                .padding(.horizontal, DeveloperToolsStyle.gutter).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            if value.expandable {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows.dropFirst()) { row in
                            DeveloperObjectRowView(debugger: debugger, row: row)
                                .contextMenu { DeveloperObjectMenu(debugger: debugger, row: row) }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: min(CGFloat(max(rows.count - 1, 1)) * (DeveloperToolsStyle.rowHeight - 4) + 4, 320))
            }
        }
        .frame(minWidth: 220, idealWidth: 340, maxWidth: 520, alignment: .leading)
        .onAppear {
            // Chrome opens the popover's object one level.
            if value.expandable, !debugger.expanded.contains(path) {
                debugger.toggleExpanded(path, objectID: value.objectID)
            }
        }
    }
}

/// Chrome's breakpoint marker: blue for a breakpoint, orange for a
/// conditional one, pink for a logpoint; faded when it can't pause.
struct DeveloperBreakpointMarker: View {
    let kind: DeveloperDebugger.Breakpoint.Kind
    var enabled = true

    var body: some View {
        let color: Color = switch kind {
        case .regular: Color(nsColor: .systemBlue)
        case .conditional: Color(nsColor: .systemOrange)
        case .logpoint: Color(nsColor: .systemPink)
        }
        Image(systemName: kind == .regular ? "arrowshape.right.fill" : kind == .conditional ? "questionmark.square.fill" : "ellipsis.rectangle.fill")
            .font(.system(size: 9)).foregroundStyle(color.opacity(enabled ? 1 : 0.4))
            .accessibilityLabel(kind.rawValue)
    }
}

/// Chrome's breakpoint edit dialog: the line, the breakpoint type and its
/// condition or log message.
struct DeveloperBreakpointEditor: View {
    @ObservedObject var debugger: DeveloperDebugger
    let url: String
    let line: Int
    /// 0-based, for one set partway along a line from a pretty-printed view.
    let column: Int?
    @State var kind: DeveloperDebugger.Breakpoint.Kind
    @State var expression: String
    var snippet: String?
    let done: () -> Void

    init(debugger: DeveloperDebugger, url: String, line: Int, column: Int? = nil, kind: DeveloperDebugger.Breakpoint.Kind,
         expression: String = "", snippet: String? = nil, done: @escaping () -> Void) {
        self.debugger = debugger
        self.url = url
        self.line = line
        self.column = column
        _kind = State(initialValue: kind)
        _expression = State(initialValue: expression)
        self.snippet = snippet
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Line \(line):")
                Picker("Breakpoint type", selection: $kind) {
                    ForEach(DeveloperDebugger.Breakpoint.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().fixedSize().help(kind.help)
                .onChange(of: kind) { _, kind in
                    // Choosing a plain breakpoint saves and closes, as in Chrome.
                    if kind == .regular { save() }
                }
                Spacer(minLength: 0)
                DeveloperPanelIcon(symbol: "xmark", title: "Close edit dialog and save changes", size: 18, action: save)
            }
            DeveloperFocusedField(text: $expression, placeholder: kind.placeholder, commit: save, cancel: done)
                .font(DeveloperToolsStyle.code)
                .developerToolsField()
        }
        .padding(10)
        .frame(width: 330)
    }

    private func save() {
        debugger.setBreakpoint(url: url, line: line, column: column, kind: kind, expression: expression, snippet: snippet)
        done()
    }
}

/// The toolbar's "Deactivate breakpoints" toggle (⌘F8 in Chrome).
struct DeveloperDeactivateBreakpointsButton: View {
    @ObservedObject var debugger: DeveloperDebugger

    var body: some View {
        let active = debugger.breakpointsActive
        DeveloperPanelIcon(symbol: active ? "arrowshape.right" : "arrowshape.right.fill",
                           title: active ? "Deactivate breakpoints (⌘F8)" : "Activate breakpoints (⌘F8)", active: !active) {
            debugger.setBreakpointsActive(!active)
        }
    }
}

/// Chrome's debugger keys, live while the Sources sidebar is shown:
/// F8 or ⌘\ pause/resume, F10 or ⌘' step over, F11 or ⌘; step into,
/// ⇧F11 or ⇧⌘; step out, F9 step, ⌘F8 deactivate breakpoints.
private struct DeveloperDebuggerShortcuts: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var debugger: DeveloperDebugger

    var body: some View {
        let paused = debugger.pause != nil
        ZStack {
            key("\\", .command) { debugger.step(paused ? "resume" : "pause") }
            key(Self.function(NSF8FunctionKey), []) { debugger.step(paused ? "resume" : "pause") }
            key("'", .command) { debugger.step("stepOver") }
            key(Self.function(NSF10FunctionKey), []) { debugger.step("stepOver") }
            key(";", .command) { debugger.step("stepInto") }
            key(Self.function(NSF11FunctionKey), []) { debugger.step("stepInto") }
            key(";", [.command, .shift]) { debugger.step("stepOut") }
            key(Self.function(NSF11FunctionKey), .shift) { debugger.step("stepOut") }
            key(Self.function(NSF9FunctionKey), []) { debugger.step("stepNext") }
            key(Self.function(NSF8FunctionKey), .command) { debugger.setBreakpointsActive(!debugger.breakpointsActive) }
        }
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }

    private static func function(_ key: Int) -> KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(UInt16(key)) ?? " "))
    }

    private func key(_ key: KeyEquivalent, _ modifiers: EventModifiers, action: @escaping () -> Void) -> some View {
        Button("", action: action).keyboardShortcut(key, modifiers: modifiers).buttonStyle(.plain)
    }
}

/// Chrome's paused-in-debugger overlay over the page: a dimmed page and a
/// "Paused in debugger" bar with Resume and Step over.
struct DeveloperPausedOverlay: View {
    @ObservedObject var debugger: DeveloperDebugger

    var body: some View {
        // Only the page's own thread stops the page; a paused worker doesn't, as in Chrome.
        if debugger.pause != nil, debugger.pausedThreads.contains("") {
            ZStack(alignment: .top) {
                Color.black.opacity(0.31)
                HStack(spacing: -1) {
                    Text("Paused in debugger")
                        .font(.system(size: 12)).foregroundStyle(Color.black)
                        .padding(.horizontal, 6).frame(height: 22)
                        .background(Self.fill).border(Self.edge, width: 1)
                    button("play.fill", "Resume script execution", color: Color(red: 66 / 255, green: 129 / 255, blue: 235 / 255)) {
                        debugger.step("resume")
                    }
                    button("arrow.turn.down.right", "Step over next function call", color: Color.black.opacity(0.75)) {
                        debugger.step("stepOver")
                    }
                }
                .padding(.top, 10)
                .environment(\.colorScheme, .light)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Paused in debugger")
        }
    }

    private static let fill = Color(red: 1, green: 1, blue: 194 / 255)
    private static let edge = Color(red: 202 / 255, green: 202 / 255, blue: 202 / 255)

    private func button(_ symbol: String, _ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
                .frame(width: 26, height: 22)
                .background(Self.fill).border(Self.edge, width: 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}

/// A row action that appears while the pointer is over the row.
private struct DeveloperHoverButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        DeveloperPanelIcon(symbol: symbol, title: title, size: 16, action: action)
            .opacity(hovering ? 1 : 0.001)
            .onHover { hovering = $0 }
            .padding(.trailing, 4)
    }
}

/// A text field that takes focus when it appears; Return commits, Escape cancels.
private struct DeveloperFocusedField: View {
    @Binding var text: String
    let placeholder: String
    let commit: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain).font(DeveloperToolsStyle.code)
            .focused($focused)
            .onSubmit(commit)
            .onExitCommand(perform: cancel)
            .onAppear { focused = true }
    }
}

/// A checkbox that can show a mixed state, as a category row does.
private struct DeveloperMixedCheckbox: NSViewRepresentable {
    enum State { case on, off, mixed }
    let title: String
    let state: State
    var enabled = true
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator, action: #selector(Coordinator.click))
        button.allowsMixedState = true
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        button.isEnabled = enabled
        button.state = state == .on ? .on : state == .off ? .off : .mixed
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func click() { action() }
    }
}
