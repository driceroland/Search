import Foundation

/// The state behind the Sources panel's debugger sidebar, as Chrome DevTools
/// keeps it: the pause (call frames, scopes and why it stopped), watch
/// expressions and every kind of breakpoint WebKit's inspector protocol has.
/// Commands go through the session's bridge into WebKit's hidden frontend.
@MainActor
final class DeveloperDebugger: ObservableObject {
    weak var session: DeveloperToolsSession?

    // MARK: Pause

    @Published private(set) var pause: Pause? { didSet { inlineGeneration += 1 } }
    @Published private(set) var selectedFrame = 0
    /// The page's dedicated workers' targets, each a thread of its own.
    @Published private(set) var workerTargets = Set<String>()
    /// The targets paused now ("" for one WebKit didn't name).
    @Published private(set) var pausedTargets = Set<String>()
    /// Pauses in threads other than the one shown, by target, for the
    /// Threads pane to bring forward.
    private var parkedPauses: [String: Pause] = [:]
    /// Loaded properties, by scope ("scope:<index>") or by object id.
    @Published private(set) var properties: [String: [Property]] = [:]
    /// The top frame's lexical scope values, independent of sidebar selection.
    @Published private(set) var inlineScopes: [InlineScope] = [] { didSet { inlineGeneration += 1 } }
    /// For a source-mapped top frame, the compiled name each authored one
    /// became (SourceInlineValues.authoredNames); nil when unknown, and the
    /// authored file then shows no inline values.
    @Published private(set) var inlineNames: [String: String]? { didSet { inlineGeneration += 1 } }
    /// Changes whenever the pause or its inline values do, so the editor
    /// can rebuild its inline value request only then.
    private(set) var inlineGeneration = 0
    /// Expanded rows in the Scope and Watch trees, by path.
    @Published private(set) var expanded = Set<String>()
    /// The line the editor should show: the selected frame or a breakpoint.
    @Published private(set) var revealed: Location?

    // MARK: Breakpoints

    @Published private(set) var breakpoints: [Breakpoint] = []
    @Published private(set) var breakpointsActive = true
    @Published private(set) var pauseOnUncaught = false
    @Published private(set) var pauseOnCaught = false
    @Published private(set) var urlBreakpoints: [URLBreakpoint] = []
    @Published private(set) var domBreakpoints: [DOMBreakpoint] = [] {
        // The Elements panel's Break on menu and DOM Breakpoints tab show
        // the same list (see DeveloperToolsSession.mirrorDOMBreakpoints).
        didSet { session?.mirrorDOMBreakpoints() }
    }
    @Published private(set) var eventBreakpoints = Set<String>()
    @Published private(set) var watches: [Watch]

    static let watchesKey = "DeveloperWatchExpressions"
    private var loading = Set<String>()
    private var watchGeneration = 0
    private var inlineScopeTask: Task<Void, Never>?
    private var lastScriptSource: (id: String, text: String)?

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.watchesKey) ?? []
        watches = saved.prefix(50).map { Watch(expression: $0) }
        loadIgnoreSettings()
    }

    var frame: CallFrame? {
        guard let pause, pause.frames.indices.contains(selectedFrame) else { return nil }
        return pause.frames[selectedFrame]
    }

    /// The paused line (1-based) of the selected frame, when it is in `url`.
    func executionLine(for url: String) -> Int? {
        executionLocation(for: url)?.line
    }

    /// The paused statement of the selected frame, when it is in `url`:
    /// a 1-based line and the 0-based column the protocol gives. In an
    /// authored file, where its source map puts it.
    func executionLocation(for url: String) -> (line: Int, column: Int)? {
        guard let frame else { return nil }
        if let original = frame.original, Self.sameScript(original.url, url) { return (original.line + 1, original.column) }
        guard Self.sameScript(frame.url, url) else { return nil }
        return (frame.line + 1, frame.column)
    }

    /// Breakpoint lines (1-based) in a file, for the editor's gutter.
    func lines(in url: String) -> Set<Int> {
        Set(breakpoints.filter { $0.url == url && $0.column == nil }.map(\.line))
    }

    /// Breakpoints set partway along a line, from a pretty-printed view.
    func columns(in url: String) -> Set<SourceBreakpoint> {
        Set(breakpoints.compactMap { item in
            guard item.url == url, let column = item.column else { return nil }
            return SourceBreakpoint(line: item.line, column: column)
        })
    }

    func breakpoint(url: String, line: Int, column: Int? = nil) -> Breakpoint? {
        breakpoints.first { $0.url == url && $0.line == line && $0.column == column }
    }

    // MARK: Events

    func handle(_ method: String, params: [String: Any], targetID: String?) {
        switch method {
        case "Debugger.paused":
            paused(params, targetID: targetID)
        case "Debugger.resumed":
            let raw = targetID ?? ""
            pausedTargets.remove(raw)
            if let targetID, let pausedTarget = pause?.targetID, targetID != pausedTarget {
                // Another thread went on: it is no longer waiting behind this pause.
                parkedPauses[raw] = nil
                return
            }
            resumed()
            showParkedPause()
        case "Debugger.globalObjectCleared":
            let thread = threadKey(targetID)
            // A worker's global object ends only its own pause; the page's
            // ends the main thread's.
            let cleared = pausedTargets.filter { threadKey($0.isEmpty ? nil : $0) == thread }
            pausedTargets.subtract(cleared)
            for raw in cleared { parkedPauses[raw] = nil }
            if thread.isEmpty { lastScriptSource = nil }
            if pause != nil, currentThread == thread {
                resumed()
                showParkedPause()
            }
        case "Debugger.breakpointResolved":
            guard let id = params["breakpointId"] as? String,
                  let index = breakpoints.firstIndex(where: { $0.protocolID == id }) else { return }
            breakpoints[index].resolved = true
        case "Debugger.scriptParsed":
            // eval and console code: no address to blackbox it by.
            guard let id = params["scriptId"] as? String,
                  (params["url"] as? String ?? "").isEmpty, (params["sourceURL"] as? String ?? "").isEmpty else { return }
            if anonymousScripts.count >= 10_000 { anonymousScripts.removeAll() }
            anonymousScripts.insert(id)
        case "Target.didCommitProvisionalTarget":
            // A new process has none of the breakpoints; set them again.
            lastScriptSource = nil
            anonymousScripts.removeAll()
            reapply()
        case "Page.frameNavigated":
            guard let frame = params["frame"] as? [String: Any],
                  (frame["parentId"] as? String)?.isEmpty != false else { return }
            // DOM breakpoints belong to nodes of the old document.
            domBreakpoints.removeAll()
            // The workspace's saved scripts run in the new one.
            DeveloperWorkspace.shared.pageNavigated()
            forgetScripts()
        default:
            break
        }
    }

    /// The session connected to a page: Search's settings win over the hidden
    /// frontend's own.
    func connected() {
        run { debugger in
            await debugger.enableAsyncStackTraces()
            try await debugger.applyExceptionState()
            if !debugger.breakpointsActive {
                _ = try await debugger.command("Debugger.setBreakpointsActive", ["active": false])
            }
        }
        syncWorkerBreakpoints()
        // Settings › Ignore list: the rules, and maps' ignore lists.
        applyIgnoreList()
        refreshWatches()
        // Local Overrides answer the page's loads while DevTools is open.
        if let session { DeveloperLocalOverrides.shared.attach(session) }
    }

    private func paused(_ params: [String: Any], targetID: String?) {
        let frames = mapped((params["callFrames"] as? [[String: Any]] ?? []).prefix(50).enumerated().map {
            CallFrame($1, index: $0)
        })
        // Settings › Ignore list: not a place to stop.
        if skipsIgnoredPause(frames, targetID: targetID) { return }
        stepping = false
        let reason = params["reason"] as? String ?? "other"
        let data = params["data"] as? [String: Any] ?? [:]
        let asyncStacks = mapped(AsyncStack.groups(params["asyncStackTrace"] as? [String: Any]))
        let raw = targetID ?? ""
        // Chrome's Threads pane: a pause in another thread waits there
        // while this one is shown.
        if let current = pause, (current.targetID ?? "") != raw {
            parkedPauses[current.targetID ?? ""] = current
        }
        parkedPauses[raw] = nil
        pausedTargets.insert(raw)
        pause = Pause(reason: reason, data: data, frames: frames, asyncStacks: asyncStacks, targetID: targetID,
                      describeNode: { [weak session] id in session?.nodes[id].map(DeveloperDebugger.nodeLabel) })
        noteRecurringPause(frames.first)
        show()
    }

    /// The sidebar and editor follow `pause`: Local open, the top frame shown.
    private func show() {
        properties = [:]
        loading = []
        // Chrome opens Local and keeps the other scopes closed on every pause.
        selectFrame(0)
        refreshInlineScopes()
    }

    // MARK: Threads

    /// The page's main thread is "", a worker its target. Only workers the
    /// session knows count; a frame's target pauses on the main thread.
    func threadKey(_ targetID: String?) -> String {
        guard let targetID, workerTargets.contains(targetID) else { return "" }
        return targetID
    }

    /// The thread whose pause the sidebar shows.
    var currentThread: String { threadKey(pause?.targetID) }

    /// The threads paused now: "" for the page's, else each worker's target.
    var pausedThreads: Set<String> { Set(pausedTargets.map { threadKey($0.isEmpty ? nil : $0) }) }

    /// Chrome's Threads pane: choosing a paused thread shows its pause;
    /// the one shown before waits, still paused.
    func selectThread(_ thread: String) {
        guard thread != currentThread,
              let key = parkedPauses.keys.first(where: { threadKey($0.isEmpty ? nil : $0) == thread }),
              let next = parkedPauses.removeValue(forKey: key) else { return }
        if let current = pause { parkedPauses[current.targetID ?? ""] = current }
        pause = next
        show()
        session?.debuggerThreadChanged()
    }

    /// After the shown thread resumed, another still paused comes forward,
    /// the page's first.
    private func showParkedPause() {
        guard pause == nil else { return }
        let keys = parkedPauses.keys.sorted()
        let next = keys.first { threadKey($0.isEmpty ? nil : $0).isEmpty } ?? keys.first
        guard let next, let parked = parkedPauses.removeValue(forKey: next) else { return }
        pause = parked
        show()
    }

    /// The session's list of workers changed: a worker that ended has no
    /// pause left.
    func workersChanged(_ ids: Set<String>) {
        guard ids != workerTargets else { return }
        let gone = workerTargets.subtracting(ids)
        workerTargets = ids
        guard !gone.isEmpty else { return }
        pausedTargets.subtract(gone)
        for thread in gone { parkedPauses[thread] = nil }
        if let targetID = pause?.targetID, gone.contains(targetID) {
            resumed()
            showParkedPause()
            session?.debuggerThreadChanged()
        }
    }

    // MARK: Source maps

    /// Each frame's place in its authored file, when the script has a map.
    private func mapped(_ frames: [CallFrame]) -> [CallFrame] {
        guard let maps = session?.sourceMaps else { return frames }
        return frames.map { frame in
            var frame = frame
            frame.original = maps.original(url: frame.url, line: frame.line, column: frame.column)
            return frame
        }
    }

    private func mapped(_ stacks: [AsyncStack]) -> [AsyncStack] {
        stacks.map { AsyncStack(id: $0.id, boundary: $0.boundary, frames: mapped($0.frames), truncated: $0.truncated) }
    }

    /// A map arrived: breakpoints in its authored files go where their
    /// lines landed, and a pause already showing moves to the authored file.
    func sourceMapLoaded(_ sources: Set<String>) {
        if var pause {
            let frames = mapped(pause.frames)
            let asyncStacks = mapped(pause.asyncStacks)
            let framesChanged = frames != pause.frames
            if framesChanged || asyncStacks != pause.asyncStacks {
                pause.frames = frames
                pause.asyncStacks = asyncStacks
                self.pause = pause
                if framesChanged, let original = frame?.original {
                    reveal(Location(url: original.url, line: original.line + 1))
                }
                // The authored file's inline values need the map's names.
                if framesChanged { refreshInlineScopes(keepingValues: true) }
            }
        }
        var moved: [(id: Breakpoint.ID, old: String?)] = []
        for index in breakpoints.indices where breakpoints[index].enabled && sources.contains(breakpoints[index].url) {
            moved.append((breakpoints[index].id, breakpoints[index].protocolID))
            breakpoints[index].protocolID = nil
            breakpoints[index].resolved = false
        }
        guard !moved.isEmpty else { return }
        run { debugger in
            for item in moved {
                if let old = item.old { _ = try? await debugger.command("Debugger.removeBreakpoint", ["breakpointId": old]) }
                try await debugger.install(item.id)
            }
        }
    }

    /// The selected frame's compiled place, for the call stack's "Show
    /// generated location": the authored view's way back to the bundle.
    func revealGenerated(_ frame: CallFrame) {
        guard !frame.url.isEmpty else { return }
        reveal(Location(url: frame.url, line: frame.line + 1))
    }

    /// An async caller has already returned. Reveal its source without changing the live frame.
    func revealAsync(_ frame: CallFrame) {
        if let original = frame.original {
            reveal(Location(url: original.url, line: original.line + 1))
        } else {
            revealGenerated(frame)
        }
    }

    // MARK: Recurring pauses

    /// Chrome's RecurringPauseDetector: stopping again and again at one
    /// place offers a way out (Disable breakpoint or Never pause here, and
    /// Deactivate all) in the paused message.
    @Published private(set) var recurring = false
    private var recentPauses: [(key: String, at: Date)] = []

    private func noteRecurringPause(_ frame: CallFrame?) {
        guard let frame else { recurring = false; return }
        let key = "\(frame.url):\(frame.line):\(frame.column)"
        let now = Date()
        recentPauses = recentPauses.filter { now.timeIntervalSince($0.at) < 10 } + [(key, now)]
        recurring = recentPauses.filter { $0.key == key }.count >= 3
    }

    /// The breakpoint the debugger stopped on, if it is one of ours.
    var pausedBreakpoint: Breakpoint? {
        guard let id = pause?.breakpointID else { return nil }
        return breakpoints.first { $0.protocolID == id }
    }

    /// "Never pause here": a breakpoint whose condition is always false,
    /// as Chrome sets one.
    func neverPauseHere(url: String, line: Int) {
        setBreakpoint(url: url, line: line, kind: .conditional, expression: "false")
    }

    func deactivateBreakpointsAndResume() {
        setBreakpointsActive(false)
        step("resume")
    }

    // MARK: Ignore list

    /// Scripts on the ignore list: WebKit's blackboxing skips them when
    /// stepping and pausing, as Chrome's ignore list does.
    @Published private(set) var ignoredScripts = Set<String>()
    @Published var showIgnoreListed = false

    /// A custom exclusion rule: a regular expression for script (and
    /// authored file) addresses, as Chrome's Settings › Ignore list has them.
    struct IgnorePattern: Codable, Equatable, Identifiable {
        var pattern: String
        var enabled: Bool
        var id: String { pattern }
    }

    static let ignorePatternsKey = "DeveloperIgnoreListPatterns"
    static let ignoreThirdPartyKey = "DeveloperIgnoreListThirdParty"
    static let ignoreAnonymousKey = "DeveloperIgnoreListAnonymous"
    /// Chrome's default rule, on until turned off.
    static let defaultIgnorePattern = "/node_modules/|/bower_components/"

    @Published private(set) var ignorePatterns: [IgnorePattern] = [] { didSet { compilePatterns() } }
    /// "Automatically add known third-party scripts to ignore list": the
    /// sources a source map's `ignoreList` names. On by default, as in Chrome.
    @Published var ignoreThirdParty = true {
        didSet {
            guard ignoreThirdParty != oldValue else { return }
            UserDefaults.standard.set(ignoreThirdParty, forKey: Self.ignoreThirdPartyKey)
            applyMapIgnoreLists()
        }
    }
    /// "Ignore anonymous scripts from eval or console": scripts with no URL,
    /// which WebKit can't blackbox by address; a pause in one goes on.
    @Published var ignoreAnonymous = false {
        didSet {
            guard ignoreAnonymous != oldValue else { return }
            UserDefaults.standard.set(ignoreAnonymous, forKey: Self.ignoreAnonymousKey)
        }
    }
    private var compiledPatterns: [NSRegularExpression] = []

    /// A script with a source map, for its ignore list.
    private struct MappedScript {
        let url: String
        let map: DeveloperSourceMap
        let startLine: Int
        let startColumn: Int
    }

    /// What was sent to blackbox a mapped script: all of it, or ranges.
    private enum MapBlackbox: Equatable {
        case whole
        case ranges([Int])
    }

    /// By address without query or fragment.
    private var mappedScripts: [String: MappedScript] = [:]
    private var mapBlackboxes: [String: MapBlackbox] = [:]
    /// Authored files some map's ignore list names.
    private var thirdPartySources = Set<String>()
    /// Scripts parsed with no URL and no sourceURL (eval, the console), by id.
    private var anonymousScripts = Set<String>()
    /// The last command was a step, so a pause in an ignored anonymous
    /// script steps on out of it rather than resuming.
    private var stepping = false

    private func loadIgnoreSettings() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.ignorePatternsKey),
           let saved = try? JSONDecoder().decode([IgnorePattern].self, from: data) {
            ignorePatterns = saved
        } else {
            ignorePatterns = [IgnorePattern(pattern: Self.defaultIgnorePattern, enabled: true)]
        }
        ignoreThirdParty = defaults.object(forKey: Self.ignoreThirdPartyKey) as? Bool ?? true
        ignoreAnonymous = defaults.object(forKey: Self.ignoreAnonymousKey) as? Bool ?? false
        compilePatterns()
    }

    private func saveIgnorePatterns() {
        if let data = try? JSONEncoder().encode(ignorePatterns) { UserDefaults.standard.set(data, forKey: Self.ignorePatternsKey) }
    }

    private func compilePatterns() {
        compiledPatterns = ignorePatterns.filter(\.enabled).compactMap { try? NSRegularExpression(pattern: $0.pattern) }
    }

    private static func scriptKey(_ url: String) -> String { String(url.prefix { $0 != "?" && $0 != "#" }) }

    /// Whether an enabled rule matches an address.
    func matchesIgnorePattern(_ url: String) -> Bool {
        guard !url.isEmpty else { return false }
        let range = NSRange(url.startIndex..., in: url)
        return compiledPatterns.contains { $0.firstMatch(in: url, range: range) != nil }
    }

    /// On the ignore list: added by hand, matched by a rule, a script whose
    /// every source is ignored, or an authored file a map lists as third-party.
    func isIgnored(_ url: String) -> Bool {
        guard !url.isEmpty else { return false }
        return isListed(url) || matchesIgnorePattern(url) || mapBlackboxes[Self.scriptKey(url)] == .whole
            || (ignoreThirdParty && thirdPartySources.contains(url))
    }

    /// A call frame on the ignore list, by its script or its authored place;
    /// an anonymous script's while those are ignored.
    func isIgnored(_ frame: CallFrame) -> Bool {
        if isIgnored(frame.url) { return true }
        if let original = frame.original, isIgnored(original.url) { return true }
        return ignoreAnonymous && frame.url.isEmpty && frame.scriptID.map(anonymousScripts.contains) == true
    }

    /// Added by hand (Add script to ignore list), not by a rule.
    func isListed(_ url: String) -> Bool { ignoredScripts.contains { Self.sameScript($0, url) } }

    func setIgnored(_ url: String, _ ignored: Bool) {
        guard !url.isEmpty, isListed(url) != ignored else { return }
        if ignored { ignoredScripts.insert(url) } else { ignoredScripts = ignoredScripts.filter { !Self.sameScript($0, url) } }
        // An authored file is ignored by its stretches of the compiled script.
        if session?.sourceMaps.isAuthored(url) == true {
            applyMapIgnoreLists()
            return
        }
        run { debugger in
            _ = try await debugger.command("Debugger.setShouldBlackboxURL",
                                           ["url": url, "shouldBlackbox": ignored, "caseSensitive": true, "isRegex": false])
        }
    }

    // MARK: Exclusion rules

    /// Adds a rule; false when it is empty, there already, or not a
    /// regular expression.
    @discardableResult
    func addIgnorePattern(_ pattern: String) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespaces)
        guard Self.isValidIgnorePattern(pattern), !ignorePatterns.contains(where: { $0.pattern == pattern }) else { return false }
        ignorePatterns.append(IgnorePattern(pattern: pattern, enabled: true))
        saveIgnorePatterns()
        sendPattern(pattern, true)
        applyMapIgnoreLists()
        return true
    }

    /// Edits a rule in place, keeping whether it is on.
    @discardableResult
    func replaceIgnorePattern(_ old: String, with new: String) -> Bool {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard let index = ignorePatterns.firstIndex(where: { $0.pattern == old }) else { return false }
        guard new != old else { return true }
        guard Self.isValidIgnorePattern(new), !ignorePatterns.contains(where: { $0.pattern == new }) else { return false }
        let enabled = ignorePatterns[index].enabled
        ignorePatterns[index].pattern = new
        saveIgnorePatterns()
        if enabled {
            sendPattern(old, false)
            sendPattern(new, true)
        }
        applyMapIgnoreLists()
        return true
    }

    func removeIgnorePattern(_ pattern: String) {
        guard let index = ignorePatterns.firstIndex(where: { $0.pattern == pattern }) else { return }
        let enabled = ignorePatterns[index].enabled
        ignorePatterns.remove(at: index)
        saveIgnorePatterns()
        if enabled { sendPattern(pattern, false) }
        applyMapIgnoreLists()
    }

    func setIgnorePattern(_ pattern: String, enabled: Bool) {
        guard let index = ignorePatterns.firstIndex(where: { $0.pattern == pattern }),
              ignorePatterns[index].enabled != enabled else { return }
        ignorePatterns[index].enabled = enabled
        saveIgnorePatterns()
        sendPattern(pattern, enabled)
        applyMapIgnoreLists()
    }

    static func isValidIgnorePattern(_ pattern: String) -> Bool {
        !pattern.isEmpty && (try? NSRegularExpression(pattern: pattern)) != nil
    }

    private func sendPattern(_ pattern: String, _ on: Bool) {
        run { debugger in
            _ = try await debugger.command("Debugger.setShouldBlackboxURL",
                                           ["url": pattern, "shouldBlackbox": on, "caseSensitive": true, "isRegex": true])
        }
    }

    /// Every enabled rule and mapped script's ignore list, sent again (a
    /// new connection or process has none of them).
    private func applyIgnoreList() {
        for item in ignorePatterns where item.enabled { sendPattern(item.pattern, true) }
        mapBlackboxes = [:]
        applyMapIgnoreLists()
    }

    // MARK: Source-mapped ignore lists

    /// A script's map arrived: its sources on the ignore list (its own
    /// third-party list, a rule, or by hand) are stepped over.
    func scriptMapLoaded(url: String, map: DeveloperSourceMap, startLine: Int, startColumn: Int) {
        guard !url.isEmpty else { return }
        mappedScripts[Self.scriptKey(url)] = MappedScript(url: url, map: map, startLine: startLine, startColumn: startColumn)
        thirdPartySources.formUnion(map.ignoredSourceURLs)
        applyMapIgnoreList(Self.scriptKey(url))
    }

    /// Whether an authored file of a map is ignored.
    private func isIgnoredSource(_ url: String, listed: Bool) -> Bool {
        (ignoreThirdParty && listed) || isListed(url) || matchesIgnorePattern(url)
    }

    private func applyMapIgnoreLists() {
        for key in mappedScripts.keys.sorted() { applyMapIgnoreList(key) }
    }

    /// Blackboxes the stretches of a mapped script its ignored sources make
    /// up: the whole script when every source is ignored, else WebKit's
    /// sourceRanges. A WebKit without ranges leaves the script as it is.
    private func applyMapIgnoreList(_ key: String) {
        guard let script = mappedScripts[key] else { return }
        let map = script.map
        let ignored = Set(map.sources.indices.filter {
            isIgnoredSource(map.sources[$0], listed: map.ignoredSources.contains($0))
        })
        var wanted: MapBlackbox?
        if !ignored.isEmpty, ignored.count == map.sources.count {
            wanted = .whole
        } else if !ignored.isEmpty {
            let ranges = map.generatedRanges(of: ignored, line: script.startLine, column: script.startColumn)
            if !ranges.isEmpty { wanted = .ranges(ranges.flatMap { $0 }) }
        }
        let previous = mapBlackboxes[key]
        guard previous != wanted else { return }
        mapBlackboxes[key] = wanted
        let url = script.url
        let sending = wanted
        run { debugger in
            // An address added by hand keeps its own blackboxing.
            if previous != nil, !debugger.isListed(url) {
                _ = try? await debugger.command("Debugger.setShouldBlackboxURL",
                                                ["url": url, "shouldBlackbox": false, "caseSensitive": true, "isRegex": false])
            }
            switch sending {
            case .whole?:
                _ = try await debugger.command("Debugger.setShouldBlackboxURL",
                                               ["url": url, "shouldBlackbox": true, "caseSensitive": true, "isRegex": false])
            case let .ranges(ranges)?:
                _ = try? await debugger.command("Debugger.setShouldBlackboxURL",
                                                ["url": url, "shouldBlackbox": true, "caseSensitive": true, "isRegex": false,
                                                 "sourceRanges": ranges])
            case nil:
                break
            }
        }
    }

    /// The page navigated: its scripts parse again and bring their maps.
    private func forgetScripts() {
        let sent = mapBlackboxes.keys.compactMap { mappedScripts[$0]?.url }.filter { !isListed($0) }
        mappedScripts = [:]
        mapBlackboxes = [:]
        thirdPartySources = []
        anonymousScripts = []
        guard !sent.isEmpty else { return }
        run { debugger in
            for url in sent {
                _ = try? await debugger.command("Debugger.setShouldBlackboxURL",
                                                ["url": url, "shouldBlackbox": false, "caseSensitive": true, "isRegex": false])
            }
        }
    }

    /// A pause in an ignore-listed script (by rule, by hand, by its source
    /// map, or an anonymous one while those are ignored): step on out of it
    /// after a step, else go on, as if it had never stopped there. WebKit's
    /// blackboxing doesn't keep Step into out of a listed script, and has
    /// no address to blackbox eval'd code by.
    private func skipsIgnoredPause(_ frames: [CallFrame], targetID: String?) -> Bool {
        guard let top = frames.first, isIgnored(top) else { return false }
        let method = stepping ? "Debugger.stepOut" : "Debugger.resume"
        run { debugger in
            _ = try await debugger.command(method, targetID: targetID)
        }
        return true
    }

    private func resumed() {
        pause = nil
        refreshInlineScopes()
        properties = [:]
        loading = []
        expanded = Set(expanded.filter { !$0.contains("/") && !$0.hasPrefix("popover:") })
        revealed = nil
        selectedFrame = 0
        refreshWatches()
    }

    // MARK: Stepping and frames

    func selectFrame(_ index: Int) {
        guard let pause, pause.frames.indices.contains(index) else { return }
        selectedFrame = index
        let frame = pause.frames[index]
        let local = frame.scopes.firstIndex { $0.kind == .local } ?? (frame.scopes.isEmpty ? nil : 0)
        expanded = Set(expanded.filter { !$0.hasPrefix("scope:") })
        properties = properties.filter { !$0.key.hasPrefix("scope:") }
        if let local {
            expanded.insert("scope:\(local)")
            loadScope(local)
        }
        refreshWatches()
        // Chrome shows a mapped frame in its authored file.
        if let original = frame.original {
            reveal(Location(url: original.url, line: original.line + 1))
        } else {
            reveal(Location(url: frame.url, line: frame.line + 1))
        }
    }

    /// Shows a line in the editor, opening its file when the page lists it.
    func reveal(_ location: Location) {
        revealed = location
        guard let session, !location.url.isEmpty else { return }
        // The same path as Console and Network links: open, scroll, flash.
        session.revealSource(url: location.url, line: location.line, showPanel: false)
    }

    func step(_ name: String) {
        guard pause != nil || name == "pause" else { return }
        stepping = ["stepInto", "stepOver", "stepNext", "stepOut"].contains(name)
        run { debugger in
            _ = try await debugger.command("Debugger.\(name)", targetID: debugger.pause?.targetID)
        }
    }

    /// "Continue to here": resume, then pause again at a line.
    func continueToHere(url: String, line: Int) {
        guard let pause, line > 0 else { return }
        run { debugger in
            guard let session = debugger.session else { return }
            // In an authored file, the line's place in the compiled script.
            let generated = session.sourceMaps.generated(url: url, line: line - 1)
            guard var location = try await session.scriptLocation(url: generated?.url ?? url, line: generated?.line ?? line - 1,
                                                                  targetID: pause.targetID) else {
                throw DebuggerError("This line isn’t in a loaded script.")
            }
            if let generated { location["columnNumber"] = generated.column }
            _ = try await debugger.command("Debugger.continueToLocation", ["location": location], targetID: pause.targetID)
        }
    }

    // MARK: Scope and object trees

    /// `keepingValues` leaves the old values showing until the new ones
    /// arrive, after a value was edited in the same pause.
    private func refreshInlineScopes(keepingValues: Bool = false) {
        inlineScopeTask?.cancel()
        guard let pause, let topFrame = pause.frames.first else { clearInlineValues(); return }
        let scopes = topFrame.scopes.prefix { $0.kind != .with }.filter(\.showsInlineValues)
        guard !scopes.isEmpty else { clearInlineValues(); return }
        if !keepingValues { clearInlineValues() }
        let targetID = pause.targetID
        inlineScopeTask = Task { @MainActor [weak self] in
            let names = await self?.authoredNames(topFrame, targetID: targetID)
            var inlineScopes: [InlineScope] = []
            for scope in scopes {
                var values: [String: String] = [:]
                for object in scope.objects {
                    guard !Task.isCancelled else { return }
                    guard let objectID = object.objectID,
                          let result = try? await self?.command("Runtime.getProperties", [
                              "objectId": objectID, "ownProperties": true, "generatePreview": false,
                          ], targetID: targetID) else { continue }
                    for property in (result["properties"] as? [[String: Any]] ?? []).prefix(5_000) {
                        guard let name = property["name"] as? String, name != "__proto__", values[name] == nil,
                              let value = property["value"] as? [String: Any] else { continue }
                        values[name] = RemoteValue(value).display
                    }
                }
                if !values.isEmpty { inlineScopes.append(InlineScope(kind: scope.kind, start: scope.start, values: values)) }
            }
            guard !Task.isCancelled, self?.session?.ready == true else { return }
            self?.inlineNames = names
            self?.inlineScopes = inlineScopes
        }
    }

    private func clearInlineValues() {
        if inlineNames != nil { inlineNames = nil }
        if !inlineScopes.isEmpty { inlineScopes = [] }
    }

    /// The compiled names behind the authored identifiers from the top
    /// frame's function start through its paused line, read from the
    /// script's text and its map's named segments.
    private func authoredNames(_ frame: CallFrame, targetID: String?) async -> [String: String]? {
        guard let original = frame.original, let scriptID = frame.scriptID, let maps = session?.sourceMaps,
              let entry = maps.attached.values.first(where: { !$0.css && Self.sameScript($0.url, frame.url) }) else { return nil }
        let text: String
        if let last = lastScriptSource, last.id == scriptID {
            text = last.text
        } else {
            guard let reply = try? await command("Debugger.getScriptSource", ["scriptId": scriptID], targetID: targetID),
                  let source = reply["scriptSource"] as? String else { return nil }
            // Kept for the next step through the same script.
            lastScriptSource = (scriptID, source)
            text = source
        }
        guard !Task.isCancelled else { return nil }
        let start = frame.scopes.first { $0.kind == .local }?.start.flatMap {
            maps.original(url: frame.url, line: $0.position.line - 1, column: $0.position.column)
        }
        var from = (line: original.line, column: 0)
        if let start, start.url == original.url, start.line <= original.line { from = (start.line, start.column) }
        let map = entry.map, source = original.url, through = original.line
        return await Task.detached(priority: .userInitiated) {
            SourceInlineValues.authoredNames(map: map, generated: text, source: source, from: from, throughLine: through)
        }.value
    }

    func toggleExpanded(_ path: String, objectID: String?) {
        if expanded.contains(path) {
            expanded = expanded.filter { $0 != path && !$0.hasPrefix(path + "/") }
            return
        }
        expanded.insert(path)
        if path.hasPrefix("scope:"), !path.contains("/"), let index = Int(path.dropFirst(6)) {
            loadScope(index)
        } else if let objectID {
            loadObject(objectID)
        }
    }

    private func loadScope(_ index: Int) {
        guard let frame, frame.scopes.indices.contains(index) else { return }
        let key = "scope:\(index)"
        let scope = frame.scopes[index]
        guard properties[key] == nil, loading.insert(key).inserted else { return }
        let frameID = frame.id
        run { debugger in
            var items: [Property] = []
            if scope.kind == .local, let this = frame.this { items.append(Property(name: "this", value: this)) }
            var seen = Set<String>()
            for object in scope.objects {
                guard let id = object.objectID else { continue }
                for property in try await debugger.loadProperties(id, scope: true) where seen.insert(property.name).inserted {
                    items.append(property)
                }
            }
            guard debugger.frame?.id == frameID else { return }
            debugger.loading.remove(key)
            debugger.properties[key] = Self.sorted(items, keepingFirst: scope.kind == .local ? 1 : 0)
        }
    }

    private func loadObject(_ objectID: String) {
        guard properties[objectID] == nil, loading.insert(objectID).inserted else { return }
        run { debugger in
            let items = try await debugger.loadProperties(objectID, scope: false)
            debugger.loading.remove(objectID)
            debugger.properties[objectID] = items
        }
    }

    private func loadProperties(_ objectID: String, scope: Bool) async throws -> [Property] {
        let targetID = pause?.targetID
        let result: [String: Any]
        do {
            result = try await command("Runtime.getDisplayableProperties", ["objectId": objectID, "generatePreview": false],
                                       targetID: targetID)
        } catch {
            result = try await command("Runtime.getProperties", ["objectId": objectID, "ownProperties": true],
                                       targetID: targetID)
        }
        var items: [Property] = []
        for raw in (result["properties"] as? [[String: Any]] ?? []).prefix(5_000) {
            guard let name = raw["name"] as? String else { continue }
            if scope && name == "__proto__" { continue }
            if let value = raw["value"] as? [String: Any] {
                items.append(Property(name: name, value: RemoteValue(value)))
            } else if raw["get"] != nil {
                items.append(Property(name: name, value: nil))
            }
        }
        if !scope {
            for raw in (result["internalProperties"] as? [[String: Any]] ?? []).prefix(50) {
                guard let name = raw["name"] as? String, let value = raw["value"] as? [String: Any] else { continue }
                items.append(Property(name: "[[\(name)]]", value: RemoteValue(value)))
            }
        }
        let prototype = items.firstIndex { $0.name == "__proto__" }.map { items.remove(at: $0) }
        var sorted = Self.sorted(items, keepingFirst: 0)
        if let prototype { sorted.append(Property(name: "[[Prototype]]", value: prototype.value)) }
        return sorted
    }

    private static func sorted(_ items: [Property], keepingFirst count: Int) -> [Property] {
        let head = Array(items.prefix(count))
        let rest = items.dropFirst(count).sorted { left, right in
            let leftInternal = left.name.hasPrefix("[["), rightInternal = right.name.hasPrefix("[[")
            if leftInternal != rightInternal { return rightInternal }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        return head + rest
    }

    // MARK: Object trees

    /// The rows of one object tree (a scope variable, a watch expression,
    /// the editor's hover popover) with its open descendants.
    func objectRows(path: String, name: String, value: RemoteValue?, missing: String?, depth: Int,
                    root: ObjectRow.Root, names: [String] = [], parent: String? = nil) -> [ObjectRow] {
        var rows: [ObjectRow] = []
        func add(_ path: String, _ name: String, _ value: RemoteValue?, _ missing: String?, _ depth: Int,
                 _ names: [String], _ parent: String?) {
            guard rows.count < 1_500, depth < 24 else { return }
            let open = expanded.contains(path)
            rows.append(ObjectRow(id: path, depth: depth, name: name, value: value, missing: missing, open: open,
                                  names: names, parentObjectID: parent, root: root))
            guard open, let id = value?.objectID, let children = properties[id] else { return }
            for child in children {
                add(path + "/" + child.name, child.name, child.value, "(...)", depth + 1, names + [child.name], id)
            }
        }
        add(path, name, value, missing, depth, names, parent)
        return rows
    }

    /// Chrome's Scope pane edit: a variable is assigned in the selected
    /// frame, a property set on its object. WebKit has no
    /// Debugger.setVariableValue, so a variable goes through
    /// `name = value` evaluated on the frame: one an inner scope shadows
    /// can't be reached that way.
    func setValue(_ row: ObjectRow, to expression: String) {
        let text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let name = row.names.last else { return }
        let callFrame = frame?.id
        let targetID = pause?.targetID
        run { debugger in
            if let parent = row.parentObjectID {
                let value = try await debugger.evaluateRaw(text, callFrame: callFrame, targetID: targetID)
                let result = try await debugger.command("Runtime.callFunctionOn", [
                    "objectId": parent, "functionDeclaration": "function(name, value) { this[name] = value; }",
                    "arguments": [["value": name], Self.callArgument(value)], "returnByValue": true,
                ], targetID: targetID)
                try Self.checkThrown(result)
            } else if case .scope = row.root, row.names.count == 1 {
                guard let callFrame else { throw DebuggerError("Values can be changed only while paused.") }
                guard Self.isIdentifier(name), name != "this" else { throw DebuggerError("“\(name)” can’t be assigned.") }
                let result = try await debugger.command("Debugger.evaluateOnCallFrame", [
                    "callFrameId": callFrame, "expression": "\(name) = (\(text))", "objectGroup": "scope-edit",
                    "includeCommandLineAPI": false, "doNotPauseOnExceptionsAndMuteConsole": true, "returnByValue": false,
                ], targetID: targetID)
                try Self.checkThrown(result)
            } else {
                return
            }
            debugger.refreshValues()
        }
    }

    /// Chrome's "Store as global variable": the value as `temp1` (or the
    /// next free number) on the page's global object, shown in the Console.
    func storeAsGlobal(_ value: RemoteValue) {
        let targetID = pause?.targetID
        let pick = "let i = 1; while ((\"temp\" + i) in globalThis) i++; const name = \"temp\" + i;"
        run { debugger in
            let result: [String: Any]
            if let id = value.objectID {
                result = try await debugger.command("Runtime.callFunctionOn", [
                    "objectId": id, "functionDeclaration": "function() { \(pick) globalThis[name] = this; return name; }",
                    "returnByValue": true,
                ], targetID: targetID)
            } else if let literal = Self.literal(value) {
                result = try await debugger.command("Runtime.evaluate", [
                    "expression": "(() => { \(pick) globalThis[name] = \(literal); return name; })()",
                    "returnByValue": true, "doNotPauseOnExceptionsAndMuteConsole": true, "includeCommandLineAPI": false,
                ], targetID: targetID)
            } else {
                throw DebuggerError("This value can’t be stored.")
            }
            try Self.checkThrown(result)
            guard let name = (result["result"] as? [String: Any])?["value"] as? String else { return }
            debugger.session?.evaluate(name)
        }
    }

    /// The editor's hover popover: an expression evaluated on the selected
    /// frame, nil when it throws or the debugger isn't paused.
    func evaluateForPopover(_ expression: String) async -> RemoteValue? {
        guard let callFrame = frame?.id else { return nil }
        let raw = try? await evaluateRaw(expression, callFrame: callFrame, targetID: pause?.targetID, group: "popover")
        return raw.map(RemoteValue.init)
    }

    /// An expression's remote object, in the frame when paused.
    private func evaluateRaw(_ expression: String, callFrame: String?, targetID: String?,
                             group: String = "scope-edit") async throws -> [String: Any] {
        let result: [String: Any]
        if let callFrame {
            result = try await command("Debugger.evaluateOnCallFrame", [
                "callFrameId": callFrame, "expression": expression, "objectGroup": group,
                "includeCommandLineAPI": false, "doNotPauseOnExceptionsAndMuteConsole": true,
                "returnByValue": false, "generatePreview": false,
            ], targetID: targetID)
        } else {
            result = try await command("Runtime.evaluate", [
                "expression": expression, "objectGroup": group, "includeCommandLineAPI": false,
                "doNotPauseOnExceptionsAndMuteConsole": true, "returnByValue": false,
            ], targetID: targetID)
        }
        try Self.checkThrown(result)
        return result["result"] as? [String: Any] ?? [:]
    }

    private static func checkThrown(_ result: [String: Any]) throws {
        guard result["wasThrown"] as? Bool == true else { return }
        let object = result["result"] as? [String: Any]
        throw DebuggerError(object?["description"] as? String ?? "The expression threw an exception.")
    }

    /// A remote object as a call argument: by id, by value, or undefined.
    private static func callArgument(_ raw: [String: Any]) -> [String: Any] {
        if let id = raw["objectId"] as? String { return ["objectId": id] }
        if let value = raw["value"], !(value is NSNull) || raw["subtype"] as? String == "null" { return ["value": value] }
        return [:]
    }

    /// A primitive written back as JavaScript.
    static func literal(_ value: RemoteValue) -> String? {
        switch value.type {
        case "string":
            let data = try? JSONSerialization.data(withJSONObject: [value.primitive ?? value.description])
            return data.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) }
        case "number", "boolean": return value.primitive ?? value.description
        case "bigint": return value.description.hasSuffix("n") ? value.description : value.description + "n"
        case "undefined": return "undefined"
        default: return value.subtype == "null" ? "null" : nil
        }
    }

    /// Loads again what the trees show, after a value changed.
    private func refreshValues() {
        let objects = properties.keys.filter { !$0.hasPrefix("scope:") }
        properties = [:]
        loading = []
        for path in expanded where path.hasPrefix("scope:") && !path.contains("/") {
            if let index = Int(path.dropFirst(6)) { loadScope(index) }
        }
        for id in objects { loadObject(id) }
        refreshInlineScopes(keepingValues: true)
        refreshWatches()
    }

    nonisolated static func isIdentifier(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil
    }

    /// Chrome's "Copy property path": the way to the row from its root, as
    /// JavaScript — `a.b[0]["c-d"]`. A watch expression's children start
    /// from the expression; [[Prototype]] steps are left out (the chain
    /// finds the property anyway); nil past another internal property.
    nonisolated static func propertyPath(_ root: ObjectRow.Root, names: [String]) -> String? {
        var rest = names[...]
        var path: String
        switch root {
        case .scope:
            guard let first = rest.popFirst(), isIdentifier(first) else { return nil }
            path = first
        case let .expression(expression):
            let simple = expression.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z_$][A-Za-z0-9_$]*)*$"#,
                                          options: .regularExpression) != nil
            path = simple ? expression : "(" + expression + ")"
        }
        for name in rest {
            if name == "[[Prototype]]" { continue }
            if name.hasPrefix("[[") { return nil }
            if isIdentifier(name) {
                path += "." + name
            } else if let index = UInt(name), String(index) == name {
                path += "[" + name + "]"
            } else {
                let data = try? JSONSerialization.data(withJSONObject: [name])
                guard let quoted = data.flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
                path += "[" + String(quoted.dropFirst().dropLast()) + "]"
            }
        }
        return path
    }

    // MARK: Watch

    func addWatch(_ expression: String) {
        let text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        watches.append(Watch(expression: text))
        saveWatches()
        refreshWatches()
    }

    func editWatch(_ id: Watch.ID, expression: String) {
        let text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = watches.firstIndex(where: { $0.id == id }) else { return }
        if text.isEmpty { watches.remove(at: index) } else { watches[index] = Watch(expression: text) }
        saveWatches()
        refreshWatches()
    }

    func removeWatch(_ id: Watch.ID) {
        watches.removeAll { $0.id == id }
        saveWatches()
    }

    func removeAllWatches() {
        watches = []
        saveWatches()
    }

    private func saveWatches() {
        UserDefaults.standard.set(watches.map(\.expression), forKey: Self.watchesKey)
    }

    /// Evaluates every watch in the selected frame, or the page when not paused.
    func refreshWatches() {
        guard session?.ready == true, !watches.isEmpty else { return }
        watchGeneration += 1
        let generation = watchGeneration
        let callFrame = frame?.id
        let targetID = pause?.targetID
        let expressions = watches.map { ($0.id, $0.expression) }
        expanded = expanded.filter { !$0.hasPrefix("watch:") }
        run { debugger in
            for (id, expression) in expressions {
                var result: [String: Any]
                do {
                    if let callFrame {
                        result = try await debugger.command("Debugger.evaluateOnCallFrame", [
                            "callFrameId": callFrame, "expression": expression, "objectGroup": "watch-group",
                            "includeCommandLineAPI": false, "doNotPauseOnExceptionsAndMuteConsole": true,
                            "returnByValue": false, "generatePreview": false,
                        ], targetID: targetID)
                    } else {
                        result = try await debugger.command("Runtime.evaluate", [
                            "expression": expression, "objectGroup": "watch-group", "includeCommandLineAPI": false,
                            "doNotPauseOnExceptionsAndMuteConsole": true, "returnByValue": false,
                        ])
                    }
                } catch {
                    result = ["wasThrown": true]
                }
                guard generation == debugger.watchGeneration,
                      let index = debugger.watches.firstIndex(where: { $0.id == id }) else { return }
                let thrown = result["wasThrown"] as? Bool == true
                debugger.watches[index].value = thrown ? nil : (result["result"] as? [String: Any]).map(RemoteValue.init)
                debugger.watches[index].evaluated = true
            }
        }
    }

    // MARK: Line breakpoints

    /// The gutter's click: add a breakpoint, or remove the one on that line.
    func toggleBreakpoint(url: String, line: Int, column: Int? = nil, snippet: String? = nil) {
        if let existing = breakpoint(url: url, line: line, column: column) {
            removeBreakpoint(existing.id)
        } else {
            setBreakpoint(url: url, line: line, column: column, kind: .regular, expression: "", snippet: snippet)
        }
    }

    /// Adds or edits a breakpoint as Chrome's breakpoint dialog does.
    func setBreakpoint(url: String, line: Int, column: Int? = nil, kind: Breakpoint.Kind, expression: String = "",
                       snippet: String? = nil) {
        guard line > 0, !url.isEmpty else { return }
        let text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = kind != .regular && text.isEmpty ? .regular : kind
        var item = breakpoint(url: url, line: line, column: column)
            ?? Breakpoint(url: url, line: line, column: column, snippet: snippet ?? "")
        let old = item.protocolID
        item.kind = kind
        item.expression = kind == .regular ? "" : text
        item.enabled = true
        item.protocolID = nil
        item.resolved = false
        if let index = breakpoints.firstIndex(where: { $0.id == item.id }) { breakpoints[index] = item }
        else { breakpoints.append(item) }
        let id = item.id
        // Setting a breakpoint turns breakpoints back on, as in Chrome.
        let activate = !breakpointsActive
        breakpointsActive = true
        run { debugger in
            if let old { _ = try? await debugger.command("Debugger.removeBreakpoint", ["breakpointId": old]) }
            if activate { _ = try await debugger.command("Debugger.setBreakpointsActive", ["active": true]) }
            try await debugger.install(id)
        }
        syncWorkerBreakpoints()
    }

    func setBreakpointEnabled(_ id: Breakpoint.ID, _ enabled: Bool) {
        guard let index = breakpoints.firstIndex(where: { $0.id == id }), breakpoints[index].enabled != enabled else { return }
        breakpoints[index].enabled = enabled
        let old = breakpoints[index].protocolID
        breakpoints[index].protocolID = nil
        breakpoints[index].resolved = false
        run { debugger in
            if let old { _ = try await debugger.command("Debugger.removeBreakpoint", ["breakpointId": old]) }
            if enabled { try await debugger.install(id) }
        }
        if !enabled { syncWorkerBreakpoints() }
    }

    func setBreakpointsEnabled(_ enabled: Bool, in url: String? = nil) {
        for item in breakpoints where url == nil || item.url == url { setBreakpointEnabled(item.id, enabled) }
    }

    func removeBreakpoint(_ id: Breakpoint.ID) {
        guard let index = breakpoints.firstIndex(where: { $0.id == id }) else { return }
        let old = breakpoints.remove(at: index).protocolID
        changed()
        guard let old else { return }
        run { debugger in _ = try await debugger.command("Debugger.removeBreakpoint", ["breakpointId": old]) }
    }

    func removeBreakpoints(in url: String? = nil, except kept: Breakpoint.ID? = nil) {
        for item in breakpoints where (url == nil || item.url == url) && item.id != kept { removeBreakpoint(item.id) }
    }

    /// Chrome's "Deactivate breakpoints": they stay listed but don't pause.
    func setBreakpointsActive(_ active: Bool) {
        breakpointsActive = active
        run { debugger in _ = try await debugger.command("Debugger.setBreakpointsActive", ["active": active]) }
        syncWorkerBreakpoints()
    }

    /// Debugger.setBreakpointByUrl's parameters for a line breakpoint.
    private func installParameters(_ item: Breakpoint) -> [String: Any] {
        var params: [String: Any] = ["url": item.url, "lineNumber": item.line - 1]
        if let column = item.column { params["columnNumber"] = column }
        // A breakpoint in an authored file goes where its source map put
        // the line in the compiled script, as Chrome sets it.
        if let generated = session?.sourceMaps.generated(url: item.url, line: item.line - 1, column: item.column) {
            params["url"] = generated.url
            params["lineNumber"] = generated.line
            params["columnNumber"] = generated.column
        }
        if let options = item.options { params["options"] = options }
        return params
    }

    /// Chrome sets a breakpoint by URL in every worker too, including ones
    /// started later: the bridge keeps the list, sets it in each worker
    /// there now and in each new one before its first line runs.
    private func syncWorkerBreakpoints() {
        run { debugger in
            guard let session = debugger.session else { return }
            let list = debugger.breakpoints.filter(\.enabled).map { debugger.installParameters($0) }
            _ = try await session.bridge("return perchInspector.setWorkerBreakpoints?.(list, active) ?? false;",
                                         ["list": list, "active": debugger.breakpointsActive])
        }
    }

    private func install(_ id: Breakpoint.ID) async throws {
        guard let item = breakpoints.first(where: { $0.id == id }), item.enabled else { return }
        let params = installParameters(item)
        let result = try await command("Debugger.setBreakpointByUrl", params)
        guard let index = breakpoints.firstIndex(where: { $0.id == id }) else {
            if let set = result["breakpointId"] as? String {
                _ = try? await command("Debugger.removeBreakpoint", ["breakpointId": set])
            }
            return
        }
        breakpoints[index].protocolID = result["breakpointId"] as? String
        breakpoints[index].resolved = !(result["locations"] as? [Any] ?? []).isEmpty
        changed()
    }

    private func changed() {
        session?.updateBreakpoints()
        syncWorkerBreakpoints()
    }

    // MARK: Exceptions

    func setPauseOnExceptions(uncaught: Bool, caught: Bool) {
        pauseOnUncaught = uncaught
        pauseOnCaught = caught
        run { debugger in try await debugger.applyExceptionState() }
    }

    /// WebKit has no caught-only state: caught exceptions pause on all.
    var exceptionState: String { pauseOnCaught ? "all" : pauseOnUncaught ? "uncaught" : "none" }

    /// Through WebKit's own exception breakpoints when the frontend has them,
    /// since it re-sends its own state and would otherwise undo a raw command.
    private func applyExceptionState() async throws {
        guard let session else { throw DebuggerError("DevTools closed.") }
        if try await session.pauseOnExceptions(uncaught: pauseOnUncaught, caught: pauseOnCaught) { return }
        _ = try await command("Debugger.setPauseOnExceptions", ["state": exceptionState])
    }

    // MARK: XHR/fetch breakpoints

    func addURLBreakpoint(_ text: String) {
        guard !urlBreakpoints.contains(where: { $0.url == text }) else { return }
        urlBreakpoints.append(URLBreakpoint(url: text))
        run { debugger in _ = try await debugger.command("DOMDebugger.setURLBreakpoint", ["url": text, "isRegex": false]) }
    }

    func setURLBreakpointEnabled(_ id: URLBreakpoint.ID, _ enabled: Bool) {
        guard let index = urlBreakpoints.firstIndex(where: { $0.id == id }), urlBreakpoints[index].enabled != enabled else { return }
        urlBreakpoints[index].enabled = enabled
        let url = urlBreakpoints[index].url
        run { debugger in
            _ = try await debugger.command(enabled ? "DOMDebugger.setURLBreakpoint" : "DOMDebugger.removeURLBreakpoint",
                                           ["url": url, "isRegex": false])
        }
    }

    func removeURLBreakpoint(_ id: URLBreakpoint.ID) {
        guard let index = urlBreakpoints.firstIndex(where: { $0.id == id }) else { return }
        let item = urlBreakpoints.remove(at: index)
        guard item.enabled else { return }
        run { debugger in
            _ = try await debugger.command("DOMDebugger.removeURLBreakpoint", ["url": item.url, "isRegex": false])
        }
    }

    // MARK: DOM breakpoints

    /// The Elements tree's "Break on" items.
    func toggleDOMBreakpoint(node: Int, type: DOMBreakpoint.Kind) {
        if let existing = domBreakpoints.first(where: { $0.node == node && $0.type == type }) {
            removeDOMBreakpoint(existing.id)
            return
        }
        let label = session?.nodes[node].map(Self.nodeLabel) ?? "node"
        domBreakpoints.append(DOMBreakpoint(node: node, type: type, label: label))
        run { debugger in
            _ = try await debugger.command("DOMDebugger.setDOMBreakpoint", ["nodeId": node, "type": type.rawValue])
        }
    }

    func setDOMBreakpointEnabled(_ id: DOMBreakpoint.ID, _ enabled: Bool) {
        guard let index = domBreakpoints.firstIndex(where: { $0.id == id }), domBreakpoints[index].enabled != enabled else { return }
        domBreakpoints[index].enabled = enabled
        let item = domBreakpoints[index]
        run { debugger in
            _ = try await debugger.command(enabled ? "DOMDebugger.setDOMBreakpoint" : "DOMDebugger.removeDOMBreakpoint",
                                           ["nodeId": item.node, "type": item.type.rawValue])
        }
    }

    func removeDOMBreakpoint(_ id: DOMBreakpoint.ID) {
        guard let index = domBreakpoints.firstIndex(where: { $0.id == id }) else { return }
        let item = domBreakpoints.remove(at: index)
        guard item.enabled else { return }
        run { debugger in
            _ = try await debugger.command("DOMDebugger.removeDOMBreakpoint", ["nodeId": item.node, "type": item.type.rawValue])
        }
    }

    static func nodeLabel(_ node: DeveloperToolsSession.DOMNode) -> String {
        guard node.type == 1 else { return node.display }
        var label = node.name.lowercased()
        var index = 0
        while index + 1 < node.attributes.count {
            let name = node.attributes[index], value = node.attributes[index + 1]
            if name == "id", !value.isEmpty { label += "#" + value }
            if name == "class" { label += value.split(separator: " ").prefix(3).map { "." + $0 }.joined() }
            index += 2
        }
        return label
    }

    // MARK: Event listener breakpoints

    func setEventBreakpoint(_ item: EventBreakpoint, _ on: Bool) {
        guard item.available, eventBreakpoints.contains(item.id) != on else { return }
        if on { eventBreakpoints.insert(item.id) } else { eventBreakpoints.remove(item.id) }
        run { debugger in
            _ = try await debugger.command(on ? "DOMDebugger.setEventBreakpoint" : "DOMDebugger.removeEventBreakpoint",
                                           item.parameters)
        }
    }

    // MARK: Plumbing

    /// Settings › Preferences › Debugger › "Disable async stack traces".
    static let asyncStackTracesDisabledKey = "perch.devtools.disableAsyncStackTraces"

    private func enableAsyncStackTraces() async {
        let off = UserDefaults.standard.bool(forKey: Self.asyncStackTracesDisabledKey)
        _ = try? await command("Debugger.setAsyncStackTraceDepth", ["depth": off ? 0 : 32])
    }

    /// The setting changed: the page's debugger records async stacks, or stops.
    func asyncStackTracesSettingChanged() {
        run { debugger in await debugger.enableAsyncStackTraces() }
    }

    /// Puts every breakpoint back after the page moved to a new process.
    private func reapply() {
        for index in breakpoints.indices {
            breakpoints[index].protocolID = nil
            breakpoints[index].resolved = false
        }
        let lines = breakpoints.filter(\.enabled).map(\.id)
        let urls = urlBreakpoints.filter(\.enabled).map(\.url)
        let events = EventBreakpoint.categories.flatMap(\.items).filter { eventBreakpoints.contains($0.id) }
        domBreakpoints.removeAll()
        let ignored = ignoredScripts
        run { debugger in
            await debugger.enableAsyncStackTraces()
            try await debugger.applyExceptionState()
            _ = try await debugger.command("Debugger.setBreakpointsActive", ["active": debugger.breakpointsActive])
            for id in lines { try await debugger.install(id) }
            for url in urls { _ = try await debugger.command("DOMDebugger.setURLBreakpoint", ["url": url, "isRegex": false]) }
            var done = Set<String>()
            for item in events where done.insert(item.id).inserted {
                _ = try await debugger.command("DOMDebugger.setEventBreakpoint", item.parameters)
            }
            for url in ignored where debugger.session?.sourceMaps.isAuthored(url) != true {
                _ = try await debugger.command("Debugger.setShouldBlackboxURL",
                                               ["url": url, "shouldBlackbox": true, "caseSensitive": true, "isRegex": false])
            }
        }
        applyIgnoreList()
    }

    private func command(_ method: String, _ params: [String: Any] = [:], targetID: String? = nil) async throws -> [String: Any] {
        guard let session else { throw DebuggerError("DevTools closed.") }
        return try await session.command(method, params, targetID: targetID)
    }

    private var queue: Task<Void, Never>?

    /// Returns once every queued command has reached the page.
    func settled() async {
        while let current = queue {
            await current.value
            if queue == current { return }
        }
    }

    /// Commands run in order, so a quick toggle can't overtake itself.
    private func run(_ action: @escaping @MainActor (DeveloperDebugger) async throws -> Void) {
        guard session?.ready == true else { return }
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self, self.session?.ready == true, !Task.isCancelled else { return }
            do { try await action(self) }
            catch is CancellationError {}
            catch { if self.session?.ready == true { self.session?.message = error.localizedDescription } }
        }
    }

    /// Two script addresses name the same file, ignoring query and fragment
    /// (the event stream drops both).
    static func sameScript(_ left: String, _ right: String) -> Bool {
        func base(_ url: String) -> Substring { url.split(whereSeparator: { $0 == "?" || $0 == "#" }).first ?? "" }
        return !left.isEmpty && base(left) == base(right)
    }

    struct DebuggerError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
}

// MARK: - Models

extension DeveloperDebugger {
    struct Location: Equatable {
        let url: String
        /// 1-based.
        let line: Int
    }

    /// A value from WebKit's Runtime domain, shown as Chrome's object
    /// properties section shows it.
    struct RemoteValue: Equatable {
        let type: String
        let subtype: String?
        let className: String?
        let description: String
        let objectID: String?
        let primitive: String?

        init(_ raw: [String: Any]) {
            type = raw["type"] as? String ?? "undefined"
            subtype = raw["subtype"] as? String
            className = raw["className"] as? String
            description = raw["description"] as? String ?? ""
            objectID = raw["objectId"] as? String
            switch raw["value"] {
            case let string as String: primitive = string
            case let number as NSNumber where type == "boolean": primitive = number.boolValue ? "true" : "false"
            case let number as NSNumber: primitive = number.stringValue
            default: primitive = nil
            }
        }

        var expandable: Bool { objectID != nil && (type == "object" || type == "function") && subtype != "null" }

        var display: String {
            switch type {
            case "string": return "\"" + String((primitive ?? description).prefix(1_000)) + "\""
            case "undefined": return "undefined"
            case "number", "boolean", "bigint": return primitive ?? description
            case "symbol": return description
            case "function":
                let head = description.split(separator: "{", maxSplits: 1).first.map(String.init) ?? description
                let signature = head.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "function ", with: "")
                    .replacingOccurrences(of: "async ", with: "async ƒ ")
                return signature.hasPrefix("async ") ? signature : "ƒ " + String(signature.prefix(160))
            default:
                if subtype == "null" { return "null" }
                return String(description.prefix(300))
            }
        }

        var style: Style {
            switch type {
            case "string": return .string
            case "number", "bigint", "boolean": return .number
            case "undefined": return .null
            case "function": return .function
            default: return subtype == "null" ? .null : .object
            }
        }

        enum Style { case string, number, null, function, object }
    }

    /// One row of an object tree in Scope, Watch or the hover popover.
    struct ObjectRow: Identifiable, Equatable {
        /// What a tree's root stands for: a scope's variables, or an
        /// expression (a watch, a hovered name).
        enum Root: Equatable {
            case scope(Int)
            case expression(String)
        }

        /// The expansion path.
        let id: String
        let depth: Int
        let name: String
        let value: RemoteValue?
        let missing: String?
        let open: Bool
        /// The property names from the root to this row: a scope's first
        /// is the variable.
        let names: [String]
        /// The object this row is a property of.
        let parentObjectID: String?
        let root: Root

        var propertyPath: String? { names.isEmpty ? nil : DeveloperDebugger.propertyPath(root, names: names) }
        /// Whether a double-click can change the value: a scope variable
        /// while paused, or a property of an object.
        var editable: Bool {
            guard let name = names.last, !name.hasPrefix("[[") else { return false }
            if parentObjectID != nil { return true }
            if case .scope = root { return names.count == 1 && name != "this" }
            return false
        }
    }

    struct Property: Identifiable, Equatable {
        let name: String
        /// Nil for an accessor WebKit didn't run: Chrome's "(...)".
        let value: RemoteValue?
        var id: String { name }
    }

    struct Scope: Identifiable, Equatable {
        enum Kind: Equatable { case local, closure, block, script, global, `catch`, with, functionName }
        struct Start: Equatable {
            let scriptID: String?
            let position: SourceBreakpoint
        }
        let id: Int
        let kind: Kind
        let title: String
        let objects: [RemoteValue]
        let empty: Bool
        let start: Start?

        var showsInlineValues: Bool {
            switch kind {
            case .local, .closure, .block, .catch, .functionName: return !empty
            case .script, .global, .with: return false
            }
        }
    }

    struct InlineScope: Equatable {
        let kind: Scope.Kind
        let start: Scope.Start?
        let values: [String: String]
    }

    struct CallFrame: Identifiable, Equatable {
        let id: String
        let index: Int
        let functionName: String
        let url: String
        let scriptID: String?
        /// 0-based, as the protocol counts.
        let line: Int
        let column: Int
        let this: RemoteValue?
        let scopes: [Scope]
        /// Where the frame is in its authored file, when the script has a
        /// source map (DeveloperSourceMaps); the call stack shows that.
        var original: DeveloperSourceMap.Original?

        init(_ raw: [String: Any], index: Int) {
            self.index = index
            id = raw["callFrameId"] as? String ?? "frame-\(index)"
            let name = raw["functionName"] as? String ?? ""
            functionName = name.isEmpty ? "(anonymous)" : name
            url = raw["url"] as? String ?? ""
            let location = raw["location"] as? [String: Any] ?? [:]
            scriptID = location["scriptId"] as? String
            line = location["lineNumber"] as? Int ?? 0
            column = location["columnNumber"] as? Int ?? 0
            this = (raw["this"] as? [String: Any]).map(RemoteValue.init)
            scopes = Self.scopes(raw["scopeChain"] as? [[String: Any]] ?? [], functionName: name)
        }

        init(asyncFrame raw: [String: Any], index: Int) {
            // Async frames use Console.CallFrame, whose line numbers are 1-based.
            // They have no call frame identifier or scope to use for evaluation.
            // Columns are 1-based there too.
            let url = raw["url"] as? String ?? ""
            var location: [String: Any] = [
                "lineNumber": max(1, raw["lineNumber"] as? Int ?? 1) - 1,
                "columnNumber": max(1, raw["columnNumber"] as? Int ?? 1) - 1,
            ]
            if let scriptID = raw["scriptId"] as? String, !scriptID.isEmpty { location["scriptId"] = scriptID }
            self.init([
                "functionName": raw["functionName"] as? String ?? "",
                "url": url == "[native code]" ? "" : url,
                "location": location,
            ], index: index)
        }

        var fileName: String { Self.fileName(original?.url ?? url) }

        /// App.tsx:42 for a mapped frame, bundle.js:1 for one that isn't.
        var location: String { "\(fileName):\((original?.line ?? line) + 1)" }

        /// The compiled place, for the tooltip and "Show generated location".
        var generatedLocation: String { "\(Self.fileName(url)):\(line + 1)" }

        private static func fileName(_ url: String) -> String {
            guard let address = URL(string: url), !address.lastPathComponent.isEmpty, address.lastPathComponent != "/" else {
                return url.isEmpty ? "(unknown)" : url
            }
            return address.lastPathComponent
        }

        /// WebKit splits one function's variables over several closure
        /// scopes; merge them as WebKit's own frontend does, then name each
        /// scope the way Chrome's Scope pane does.
        private static func scopes(_ chain: [[String: Any]], functionName: String) -> [Scope] {
            struct Raw {
                let type: String
                let name: String
                let start: Scope.Start?
                var objects: [RemoteValue]
                var empty: Bool
            }
            var merged: [Raw] = []
            for item in chain {
                let type = item["type"] as? String ?? ""
                let name = item["name"] as? String ?? ""
                let object = RemoteValue(item["object"] as? [String: Any] ?? [:])
                let start = (item["location"] as? [String: Any]).flatMap { raw -> Scope.Start? in
                    guard let line = raw["lineNumber"] as? Int, line >= 0 else { return nil }
                    return Scope.Start(scriptID: raw["scriptId"] as? String,
                                       position: SourceBreakpoint(line: line + 1, column: raw["columnNumber"] as? Int ?? 0))
                }
                let empty = item["empty"] as? Bool == true
                if type == "closure", let start, let last = merged.last, last.type == "closure",
                   last.name == name, last.start == start {
                    merged[merged.count - 1].objects.append(object)
                    merged[merged.count - 1].empty = last.empty && empty
                    continue
                }
                merged.append(Raw(type: type, name: name, start: start, objects: [object], empty: empty))
            }
            var seenClosure = false
            return merged.enumerated().map { index, raw in
                let kind: Scope.Kind
                let title: String
                switch raw.type {
                case "closure":
                    // The innermost function scope is the frame's own.
                    let local = !seenClosure && (raw.name == functionName || raw.name.isEmpty || functionName.isEmpty)
                    seenClosure = true
                    kind = local ? .local : .closure
                    title = local ? "Local" : raw.name.isEmpty ? "Closure" : "Closure (\(raw.name))"
                case "nestedLexical": kind = .block; title = "Block"
                case "globalLexicalEnvironment": kind = .script; title = "Script"
                case "global": kind = .global; title = "Global"
                case "catch": kind = .catch; title = "Catch block"
                case "with": kind = .with; title = "With block"
                case "functionName": kind = .functionName; title = "Closure"
                default: kind = .block; title = raw.type.isEmpty ? "Block" : raw.type.capitalized
                }
                return Scope(id: index, kind: kind, title: title, objects: raw.objects, empty: raw.empty, start: raw.start)
            }
        }
    }

    struct AsyncStack: Identifiable, Equatable {
        let id: Int
        let boundary: String
        let frames: [CallFrame]
        /// Set on the last group when WebKit, or the limits here, cut the
        /// chain short: the Call Stack ends with a "(truncated)" row.
        var truncated = false

        static func groups(_ trace: [String: Any]?) -> [Self] {
            var current = trace
            var stacks: [Self] = []
            var truncated = false
            for index in 0..<32 {
                guard let stack = current else { break }
                current = stack["parentStackTrace"] as? [String: Any]
                let all = stack["callFrames"] as? [[String: Any]] ?? []
                if stack["truncated"] as? Bool == true || all.count > 32 { truncated = true }
                let raw = all.prefix(32)
                let hasBoundary = stack["topCallFrameIsBoundary"] as? Bool == true
                let name = hasBoundary ? (raw.first?["functionName"] as? String ?? "") : ""
                let frames = raw.dropFirst(hasBoundary ? 1 : 0).enumerated().map {
                    CallFrame(asyncFrame: $1, index: $0)
                }
                if !frames.isEmpty {
                    stacks.append(Self(id: index, boundary: name.isEmpty ? "Async" : name, frames: frames))
                }
            }
            if (truncated || current != nil), !stacks.isEmpty { stacks[stacks.count - 1].truncated = true }
            return stacks
        }
    }

    struct Pause: Equatable {
        let reason: String
        /// Changed only to add authored places when a map arrives late.
        var frames: [CallFrame]
        var asyncStacks: [AsyncStack]
        let targetID: String?
        let message: String
        let detail: String?
        let errorLike: Bool
        let breakpointID: String?

        init(reason: String, data: [String: Any], frames: [CallFrame], asyncStacks: [AsyncStack] = [], targetID: String?,
             describeNode: (Int) -> String?) {
            self.reason = reason
            self.frames = frames
            self.asyncStacks = asyncStacks
            self.targetID = targetID
            breakpointID = data["breakpointId"] as? String
            var detail: String?
            var errorLike = false
            let message: String
            // Chrome's DebuggerPausedMessage wording.
            switch reason {
            case "exception":
                message = "Paused on exception"
                errorLike = true
                detail = (data["description"] as? String).map { String($0.split(separator: "\n").first ?? "") }
            case "assert":
                message = "Paused on assertion"
                errorLike = true
                detail = data["description"] as? String
            case "CSPViolation":
                message = "Paused on CSP violation"
                errorLike = true
                detail = data["directive"] as? String
            case "Breakpoint":
                message = "Paused on breakpoint"
            case "DOM":
                let type = DOMBreakpoint.Kind(rawValue: data["type"] as? String ?? "")
                message = "Paused on " + (type?.pausedTitle ?? "DOM breakpoint")
                detail = (data["nodeId"] as? Int).flatMap(describeNode)
            case "Listener":
                message = "Paused on event listener"
                detail = data["eventName"] as? String
            case "Timeout":
                message = "Paused on event listener"
                detail = "setTimeout fired"
            case "Interval":
                message = "Paused on event listener"
                detail = "setInterval fired"
            case "AnimationFrame":
                message = "Paused on event listener"
                detail = "Animation Frame Fired"
            case "URL":
                message = "Paused on XHR or fetch"
                detail = data["url"] as? String
            default:
                message = "Debugger paused"
            }
            self.message = message
            self.detail = detail
            self.errorLike = errorLike
        }

        var stackTrace: String {
            func lines(_ frames: [CallFrame]) -> [String] {
                frames.map { "\($0.functionName) (\($0.location))" }
            }
            let truncated = asyncStacks.last?.truncated == true ? ["(truncated)"] : []
            return (lines(frames) + asyncStacks.flatMap { [$0.boundary] + lines($0.frames) } + truncated)
                .joined(separator: "\n")
        }
    }

    struct Watch: Identifiable, Equatable {
        let id = UUID()
        let expression: String
        var value: RemoteValue?
        var evaluated = false
    }

    struct Breakpoint: Identifiable, Equatable {
        enum Kind: String, CaseIterable, Identifiable {
            case regular = "Breakpoint"
            case conditional = "Conditional breakpoint"
            case logpoint = "Logpoint"
            var id: Self { self }
            var placeholder: String {
                switch self {
                case .regular: return ""
                case .conditional: return "Expression to check before pausing, e.g. x > 5"
                case .logpoint: return "Log message, e.g. 'x is', x"
                }
            }
            var help: String {
                self == .logpoint ? "Log a message to Console, don’t break" : "Pause only when the condition is true"
            }
        }

        let id = UUID()
        let url: String
        /// 1-based.
        let line: Int
        /// 0-based, for a breakpoint partway along a line (set from a
        /// pretty-printed view); nil for the whole line.
        let column: Int?
        var snippet: String
        var kind: Kind = .regular
        var expression = ""
        var enabled = true
        var protocolID: String?
        var resolved = false

        init(url: String, line: Int, column: Int? = nil, snippet: String) {
            self.url = url
            self.line = line
            self.column = column
            self.snippet = String(snippet.trimmingCharacters(in: .whitespaces).prefix(200))
        }

        var fileName: String {
            guard let address = URL(string: url), !address.lastPathComponent.isEmpty else { return url }
            return address.lastPathComponent
        }

        /// Chrome turns a logpoint into a condition that logs and returns
        /// false; WebKit has breakpoint actions for exactly that.
        var options: [String: Any]? {
            switch kind {
            case .regular: return nil
            case .conditional: return ["condition": expression]
            case .logpoint:
                return ["actions": [["type": "evaluate", "data": "console.log(\(expression))"]], "autoContinue": true]
            }
        }

        var hover: String? {
            switch kind {
            case .regular: return nil
            case .conditional: return "Condition: " + expression
            case .logpoint: return "Logpoint: " + expression
            }
        }
    }

    struct URLBreakpoint: Identifiable, Equatable {
        let id = UUID()
        let url: String
        var enabled = true
        var title: String { url.isEmpty ? "Any XHR or fetch" : "URL contains \"\(url)\"" }
    }

    struct DOMBreakpoint: Identifiable, Equatable {
        enum Kind: String, CaseIterable, Identifiable {
            case subtreeModified = "subtree-modified"
            case attributeModified = "attribute-modified"
            case nodeRemoved = "node-removed"
            var id: Self { self }
            var title: String {
                switch self {
                case .subtreeModified: return "Subtree modified"
                case .attributeModified: return "Attribute modified"
                case .nodeRemoved: return "Node removed"
                }
            }
            /// Chrome's Elements "Break on" menu, and the paused message.
            var pausedTitle: String {
                switch self {
                case .subtreeModified: return "subtree modifications"
                case .attributeModified: return "attribute modifications"
                case .nodeRemoved: return "node removal"
                }
            }
        }

        let id = UUID()
        let node: Int
        let type: Kind
        let label: String
        var enabled = true
    }

    /// One row of Chrome's Event Listener Breakpoints pane.
    struct EventBreakpoint: Identifiable, Hashable {
        let type: String
        let eventName: String?
        let title: String
        /// False for Chrome's instrumentation breakpoints WebKit has no
        /// backend for; listed so the pane matches Chrome, but not checkable.
        var available = true

        /// WebKit matches a listener breakpoint by event name alone, so
        /// "load" under Load and under XHR are one breakpoint.
        var id: String { type + ":" + (eventName ?? "") }

        var parameters: [String: Any] {
            var parameters: [String: Any] = ["breakpointType": type]
            if let eventName { parameters["eventName"] = eventName; parameters["caseSensitive"] = true; parameters["isRegex"] = false }
            return parameters
        }

        struct Category: Identifiable {
            let name: String
            let items: [EventBreakpoint]
            var id: String { name }
        }

        private static func listeners(_ names: [String]) -> [EventBreakpoint] {
            names.map { EventBreakpoint(type: "listener", eventName: $0, title: $0) }
        }

        private static func missing(_ titles: [String]) -> [EventBreakpoint] {
            titles.map { EventBreakpoint(type: "unavailable", eventName: $0, title: $0, available: false) }
        }

        /// Chrome's categories and events, in Chrome's order and wording
        /// (DOMDebuggerModel, EventBreakpointsModel, CategorizedBreakpointL10n).
        /// Instrumentation breakpoints WebKit lacks are kept, marked unavailable.
        static let categories: [Category] = [
            Category(name: "Ad auction worklet", items: missing(["Bidder Bidding Phase Start", "Bidder Reporting Phase Start",
                                                                 "Seller Scoring Phase Start", "Seller Reporting Phase Start"])),
            Category(name: "Animation", items: missing(["Request Animation Frame", "Cancel Animation Frame"])
                + [EventBreakpoint(type: "animation-frame", eventName: nil, title: "Animation Frame Fired")]),
            Category(name: "Canvas", items: missing(["Create canvas context", "WebGL Error Fired", "WebGL Warning Fired"])),
            Category(name: "Clipboard", items: listeners(["copy", "cut", "paste", "beforecopy", "beforecut", "beforepaste"])),
            Category(name: "Control", items: listeners(["resize", "scroll", "scrollend", "scrollsnapchange", "scrollsnapchanging",
                                                        "zoom", "focus", "blur", "select", "change", "submit", "reset"])),
            Category(name: "Device", items: listeners(["deviceorientation", "devicemotion"])),
            Category(name: "DOM mutation", items: listeners(["DOMActivate", "DOMFocusIn", "DOMFocusOut", "DOMAttrModified",
                                                             "DOMCharacterDataModified", "DOMNodeInserted",
                                                             "DOMNodeInsertedIntoDocument", "DOMNodeRemoved",
                                                             "DOMNodeRemovedFromDocument", "DOMSubtreeModified",
                                                             "DOMContentLoaded"])),
            Category(name: "Drag / drop", items: listeners(["drag", "dragstart", "dragend", "dragenter", "dragover",
                                                            "dragleave", "drop"])),
            Category(name: "Geolocation", items: missing(["getCurrentPosition", "watchPosition"])),
            Category(name: "Keyboard", items: listeners(["keydown", "keyup", "keypress", "input"])),
            Category(name: "Load", items: listeners(["load", "beforeunload", "unload", "abort", "error", "hashchange",
                                                     "popstate", "navigate", "navigatesuccess", "navigateerror",
                                                     "currentchange", "navigateto", "navigatefrom", "finish", "dispose"])),
            Category(name: "Media", items: listeners(["play", "pause", "playing", "canplay", "canplaythrough", "seeking",
                                                      "seeked", "timeupdate", "ended", "ratechange", "durationchange",
                                                      "volumechange", "loadstart", "progress", "suspend", "abort", "error",
                                                      "emptied", "stalled", "loadedmetadata", "loadeddata", "waiting"])),
            Category(name: "Mouse", items: listeners(["auxclick", "click", "dblclick", "mousedown", "mouseup", "mouseover",
                                                      "mousemove", "mouseout", "mouseenter", "mouseleave", "mousewheel",
                                                      "wheel", "contextmenu"])),
            Category(name: "Notification", items: missing(["requestPermission"])),
            Category(name: "Parse", items: missing(["Set innerHTML", "document.write"])),
            Category(name: "Picture-in-picture", items: listeners(["enterpictureinpicture", "leavepictureinpicture", "resize", "enter"])),
            Category(name: "Pointer", items: listeners(["pointerover", "pointerout", "pointerenter", "pointerleave",
                                                        "pointerdown", "pointerup", "pointermove", "pointercancel",
                                                        "gotpointercapture", "lostpointercapture", "pointerrawupdate"])),
            Category(name: "Script", items: missing(["Script First Statement", "Script Blocked by Content Security Policy"])),
            Category(name: "Timer", items: missing(["setTimeout", "clearTimeout"])
                + [EventBreakpoint(type: "timeout", eventName: nil, title: "setTimeout fired")]
                + missing(["setInterval", "clearInterval"])
                + [EventBreakpoint(type: "interval", eventName: nil, title: "setInterval fired")]),
            Category(name: "Touch", items: listeners(["touchstart", "touchmove", "touchend", "touchcancel"])),
            Category(name: "WebAudio", items: missing(["Create AudioContext", "Close AudioContext", "Resume AudioContext",
                                                       "Suspend AudioContext"])),
            Category(name: "Window", items: missing(["window.close"])),
            Category(name: "Worker", items: listeners(["message", "messageerror"])),
            Category(name: "XHR", items: listeners(["readystatechange", "load", "loadstart", "loadend", "abort", "error",
                                                    "progress", "timeout"])),
        ]

        /// Why some of Chrome's rows can't be checked.
        static let unavailable = "Greyed-out items are Chrome instrumentation breakpoints. WebKit’s DOMDebugger can break on event listeners, timers firing and animation frames only."
        /// Chrome's CSP violation breakpoints pane (Trusted Type violations).
        static let cspUnavailable = "WebKit can’t pause on Trusted Type sink or policy violations: its DOMDebugger domain has no CSP violation breakpoints."
    }
}
