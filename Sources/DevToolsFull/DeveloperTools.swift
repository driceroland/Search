import AppKit
import Combine
import WebKit

/// The built-in frontend already negotiates WebKit's versioned protocol and
/// its page/frame targets. Connect it locally without showing a second UI
/// (DeveloperInspectorLink, the one file that touches it). All bridge code
/// runs in WebKit's inspector view, never in a site's world.
@MainActor
final class DeveloperToolsSession: ObservableObject {
    private(set) weak var web: WKWebView?
    private var inspector: DeveloperInspectorLink?
    private weak var frontend: WKWebView?
    private var pump: Task<Void, Never>?
    /// Drains in a row that found no events; the pump waits longer the
    /// more there are (pumpInterval), and any command resets it.
    private var idleDrains = 0
    private var operations: Task<Void, Never>?
    /// The selected element's styles, attributes and $0, being read; a
    /// newer selection cancels it rather than queueing behind it.
    private var selection: Task<Void, Never>?
    private var panelRefresh: Task<Void, Never>?
    private var highlight: Task<Void, Never>?
    /// What DOM.highlightNode / highlightSelector / hideHighlight last
    /// drew on the page, so the same hover is not sent twice.
    private var shownHighlight: ShownHighlight = .unknown
    /// DOM.highlightNode / highlightSelector / hideHighlight commands sent,
    /// from anywhere; each makes shownHighlight unknown until its sender
    /// (showHighlight) says what it drew.
    private var highlightSends = 0
    private var pickerMonitor: Any?
    private var swallowPickerMouseUp = false
    private(set) var highlightedPick: Int?
    /// The picker's hover: the point waiting for the hit test in flight,
    /// and whether one is in flight (latest wins, nothing queues).
    private var pendingHover: NSPoint??
    private var hoverInFlight = false
    /// A hover is being answered, or waits to be (for tests).
    var hoverBusy: Bool { hoverInFlight || pendingHover != nil }
    /// The page element the picker last lit, as a JS object id of the
    /// page; equal ids mean the same element.
    private var litPick: String?
    /// Nodes the page changed while Elements was hidden (drain), read when it shows.
    private var hiddenNodeChanges = Set<Int>()
    private var disconnectTask: Task<Void, Never>?
    /// Disconnected (or disconnecting): nothing new starts for it.
    var isClosed: Bool { disconnectTask != nil }
    private(set) var domRevision = 0
    private(set) var domTargetID: String?
    private(set) var runtimeTargetID: String?
    private var pausedTargetID: String?
    /// The Network panel's blocking, HAR, search and WebSocket tools.
    private(set) lazy var networkTools = DeveloperNetworkTools(session: self)
    /// The Coverage drawer tool's recording.
    private(set) lazy var coverage = DeveloperCoverage(session: self)
    private(set) lazy var memory = DeveloperMemory(session: self)
    /// The source maps of the page's scripts and stylesheets.
    private(set) lazy var sourceMaps = DeveloperSourceMaps(session: self)
    /// The Sources panel's debugger sidebar: scopes, watches, breakpoints.
    let debugger = DeveloperDebugger()
    /// Elements-panel state beyond the tree: hidden nodes, layout badges, fonts.
    let elements = DeveloperElementsState()

    @Published private(set) var panel: DeveloperPanel = .elements
    let extensionPanels = DeveloperExtensionPanelState()
    @Published private(set) var ready = false
    @Published private(set) var connectionFailed = false
    @Published var message: String?
    @Published private(set) var picking = false
    @Published var nodes: [Int: DOMNode] = [:]
    @Published private(set) var root: Int?
    @Published var expanded = Set<Int>()
    @Published private(set) var selectedNode: Int?
    @Published private(set) var styles: [Detail] = []
    @Published private(set) var matchedStyles: [StyleRule] = []
    /// The selected element's and its parent's layout (display, position…),
    /// read with its computed style, for Styles' inactive-declaration hints.
    @Published private(set) var layoutContext: DeveloperInactiveCSS.Context?
    @Published private(set) var listeners: [EventListener] = []
    /// Whether the Event Listeners tab is in front, so a new selection loads them.
    var listenersShown = false
    @Published var listenerAncestors = true
    @Published var listenerFramework = false
    @Published private(set) var forcedStates: [Int: Set<PseudoState>] = [:]
    @Published private(set) var console: [ConsoleLine] = []
    @Published private(set) var requests: [Request] = []
    @Published private(set) var resources: [Resource] = []
    @Published private(set) var source: String?
    @Published private(set) var sourceResource: Resource?
    /// A line Sources is asked to show: a Console link, a Network
    /// initiator, a paused frame. The editor scrolls to it once.
    @Published private(set) var sourceReveal: SourceReveal?
    private var revealSerial = 0
    @Published private(set) var paused = false
    @Published private(set) var callStack: [String] = []
    @Published private(set) var breakpoints = Set<Int>()
    /// Breakpoints set partway along a line, from a pretty-printed view.
    @Published private(set) var columnBreakpoints = Set<SourceBreakpoint>()
    /// Scripts extensions put in the page (Sources › Content scripts).
    @Published private(set) var contentScripts: [Resource] = []
    /// The page's dedicated workers (DeveloperWorkers.swift).
    @Published private(set) var workers: [DeveloperWorker] = []
    /// Counts changes to the page's Local and Session storage while
    /// Application shows, so its tables update as Chrome's do.
    @Published private(set) var domStorageRevision = 0
    /// Console results waiting for their place among the events, by the
    /// token their evaluation marked the bridge's queue with.
    var awaitingConsoleResults: [String: ConsoleLine] = [:]
    /// The workers' scripts, under each worker in Sources › Page; type
    /// `DeveloperWorker.scriptType`, frame naming target and script id.
    @Published private(set) var workerScripts: [Resource] = []
    private var workerRead: Task<Void, Never>?
    private var workerReadAgain = false
    /// The page's frames, top first, for grouping Sources › Page by frame.
    @Published private(set) var resourceFrames: [ResourceFrame] = []
    @Published private(set) var timeline: [Timing] = []
    @Published private(set) var timelineAnnotations: [DeveloperPerformanceAnnotation] = []
    @Published private(set) var lineProfile = DeveloperLineProfile()
    private(set) var timelineScripts: [DeveloperPerformanceScript]?
    private var timelineDocument: String?
    private var timelineAddress: URL?
    var timelineIsCurrentDocument: Bool {
        timelineAddress != nil && timelineAddress == address && timelineDocument == navigationID
    }
    @Published private(set) var recordingTimeline = false
    private var collectingScriptSamples = false
    private(set) var scriptProfilerStarted = false
    private var capturingTracks = false
    private var trackStart: Double?
    private var trackNetwork = DeveloperPerformanceNetworkRecording()
    /// What the page's metrics script answered as the recording stopped:
    /// its timings and shifts for the Timings and Layout shifts tracks.
    private var trackPage: [String: Any]?
    /// When trackPage was answered, to put the screenshots' times on the page's clock.
    private var trackPageDate: Date?
    /// Performance's screenshots, a frame of the view whenever it changes.
    private var trackShots: DeveloperFilmstripRecorder?
    private(set) var recordingTimelineMemory = false
    @Published private(set) var heapTotal: Double?
    private var heapPreview = false
    @Published private(set) var throttle: NetworkCondition = .unrestricted
    @Published private(set) var requestInterception = false
    @Published private(set) var cacheDisabled = false
    /// Network conditions' user agent, in place of the browser's own; nil
    /// for the browser default. Applies to what the tab loads next.
    @Published private(set) var userAgentOverride: String?
    /// The tab's own user agent before the override, to put back.
    private var agentBeforeOverride: String??

    func setUserAgentOverride(_ agent: String?) {
        let agent = agent.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        userAgentOverride = agent
        guard let web else { return }
        if let agent {
            if agentBeforeOverride == nil { agentBeforeOverride = .some(web.customUserAgent) }
            if web.customUserAgent != agent { web.customUserAgent = agent }
        } else if let before = agentBeforeOverride {
            web.customUserAgent = before
            agentBeforeOverride = nil
        }
    }
    @Published var recordNetwork = true
    @Published var preserveNetworkLog = false
    @Published var preserveConsoleLog = false
    /// Console object trees, groups, filters and prompt history.
    let consoleStore = DeveloperConsoleStore()
    /// More tools › Protocol monitor: commands sent and events drained.
    /// More tools › AI assistance: the chat with the on-device model.

    private var requestIndex: [String: Int] = [:]
    private var requestNumber = 0
    private var pendingPick: NSPoint?
    private var pickWhenReady = false
    private var commandNumber = 0
    private var navigationID: String?
    private var remainingCapabilityChecks = 0

    var host: String { web?.url?.host() ?? web?.url?.scheme ?? "Web page" }
    var address: URL? { web?.url }
    var nativeInspectorVisible: Bool { inspector?.visible ?? false }

    init(web: WKWebView, after closing: Task<Void, Never>?) {
        self.web = web
        consoleStore.keepsHistory = !DevHost.isPrivate(web)
        debugger.session = self
        pump = Task { [weak self] in
            do {
                await closing?.value
                try Task.checkCancellation()
                try await self?.connect()
                // Drop the strong reference between samples so the task
                // cannot outlive the tab or the dock that owns the session.
                var failures = 0
                while !Task.isCancelled {
                    // Short slices, so a command sent mid-wait (the user
                    // doing something) cuts a long idle wait short.
                    var waited = 0
                    repeat {
                        try await Task.sleep(for: .milliseconds(Self.pumpSlice))
                        waited += Self.pumpSlice
                    } while waited < (self.map { Self.pumpInterval(afterIdleDrains: $0.idleDrains) } ?? 0)
                    guard let self else { return }
                    guard self.web != nil else {
                        _ = self.disconnect()
                        return
                    }
                    // One bad batch of events (a page's odd console message,
                    // say) is reported and skipped, not the end of the
                    // session; only an inspector that keeps failing is.
                    do {
                        let busy = try await self.drain()
                        self.idleDrains = busy ? 0 : self.idleDrains + 1
                        failures = 0
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failures += 1
                        self.message = error.localizedDescription
                        if failures >= 10 { throw error }
                    }
                }
            } catch is CancellationError {
            } catch {
                if let self {
                    self.message = error.localizedDescription
                    self.connectionFailed = true
                    _ = self.disconnect()
                }
            }
        }
    }

    private func connect() async throws {
        guard let web, let inspector = DeveloperInspectorLink(web) else { throw Error.notOnThisMac }
        self.inspector = inspector
        inspector.connect()

        var capabilities: [String: Any]?
        for _ in 0..<40 {
            try Task.checkCancellation()
            if let frontend = inspector.frontend(besides: web) {
                self.frontend = frontend
                capabilities = await installScripts(in: frontend) {
                    try await self.bridge("return searchInspector.capabilities();")
                }
                if capabilities != nil { break }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let capabilities else { throw Error.unavailable }
        _ = try? await frontend?.evaluateJavaScript(DeveloperNetworkBridgeScript.source)
        requestInterception = capabilities["requestInterception"] as? Bool == true
        domTargetID = capabilities["domTargetId"] as? String
        runtimeTargetID = capabilities["runtimeTargetId"] as? String
        try await updateEventDomains()
        // Elements' DOM mirror listens from the start (DeveloperElementsBridgeScript).
        _ = try? await elementsBridge("return searchElements.setUserAgentShadowDOM(on);", [
            "on": DeveloperElementsSettings.showUserAgentShadowDOM,
        ])
        ready = true
        debugger.connected()
        // Workers the page started before DevTools connected.
        readWorkers()
        refresh()
        if let point = pendingPick {
            pendingPick = nil
            inspect(at: point)
        } else if pickWhenReady {
            pickWhenReady = false
            togglePicker()
        }
    }


    /// Puts Search's bridge and Console scripts in the frontend; the
    /// capabilities it then answers with, once it says it is ready.
    private func installScripts(in frontend: WKWebView,
                                capabilities: () async throws -> Any?) async -> [String: Any]? {
        let status = try? await frontend.evaluateJavaScript(DeveloperToolsBridgeScript.source)
        _ = try? await frontend.evaluateJavaScript(DeveloperConsoleScript.source)
        guard status as? Bool == true,
              let state = try? await capabilities() as? [String: Any],
              state["ready"] as? Bool == true else { return nil }
        return state
    }





    func disconnect() -> Task<Void, Never> {
        if let disconnectTask { return disconnectTask }
        extensionPanels.stop()
        if userAgentOverride != nil { setUserAgentOverride(nil) }
        DeveloperIssuesModel.closed(self)
        DeveloperLiveMetricsModel.closed(self)
        DeveloperSessionModels.closed(self)
        stopPicking(clearHighlight: false)
        pump?.cancel()
        operations?.cancel()
        trackShots?.stop()
        trackShots = nil
        selection?.cancel()
        panelRefresh?.cancel()
        highlight?.cancel()
        ready = false
        let task = Task {
            await withCheckedContinuation { done in
                var closed = false
                let finish = {
                    guard !closed else { return }
                    closed = true
                    self.inspector?.close()
                    self.inspector = nil
                    self.frontend = nil
                    self.failPendingFrontendCalls()
                    done.resume()
                }
                let cleanup = Task {
                    if paused { _ = try? await command("Debugger.resume", targetID: pausedTargetID) }
                    // Workers paused beside it go on too.
                    for thread in debugger.pausedThreads where !thread.isEmpty && thread != pausedTargetID {
                        _ = try? await command("Debugger.resume", targetID: thread)
                    }
                    await coverage.detach()
                    if !forcedStates.isEmpty { _ = try? await command("CSS.disable", targetID: domTargetID) }
                    if throttle != .unrestricted {
                        _ = try? await bridge("return await searchInspector.networkConditions();")
                    }
                    finish()
                }
                Task {
                    // A debugger paused in page JavaScript may not answer.
                    // WebKit releases its overrides when the inspector closes.
                    try? await Task.sleep(for: .milliseconds(500))
                    cleanup.cancel()
                    finish()
                }
            }
        }
        disconnectTask = task
        return task
    }

    func bridge(_ source: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        do {
            return try await callFrontend(source, arguments)
        } catch Error.script(let message) where message.contains("Can't find variable: search") {
            // WebKit reloads its hidden frontend now and then, most often
            // when DevTools is reopened on the same tab right after closing:
            // the page Search set up is replaced by a fresh one without
            // searchInspector. Set it up again and try once more.
            if reinstalling == nil {
                reinstalling = Task { [weak self] in
                    defer { self?.reinstalling = nil }
                    try await self?.reinstallBridge()
                }
            }
            try await reinstalling?.value
            return try await callFrontend(source, arguments)
        }
    }

    private func callFrontend(_ source: String, _ arguments: [String: Any]) async throws -> Any? {
        guard let frontend, DeveloperInspectorLink.isInspectorPage(frontend.url) else { throw Error.unavailable }
        // A call the inspector closed under may never be answered; the
        // disconnect fails what is still waiting (failPendingFrontendCalls),
        // so nothing awaiting it keeps the closed session alive.
        let id = UUID()
        let result: Any? = try await withCheckedThrowingContinuation { continuation in
            frontendCalls[id] = continuation
            Task { @MainActor [weak self] in
                let outcome: Result<Any?, Swift.Error>
                do {
                    outcome = .success(try await frontend.callAsyncJavaScript(source, arguments: arguments, in: nil, contentWorld: .page))
                } catch let error as NSError where error.userInfo["WKJavaScriptExceptionMessage"] != nil {
                    // WebKit's own wording is "A JavaScript exception occurred";
                    // the exception's message says which.
                    outcome = .failure(Error.script(error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription))
                } catch {
                    outcome = .failure(error)
                }
                self?.frontendCalls.removeValue(forKey: id)?.resume(with: outcome)
            }
        }
        try Task.checkCancellation()
        return result
    }

    /// Frontend calls waiting on their answer (callFrontend).
    private var frontendCalls: [UUID: CheckedContinuation<Any?, Swift.Error>] = [:]

    private func failPendingFrontendCalls() {
        let waiting = frontendCalls.values
        frontendCalls = [:]
        for continuation in waiting { continuation.resume(throwing: Error.unavailable) }
    }

    /// One reinstall shared by every call that found the frontend bare.
    private var reinstalling: Task<Void, Swift.Error>?

    /// The frontend's scripts and event domains, put back after it reloaded.
    private func reinstallBridge() async throws {
        guard let inspector else { throw Error.unavailable }
        for _ in 0..<40 {
            try Task.checkCancellation()
            if let current = inspector.frontend(besides: web) {
                frontend = current
                if let state = await installScripts(in: current, capabilities: {
                    try await self.callFrontend("return searchInspector.capabilities();", [:])
                }) {
                    _ = try? await current.evaluateJavaScript(DeveloperNetworkBridgeScript.source)
                    _ = try? await callFrontend("return await searchNetwork.setBlocking(options);",
                                                ["options": networkTools.blockingOptions])
                    domTargetID = state["domTargetId"] as? String
                    runtimeTargetID = state["runtimeTargetId"] as? String
                    _ = try await callFrontend("searchInspector.setDomains(domains);", [
                        "domains": eventDomains,
                    ])
                    refresh()
                    // The fresh frontend has none of the Local Overrides (content or headers).
                    DeveloperLocalOverrides.shared.attach(self)
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Error.unavailable
    }

    /// Runs extra code in WebKit's hidden inspector frontend, beside `searchInspector`.
    func evaluateInFrontend(_ source: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await bridge(source, arguments)
    }

    func command(_ method: String, _ params: [String: Any] = [:], targetID: String? = nil) async throws -> [String: Any] {
        // The user is doing something: drain at the quick pace again.
        idleDrains = 0
        if method == "DOM.highlightNode" || method == "DOM.highlightSelector" || method == "DOM.hideHighlight" {
            highlightSends += 1
            shownHighlight = .unknown
        }
        let arguments: [String: Any] = ["method": method, "params": params, "target": targetID as Any? ?? NSNull()]
        return try await bridge("return await searchInspector.command(method, params, target);", arguments) as? [String: Any] ?? [:]
    }

    func select(_ panel: DeveloperPanel) {
        // As in Chrome DevTools: drawer tools (Rendering, Sensors) and panels
        // moved to the drawer open there, under the panel already shown.
        if DeveloperToolsShell.shared.openInDrawer(panel) { return }
        extensionPanels.select(nil)
        guard self.panel != panel else { return }
        idleDrains = 0
        if self.panel == .elements { stopPicking() }
        self.panel = panel
        if panel == .network { remainingCapabilityChecks = 8 }
        if panel == .elements, !hiddenNodeChanges.isEmpty {
            let changed = hiddenNodeChanges.filter { nodes[$0] != nil }
            hiddenNodeChanges = []
            syncNodes(changed)
            syncFlags(changed)
        }
        message = nil
        refresh()
    }

    func refresh() {
        guard ready else { return }
        panelRefresh?.cancel()
        panelRefresh = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.updateEventDomains()
                switch self.panel {
                case .elements: try await self.readDocument()
                case .sources: try await self.readResources()
                default: break
                }
            } catch is CancellationError {
            } catch { self.message = error.localizedDescription }
        }
    }

    func updateEventDomains() async throws {
        // Network is recorded as long as the dock is open, independent of its selected tab.
        // The bridge limits every message and drops sensitive request fields.
        let domains = eventDomains
        _ = try await bridge("searchInspector.setDomains(domains);", [
            "domains": domains,
        ])
        // WebKit sends storage changes only once the domain is enabled.
        if domains.contains("DOMStorage") { _ = try? await command("DOMStorage.enable") }
    }

    /// Heap's and Memory's events come only while something reads them: an
    /// allocation recording (Memory panel) or a Performance recording with
    /// Memory checked. Otherwise their garbage collections and heap readings
    /// would wait in the bridge's queue all session. (Performance monitor
    /// reads the heap through its own frontend hook.)
    private var eventDomains: [String] {
        var domains = ["DOM", "Page", "Target", "Network", "Console", "Debugger", "Timeline", "ScriptProfiler"]
        if recordingTimelineMemory || heapPreview { domains.append("Memory") }
        // Performance's CPU track, while a recording is captured.
        if capturingTracks { domains.append("CPUProfiler") }
        if memory.tracking { domains.append("Heap") }
        if panel == .storage { domains.append("DOMStorage") }
        return domains
    }

    func run(inCurrentDocument: Bool = false, _ action: @escaping @MainActor (DeveloperToolsSession) async throws -> Void) {
        guard ready else { return }
        let previous = operations
        let revision = domRevision
        let address = web?.url
        operations = Task { [weak self] in
            await previous?.value
            guard let self, self.ready, !Task.isCancelled else { return }
            if inCurrentDocument && (self.domRevision != revision || self.web?.url != address) {
                self.message = "The page changed before the command could run."
                return
            }
            self.message = nil
            do { try await action(self) }
            catch is CancellationError {}
            catch { if self.ready { self.message = error.localizedDescription } }
        }
    }

    /// Whether the bridge had any events.
    @discardableResult
    func drain() async throws -> Bool {
        guard ready else { return false }
        if let inspector, inspector.visible { inspector.hide() }
        // The main JavaScript target can be ready before the page's network
        // target. Check again briefly when entering the Network panel.
        if panel == .network, !requestInterception, remainingCapabilityChecks > 0 {
            remainingCapabilityChecks -= 1
            let capabilities = try await bridge("return searchInspector.capabilities();") as? [String: Any]
            requestInterception = capabilities?["requestInterception"] as? Bool == true
        }
        guard let events = try await bridge("return searchInspector.drain();") as? [[String: Any]] else { return false }
        var documentChanged = false
        var eventsDropped = false
        var navigated = false
        var targetChanged = false
        var resourcesChanged = false
        var network = requests
        var logs = console
        var record = timeline
        var dom = nodes
        var editedTree = false
        var changedNodes = Set<Int>()
        var workersChanged = false
        var workerIDs = Set(workers.map(\.id))
        var inspectedObject: String?
        var domStorageChanged = false
        for event in events {
            guard let method = event["method"] as? String, let params = event["params"] as? [String: Any] else { continue }
            let targetID = event["targetId"] as? String
            if method.hasPrefix("DOM."), let targetID, let domTargetID, targetID != domTargetID { continue }
            debugger.handle(method, params: params, targetID: targetID)
            coverage.handle(method, params: params, targetID: targetID)
            sourceMaps.handle(method, params: params, targetID: targetID)
            if Self.resourceEvents.contains(method) { resourcesChanged = true }
            switch method {
            case "Search.eventsDropped":
                // More events came between two drains than the bridge
                // keeps; the ones after were lost. The DOM mirror is read
                // again below, as for a document sent anew.
                eventsDropped = true
                documentChanged = true
            case "DOMStorage.domStorageItemAdded", "DOMStorage.domStorageItemRemoved",
                 "DOMStorage.domStorageItemUpdated", "DOMStorage.domStorageItemsCleared":
                domStorageChanged = true
            case "Search.inspectNode":
                // The Console's inspect(node): selected in Elements below.
                if let object = params["objectId"] as? String { inspectedObject = object }
            case "Target.didCommitProvisionalTarget":
                targetChanged = true
                memory.targetChanged()
                workersChanged = true
            case "Target.workersChanged", "Target.targetCreated", "Target.targetDestroyed":
                // The bridge's note that a worker started or ended (and
                // WebKit's own target events): the list is read below.
                if method == "Target.workersChanged", let targetID { workerIDs.insert(targetID) }
                workersChanged = true
            case "Heap.trackingStart", "Heap.trackingComplete", "Heap.garbageCollected":
                memory.handle(method, params: params, targetID: targetID)
            case "Page.frameNavigated":
                guard let frame = params["frame"] as? [String: Any],
                      (frame["parentId"] as? String)?.isEmpty != false else { continue }
                let id = frame["loaderId"] as? String
                if navigationID != id {
                    navigationID = id
                    memory.invalidateObjectIDs()
                    documentChanged = true
                    navigated = true
                    if !preserveConsoleLog { logs.removeAll(); consoleStore.reset() }
                    else if let url = frame["url"] as? String { logs.append(ConsoleLine(level: "info", text: "Navigated to " + url, details: ConsoleMessageDetails(type: "navigation"))) }
                    remainingCapabilityChecks = 8
                    workersChanged = true
                    DeveloperIssuesModel.navigated(self)
                    source = nil
                    sourceResource = nil
                    breakpoints = []
                    columnBreakpoints = []
                    if !preserveNetworkLog {
                        // The new document request normally arrives before the commit.
                        let current = network.filter { $0.loader == id }
                        network = current
                        requestIndex = Dictionary(uniqueKeysWithValues: current.enumerated().map { ($1.id, $0) })
                    }
                }
            case "DOM.documentUpdated":
                documentChanged = true
            case "DOM.setChildNodes", "DOM.childNodeCountUpdated", "DOM.childNodeInserted",
                 "DOM.shadowRootPushed", "DOM.pseudoElementAdded", "DOM.shadowRootPopped",
                 "DOM.pseudoElementRemoved", "DOM.childNodeRemoved",
                 "DOM.attributeModified", "DOM.attributeRemoved", "DOM.characterDataModified":
                Self.applyTreeEvent(method, params, to: &dom, changed: &changedNodes, edited: &editedTree)
            case "Console.messageAdded", "Search.evaluated", "Console.messageRepeatCountUpdated",
                 "Console.messagesCleared":
                applyConsoleEvent(method, params, targetID: targetID, to: &logs)
            case "Debugger.paused":
                paused = true
                pausedTargetID = targetID
                callStack = (params["callFrames"] as? [[String: Any]] ?? []).prefix(50).map {
                    let name = $0["functionName"] as? String ?? ""
                    return name.isEmpty ? "(anonymous)" : name
                }
            case "Debugger.scriptParsed":
                // A worker's script: the worker's list is read again, with
                // its scripts, from WebKit's frontend.
                if let targetID, workerIDs.contains(targetID) {
                    workersChanged = true
                    continue
                }
                // Content scripts are not in the resource tree; their source
                // comes from the debugger by script id.
                guard params["isContentScript"] as? Bool == true, let id = params["scriptId"] as? String,
                      let url = params["url"] as? String ?? params["sourceURL"] as? String, !url.isEmpty,
                      !contentScripts.contains(where: { $0.url == url }) else { continue }
                contentScripts.append(Resource(frame: id, url: url, type: "ContentScript"))
            case "Debugger.globalObjectCleared":
                if let targetID, workerIDs.contains(targetID) { continue }
                contentScripts = []
            case "Debugger.resumed":
                if let targetID, let pausedTargetID, targetID != pausedTargetID { continue }
                paused = false
                pausedTargetID = nil
                callStack = []
                // Another thread still paused (a worker, or the page while
                // a worker ran on): the debugger shows it next.
                if let next = debugger.pause {
                    paused = true
                    pausedTargetID = next.targetID
                    callStack = next.frames.map(\.functionName)
                }
            case "Timeline.eventRecorded", "Timeline.recordingStarted", "Timeline.recordingStopped",
                 "Memory.trackingUpdate", "CPUProfiler.trackingUpdate", "ScriptProfiler.trackingComplete":
                applyTimelineEvent(method, params, to: &record)
            default:
                if method.hasPrefix("Network.") {
                    // Only once the recording has started: events queued
                    // before Timeline.recordingStarted came before it.
                    if capturingTracks, let start = trackStart {
                        trackNetwork.capture(method, params: params, targetID: targetID, since: start)
                    }
                    if recordNetwork {
                        updateRequest(method, params: params, in: &network)
                        if method == "Network.loadingFinished" { logConsoleRequest(params, in: network, to: &logs) }
                    }
                }
            }
        }
        if logs != console { console = Array(logs.suffix(Self.consoleLimit)) }
        if record.count != timeline.count || record.last?.id != timeline.last?.id {
            timeline = Self.cappedTimeline(record)
        }
        if network != requests { requests = network }
        if workersChanged { readWorkers() }
        if documentChanged || targetChanged {
            let capabilities = try await bridge("return searchInspector.capabilities();") as? [String: Any]
            let target = capabilities?["domTargetId"] as? String
            documentChanged = documentChanged || target != domTargetID
            domTargetID = target
            runtimeTargetID = capabilities?["runtimeTargetId"] as? String
            remainingCapabilityChecks = 8
            requestInterception = capabilities?["requestInterception"] as? Bool == true
            if throttle != .unrestricted,
               capabilities?["networkConditionsTargetId"] as? String != capabilities?["networkTargetId"] as? String {
                _ = try await bridge("return await searchInspector.networkConditions();")
                throttle = .unrestricted
                message = "Network conditions reset when the page moved to a new process."
            }
        }
        // Sources lists the page's files as they load, as Chrome's
        // navigator fills in, not only those there when the page committed.
        if resourcesChanged, panel == .sources, !documentChanged { scheduleResourceRead() }
        if editedTree && !documentChanged {
            nodes = dom
            if let selectedNode { reveal(selectedNode) }
        }
        if let inspectedObject { inspect(object: inspectedObject) }
        if domStorageChanged { domStorageRevision &+= 1 }
        if !changedNodes.isEmpty && !documentChanged {
            if panel == .elements {
                syncNodes(changedNodes)
                syncFlags(changedNodes)
            } else {
                // Nothing shows a node's attributes or flags while Elements
                // is hidden: they are read once, when it shows again.
                hiddenNodeChanges.formUnion(changedNodes)
            }
        }
        if documentChanged { hiddenNodeChanges = [] }
        if documentChanged {
            if picking || pickerMonitor != nil { stopPicking() }
            // The same page's document sent again (DevTools reopened, the
            // inspector resynced): as Chrome does, the element that was
            // selected is found again by its place in the new tree.
            reselectPath = navigated ? nil : selectedNode.flatMap { selectorPath(of: $0) }
            domRevision += 1
            root = nil
            selectedNode = nil
            styles = []
            matchedStyles = []
            forcedStates = [:]
            elements.reset()
            shownHighlight = .unknown
            refresh()
        }
        if eventsDropped {
            message = "The page sent events faster than DevTools could read them; some were missed and Elements was read again."
        }
        return !events.isEmpty
    }

    // drain()'s cases by concern, each a function of its own so the
    // type checker never meets the whole switch at once.

    /// The DOM mirror's tree events, applied to `dom`.
    private static func applyTreeEvent(_ method: String, _ params: [String: Any], to dom: inout [Int: DOMNode],
                                       changed changedNodes: inout Set<Int>, edited editedTree: inout Bool) {
        switch method {
        case "DOM.setChildNodes":
            guard let parent = params["parentId"] as? Int, let children = params["nodes"] as? [[String: Any]],
                  dom[parent] != nil else { return }
            let childrenIDs = Self.addNodes(children, into: &dom, parent: parent)
            // ::before, the shadow root and the rest stay beside them.
            let extras = (dom[parent]?.children ?? []).filter { dom[$0]?.isExtraChild ?? false }
            let ordered = DOMNode.treeOrder(extras + childrenIDs, in: dom)
            dom[parent]?.children = ordered
            // Search's own overlays, left out, are left out of the count too.
            let hidden = children.filter(Self.isSearchOverlay).count
            if hidden > 0, let count = dom[parent]?.count { dom[parent]?.count = max(ordered.count, count - hidden) }
            changedNodes.formUnion(childrenIDs)
            editedTree = true
        case "DOM.childNodeCountUpdated":
            guard let id = params["nodeId"] as? Int, let count = params["childNodeCount"] as? Int,
                  let node = dom[id] else { return }
            let extra = DOMNode.extraCount(node.children, in: dom)
            dom[id]?.count = count + extra
            editedTree = true
        case "DOM.childNodeInserted":
            guard let parent = params["parentNodeId"] as? Int, var container = dom[parent],
                  let child = params["node"] as? [String: Any],
                  let id = Self.addNodes([child], into: &dom, parent: parent).first,
                  !container.children.contains(id) else { return }
            let previous = (params["previousNodeId"] as? Int).flatMap { container.children.firstIndex(of: $0) }
            container.children.insert(id, at: previous.map { $0 + 1 } ?? 0)
            container.children = DOMNode.treeOrder(container.children, in: dom)
            container.count = max(container.count, container.children.count)
            dom[parent] = container
            changedNodes.insert(id)
            editedTree = true
        case "DOM.shadowRootPushed", "DOM.pseudoElementAdded":
            // A shadow root attached, or a ::before that now has content.
            let parentKey = method == "DOM.shadowRootPushed" ? "hostId" : "parentId"
            let childKey = method == "DOM.shadowRootPushed" ? "root" : "pseudoElement"
            guard let parent = params[parentKey] as? Int, var container = dom[parent],
                  let child = params[childKey] as? [String: Any],
                  DeveloperElementsSettings.showUserAgentShadowDOM || child["shadowRootType"] as? String != "user-agent",
                  let id = Self.addNodes([child], into: &dom, parent: parent).first,
                  !container.children.contains(id) else { return }
            container.children = DOMNode.treeOrder(container.children + [id], in: dom)
            container.count += 1
            dom[parent] = container
            changedNodes.insert(id)
            editedTree = true
        case "DOM.shadowRootPopped", "DOM.pseudoElementRemoved":
            let parentKey = method == "DOM.shadowRootPopped" ? "hostId" : "parentId"
            let childKey = method == "DOM.shadowRootPopped" ? "rootId" : "pseudoElementId"
            guard let parent = params[parentKey] as? Int, var container = dom[parent],
                  let id = params[childKey] as? Int, container.children.contains(id) else { return }
            container.children.removeAll { $0 == id }
            container.count = max(container.children.count, container.count - 1)
            dom[parent] = container
            Self.removeNode(id, from: &dom)
            editedTree = true
        case "DOM.childNodeRemoved":
            guard let parent = params["parentNodeId"] as? Int, var container = dom[parent],
                  let id = params["nodeId"] as? Int, container.children.contains(id) else { return }
            container.children.removeAll { $0 == id }
            container.count = max(container.children.count, container.count - 1)
            dom[parent] = container
            Self.removeNode(id, from: &dom)
            editedTree = true
        case "DOM.attributeModified", "DOM.attributeRemoved", "DOM.characterDataModified":
            if let id = params["nodeId"] as? Int, dom[id] != nil { changedNodes.insert(id) }
        default: break
        }
    }

    /// Console messages, results and clears, applied to `logs`.
    private func applyConsoleEvent(_ method: String, _ params: [String: Any], targetID: String?,
                                   to logs: inout [ConsoleLine]) {
        switch method {
        case "Console.messageAdded":
            guard let item = params["message"] as? [String: Any] else { return }
            logs.append(ConsoleLine(level: Self.consoleLevel(item), text: item["text"] as? String ?? "",
                                    url: item["url"] as? String, line: item["line"] as? Int,
                                    repeatCount: max(1, item["repeatCount"] as? Int ?? 1),
                                    details: ConsoleMessageDetails(message: item, targetID: targetID)))
        case "Search.evaluated":
            if let token = params["token"] as? String, let line = awaitingConsoleResults.removeValue(forKey: token) {
                logs.append(line)
            }
        case "Console.messageRepeatCountUpdated":
            if let count = params["count"] as? Int, let last = logs.lastIndex(where: { $0.details?.source != nil }) {
                logs[last].repeatCount = max(1, count)
            }
        case "Console.messagesCleared":
            // console.clear() from the page, as Chrome shows it.
            if params["reason"] as? String == "console-api" {
                logs.removeAll()
                consoleStore.reset()
                logs.append(ConsoleLine(level: "log", text: "Console was cleared", details: ConsoleMessageDetails(type: "clear")))
            }
        default: break
        }
    }

    /// A Performance recording's timeline, heap, CPU and script
    /// profiler events, applied to `record`.
    private func applyTimelineEvent(_ method: String, _ params: [String: Any], to record: inout [Timing]) {
        switch method {
        case "Timeline.eventRecorded":
            if let raw = params["record"] as? [String: Any] {
                // Screenshots are large: a recording keeps its first few hundred.
                if raw["type"] as? String == "Screenshot" {
                    guard screenshotsRecorded < Self.screenshotLimit else { return }
                    screenshotsRecorded += 1
                }
                Self.addTimings(raw, to: &record)
            }
        case "Timeline.recordingStarted":
            if capturingTracks { trackStart = params["startTime"] as? Double }
        case "Timeline.recordingStopped":
            guard capturingTracks else { return }
            capturingTracks = false
            recordingTimelineMemory = false
            timelineDocument = navigationID
            timelineAddress = address
            trackShots?.stop()
            if let start = trackStart, let end = params["endTime"] as? Double, end >= start {
                record.append(Timing(type: "RecordingBounds", start: start, end: end))
                record += trackNetwork.timings(from: start, to: end)
                if let page = trackPage,
                   let sync = DeveloperPerformancePageTimings.merge(page, into: &record, bounds: start...end),
                   let shots = trackShots, let date = trackPageDate, let now = DeveloperMeasure.finite(page["now"]) {
                    record += DeveloperPerformancePageTimings.screenshots(shots.images, pageNow: now, pageDate: date,
                                                                          sync: sync, bounds: start...end)
                }
                record = Self.withinRecording(record, from: start)
            }
            trackStart = nil
            trackNetwork = .init()
            trackPage = nil
            trackPageDate = nil
            trackShots = nil
        case "Memory.trackingUpdate":
            guard let sample = params["event"] as? [String: Any],
                  let categories = sample["categories"] as? [[String: Any]],
                  let bytes = categories.first(where: { $0["type"] as? String == "javascript" })?["size"] as? NSNumber else { return }
            if heapPreview { heapTotal = bytes.doubleValue }
            guard capturingTracks, recordingTimelineMemory, let start = trackStart,
                  let time = sample["timestamp"] as? Double, time >= start else { return }
            record.append(Timing(type: "JSHeapSample", start: time, end: time, data: ["bytes": bytes.stringValue]))
        case "CPUProfiler.trackingUpdate":
            guard capturingTracks, let start = trackStart, let event = params["event"] as? [String: Any],
                  let sample = DeveloperPerformanceCPU.timing(event, since: start) else { return }
            record.append(sample)
        case "ScriptProfiler.trackingComplete":
            guard collectingScriptSamples else { return }
            collectingScriptSamples = false
            let traces = (params["samples"] as? [String: Any])?["stackTraces"] as? [[String: Any]] ?? []
            lineProfile = DeveloperLineProfile(traces, within: record)
            record += DeveloperScriptProfile.timings(traces, within: record)
        default: break
        }
    }

    /// Between drains, the pump sleeps in slices this long (ms).
    static let pumpSlice = 110
    /// The pump's wait before the next drain (ms): 220 while events come,
    /// stretching a slice per idle drain after four, up to about 1 s.
    static func pumpInterval(afterIdleDrains idle: Int) -> Int {
        guard idle > 4 else { return 2 * pumpSlice }
        return min(9 * pumpSlice, (2 + idle - 4) * pumpSlice)
    }

    // MARK: Elements

    /// The document, from the one DOM.getDocument WebKit's own frontend
    /// makes and the Elements mirror shares (searchElements.documentRoot).
    /// A page mid-navigation may have none yet; ask again shortly.
    private func readDocument() async throws {
        let revision = domRevision
        var raw: [String: Any]?
        for attempt in 0..<12 {
            raw = try await elementsBridge("return await searchElements.documentRoot(target);", [
                "target": domTargetID as Any? ?? NSNull(),
            ]) as? [String: Any]
            if raw != nil || domRevision != revision { break }
            try await Task.sleep(for: .milliseconds(attempt < 4 ? 100 : 250))
        }
        guard let raw, domRevision == revision else { return }
        var tree: [Int: DOMNode] = [:]
        guard let id = Self.addNodes([raw], into: &tree, parent: nil).first else { return }
        nodes = tree
        root = id
        expanded = [id]
        syncNodes(Set(tree.keys))
        syncFlags(Set(tree.keys))
        if let html = tree[id]?.children.first(where: { tree[$0]?.type == 1 && tree[$0]?.name == "html" }),
           let node = tree[html] {
            expand(node)
        }
        let path = reselectPath ?? "body"
        let reselecting = reselectPath != nil
        reselectPath = nil
        if selectedNode == nil {
            let found = try? await command("DOM.querySelector", ["nodeId": id, "selector": path], targetID: domTargetID)
            if domRevision == revision, selectedNode == nil, let node = found?["nodeId"] as? Int, node > 0 {
                selectNode(node)
                if !reselecting, let body = nodes[node], !expanded.contains(node) { expand(body) }
            }
        }
    }

    /// Found again after the document is sent anew (readDocument).
    private var reselectPath: String?

    /// A selector that finds the element `id` again by its place in the
    /// tree: `:root > *:nth-child(2) > *:nth-child(3)`. Nil for a node that
    /// isn't an element of the main document, or under a parent whose
    /// children aren't all known.
    func selectorPath(of id: Int) -> String? {
        var steps: [String] = []
        var current = id
        for _ in 0..<200 {
            guard let node = nodes[current], node.type == 1, node.pseudoType == nil else { return nil }
            guard let parentID = node.parent, let parent = nodes[parentID] else { return nil }
            if parent.type == 9 {
                return ([":root"] + steps.reversed()).joined(separator: " > ")
            }
            guard parent.type == 1, parent.shadowRootType == nil, parent.children.count >= parent.count else { return nil }
            let elements = parent.children.filter { nodes[$0].map { $0.type == 1 && $0.pseudoType == nil } == true }
            guard let index = elements.firstIndex(of: current) else { return nil }
            steps.append("*:nth-child(\(index + 1))")
            current = parentID
        }
        return nil
    }

    /// The most nodes the Elements mirror holds; the tree renders only the
    /// rows on screen, so this bounds memory, not drawing.
    static let mirrorLimit = 100_000

    /// The elements Search puts in the page for Rendering's overlays (the
    /// frame meter, layout shift flashes): Chrome draws these outside the
    /// page, so the Elements tree never shows them.
    nonisolated static func isSearchOverlay(_ node: [String: Any]) -> Bool {
        guard node["nodeType"] as? Int == 1, let name = node["nodeName"] as? String else { return false }
        return name.lowercased().hasPrefix("search-")
    }

    static func addNodes(_ raw: [[String: Any]], into tree: inout [Int: DOMNode], parent: Int?) -> [Int] {
        raw.prefix(800).compactMap { node in
            guard let id = node["nodeId"] as? Int, id > 0, tree[id] != nil || tree.count < Self.mirrorLimit,
                  !Self.isSearchOverlay(node) else { return nil }
            let existing = tree[id]
            // Some payloads (a projected event, a partial mirror entry) leave
            // out the name or value; keep what is known rather than blank it.
            let type = node["nodeType"] as? Int ?? existing?.type ?? 0
            var name = (node["nodeName"] as? String ?? "").lowercased()
            if name.isEmpty { name = existing?.name ?? DOMNode.name(forType: type) }
            let attributes = (node["attributes"] as? [String] ?? existing?.attributes ?? [])
                .prefix(60).map { String($0.prefix(300)) }
            let pseudoType = node["pseudoType"] as? String ?? existing?.pseudoType
            let shadowRootType = node["shadowRootType"] as? String ?? existing?.shadowRootType
            let flags = (node["layoutFlags"] as? [String]).map { Array($0.prefix(12)) } ?? existing?.flags ?? []
            // The node itself first, so its rows can be ranked by kind.
            if tree[id] == nil {
                tree[id] = DOMNode(id: id, parent: parent, type: type, name: name, text: "", attributes: [],
                                   children: [], count: 0, pseudoType: pseudoType, shadowRootType: shadowRootType)
            }
            let light = (node["children"] as? [[String: Any]]).map { addNodes($0, into: &tree, parent: id) }
            // What WebKit sends beside the children, as raw protocol nodes.
            let extras = Self.extraPayloads(of: node)
            let extraIDs = extras.map { addNodes($0, into: &tree, parent: id) } ?? []
            let children: [Int]
            if light == nil && extras == nil {
                children = existing?.children ?? []
            } else {
                // Rows of a kind the payload left out stay as they were.
                // Children the bridge already put in tree order are the
                // whole list.
                let complete = light?.contains { tree[$0]?.isExtraChild ?? false } ?? false
                let kept = (existing?.children ?? []).filter { child in
                    let extra = tree[child]?.isExtraChild ?? false
                    return extra ? extras == nil && !complete : light == nil
                }
                children = DOMNode.treeOrder((light ?? []) + extraIDs + kept, in: tree)
            }
            var value = node["nodeValue"] as? String ?? existing?.text ?? ""
            if value.isEmpty, let known = existing?.text { value = known }
            let extraCount = node["extraChildCount"] as? Int ?? DOMNode.extraCount(children, in: tree)
            let lightCount = children.filter { !(tree[$0]?.isExtraChild ?? false) }.count
            tree[id] = DOMNode(id: id, parent: parent, type: type,
                               name: name, text: String(value.prefix(300)),
                               attributes: attributes, children: children,
                               count: (node["childNodeCount"] as? Int ?? lightCount) + extraCount,
                               pseudoType: pseudoType, shadowRootType: shadowRootType, flags: flags)
            return id
        }
    }

    /// A protocol node's pseudo-elements, shadow roots (the browser's own
    /// only with Settings › Preferences › Elements › "Show user agent
    /// shadow DOM" on, as in Chrome),
    /// template content and frame document; nil when it sent none.
    static func extraPayloads(of node: [String: Any]) -> [[String: Any]]? {
        var output: [[String: Any]] = []
        var found = false
        if let pseudo = node["pseudoElements"] as? [[String: Any]] { output += pseudo; found = true }
        if let shadows = node["shadowRoots"] as? [[String: Any]] {
            let browsers = DeveloperElementsSettings.showUserAgentShadowDOM
            output += shadows.filter { browsers || $0["shadowRootType"] as? String != "user-agent" }
            found = true
        }
        for key in ["templateContent", "contentDocument"] {
            if let item = node[key] as? [String: Any] { output.append(item); found = true }
        }
        return found ? output : nil
    }

    private static func removeNode(_ id: Int, from tree: inout [Int: DOMNode]) {
        guard let node = tree.removeValue(forKey: id) else { return }
        for child in node.children { removeNode(child, from: &tree) }
    }

    #if DEBUG
    /// Tests: a tree without a page behind it (call `disconnect()` first so
    /// the inspector doesn't replace it).
    func loadTreeForTesting(_ tree: [Int: DOMNode], root: Int, expanded: Set<Int>) {
        nodes = tree
        self.root = root
        self.expanded = expanded
    }

    func selectForTesting(_ id: Int?) { selectedNode = id }
    #endif

    func expand(_ node: DOMNode) {
        if expanded.remove(node.id) != nil { return }
        expanded.insert(node.id)
        if node.children.count < min(node.count, 800) {
            let revision = domRevision
            run(inCurrentDocument: true) { session in
                let target = session.domTargetID
                // The Elements mirror: what the backend sent this connection,
                // with attributes and text, else the frontend's own model.
                let children = try await session.elementsBridge("return await searchElements.children(node, target);", [
                    "node": node.id, "target": target as Any? ?? NSNull(),
                ]) as? [[String: Any]]
                guard session.domRevision == revision, let current = session.nodes[node.id],
                      let children, children.count > current.children.count else { return }
                var tree = session.nodes
                let ids = Self.addNodes(children, into: &tree, parent: node.id)
                tree[node.id]?.children = ids
                session.nodes = tree
                session.syncNodes(Set(ids))
                session.syncFlags(Set(ids))
            }
        }
    }

    /// The tree's scroll and event badges, from WebKit's layout flags as
    /// the Elements mirror last heard them.
    func syncFlags(_ ids: Set<Int>) {
        guard ready, !ids.isEmpty else { return }
        let revision = domRevision
        let asked = Array(ids.prefix(4000))
        let target: Any = domTargetID as Any? ?? NSNull()
        Task { [weak self] in
            guard let self else { return }
            let raw = try? await self.elementsBridge("return searchElements.flags(ids, target);", [
                "ids": asked, "target": target,
            ]) as? [String: [String]]
            guard self.domRevision == revision, let raw else { return }
            var tree = self.nodes
            var changed = false
            for id in asked {
                let flags = raw[String(id)] ?? []
                guard let node = tree[id], node.flags != flags else { continue }
                tree[id]?.flags = flags
                changed = true
            }
            if changed { self.nodes = tree }
        }
    }

    /// Synthetic adopted-style rows have no DOM node of their own.
    func deselectNode() {
        selection?.cancel()
        selection = nil
        selectedNode = nil
        styles = []
        matchedStyles = []
        layoutContext = nil
        listeners = []
    }

    func selectNode(_ id: Int) {
        selectedNode = id
        consoleStore.noteInspected(id)
        styles = []
        matchedStyles = []
        layoutContext = nil
        listeners = []
        reveal(id)
        // A newer selection (an arrow key held down the tree) cancels
        // this one's reads instead of queueing a full style fetch behind
        // each row passed.
        selection?.cancel()
        selection = nil
        if let node = nodes[id], node.type != 1 { return }
        guard ready else { return }
        let revision = domRevision
        let address = web?.url
        selection = Task { [weak self] in
            guard let self, self.ready else { return }
            @MainActor func current() -> Bool {
                guard !Task.isCancelled, self.ready, self.selectedNode == id else { return false }
                return self.domRevision == revision
            }
            guard current() else { return }
            if self.web?.url != address {
                self.message = "The page changed before the command could run."
                return
            }
            self.message = nil
            let target = self.domTargetID
            let ancestors = self.ancestorLabels(of: id)
            do {
                // None of these depends on another: sent together.
                async let inspected = self.optionalCommand("DOM.setInspectedNode", ["nodeId": id], targetID: target)
                async let computed = self.command("CSS.getComputedStyleForNode", ["nodeId": id], targetID: target)
                // The parent's too, for the hints on declarations its
                // layout makes inactive (flex-grow outside a flex container).
                async let parentComputed = self.parentComputedStyle(of: id, targetID: target)
                async let matched = self.elementsBridge("return await searchElements.styles(node, target, ancestors);", [
                    "node": id, "target": target as Any? ?? NSNull(), "ancestors": ancestors,
                ])
                async let attributes = self.optionalCommand("DOM.getAttributes", ["nodeId": id], targetID: target)
                if self.nodes[id] == nil {
                    try? await self.addPath(to: id, target: target, revision: revision)
                    guard current() else { return }
                }
                _ = await inspected
                guard current() else { return }
                let values = await attributes
                guard current() else { return }
                if let values = values?["attributes"] as? [String] {
                    self.nodes[id]?.attributes = values.prefix(60).map { String($0.prefix(300)) }
                }
                let result = try await computed
                guard current() else { return }
                self.styles = (result["computedStyle"] as? [[String: String]] ?? []).compactMap {
                    guard let name = $0["name"], let value = $0["value"] else { return nil }
                    return Detail(name: name, value: value)
                }
                let parentValues = await parentComputed
                guard current() else { return }
                var ownValues: [String: String] = [:]
                for entry in self.styles { ownValues[entry.name] = entry.value }
                let nodeName = self.nodes[id]?.name ?? ""
                // An HTML document names its HTML elements in capitals; a
                // lowercase name is SVG's (or MathML's), sized while inline.
                self.layoutContext = DeveloperInactiveCSS.Context(
                    tag: nodeName, svgShape: nodeName != nodeName.uppercased(),
                    computed: ownValues, parent: parentValues)
                let rules = (try? await matched) as? [[String: Any]] ?? []
                guard current() else { return }
                self.matchedStyles = StyleRule.cascade(rules.enumerated().compactMap { StyleRule(raw: $1, id: $0) })
                if self.listenersShown { self.loadListeners() }
            } catch is CancellationError {
            } catch {
                if self.ready, self.selectedNode == id { self.message = error.localizedDescription }
            }
        }
    }

    /// The computed style of the element a node's layout comes from: its
    /// parent element, past a shadow root to the host. Empty at the
    /// document element, or when the read fails.
    private func parentComputedStyle(of id: Int, targetID: String?) async -> [String: String] {
        var current = nodes[id]?.parent
        var parent: Int?
        var steps = 0
        while let at = current, steps < 8, let node = nodes[at], node.type != 9 {
            if node.type == 1 { parent = at; break }
            current = node.parent
            steps += 1
        }
        guard let parent,
              let result = await optionalCommand("CSS.getComputedStyleForNode", ["nodeId": parent], targetID: targetID)
        else { return [:] }
        var values: [String: String] = [:]
        for entry in result["computedStyle"] as? [[String: String]] ?? [] {
            if let name = entry["name"], let value = entry["value"] { values[name] = value }
        }
        return values
    }

    /// A protocol command whose failure the caller can do without.
    private func optionalCommand(_ method: String, _ params: [String: Any], targetID: String?) async -> [String: Any]? {
        try? await command(method, params, targetID: targetID)
    }

    /// A rule's declarations written back, changed: a value edited, one
    /// switched off or on, one added (element.style's too) or taken out.
    func editRule(_ ruleID: Int, properties: [Detail]) {
        guard let selected = selectedNode, let rule = matchedStyles.first(where: { $0.id == ruleID }),
              let style = rule.style else { return }
        let text = properties.map(\.text).joined(separator: " ")
        if let index = matchedStyles.firstIndex(where: { $0.id == ruleID }) {
            matchedStyles[index].properties = properties
        }
        run(inCurrentDocument: true) { session in
            try await session.setStyleText(style, text)
            // A step ⌘Z in the Elements panel takes back, as in Chrome.
            _ = try? await session.command("DOM.markUndoableState", targetID: session.domTargetID)
            if session.selectedNode == selected { session.selectNode(selected) }
        }
    }

    /// One "name: value" typed into a rule, split as DevTools splits it.
    static func declarations(from typed: String) -> [Detail] {
        typed.split(separator: ";").compactMap { part in
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { return nil }
            var value = pair[1]
            var important = false
            if value.lowercased().hasSuffix("!important") {
                important = true
                value = String(value.dropLast("!important".count)).trimmingCharacters(in: .whitespaces)
            }
            return Detail(name: pair[0].lowercased(), value: value, important: important)
        }
    }

    func loadListeners() {
        listenersShown = true
        guard let selected = selectedNode, nodes[selected]?.type == 1 else { listeners = []; return }
        let ancestors = listenerAncestors
        let framework = listenerFramework
        run(inCurrentDocument: true) { session in
            let raw = try await session.bridge("return await searchInspector.eventListeners(node, target, ancestors, framework);", [
                "node": selected, "target": session.domTargetID as Any? ?? NSNull(), "ancestors": ancestors,
                "framework": framework,
            ]) as? [[String: Any]] ?? []
            guard session.selectedNode == selected, session.listenerAncestors == ancestors,
                  session.listenerFramework == framework else { return }
            session.listeners = raw.compactMap(EventListener.init)
        }
    }

    func setListener(_ id: Int, disabled: Bool) {
        guard id > 0 else { return }
        if let index = listeners.firstIndex(where: { $0.id == id }) { listeners[index].disabled = disabled }
        run(inCurrentDocument: true) { session in
            _ = try await session.command("DOM.setEventListenerDisabled", ["eventListenerId": id, "disabled": disabled],
                                          targetID: session.domTargetID)
        }
    }

    private func addPath(to id: Int, target: String?, revision: Int) async throws {
        // WebKit may already have sent the ancestors to its built-in
        // frontend before our local tree started collecting events.
        let path = try await bridge("return searchInspector.nodePath(node, target);", [
            "node": id, "target": target as Any? ?? NSNull(),
        ]) as? [[String: Any]]
        guard domRevision == revision, selectedNode == id, let path,
              path.first?["nodeId"] as? Int == root else { return }
        var tree = nodes
        var parent: Int?
        for node in path {
            guard let id = Self.addNodes([node], into: &tree, parent: parent).first else { break }
            if let parent, let siblings = tree[parent]?.children, !siblings.contains(id) {
                let ordered = DOMNode.treeOrder(siblings + [id], in: tree)
                tree[parent]?.children = ordered
            }
            parent = id
        }
        nodes = tree
        reveal(id)
    }

    /// The Console's inspect(node), as in Chrome: Elements comes forward
    /// with the node selected. The node is asked for once Elements has read
    /// the document, so its path is sent into the tree Elements now shows.
    private func inspect(object: String) {
        let switching = panel != .elements
        select(.elements)
        Task { [weak self] in
            guard let self else { return }
            if switching { await self.panelRefresh?.value }
            let reply = try? await self.command("DOM.requestNode", ["objectId": object], targetID: self.domTargetID)
            _ = try? await self.command("Runtime.releaseObject", ["objectId": object], targetID: self.runtimeTargetID)
            guard let id = (reply?["nodeId"] as? NSNumber)?.intValue, id > 0 else { return }
            for _ in 0..<40 where self.nodes[id] == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard self.nodes[id] != nil else { return }
            self.selectNode(id)
        }
    }

    private func reveal(_ id: Int) {
        var parent = nodes[id]?.parent
        for _ in 0..<100 {
            guard let id = parent else { break }
            expanded.insert(id)
            parent = nodes[id]?.parent
        }
    }

    /// A node hovered in the tree or the breadcrumbs, or moved to with
    /// the keys, drawn on the page as Chrome draws it; nil hides it.
    func highlightNode(_ id: Int?) {
        if let id { highlightNode(id, config: .chrome) } else { hideHighlight() }
    }

    /// A node drawn with a highlight of the caller's: one box of the box
    /// model alone, say, as Chrome's Layout and Styles box model hover.
    func highlightNode(_ id: Int, config: DeveloperHighlight) {
        showHighlight(.node(id, config)) { session, target in
            _ = try await session.command("DOM.highlightNode", [
                "nodeId": id, "highlightConfig": config.protocolValue,
            ], targetID: target)
            await session.showRulers(true, target: target)
        }
    }

    /// Every node a selector matches, highlighted as Chrome DevTools does
    /// when a rule's selector is hovered (DOM.highlightSelector); nil
    /// hides it.
    func highlightSelector(_ selector: String?, config: DeveloperHighlight = .chrome) {
        highlight?.cancel()
        guard ready, !picking else { return }
        guard let selector, !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hideHighlight()
            return
        }
        showHighlight(.selector(selector, config)) { session, target in
            _ = try await session.command("DOM.highlightSelector", [
                "selectorString": selector, "highlightConfig": config.protocolValue,
            ], targetID: target)
            await session.showRulers(true, target: target)
        }
    }

    func hideHighlight() {
        showHighlight(.hidden) { session, target in
            _ = try await session.command("DOM.hideHighlight", targetID: target)
            await session.showRulers(false, target: target)
        }
    }

    /// Whether WebKit's page rulers are on: Settings › Preferences ›
    /// Elements › "Show rulers on hover" has them while a highlight is.
    private var rulersShown = false

    func showRulers(_ on: Bool, target: String?) async {
        let wanted = on && DeveloperElementsSettings.showRulersOnHover
        guard wanted != rulersShown else { return }
        rulersShown = wanted
        // Not every WebKit has Page.setShowRulers; without it there are none.
        _ = try? await command("Page.setShowRulers", ["result": wanted], targetID: target)
    }

    /// Settings › Preferences › Elements changed what the tree shows: the
    /// browser's shadow roots (the document is read again with or without
    /// them) or comments (the rows are rebuilt).
    func elementsSettingsChanged() {
        let tree = nodes
        nodes = tree
        guard ready else { return }
        let on = DeveloperElementsSettings.showUserAgentShadowDOM
        run { session in
            _ = try? await session.elementsBridge("return searchElements.setUserAgentShadowDOM(on);", ["on": on])
            if session.panel == .elements {
                // The selection is found again in the tree read anew.
                if let selected = session.selectedNode, let path = session.selectorPath(of: selected) {
                    session.reselectPath = path
                    session.selectedNode = nil
                }
                try await session.readDocument()
            }
        }
    }

    /// One highlight change, sent after a short pause: moving across the
    /// tree's rows sends only where the pointer stops, a hide between two
    /// rows is cancelled by the next row's highlight, and the highlight
    /// already on the page is not sent again.
    private func showHighlight(_ wanted: ShownHighlight,
                               _ send: @escaping @MainActor (DeveloperToolsSession, String?) async throws -> Void) {
        highlight?.cancel()
        highlight = nil
        guard ready, !picking, wanted != shownHighlight else { return }
        let target = domTargetID
        highlight = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(55))
            guard let self, !Task.isCancelled, self.ready, !self.picking else { return }
            let sends = self.highlightSends
            try? await send(self, target)
            // Known only when no other highlight command (the Console's
            // hover, say) went out meanwhile and this one wasn't superseded.
            if !Task.isCancelled, self.highlightSends == sends + 1 { self.shownHighlight = wanted }
        }
    }

    func setAttribute(name: String, value: String) {
        guard !name.isEmpty, let selectedNode else { return }
        let revision = domRevision
        run(inCurrentDocument: true) { session in
            let target = session.domTargetID
            _ = try await session.command("DOM.setAttributeValue", ["nodeId": selectedNode, "name": name, "value": value], targetID: target)
            let reply = try await session.command("DOM.getAttributes", ["nodeId": selectedNode], targetID: target)
            guard session.domRevision == revision else { return }
            if let values = reply["attributes"] as? [String] {
                session.nodes[selectedNode]?.attributes = values.prefix(60).map { String($0.prefix(300)) }
            }
            if session.selectedNode == selectedNode { session.selectNode(selectedNode) }
        }
    }

    /// In the order of DevTools' :hov pane.
    enum PseudoState: String, CaseIterable, Identifiable {
        case active, hover, focus, visited
        case focusWithin = "focus-within"
        case focusVisible = "focus-visible"
        case target

        var id: Self { self }
    }

    func force(_ state: PseudoState, on: Bool, for id: Int) {
        guard nodes[id]?.type == 1 else { return }
        run(inCurrentDocument: true) { session in
            guard session.nodes[id]?.type == 1 else { return }
            let revision = session.domRevision
            var states = session.forcedStates[id, default: []]
            if on { states.insert(state) } else { states.remove(state) }
            let parameters: [String: Any] = ["nodeId": id, "forcedPseudoClasses": states.map(\.rawValue).sorted()]
            _ = try await session.command("CSS.forcePseudoState", parameters, targetID: session.domTargetID)
            guard session.domRevision == revision else { return }
            session.forcedStates[id] = states.isEmpty ? nil : states
            if session.selectedNode == id { session.selectNode(id) }
        }
    }

    func togglePicker() {
        guard ready else { pickWhenReady.toggle(); return }
        if picking {
            stopPicking()
            return
        }
        highlight?.cancel()
        // The picker lights the page itself (lightPick).
        shownHighlight = .unknown
        picking = true
        // As in Chrome, the page hears no hovers while picking: its
        // cursors (a text I-beam over text) and :hover styles stay put,
        // and the pointer is the arrow.
        if pickerMonitor == nil {
            pickerMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseUp, .mouseMoved, .keyDown]
            ) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handlePicker(event) ?? false }
                return consumed ? nil : event
            }
        }
    }

    private func stopPicking(clearHighlight: Bool = true, waitsForMouseUp: Bool = false) {
        pickWhenReady = false
        picking = false
        swallowPickerMouseUp = waitsForMouseUp
        highlightedPick = nil
        pendingHover = nil
        if let lit = litPick {
            litPick = nil
            let target = runtimeTargetID
            Task { _ = try? await command("Runtime.releaseObject", ["objectId": lit], targetID: target) }
        }
        highlight?.cancel()
        shownHighlight = .unknown
        if !waitsForMouseUp, let pickerMonitor {
            NSEvent.removeMonitor(pickerMonitor)
            self.pickerMonitor = nil
        }
        if clearHighlight { highlightNode(nil) }
    }

    private func handlePicker(_ event: NSEvent) -> Bool {
        guard let web, let window = web.window, event.window === window else { return false }
        if swallowPickerMouseUp, event.type == .leftMouseUp {
            stopPicking(clearHighlight: false)
            return true
        }
        guard picking else { return false }
        if event.type == .keyDown, event.keyCode == 53 {
            stopPicking()
            return true
        }
        guard event.type == .mouseMoved || event.type == .leftMouseDown,
              let content = window.contentView,
              let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow),
              hit === web || hit.isDescendant(of: web) else {
            if event.type == .mouseMoved, highlightedPick != nil { previewPick(nil) }
            return false
        }
        let point = Self.pagePoint(event.locationInWindow, in: web)
        if event.type == .mouseMoved {
            NSCursor.arrow.set()
            previewPick(point)
            return false
        }
        stopPicking(waitsForMouseUp: true)
        inspect(at: point)
        return true
    }

    static func pagePoint(_ windowPoint: NSPoint, in web: WKWebView) -> NSPoint {
        let local = web.convert(windowPoint, from: nil)
        let bounds = web.bounds
        let zoom = max(web.pageZoom, 0.01)
        return NSPoint(x: (local.x - bounds.minX) / zoom,
                       y: (web.isFlipped ? local.y - bounds.minY : bounds.maxY - local.y) / zoom)
    }

    /// Lights the element under the pointer as the mouse moves. One
    /// protocol round trip a move, with no wait before it: the hit test
    /// answers the element as a JS object, which DOM.highlightNode takes
    /// as it is (no DOM.requestNode, which the click alone needs). Moves
    /// that come while one is being answered keep only the latest point.
    func previewPick(_ point: NSPoint?) {
        pendingHover = .some(point)
        guard !hoverInFlight else { return }
        hoverInFlight = true
        highlight = Task { [weak self] in
            while let self, self.picking, let next = self.pendingHover {
                self.pendingHover = nil
                await self.lightPick(at: next)
            }
            self?.hoverInFlight = false
        }
    }

    private func lightPick(at point: NSPoint?) async {
        let target = runtimeTargetID
        var object: [String: Any]?
        if let point {
            object = (try? await command("Runtime.evaluate", [
                "expression": Self.hitTest(point), "objectGroup": "search-picker",
            ], targetID: target))?["result"] as? [String: Any]
        }
        guard picking else { return }
        let id = object?["objectId"] as? String
        // The same element as before: the highlight stands.
        if let id, let lit = litPick, id == lit { return }
        if id == nil, litPick == nil, highlightedPick == nil { return }
        let previous = litPick
        litPick = id
        highlightedPick = id == nil ? nil : -1
        if let id {
            // The same boxes and label as a hover in the tree.
            _ = try? await command("DOM.highlightNode", [
                "objectId": id, "highlightConfig": DeveloperHighlight.chrome.protocolValue,
            ], targetID: domTargetID)
        } else {
            _ = try? await command("DOM.hideHighlight", targetID: domTargetID)
        }
        if let previous {
            Task { _ = try? await command("Runtime.releaseObject", ["objectId": previous], targetID: target) }
        }
    }

    static func hitTest(_ point: NSPoint) -> String {
        """
        (() => {
            const x = \(Double(point.x)), y = \(Double(point.y));
            let node = document.elementFromPoint(x, y);
            for (let i = 0; i < 12; i++) {
                const next = node?.shadowRoot?.elementFromPoint(x, y);
                if (!next || next === node) break;
                node = next;
            }
            return node;
        })()
        """
    }

    func inspect(at point: NSPoint) {
        guard ready else { pendingPick = point; return }
        guard point.x.isFinite, point.y.isFinite else { return }
        run(inCurrentDocument: true) { session in
            if let id = try await session.node(at: point) { session.selectNode(id) }
        }
    }

    /// Hit-test without entering WebKit's native element-selection mode.
    /// That mode brings its inspector window forward when a node is picked.
    private func node(at point: NSPoint) async throws -> Int? {
        let target = runtimeTargetID
        let result = try await command("Runtime.evaluate", ["expression": Self.hitTest(point)], targetID: target)
        guard let object = result["result"] as? [String: Any], let id = object["objectId"] as? String else { return nil }
        let node = try? await command("DOM.requestNode", ["objectId": id], targetID: domTargetID)
        _ = try? await command("Runtime.releaseObject", ["objectId": id], targetID: target)
        guard let nodeID = node?["nodeId"] as? Int, nodeID > 0 else { return nil }
        return nodeID
    }

    // MARK: Console and Network

    func evaluate(_ expression: String) {
        guard !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if ready { evaluateInConsole(expression); return }
        let target = runtimeTargetID
        run(inCurrentDocument: true) { session in
            session.commandNumber += 1
            let group = "search-console-\(session.commandNumber)"
            session.appendConsole("command", expression)
            let reply = try await session.command("Runtime.evaluate", [
                "expression": expression, "objectGroup": group, "includeCommandLineAPI": true, "generatePreview": true,
            ], targetID: target)
            if let object = reply["result"] as? [String: Any] {
                session.appendConsole(reply["wasThrown"] as? Bool == true ? "error" : "result",
                                      object["description"] as? String ?? object["value"].map { String(describing: $0) } ?? "undefined")
            }
            _ = try? await session.command("Runtime.releaseObjectGroup", ["objectGroup": group], targetID: target)
        }
    }

    private func appendConsole(_ level: String, _ text: String) {
        console = Array((console + [ConsoleLine(level: level, text: String(text.prefix(8_192)))]).suffix(Self.consoleLimit))
    }

    func appendConsoleLine(_ line: ConsoleLine) {
        console = Array((console + [line]).suffix(Self.consoleLimit))
    }

    func clearConsole() {
        console = []
        consoleStore.reset()
        run { _ = try await $0.command("Console.clearMessages") }
    }

    func clearNetwork() {
        requests = []
        requestIndex = [:]
        requestNumber = 0
        Task { _ = try? await bridge("searchInspector.clearRequestDetails?.(); return true;") }
    }

    /// Everything DevTools shows for one request: its headers both ways, what
    /// it sent, and what came back. Asked for only when a request is chosen.
    func requestDetails(_ id: String) async -> DeveloperRequestDetails? {
        if let imported = networkTools.imported[id] { return imported }
        guard ready else { return nil }
        do {
            let raw = try await bridge("return await searchInspector.requestDetails(id);", ["id": id]) as? [String: Any]
            return raw.map(DeveloperRequestDetails.init)
        } catch {
            return nil
        }
    }

    /// Bridge calls for the Network panel's tools (DeveloperNetworkTools).
    func networkBridge(_ source: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await bridge(source, arguments)
    }

    /// Requests read from a HAR file, listed after the recorded ones.
    func addImportedRequests(_ imported: [Request]) {
        var network = requests
        for var request in imported where requestIndex[request.id] == nil {
            requestNumber += 1
            request.number = requestNumber
            requestIndex[request.id] = network.count
            network.append(request)
        }
        requests = network
    }

    private func updateRequest(_ method: String, params: [String: Any], in network: inout [Request]) {
        guard let id = params["requestId"] as? String else { return }
        let at = params["timestamp"] as? Double
        if method == "Network.requestWillBeSent" || method == "Network.requestServedFromMemoryCache"
            || method == "Network.webSocketCreated" {
            let data = params["request"] as? [String: Any] ?? params["resource"] as? [String: Any] ?? params
            guard let url = data["url"] as? String else { return }
            let initiator = params["initiator"] as? [String: Any]
            let type = method == "Network.webSocketCreated"
                ? "WebSocket" : (params["type"] ?? data["type"]) as? String ?? "Other"
            var request = Request(id: id, url: url, method: data["method"] as? String ?? "GET",
                                  type: type, loader: params["loaderId"] as? String, started: at)
            request.wallStarted = params["walltime"] as? Double
            request.documentURL = params["documentURL"] as? String
            request.referrerPolicy = data["referrerPolicy"] as? String
            request.frameId = params["frameId"] as? String
            request.initiatorURL = initiator?["url"] as? String
            request.initiatorType = initiator?["type"] as? String
            if method == "Network.requestServedFromMemoryCache" {
                request.applyResponse(data["response"] as? [String: Any], received: at)
                request.bytes = data["bodySize"] as? Int
                request.cached = true
                request.ended = at
            }
            if let index = requestIndex[id] {
                request.number = network[index].number
                if params["redirectResponse"] != nil {
                    let previous = network[index]
                    request.originalURL = previous.originalURL ?? previous.url
                    request.wallStarted = previous.wallStarted ?? request.wallStarted
                }
                network[index] = request
            } else {
                requestNumber += 1
                request.number = requestNumber
                if network.count >= 1_000 {
                    network.removeFirst(100)
                    requestIndex = Dictionary(uniqueKeysWithValues: network.enumerated().map { ($1.id, $0) })
                }
                requestIndex[id] = network.count
                network.append(request)
            }
            return
        }
        guard let index = requestIndex[id] else { return }
        switch method {
        case "Network.responseReceived":
            network[index].applyResponse(params["response"] as? [String: Any], received: at)
            if let type = params["type"] as? String { network[index].type = type }
        case "Network.webSocketWillSendHandshakeRequest":
            network[index].started = at
        case "Network.webSocketHandshakeResponseReceived":
            network[index].applyResponse(params["response"] as? [String: Any], received: at)
            network[index].ended = at
        case "Network.webSocketClosed":
            if network[index].ended == nil { network[index].ended = at }
        case "Network.loadingFinished":
            network[index].ended = at
            if let metrics = params["metrics"] as? [String: Any] {
                let headers = metrics["responseHeaderBytesReceived"] as? Int
                let body = metrics["responseBodyBytesReceived"] as? Int
                if headers != nil || body != nil {
                    let (total, overflow) = max(0, headers ?? 0).addingReportingOverflow(max(0, body ?? 0))
                    network[index].bytes = overflow ? nil : total
                }
            }
        case "Network.loadingFailed":
            network[index].ended = at
            network[index].failure = params["errorText"] as? String ?? "Failed"
        default: break
        }
    }

    func setCacheDisabled(_ disabled: Bool) {
        run { session in
            _ = try await session.command("Network.setResourceCachingDisabled", ["disabled": disabled])
            session.cacheDisabled = disabled
        }
    }

    func setNetwork(_ condition: NetworkCondition) {
        run { session in
            // Intercept the inspected page's requests at the WebKit backend.
            // Engine bandwidth pacing applies to the entire shared data store.
            _ = try await session.bridge("return await searchInspector.networkConditions(options);", [
                "options": ["latency": condition.latency, "offline": condition == .offline],
            ])
            session.throttle = condition
        }
    }

    func reload() { web?.reload() }



    // MARK: Sources, Storage, Performance

    /// Events after which the page may have more files for Sources.
    private static let resourceEvents: Set<String> = [
        "Page.domContentEventFired", "Page.loadEventFired", "Network.loadingFinished", "Debugger.scriptParsed",
    ]
    private var resourceRead: Task<Void, Never>?

    /// One re-read of the page's files shortly after a burst of loads.
    private func scheduleResourceRead() {
        guard resourceRead == nil else { return }
        resourceRead = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.resourceRead = nil
            guard self.ready, self.panel == .sources else { return }
            try? await self.readResources()
        }
    }

    private func readResources() async throws {
        let result = try await command("Page.getResourceTree")
        guard let tree = result["frameTree"] as? [String: Any] else { return }
        var list = [Resource]()
        Self.addResources(tree, to: &list)
        var frames = [ResourceFrame]()
        Self.addFrames(tree, parent: nil, to: &frames)
        resourceFrames = frames
        var seen = Set<String>()
        resources = list.filter { seen.insert($0.id).inserted }.sorted { $0.url < $1.url }
        sourceMaps.noteResources(resources)
    }

    static func addResources(_ tree: [String: Any], to list: inout [Resource]) {
        guard list.count < 1_000, let frame = tree["frame"] as? [String: Any], let id = frame["id"] as? String else { return }
        if let url = frame["url"] as? String { list.append(Resource(frame: id, url: url, type: "Document")) }
        for item in (tree["resources"] as? [[String: Any]] ?? []).prefix(300) {
            // WebKit names stylesheets "StyleSheet"; the panels say "Stylesheet".
            if let url = item["url"] as? String, let raw = item["type"] as? String {
                let type = raw == "StyleSheet" ? "Stylesheet" : raw
                if ["Script", "Stylesheet", "Document", "XHR", "Fetch"].contains(type) {
                    list.append(Resource(frame: id, url: url, type: type))
                }
            }
        }
        for child in tree["childFrames"] as? [[String: Any]] ?? [] { addResources(child, to: &list) }
    }

    private static func addFrames(_ tree: [String: Any], parent: String?, to frames: inout [ResourceFrame]) {
        guard frames.count < 200, let frame = tree["frame"] as? [String: Any], let id = frame["id"] as? String else { return }
        frames.append(ResourceFrame(id: id, parent: parent, url: frame["url"] as? String ?? "", name: frame["name"] as? String ?? ""))
        for child in tree["childFrames"] as? [[String: Any]] ?? [] { addFrames(child, parent: id, to: &frames) }
    }

    /// A snippet in the editor (Sources › Snippets): its text is the
    /// snippet's own, kept by DeveloperSnippets rather than fetched.
    func openSnippet(_ name: String, text: String) {
        sourceResource = Resource(frame: "snippet", url: "snippet:///" + name, type: "Snippet")
        source = text
        updateBreakpoints()
    }

    struct SourceReveal: Equatable {
        let url: String
        /// 1-based, as Chrome's links write it.
        let line: Int
        let column: Int?
        let serial: Int
    }

    /// Opens a script in Sources and scrolls to a line, as a file:line link
    /// does in Chrome's Console and Network panels. The file is matched on
    /// its address without query or fragment when no exact match is listed.
    /// Chrome's name for a script with no address: VM and its id.
    nonisolated static func anonymousScriptURL(_ id: String) -> String { "VM" + id }

    nonisolated static func anonymousScriptID(_ url: String) -> String? {
        guard url.hasPrefix("VM"), url.count > 2, url.dropFirst(2).allSatisfy(\.isNumber) else { return nil }
        return String(url.dropFirst(2))
    }

    func revealSource(url: String, line: Int, column: Int? = nil, showPanel: Bool = true) {
        guard ready, !url.isEmpty else { return }
        revealSerial += 1
        let reveal = SourceReveal(url: url, line: max(1, line), column: column, serial: revealSerial)
        sourceReveal = reveal
        if showPanel { select(.sources) }
        if let current = sourceResource, DeveloperDebugger.sameScript(current.url, url), source != nil { return }
        if let id = Self.anonymousScriptID(url) {
            // eval or console code: read by its script id, as Chrome opens VM scripts.
            openSource(Resource(frame: id, url: url, type: "ContentScript"))
            return
        }
        if resources.isEmpty { refresh() }
        Task { [weak self] in
            for _ in 0..<30 {
                guard let self, self.ready, self.sourceReveal == reveal else { return }
                // A paused worker's frame opens the worker's script.
                let workers = self.workerScripts.filter { script in
                    DeveloperWorker.parse(resourceFrame: script.frame)?.target == self.debugger.pause?.targetID
                }
                let listed = workers + self.resources + self.contentScripts + self.sourceMaps.authoredResources
                    + self.workerScripts
                if let resource = listed.first(where: { $0.url == url })
                    ?? listed.first(where: { DeveloperDebugger.sameScript($0.url, url) }) {
                    if self.sourceResource != resource { self.openSource(resource) }
                    return
                }
                if self.resources.isEmpty, self.panel == .sources { self.refresh() }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, self.sourceReveal == reveal, let frame = self.resources.first?.frame else { return }
            self.openSource(Resource(frame: frame, url: url, type: "Script"))
        }
    }

    /// The editor has scrolled to the line; later openings of the file
    /// start at the top again.
    func revealedSource(_ serial: Int) {
        if sourceReveal?.serial == serial { sourceReveal = nil }
    }

    func closeSource() {
        sourceResource = nil
        source = nil
        updateBreakpoints()
    }

    func openSource(_ resource: Resource) {
        if let reveal = sourceReveal, !DeveloperDebugger.sameScript(reveal.url, resource.url) { sourceReveal = nil }
        sourceResource = resource
        source = nil
        if resource.type == DeveloperSourceMaps.authoredType {
            // An authored file: its text is in its source map, or at its address.
            run { session in
                let text = await session.sourceMaps.content(of: resource.url)
                guard session.sourceResource == resource else { return }
                session.source = text
                session.updateBreakpoints()
            }
            return
        }
        if resource.type == DeveloperWorker.scriptType, let place = DeveloperWorker.parse(resourceFrame: resource.frame) {
            // A worker's script: from the worker's own debugger, by script id.
            run { session in
                let result = try await session.command("Debugger.getScriptSource", ["scriptId": place.script],
                                                       targetID: place.target)
                guard session.sourceResource == resource else { return }
                session.source = result["scriptSource"] as? String ?? "This script has no source."
                session.updateBreakpoints()
            }
            return
        }
        if resource.type == "ContentScript" {
            run { session in
                let result = try await session.command("Debugger.getScriptSource", ["scriptId": resource.frame])
                guard session.sourceResource == resource else { return }
                session.source = result["scriptSource"] as? String ?? "This script has no source."
                session.updateBreakpoints()
            }
            return
        }
        run { session in
            let content = try await session.bridge("""
                const result = await searchInspector.command("Page.getResourceContent", resource);
                return result.base64Encoded ? null : (result.content ?? "").slice(0, 10000000);
                """, ["resource": ["frameId": resource.frame, "url": resource.url]]) as? String
            guard session.sourceResource == resource else { return }
            session.source = content ?? "This resource has no text preview."
            session.updateBreakpoints()
            if let content { session.sourceMaps.noteSource(resource, text: content) }
        }
    }

    /// Reads the page's workers and their scripts from WebKit's frontend
    /// (searchInspector.workers), after one started, ended or loaded a
    /// script. Reads asked for while one runs are folded into one more.
    func readWorkers() {
        guard ready else { return }
        if workerRead != nil {
            workerReadAgain = true
            return
        }
        workerRead = Task { [weak self] in
            var again = true
            while again {
                guard let session = self, session.ready, !Task.isCancelled else { break }
                session.workerReadAgain = false
                let reply = try? await session.bridge("return searchInspector.workers?.() ?? [];") as? [[String: Any]]
                if let reply { session.applyWorkers(reply.compactMap { DeveloperWorker($0) }) }
                again = session.workerReadAgain
            }
            self?.workerRead = nil
        }
    }

    /// The debugger shows another thread's pause (its Threads pane).
    func debuggerThreadChanged() {
        paused = debugger.pause != nil
        pausedTargetID = debugger.pause?.targetID
        callStack = debugger.pause?.frames.map(\.functionName) ?? []
    }

    private func applyWorkers(_ list: [DeveloperWorker]) {
        if list != workers { workers = list }
        let scripts = list.flatMap { worker in
            worker.scripts.map {
                Resource(frame: DeveloperWorker.resourceFrame(target: worker.id, script: $0.id), url: $0.url,
                         type: DeveloperWorker.scriptType)
            }
        }
        if scripts != workerScripts { workerScripts = scripts }
        debugger.workersChanged(Set(list.map(\.id)))
        // The Console's context selector lists each worker.
        refreshConsoleContexts()
    }

    func debug(_ name: String) {
        Task { [weak self] in
            guard let self, self.ready else { return }
            do { _ = try await self.command("Debugger.\(name)", targetID: self.debugger.pause?.targetID ?? self.pausedTargetID) }
            catch { if self.ready { self.message = error.localizedDescription } }
        }
    }

    func toggleBreakpoint(line: Int, column: Int? = nil) {
        guard let resource = sourceResource, line > 0 else { return }
        debugger.toggleBreakpoint(url: resource.url, line: line, column: column, snippet: snippet(line))
        updateBreakpoints()
    }

    /// A breakpoint with a condition, or a logpoint (which logs and goes
    /// on), as the editor's context menu sets them; one already at the
    /// place is replaced. Kept by the debugger sidebar, which lists them.
    func setBreakpoint(line: Int, column: Int? = nil, condition: String? = nil, log: String? = nil) {
        guard let resource = sourceResource, line > 0 else { return }
        let kind: DeveloperDebugger.Breakpoint.Kind
        let expression: String
        if let log, !log.isEmpty { kind = .logpoint; expression = log }
        else if let condition, !condition.isEmpty { kind = .conditional; expression = condition }
        else { kind = .regular; expression = "" }
        debugger.setBreakpoint(url: resource.url, line: line, column: column, kind: kind, expression: expression,
                               snippet: snippet(line))
        updateBreakpoints()
    }

    private func snippet(_ line: Int) -> String? {
        let text = source?.split(separator: "\n", omittingEmptySubsequences: false)
        return text.flatMap { $0.indices.contains(line - 1) ? String($0[line - 1]) : nil }
    }

    /// The open file's breakpoints, kept by the debugger sidebar.
    func updateBreakpoints() {
        guard let sourceResource else { breakpoints = []; columnBreakpoints = []; return }
        breakpoints = debugger.lines(in: sourceResource.url)
        columnBreakpoints = debugger.columns(in: sourceResource.url)
    }

    /// A line of a loaded script as a protocol location, for Continue to here.
    func scriptLocation(url: String, line: Int, targetID: String?) async throws -> [String: Any]? {
        try await bridge("return searchInspector.scriptLocation(url, line, target);",
                         ["url": url, "line": line, "target": targetID as Any? ?? NSNull()]) as? [String: Any]
    }

    /// Sets the frontend's exception breakpoints; false when it has none.
    func pauseOnExceptions(uncaught: Bool, caught: Bool) async throws -> Bool {
        try await bridge("return searchInspector.pauseOnExceptions(uncaught, caught) != null;",
                         ["uncaught": uncaught, "caught": caught]) as? Bool ?? false
    }

    /// A recording opened from a file (Performance › Load profile, ⌘O),
    /// shown as one just made would be. Not while recording.
    /// A console message's level as Chrome gives it. WebKit makes
    /// console.count's and console.time's lines Debug, which Chrome's
    /// default levels hide; Chrome makes them Info. Those lines carry no
    /// arguments, unlike console.debug's, which always has its own.
    nonisolated static func consoleLevel(_ message: [String: Any]) -> String {
        let level = message["level"] as? String ?? "log"
        guard level == "debug", message["source"] as? String == "console-api" else { return level }
        if message["type"] as? String == "timing" { return "info" }
        let parameters = message["parameters"] as? [Any] ?? []
        return parameters.isEmpty && message["type"] as? String ?? "log" == "log" ? "info" : level
    }

    func loadTimeline(_ timings: [Timing], annotations: [DeveloperPerformanceAnnotation] = [],
                      scripts: [DeveloperPerformanceScript]? = nil) {
        guard !recordingTimeline else { return }
        // Nothing of a recording left unfinished applies to the file.
        collectingScriptSamples = false
        capturingTracks = false
        recordingTimelineMemory = false
        trackStart = nil
        trackNetwork = .init()
        trackPage = nil
        trackPageDate = nil
        trackShots?.stop()
        trackShots = nil
        timelineScripts = scripts ?? []
        timelineDocument = nil
        timelineAddress = nil
        lineProfile = DeveloperLineProfile()
        timeline = Self.cappedTimeline(timings)
        timelineAnnotations = annotations
    }

    func annotateTimeline(_ range: ClosedRange<Double>, label: String) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recordingTimeline, !timeline.isEmpty, !label.isEmpty, timelineAnnotations.count < 256 else { return }
        timelineAnnotations.append(DeveloperPerformanceAnnotation(label: String(label.prefix(120)), range: range))
    }

    /// Performance's Link entries: an arrow from one entry to another.
    func linkTimelineEntries(_ from: DeveloperPerformanceAnnotation.Entry, to: DeveloperPerformanceAnnotation.Entry) {
        guard !recordingTimeline, !timeline.isEmpty, from != to, timelineAnnotations.count < 256 else { return }
        timelineAnnotations.append(.linking(from, to: to))
    }

    /// Delete annotation, from the label's context menu.
    func removeTimelineAnnotation(_ id: UUID) {
        timelineAnnotations.removeAll { $0.id == id }
    }

    /// Performance's Clear: the labels go with the recording.
    func clearTimelineAnnotations() {
        timelineAnnotations = []
    }

    func clearLineProfile() { lineProfile = DeveloperLineProfile() }

    func setHeapPreview(_ watching: Bool) {
        run { session in
            guard session.heapPreview != watching else { return }
            session.heapPreview = watching
            if watching {
                try await session.updateEventDomains()
                if !session.recordingTimelineMemory { _ = try? await session.command("Memory.startTracking") }
            } else {
                session.heapTotal = nil
                if !session.recordingTimelineMemory { _ = try? await session.command("Memory.stopTracking") }
                try await session.updateEventDomains()
            }
        }
    }

    func toggleTimeline(reloading: Bool = false) {
        run { session in
            let start = !session.recordingTimeline
            // Performance's Memory checkbox, for ⌘E and the command menu as for Record.
            let memory = start && DeveloperPerformanceMemory.enabled
            if start {
                session.timeline = []
                session.timelineAnnotations = []
                session.timelineScripts = nil
                session.timelineDocument = nil
                session.timelineAddress = nil
                session.lineProfile = DeveloperLineProfile()
                session.screenshotsRecorded = 0
                session.capturingTracks = true
                session.trackStart = nil
                session.trackNetwork = .init()
                session.trackShots?.stop()
                session.trackShots = nil
                session.recordingTimelineMemory = memory
                // Memory.trackingUpdate reaches the app only for such a
                // recording, CPUProfiler.trackingUpdate only while recording.
                try? await session.updateEventDomains()
                // WebKit's Screenshot instrument captures full-size frames and can
                // stall compositing. Track screenshots using small view snapshots.
                let samples = !DeveloperPerformanceCapture.jsSamplesDisabled
                var instruments = samples ? ["Timeline", "ScriptProfiler"] : ["Timeline"]
                if memory { instruments.append("Memory") }
                // The CPU and Animations tracks' instruments; WebKit refuses
                // the whole list over an instrument it doesn't know.
                for extra in [["CPU", "Animation"], ["CPU"], []] {
                    if (try? await session.command("Timeline.setInstruments", ["instruments": instruments + extra])) != nil { break }
                }
                // The page's metrics script watches its shifts throughout.
                session.trackPage = nil
                session.trackPageDate = nil
                if let web = session.web, !session.paused { await DeveloperLiveMetricsModel.hold(web, true) }
            } else {
                session.trackShots?.stop()
            }
            if !start, session.recordingTimelineMemory, !session.heapPreview {
                _ = try? await session.command("Memory.stopTracking")
            }
            if !start {
                _ = try? await session.command("CPUProfiler.stopTracking")
            }
            if !start, session.capturingTracks, let web = session.web, !session.paused {
                // While still recording: the page's clock lined up with the
                // timeline's, and its timings and shifts, for the tracks.
                session.trackPage = await DeveloperLiveMetricsModel.recording(web)
                session.trackPageDate = Date()
                await DeveloperLiveMetricsModel.hold(web, false)
            }
            do {
                _ = try await session.command(start ? "Timeline.start" : "Timeline.stop", start ? ["maxCallStackDepth": 5] : [:])
            } catch {
                session.capturingTracks = false
                session.recordingTimelineMemory = false
                session.collectingScriptSamples = false
                session.trackShots = nil
                try? await session.updateEventDomains()
                throw error
            }
            if start {
                // Manual Timeline.start does not start the other instruments on some WebKit versions.
                if DeveloperPerformanceScreenshots.enabled, let web = session.web {
                    let shots = DeveloperFilmstripRecorder(imageLimit: DeveloperToolsSession.screenshotLimit)
                    shots.start(web)
                    session.trackShots = shots
                }
                session.scriptProfilerStarted = !DeveloperPerformanceCapture.jsSamplesDisabled
                    ? (try? await session.command("ScriptProfiler.startTracking", ["includeSamples": true])) != nil : false
                session.collectingScriptSamples = session.scriptProfilerStarted
                if memory, !session.heapPreview { _ = try? await session.command("Memory.startTracking") }
                _ = try? await session.command("CPUProfiler.startTracking")
                _ = try? await session.command("Animation.startTracking")
            } else if session.scriptProfilerStarted {
                _ = try? await session.command("ScriptProfiler.stopTracking")
                session.scriptProfilerStarted = false
            }
            if !start {
                // Finish receiving the old capture before Record can open a new one.
                _ = try? await session.drain()
                session.recordingTimelineMemory = false
                session.collectingScriptSamples = false
                try? await session.updateEventDomains()
            }
            session.recordingTimeline = start
            if start, reloading { session.reload() }
        }
    }

    /// The most screenshots a Performance recording keeps.
    nonisolated static let screenshotLimit = 300
    var screenshotsRecorded = 0

    /// The most records a Performance recording keeps; the oldest go first.
    nonisolated static let timelineLimit = 20_000

    /// Records Search draws from other domains beside Timeline's own, each
    /// kind with its own budget: sampled JavaScript frames, network bars,
    /// heap readings and the recording's bounds.
    private nonisolated static let derivedTimingLimits = [
        "JavaScriptFrame": 10_000, "NetworkRequest": 4_000, "JSHeapSample": 10_000, "RecordingBounds": 1,
        "PageTiming": 2_000, "LayoutShift": 2_000, DeveloperPerformanceCPU.type: DeveloperPerformanceCPU.limit,
        DeveloperPerformanceAnimationTrack.type: DeveloperPerformanceAnimationTrack.limit,
        DeveloperPerformanceExtensions.type: DeveloperPerformanceExtensions.limit,
    ]

    /// A recording within its limits: the newest `timelineLimit` of
    /// Timeline's records, then the derived ones within their budgets, so
    /// the frames and bars appended last never push out the records
    /// (FunctionCall and the like) they are drawn in.
    nonisolated static func cappedTimeline(_ records: [Timing]) -> [Timing] {
        guard records.count > timelineLimit else { return records }
        var own: [Timing] = []
        var derived: [String: [Timing]] = [:]
        for record in records {
            if let limit = derivedTimingLimits[record.type] {
                if derived[record.type, default: []].count < limit { derived[record.type, default: []].append(record) }
            } else {
                own.append(record)
            }
        }
        var result = Array(own.suffix(timelineLimit))
        for type in ["RecordingBounds", "NetworkRequest", "JSHeapSample", DeveloperPerformanceCPU.type,
                     DeveloperPerformanceAnimationTrack.type, "PageTiming", DeveloperPerformanceExtensions.type, "LayoutShift",
                     "JavaScriptFrame"] {
            result += derived[type] ?? []
        }
        return result
    }

    /// A recording's records without those that were over before it
    /// started: WebKit can send a record left from before
    /// Timeline.recordingStarted, and the earliest record sets the
    /// recording's zero, so one such record put the page load seconds in.
    nonisolated static func withinRecording(_ records: [Timing], from start: Double) -> [Timing] {
        records.filter { $0.end >= start }.map { record in
            guard record.start < start else { return record }
            var clipped = record
            clipped.start = start
            return clipped
        }
    }

    /// A WebKit timeline record and the records nested in it, in the order
    /// they began, each with its depth so the flame chart can stack them as
    /// Chrome DevTools does. A record with no end is an instant (a console
    /// timestamp, say); one with no start is skipped, its children kept.
    nonisolated static func addTimings(_ event: [String: Any], depth: Int = 0, to result: inout [Timing]) {
        var childDepth = depth
        if let start = (event["startTime"] as? NSNumber)?.doubleValue, let type = event["type"] as? String {
            let end = max(start, (event["endTime"] as? NSNumber)?.doubleValue ?? start)
            var data: [String: String] = [:]
            for (key, value) in event["data"] as? [String: Any] ?? [:] {
                if let text = value as? String { data[key] = text }
                else if let number = value as? NSNumber { data[key] = number.stringValue }
            }
            let stack = (event["stackTrace"] as? [[String: Any]] ?? []).prefix(5).map(Timing.frame)
            result.append(Timing(type: type, start: start, end: end, depth: depth, data: data, stack: Array(stack),
                                 frames: Timing.frames(event["stackTrace"])))
            childDepth = depth + 1
        }
        guard depth < 32 else { return }
        for child in (event["children"] as? [[String: Any]] ?? []).prefix(200) {
            addTimings(child, depth: childDepth, to: &result)
        }
    }

    /// What the inspector panels say when this macOS's WebKit lacks what
    /// DeveloperInspectorLink asks for.
    static let notAvailable = "Not available on this macOS"

    private enum Error: LocalizedError {
        case unavailable
        case notOnThisMac
        case script(String)
        var errorDescription: String? {
            switch self {
            case .script(let message): return message
            case .notOnThisMac: return DeveloperToolsSession.notAvailable
            case .unavailable: return "Search couldn’t connect to this page’s debugger."
            }
        }
    }
}

extension DeveloperToolsSession {
    /// The user scripts the tab's next document needs from the open panels,
    /// each in the package's own world: the load observer while Performance
    /// shows.
    func pageScripts() -> [WKUserScript] {
        [DeveloperLiveMetricsModel.existing(for: self)?.userScript].compactMap { $0 }
    }
}

extension DeveloperToolsSession {
    /// A rule's declarations replaced, as Styles edits them.
    func setStyleText(_ style: StyleID, _ text: String) async throws {
        _ = try await bridge("return await searchInspector.setStyleText(style, text, target);", [
            "style": style.protocolValue, "text": text, "target": domTargetID as Any? ?? NSNull(),
        ])
    }
}
