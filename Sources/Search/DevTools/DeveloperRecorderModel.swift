import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// Chrome's Recorder panel against the page: recording a flow and
// replaying it. Recording puts DeveloperRecorder-record.js in the tab as
// a user script of the recorder's own content world (so it is in every
// page the tab loads until the recording ends) and runs it once in the
// page already up; the page posts each step to a message handler in
// that world as it happens. Replay runs each step with
// DeveloperRecorder-replay.js (callAsyncJavaScript, same world), and
// navigates through the tab. The steps' rules and formats are
// DeveloperRecorder.swift.

/// The recordings, kept with the profile's other files and listed in
/// the panel's recordings menu, whichever page DevTools is open on.
@MainActor
final class DeveloperRecordings: ObservableObject {
    static let shared = DeveloperRecordings()
    static var file: URL { Store.file("devtools-recordings.json") }

    @Published private(set) var all: [DeveloperRecording] = []

    private init() {
        guard let data = try? Data(contentsOf: Self.file) else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let saved = object["recordings"] as? [[String: Any]] else {
            Store.quarantine(Self.file)
            return
        }
        all = saved.compactMap(DeveloperRecording.init(saved:))
    }

    func recording(_ id: UUID?) -> DeveloperRecording? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    func add(_ recording: DeveloperRecording) {
        all.append(recording)
        save()
    }

    func update(_ recording: DeveloperRecording) {
        guard let index = all.firstIndex(where: { $0.id == recording.id }) else { return }
        guard all[index] != recording else { return }
        all[index] = recording
        save()
    }

    func remove(_ id: UUID) {
        all.removeAll { $0.id == id }
        save()
    }

    private func save() {
        let payload: [String: Any] = ["recordings": all.map(\.saved)]
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        Disk.write(Self.file) { data }
    }
}

/// The page's messages, to the model; WebKit holds this strongly.
final class DeveloperRecorderRelay: NSObject, WKScriptMessageHandler {
    private let receive: @MainActor (Any, WKWebView?) -> Void

    init(_ receive: @escaping @MainActor (Any, WKWebView?) -> Void) {
        self.receive = receive
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        let body = message.body
        let web = message.webView
        MainActor.assumeIsolated { receive(body, web) }
    }
}

@MainActor
final class DeveloperRecorderModel: ObservableObject, DeveloperSessionModel {
    enum Status: Equatable {
        case pending, running, done
        case failed(String)
    }

    @Published var selectedID: UUID?
    /// The recording being recorded into.
    @Published private(set) var recordingID: UUID?
    /// The recording being replayed.
    @Published private(set) var replayingID: UUID?
    @Published private(set) var status: [UUID: Status] = [:]
    /// The step replay is stopped before, at a breakpoint or a step over.
    @Published private(set) var pausedAt: UUID?
    @Published var speed: DeveloperRecorderSpeed = .normal
    @Published var problem: String?
    /// Create a new recording's form, shown.
    @Published var creating = false

    let store: DeveloperRecordings

    static let world = WKContentWorld.world(name: "PerchRecorder")
    static let handlerName = "perchRecorder"
    static let selectorsScript = DevToolsResources.script("DeveloperRecorder-selectors.js")
    static let recordScript = DevToolsResources.script("DeveloperRecorder-record.js")
    static let replayScript = DevToolsResources.script("DeveloperRecorder-replay.js")

    private weak var session: DeveloperToolsSession?
    private weak var recordingWeb: WKWebView?
    private var relay: DeveloperRecorderRelay?
    private var userScript: WKUserScript?
    private var recordingSource = ""
    private var loading: NSKeyValueObservation?
    private var firstLoadPending = false
    private var lastAction: Date?
    private var replayTask: Task<Void, Never>?
    private var resume: CheckedContinuation<Void, Never>?
    private var steppingOver = false

    static func model(for session: DeveloperToolsSession) -> DeveloperRecorderModel {
        DeveloperSessionModels.model(for: session, make: DeveloperRecorderModel.init)
    }

    private init(session: DeveloperToolsSession) {
        self.session = session
        store = DeveloperRecordings.shared
        selectedID = store.all.last?.id
        creating = store.all.isEmpty
    }

    func sessionClosed() {
        stopRecording()
        cancelReplay()
    }

    var selected: DeveloperRecording? { store.recording(selectedID) }
    var recording: Bool { recordingID != nil }
    var replaying: Bool { replayingID != nil }

    // MARK: Editing

    func edit(_ id: UUID?, _ change: (inout DeveloperRecording) -> Void) {
        guard var recording = store.recording(id) else { return }
        change(&recording)
        store.update(recording)
    }

    func editStep(_ stepID: UUID, in id: UUID?, _ change: (inout DeveloperRecorderStep) -> Void) {
        edit(id) { recording in
            guard let index = recording.steps.firstIndex(where: { $0.id == stepID }) else { return }
            change(&recording.steps[index])
        }
    }

    /// Add step before or after a step, as Chrome's step menu does.
    func addStep(near stepID: UUID?, after: Bool, in id: UUID?) {
        edit(id) { recording in
            let step = DeveloperRecorderStep(.waitForElement)
            guard let stepID, let index = recording.steps.firstIndex(where: { $0.id == stepID }) else {
                recording.steps.append(step)
                return
            }
            recording.steps.insert(step, at: after ? index + 1 : index)
        }
    }

    func duplicateStep(_ stepID: UUID, in id: UUID?) {
        edit(id) { recording in
            guard let index = recording.steps.firstIndex(where: { $0.id == stepID }) else { return }
            var copy = recording.steps[index]
            copy.id = UUID()
            copy.breakpoint = false
            recording.steps.insert(copy, at: index + 1)
        }
    }

    func removeStep(_ stepID: UUID, in id: UUID?) {
        edit(id) { $0.steps.removeAll { $0.id == stepID } }
    }

    func toggleBreakpoint(_ stepID: UUID, in id: UUID?) {
        editStep(stepID, in: id) { $0.breakpoint.toggle() }
    }

    func delete(_ id: UUID) {
        guard id != recordingID, id != replayingID else { return }
        store.remove(id)
        if selectedID == id { selectedID = store.all.last?.id }
        if store.all.isEmpty { creating = true }
    }

    // MARK: Recording

    func startRecording(title: String, types: Set<DeveloperRecorderSelectorType>, attribute: String) {
        guard recordingID == nil, replayingID == nil else { return }
        guard let session, let web = session.web else {
            problem = "There's no page to record."
            return
        }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var recording = DeveloperRecording(title: name.isEmpty ? DeveloperRecording.defaultTitle() : name,
                                           selectorTypes: types.isEmpty ? Set(DeveloperRecorderSelectorType.allCases) : types)
        let attribute = attribute.trimmingCharacters(in: .whitespacesAndNewlines)
        recording.selectorAttribute = attribute.isEmpty ? nil : attribute
        let size = web.bounds.size
        recording.steps = DeveloperRecorderFlow.opening(
            width: Double(size.width), height: Double(size.height),
            scale: Double(web.window?.backingScaleFactor ?? 1),
            url: web.url?.absoluteString ?? "about:blank", title: web.title
        )
        store.add(recording)
        problem = nil
        creating = false
        selectedID = recording.id
        recordingID = recording.id
        firstLoadPending = true
        lastAction = nil
        install(on: web, recording)
    }

    private func source(for recording: DeveloperRecording) -> String {
        let config: [String: Any] = [
            "handler": Self.handlerName,
            "selectorTypes": DeveloperRecorderSelectorType.allCases.filter(recording.selectorTypes.contains).map(\.rawValue),
            "selectorAttribute": recording.selectorAttribute ?? "",
        ]
        let json = (try? JSONSerialization.data(withJSONObject: config)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "(\n\(Self.recordScript)\n)(\n\(Self.selectorsScript)\n, \(json));"
    }

    private func install(on web: WKWebView, _ recording: DeveloperRecording) {
        let controller = web.configuration.userContentController
        let relay = DeveloperRecorderRelay { [weak self] body, from in
            guard let self, let from, from === self.recordingWeb else { return }
            self.received(body)
        }
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.world)
        controller.add(relay, contentWorld: Self.world, name: Self.handlerName)
        let source = source(for: recording)
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world)
        controller.addUserScript(script)
        // Kept by Tab.arm at each navigation: a load or reload says it is
        // loading before Tab.arm takes the scripts out.
        ArmedRiders.add(script, to: controller)
        self.relay = relay
        userScript = script
        recordingSource = source
        recordingWeb = web
        loading = web.observe(\.isLoading, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated { self?.loadingChanged(web) }
        }
        web.evaluateJavaScript(source, in: nil, in: Self.world, completionHandler: nil)
    }

    /// The tab puts its own scripts back as each navigation begins (Tab.arm),
    /// taking the recorder's with them: it goes back in before the page
    /// commits. Once the page is up, the script is run in it in case it
    /// came too late; already there, it does nothing.
    private func loadingChanged(_ web: WKWebView) {
        guard recordingID != nil, web === recordingWeb else { return }
        let controller = web.configuration.userContentController
        if web.isLoading {
            if let script = userScript, !controller.userScripts.contains(where: { $0 === script }) {
                controller.addUserScript(script)
            }
        } else {
            web.evaluateJavaScript(recordingSource, in: nil, in: Self.world, completionHandler: nil)
        }
    }

    private func received(_ body: Any) {
        guard session != nil else {
            stopRecording()
            return
        }
        guard let recordingID, var recording = store.recording(recordingID),
              let message = body as? [String: Any] else { return }
        switch message["kind"] as? String {
        case "step":
            guard let raw = message["step"] as? [String: Any],
                  let step = DeveloperRecorderFlow.step(from: raw, types: recording.selectorTypes) else { return }
            DeveloperRecorderFlow.append(step, to: &recording.steps)
            lastAction = Date()
        case "load":
            guard let url = message["url"] as? String else { return }
            let first = firstLoadPending
            firstLoadPending = false
            DeveloperRecorderFlow.loaded(url: url, title: message["title"] as? String ?? "", into: &recording.steps,
                                         lastAction: lastAction, first: first)
            lastAction = nil
        default:
            return
        }
        store.update(recording)
    }

    /// Add assertion, while recording: waits for the element last acted on.
    func addAssertion() {
        guard let recordingID else { return }
        edit(recordingID) { recording in
            recording.steps.append(DeveloperRecorderFlow.assertion(after: recording.steps))
        }
    }

    // MARK: Replay settings

    func replayNetwork(_ id: UUID?) -> DeveloperToolsSession.NetworkCondition {
        store.recording(id).map(DeveloperRecorderNetwork.condition(of:)) ?? .unrestricted
    }

    func setReplayNetwork(_ condition: DeveloperToolsSession.NetworkCondition, in id: UUID?) {
        edit(id) { DeveloperRecorderNetwork.set(condition, in: &$0) }
    }

    /// Replay settings › Timeout: the recording's wait for each step, in
    /// milliseconds; nil for Chrome's 5000.
    func setReplayTimeout(_ timeout: Double?, in id: UUID?) {
        edit(id) { recording in
            recording.timeout = timeout.flatMap { $0 > 0 ? min($0, 600_000) : nil }
        }
    }

    func stopRecording() {
        guard recordingID != nil else { return }
        recordingID = nil
        loading?.invalidate()
        loading = nil
        if let script = userScript { ArmedRiders.remove(script) }
        if let web = recordingWeb {
            let controller = web.configuration.userContentController
            controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.world)
            if let script = userScript, controller.userScripts.contains(where: { $0 === script }) {
                // WebKit takes user scripts out all at once; the tab's go back.
                let others = controller.userScripts.filter { $0 !== script }
                controller.removeAllUserScripts()
                others.forEach(controller.addUserScript)
            }
            web.evaluateJavaScript("(() => { const r = window[Symbol.for('perch.recorder')]; if (r) r.stop(); return true; })()",
                                   in: nil, in: Self.world, completionHandler: nil)
        }
        relay = nil
        userScript = nil
        recordingWeb = nil
    }

    // MARK: Replay

    func replay(_ id: UUID?, measure: Bool = false) {
        guard replayingID == nil, recordingID == nil, let recording = store.recording(id) else { return }
        guard let session, let web = session.web else {
            problem = "There's no page to replay in."
            return
        }
        replayingID = recording.id
        problem = nil
        pausedAt = nil
        steppingOver = false
        status = Dictionary(uniqueKeysWithValues: recording.steps.map { ($0.id, Status.pending) })
        replayTask = Task { [weak self] in
            guard let self else { return }
            if measure, !session.recordingTimeline {
                session.toggleTimeline()
                for _ in 0..<40 where !session.recordingTimeline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            // Replay settings › Network: throttled with the Network
            // conditions tool for the replay, then put back as it was.
            let before = session.throttle
            let throttled = recording.steps.contains { $0.kind == .emulateNetworkConditions }
            await self.run(recording, web: web)
            if throttled, session.throttle != before { session.networkTools.apply(before) }
            if measure, session.recordingTimeline {
                session.toggleTimeline()
                session.select(.performance)
            }
            self.replayingID = nil
            self.pausedAt = nil
            self.replayTask = nil
        }
    }

    /// Continue from a breakpoint; `stepping` stops again before the next step.
    func continueReplay(stepping: Bool = false) {
        steppingOver = stepping
        let waiting = resume
        resume = nil
        waiting?.resume()
    }

    func cancelReplay() {
        replayTask?.cancel()
        continueReplay()
    }

    private func run(_ recording: DeveloperRecording, web: WKWebView) async {
        for (index, step) in recording.steps.enumerated() {
            if Task.isCancelled { break }
            // The breakpoint as it is now, set or cleared while replaying.
            let current = store.recording(recording.id)?.steps.first { $0.id == step.id } ?? step
            if current.breakpoint || steppingOver {
                steppingOver = false
                pausedAt = step.id
                await withCheckedContinuation { resume = $0 }
                pausedAt = nil
                if Task.isCancelled { break }
            }
            if index > 0, speed.delay != .zero { try? await Task.sleep(for: speed.delay) }
            if Task.isCancelled { break }
            status[step.id] = .running
            do {
                try await execute(current, in: recording, web: web)
                status[step.id] = .done
            } catch {
                let message = error.localizedDescription
                status[step.id] = .failed(message)
                problem = "Step \(index + 1) (\(current.title)) failed: \(message)"
                return
            }
        }
    }

    private func execute(_ step: DeveloperRecorderStep, in recording: DeveloperRecording, web: WKWebView) async throws {
        let timeout = step.timeout ?? recording.timeout ?? DeveloperRecorderExport.defaultTimeout
        switch step.kind {
        case .emulateNetworkConditions:
            guard let condition = DeveloperRecorderNetwork.condition(of: step) else {
                throw DeveloperRecorderError("The step has no latency to emulate.")
            }
            session?.networkTools.apply(condition)
            // Let the conditions reach the page before the next step.
            for _ in 0..<20 where session?.throttle != condition {
                try await Task.sleep(for: .milliseconds(50))
            }
        case .setViewport, .close, .customStep:
            // The window's size is yours, and the tab stays open: these
            // steps are for Puppeteer, which makes its own page.
            return
        case .navigate:
            guard let address = step.url, let url = URL(string: address) else {
                throw DeveloperRecorderError("The step has no address to go to.")
            }
            let before = marker(web)
            if let tab = session?.tab, tab.built === web { tab.go(to: url) } else { web.load(URLRequest(url: url)) }
            try await waitForNavigation(web, since: before, timeout: max(timeout, 30_000))
        case nil:
            throw DeveloperRecorderError("Replay doesn't know \(step.type) steps.")
        default:
            await waitWhileLoading(web, timeout: timeout)
            let before = marker(web)
            let navigates = step.assertsNavigation
            do {
                let result = try await web.callAsyncJavaScript(
                    "const lib = \(Self.selectorsScript);\n\(Self.replayScript)",
                    arguments: ["step": step.json.any, "timeout": timeout],
                    in: nil, contentWorld: Self.world
                )
                if let reply = result as? [String: Any], let error = reply["error"] as? String {
                    throw DeveloperRecorderError(error)
                }
            } catch let error as DeveloperRecorderError {
                throw error
            } catch {
                // The page going away mid-step is what a navigating step does.
                guard navigates else { throw error }
            }
            if navigates { try await waitForNavigation(web, since: before, timeout: max(timeout, 30_000)) }
        }
    }

    private struct Marker {
        weak var item: WKBackForwardListItem?
        var url: URL?
    }

    private func marker(_ web: WKWebView) -> Marker {
        Marker(item: web.backForwardList.currentItem, url: web.url)
    }

    private func waitForNavigation(_ web: WKWebView, since start: Marker, timeout: Double) async throws {
        let deadline = Date().addingTimeInterval(timeout / 1000)
        var sawLoading = false
        while Date() < deadline {
            try Task.checkCancellation()
            if web.isLoading { sawLoading = true }
            let moved = web.backForwardList.currentItem !== start.item || web.url != start.url
            if sawLoading || moved, !web.isLoading { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw DeveloperRecorderError("Timed out after \(DeveloperRecorderJSON.format(timeout)) ms waiting for the page to navigate.")
    }

    private func waitWhileLoading(_ web: WKWebView, timeout: Double) async {
        let deadline = Date().addingTimeInterval(timeout / 1000)
        while web.isLoading, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: Files

    enum ExportFormat: String, CaseIterable, Identifiable {
        case json = "JSON"
        case replay = "@puppeteer/replay"
        case puppeteer = "Puppeteer"
        case puppeteerFirefox = "Puppeteer (for Firefox)"
        case puppeteerLighthouse = "Puppeteer (including Lighthouse analysis)"

        var id: Self { self }

        func text(_ recording: DeveloperRecording) -> String {
            switch self {
            case .json: recording.exportedJSON
            case .replay: DeveloperRecorderExport.puppeteerReplay(recording)
            case .puppeteer: DeveloperRecorderExport.puppeteer(recording)
            case .puppeteerFirefox: DeveloperRecorderExport.puppeteer(recording, firefox: true)
            case .puppeteerLighthouse: DeveloperRecorderExport.puppeteerLighthouse(recording)
            }
        }

        var type: UTType { self == .json ? .json : .javaScript }
        var fileExtension: String { self == .json ? "json" : "js" }
    }

    func export(_ id: UUID?, as format: ExportFormat) {
        guard let recording = store.recording(id) else { return }
        let panel = NSSavePanel()
        let base = recording.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = base + "." + format.fileExtension
        panel.allowedContentTypes = [format.type]
        panel.canCreateDirectories = true
        let text = format.text(recording)
        let write = { [weak self] (url: URL) in
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
            } catch {
                self?.problem = error.localizedDescription
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                write(url)
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            write(url)
        }
    }

    /// Import recording: a Chrome Recorder JSON file.
    func importRecording() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let read = { [weak self] (url: URL) in
            guard let self else { return }
            do {
                let recording = try DeveloperRecording(data: Data(contentsOf: url))
                self.store.add(recording)
                self.selectedID = recording.id
                self.creating = false
                self.problem = nil
            } catch {
                self.problem = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                read(url)
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            read(url)
        }
    }
}
