import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// The Lighthouse panel's run against the page. Navigation mode emulates
// Lighthouse's screen through the device toolbar (Mobile: 412×823 at 1.75×
// with a mobile user agent; Desktop: 1350×940 at 1×), turns the cache off,
// puts DeveloperLighthouse-observe.js in the tab as a user script of the
// panel's own content world (as the Recorder does, so Sensors' bootstrap
// script is left alone) and reloads; once the load is done and the
// network has been quiet a moment, DeveloperLighthouse-metrics.js reads
// what the observer measured. Both modes then scan the page
// (DeveloperLighthouse-collect.js, through the inspector so its elements
// can be revealed), read the Network panel's requests and headers, the
// Console's errors and the Issues tool's issues, and run the rules
// (DeveloperLighthouseRules.swift). A Navigation run also turns on
// JavaScriptCore's control flow profiler for the reload (unused-javascript,
// through DeveloperCoverage) and, for Best practices, puts a watcher of
// permission requests in the page's world
// (DeveloperLighthouse-permissions.js); the scripts' and stylesheets' text,
// the stylesheets' coverage, the source maps DevTools loaded and the
// origin's robots.txt are read after the scan. Everything is put back afterwards.
// Timespan mode puts the observer in the page as it is, watching from
// then on only, until End timespan; then the run reads what it measured
// (TBT, CLS and, where WebKit has event timing, INP) and audits the
// requests and console messages of the timespan.
// With Performance chosen, a Navigation run also records a Performance
// trace of the load (View trace opens it in Performance; Performance's own
// recording is put back), whose main-thread tasks the simulated throttling
// works from (DeveloperLighthouseLantern.swift). Clear storage first
// removes the site's stored data but its cookies; DevTools throttling
// slows the network through the Network panel for the load.
// Reports are kept for the session, listed in the toolbar's menu.
@MainActor
final class DeveloperLighthouseModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case loading
        case settling
        /// A timespan is being recorded: the user interacts with the page.
        case timespan
        case auditing

        var title: String {
            switch self {
            case .idle: ""
            case .preparing: "Preparing…"
            case .loading: "Loading page…"
            case .settling: "Waiting for the page to settle…"
            case .timespan: "Timespan started, interact with the page"
            case .auditing: "Auditing…"
            }
        }
    }

    @Published var mode: DeveloperLighthouseMode {
        didSet { Store.settings.set(mode.rawValue, forKey: Self.modeKey) }
    }
    @Published var formFactor: DeveloperLighthouseFormFactor {
        didSet { Store.settings.set(formFactor.rawValue, forKey: Self.formFactorKey) }
    }
    @Published var categories: Set<DeveloperLighthouseCategoryID> {
        didSet { Store.settings.set(categories.map(\.rawValue), forKey: Self.categoriesKey) }
    }
    /// How a Navigation run's metrics are throttled: simulated by default, as in Chrome.
    @Published var throttling: DeveloperLighthouseThrottling {
        didSet { Store.settings.set(throttling.rawValue, forKey: Self.throttlingKey) }
    }
    /// Clear storage: the site's caches, service workers and stored data
    /// (not its cookies) are removed before a Navigation run.
    @Published var clearStorage: Bool {
        didSet { Store.settings.set(clearStorage, forKey: Self.clearStorageKey) }
    }
    @Published private(set) var reports: [DeveloperLighthouseReport] = []
    @Published var selectedID: UUID?
    /// The start view, shown instead of a report.
    @Published var starting = true
    @Published private(set) var phase = Phase.idle
    @Published var problem: String?

    static let world = WKContentWorld.world(name: "PerchLighthouse")
    static let observeScript = DeveloperLayoutShiftEstimator.compose(DevToolsResources.script("DeveloperLighthouse-observe.js"))
    static let metricsScript = DevToolsResources.script("DeveloperLighthouse-metrics.js")
    static let collectScript = DevToolsResources.script("DeveloperLighthouse-collect.js")
    /// In the page's own world for a Navigation run's reload: notes the
    /// geolocation and notification requests the page makes as it loads.
    static let permissionsScript = DevToolsResources.script("DeveloperLighthouse-permissions.js")
    /// The observer's state for a timespan, apart from a Navigation run's.
    static let timespanKey = "perch.lighthouse.timespan"
    private static let objectGroup = "perch-lighthouse"
    private static let modeKey = "developerTools.lighthouse.mode"
    private static let formFactorKey = "developerTools.lighthouse.formFactor"
    private static let categoriesKey = "developerTools.lighthouse.categories"
    private static let throttlingKey = "developerTools.lighthouse.throttling"
    private static let clearStorageKey = "developerTools.lighthouse.clearStorage"

    private weak var session: DeveloperToolsSession?
    private var run: Task<Void, Never>?
    private weak var observedWeb: WKWebView?
    private var userScript: WKUserScript?
    /// The permission watcher, in the page's world.
    private var pageScript: WKUserScript?
    /// JavaScript coverage is being captured over the reload.
    private var capturingCoverage = false
    private var loading: NSKeyValueObservation?
    /// The reload has begun: the tab reported it loading.
    private var loadStarted = false
    private var savedDeviceMode: (on: Bool, settings: DeveloperViewportSettings)?
    private var restoreCache = false
    /// The scan's holder, for the latest report's elements.
    private var holder: String?
    private var holderTarget: String?
    private var holderReport: UUID?
    private var holderAddress: URL?
    private var hoverTask: Task<Void, Never>?
    /// End timespan was pressed.
    private var timespanEnded = false
    /// The run is recording a Performance trace of the load, and what
    /// Performance showed before, put back once it's read.
    private var recordingTrace = false
    private var previousTimeline: (timings: [DeveloperToolsSession.Timing], annotations: [DeveloperPerformanceAnnotation])?
    /// Each report's trace, for View trace.
    private var traces: [UUID: [DeveloperToolsSession.Timing]] = [:]
    /// The Network panel's throttling before DevTools throttling, to put back.
    private var savedNetwork: (condition: DeveloperToolsSession.NetworkCondition, profile: DeveloperNetworkTools.ThrottlingProfile?)?

    private static var models: [ObjectIdentifier: (session: WeakSession, model: DeveloperLighthouseModel)] = [:]
    struct WeakSession { weak var value: DeveloperToolsSession? }

    static func model(for session: DeveloperToolsSession) -> DeveloperLighthouseModel {
        for (key, entry) in models where entry.session.value == nil {
            entry.model.cancel()
            models[key] = nil
        }
        let key = ObjectIdentifier(session)
        if let found = models[key], found.session.value === session { return found.model }
        let model = DeveloperLighthouseModel(session: session)
        if !session.isClosed { models[key] = (WeakSession(value: session), model) }
        return model
    }

    /// DevTools closed: a run in progress stops and the model goes.
    static func closed(_ session: DeveloperToolsSession) {
        models.removeValue(forKey: ObjectIdentifier(session))?.model.cancel()
    }

    private init(session: DeveloperToolsSession) {
        self.session = session
        mode = Store.settings.string(forKey: Self.modeKey).flatMap(DeveloperLighthouseMode.init) ?? .navigation
        formFactor = Store.settings.string(forKey: Self.formFactorKey).flatMap(DeveloperLighthouseFormFactor.init) ?? .mobile
        let saved = (Store.settings.stringArray(forKey: Self.categoriesKey) ?? []).compactMap(DeveloperLighthouseCategoryID.init)
        categories = saved.isEmpty ? Set(DeveloperLighthouseCategoryID.allCases) : Set(saved)
        throttling = Store.settings.string(forKey: Self.throttlingKey).flatMap(DeveloperLighthouseThrottling.init) ?? .simulated
        clearStorage = Store.settings.object(forKey: Self.clearStorageKey) as? Bool ?? true
    }

    var running: Bool { phase != .idle }

    var selected: DeveloperLighthouseReport? {
        guard let selectedID else { return reports.last }
        return reports.first { $0.id == selectedID }
    }

    /// Whether the selected report's elements can still be found in the page.
    var live: Bool {
        guard let selected, holder != nil, holderReport == selected.id else { return false }
        return session?.address == holderAddress
    }

    func toggle(_ category: DeveloperLighthouseCategoryID) {
        if categories.contains(category) { categories.remove(category) } else { categories.insert(category) }
    }

    func removeReport(_ id: UUID) {
        reports.removeAll { $0.id == id }
        traces[id] = nil
        if selectedID == id { selectedID = reports.last?.id }
        if reports.isEmpty { starting = true }
    }

    func clearReports() {
        reports = []
        traces = [:]
        selectedID = nil
        starting = true
        release()
    }

    // MARK: The run

    func start() {
        guard !running else { return }
        guard let session, session.ready, let web = session.web else {
            problem = "There's no page to audit."
            return
        }
        let chosen = mode.categories.filter(categories.contains)
        guard !chosen.isEmpty else {
            problem = mode == .timespan ? "Timespan mode audits Performance and Best practices: choose at least one of them."
                : "Choose at least one category."
            return
        }
        guard let address = web.url, ["http", "https", "file"].contains(address.scheme?.lowercased() ?? "") else {
            problem = "Lighthouse audits web pages: open an http or https page first."
            return
        }
        problem = nil
        let settings = RunSettings(mode: mode, formFactor: formFactor, categories: chosen, throttling: throttling,
                                   clearStorage: clearStorage)
        timespanEnded = false
        phase = .preparing
        run = Task { [weak self] in
            await self?.perform(session, web, settings)
        }
    }

    /// Ends the timespan being recorded and audits it.
    func endTimespan() {
        guard phase == .timespan else { return }
        timespanEnded = true
    }

    func cancel() {
        run?.cancel()
        run = nil
        cleanUp()
        phase = .idle
    }

    /// What a run was started with.
    private struct RunSettings {
        var mode: DeveloperLighthouseMode
        var formFactor: DeveloperLighthouseFormFactor
        var categories: [DeveloperLighthouseCategoryID]
        var throttling: DeveloperLighthouseThrottling
        var clearStorage: Bool
    }

    private func perform(_ session: DeveloperToolsSession, _ web: WKWebView, _ settings: RunSettings) async {
        let started = Date()
        let requested = web.url?.absoluteString ?? ""
        var warnings: [String] = []
        var emulation = "The window's own viewport (\(settings.mode.rawValue) mode doesn't emulate a device)."
        let consoleBefore = Set(session.console.map(\.id))
        let requestsBefore = Set(session.requests.map(\.id))
        var metrics: DeveloperLighthouseMetrics?
        var scriptCoverage: [DeveloperCoverageMath.Entry]?
        var trace: [DeveloperToolsSession.Timing]?
        defer {
            cleanUp()
            phase = .idle
        }
        let performance = settings.categories.contains(.performance)
        let bestPractices = settings.categories.contains(.bestPractices)
        if settings.mode == .navigation {
            emulation = emulate(settings.formFactor, throttling: settings.throttling)
            if !session.cacheDisabled {
                session.setCacheDisabled(true)
                restoreCache = true
            }
            if settings.clearStorage, let address = web.url {
                if await Self.clearStorage(for: address, in: web.configuration.websiteDataStore) {
                    emulation += " Storage cleared."
                } else {
                    warnings.append("The site's storage couldn't be cleared before the load.")
                }
                guard !Task.isCancelled else { return }
            }
            if settings.throttling == .devtools, settings.formFactor == .mobile {
                throttleNetwork(session)
            }
            install(on: web, watchPermissions: bestPractices)
            // unused-javascript: the profiler instruments only code compiled
            // after it's on, so it goes on before the reload.
            if performance { capturingCoverage = await session.coverage.beginLighthouseCapture() }
            // View trace, and the main-thread tasks the simulation works
            // from: a Performance recording of the load, unless one is
            // being made already.
            if performance, !session.recordingTimeline {
                previousTimeline = (timings: session.timeline, annotations: session.timelineAnnotations)
                session.toggleTimeline()
                // Set first, so a recording that starts late is still stopped.
                recordingTrace = true
                _ = await Self.wait { session.recordingTimeline }
            }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            phase = .loading
            let filmstrip = DeveloperFilmstripRecorder()
            if performance { filmstrip.start(web) }
            defer { filmstrip.stop() }
            session.reload()
            guard await waitForLoad(web) else {
                if !Task.isCancelled { problem = "The page didn't finish loading in time." }
                return
            }
            phase = .settling
            await settle(session)
            guard !Task.isCancelled else { return }
            phase = .auditing
            filmstrip.stop()
            if recordingTrace {
                trace = await stopTrace(session)
                guard !Task.isCancelled else { return }
            }
            if let raw = await readMetrics(web) {
                var measured = DeveloperLighthouseMetrics(raw)
                if performance, let origin = (try? await web.evaluateJavaScript("performance.timeOrigin")) as? NSNumber,
                   origin.doubleValue.isFinite {
                    let start = Date(timeIntervalSince1970: origin.doubleValue / 1_000)
                    let frames = filmstrip.timed(from: start)
                    measured.speedIndexFrames = filmstrip.captured
                    measured.speedIndex = DeveloperSpeedIndex.speedIndex(
                        frames, fcp: measured.fcp, end: filmstrip.lastCapture.map { $0.timeIntervalSince(start) * 1_000 })
                }
                metrics = measured
            } else {
                warnings.append("The load metrics couldn't be read from the page.")
            }
            if capturingCoverage {
                capturingCoverage = false
                scriptCoverage = await session.coverage.endLighthouseCapture()
                guard !Task.isCancelled else { return }
            }
        }
        if settings.mode == .timespan {
            guard await startTimespan(web) else {
                if !Task.isCancelled { problem = "The timespan couldn't be started in the page." }
                return
            }
            phase = .timespan
            while !timespanEnded {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
            }
            phase = .auditing
            if let raw = await readMetrics(web, key: Self.timespanKey) {
                let measured = DeveloperLighthouseMetrics(raw)
                if measured.observed {
                    metrics = measured
                } else {
                    warnings.append("The page navigated during the timespan, so its metrics were lost.")
                }
            } else {
                warnings.append("The timespan's metrics couldn't be read from the page.")
            }
        }
        phase = .auditing
        let scanned: [String: Any]
        do {
            scanned = try await scan(session)
        } catch {
            if !Task.isCancelled { problem = error.localizedDescription }
            return
        }
        guard !Task.isCancelled else { return }
        await session.networkTools.poll()
        let extras = session.networkTools.extras
        let fresh = settings.mode != .snapshot
            ? session.requests.filter { !requestsBefore.contains($0.id) } : session.requests
        let requests = fresh.map { request in
            DeveloperLighthouseRequest(
                url: request.url, type: request.type, mimeType: request.mimeType ?? "", status: request.status,
                transferSize: request.bytes.map { Double($0) }, resourceSize: extras[request.id]?.resourceSize.map { Double($0) },
                headers: extras[request.id]?.responseHeaderValues ?? [:], cached: request.cached,
                durationMs: request.time, failed: request.failed, startedAt: request.started, endedAt: request.ended,
                connectMs: Self.connectionTime(extras[request.id]?.timing ?? [:]), originalURL: request.originalURL,
                sentAt: request.sent, receivedAt: request.received, initiatorType: request.initiatorType,
                initiatorURL: request.initiatorURL, networkProtocol: extras[request.id]?.networkProtocol,
                priority: extras[request.id]?.priority)
        }
        if requests.isEmpty {
            warnings.append("The Network panel recorded no requests for this page, so the network audits are not applicable.")
        }
        let errors = session.console
            .filter { $0.level == "error" && (settings.mode == .snapshot || !consoleBefore.contains($0.id)) }
            .map { DeveloperLighthouseConsoleError(text: $0.text, url: $0.url) }
        let issues = DeveloperIssuesModel.model(for: session).groups.map { group in
            DeveloperLighthouseIssue(title: group.title, category: group.category.rawValue, subtitle: group.subtitle,
                                     count: group.count, deprecation: group.code == .deprecation,
                                     scored: group.code.countsInLighthouse)
        }
        let page = DeveloperLighthousePage(scanned)
        var input = DeveloperLighthouseInput(
            mode: settings.mode, formFactor: settings.formFactor, categories: settings.categories,
            requestedURL: requested, page: page, requests: requests, metrics: metrics, consoleErrors: errors,
            issues: issues, fetchTime: started, userAgent: scanned["userAgent"] as? String ?? "", emulation: emulation,
            warnings: warnings)
        input.scriptCoverage = scriptCoverage
        input.throttling = settings.mode == .navigation ? settings.throttling : .none
        if let trace, !trace.isEmpty {
            input.traceTasks = DeveloperLighthouseLantern.tasks(fromTimeline: trace)
            // WebKit's own task bounds, not the observer's timer gaps, which
            // count the timer's clamp and queueing as blocking too.
            if settings.mode == .navigation, input.metrics?.taskSource != .longTask,
               let tasks = DeveloperLighthouseLantern.pageTasks(input) {
                input.metrics?.tasks = tasks
                input.metrics?.taskSource = .trace
            }
        }
        if settings.mode != .timespan {
            if performance { input.styleCoverage = await session.coverage.lighthouseStyleSheets() }
            if performance || bestPractices { input.contents = await Self.contents(session) }
            if bestPractices, DeveloperSourceMaps.javaScriptEnabled {
                input.sourceMaps = session.sourceMaps.resourceLog.list.records.filter { $0.kind == .sourceMap }.map {
                    DeveloperLighthouseSourceMap(scriptURL: $0.initiator, mapURL: $0.url,
                                                 error: $0.status == .failure ? $0.error ?? "Failed to load." : nil)
                }
            }
            if settings.categories.contains(.seo), let address = URL(string: page.url.isEmpty ? requested : page.url) {
                input.robots = await Self.robots(for: address)
            }
            guard !Task.isCancelled else { return }
        }
        var report = DeveloperLighthouseRules.report(input, totalTime: Date().timeIntervalSince(started) * 1_000)
        if let contents = input.contents {
            let scripts = contents.filter { $0.kind == .script }.map {
                DeveloperLighthouseTreemap.Script(url: $0.url, text: $0.text, map: session.sourceMaps.scriptMap(for: $0.url))
            }
            report.treemap = DeveloperLighthouseTreemap.nodes(scripts, coverage: scriptCoverage)
        }
        if let trace, !trace.isEmpty { traces[report.id] = trace }
        reports.append(report)
        if reports.count > 20 {
            for old in reports.prefix(reports.count - 20) { traces[old.id] = nil }
            reports.removeFirst(reports.count - 20)
        }
        selectedID = report.id
        holderReport = report.id
        holderAddress = session.address
        starting = false
    }

    /// Lighthouse's screen, through the device toolbar; what it was is put back afterwards.
    private func emulate(_ formFactor: DeveloperLighthouseFormFactor, throttling: DeveloperLighthouseThrottling) -> String {
        let device = DeveloperDeviceMode.shared
        savedDeviceMode = (device.on, device.settings)
        var settings = device.settings
        settings.select(nil)
        settings.set(width: formFactor.width, height: formFactor.height)
        settings.responsiveType = formFactor == .mobile ? .mobile : .desktop
        settings.responsiveScaleFactor = formFactor.deviceScaleFactor
        device.settings = settings
        device.on = true
        let ua = formFactor == .mobile ? ", a mobile user agent and touch" : ""
        let throttled: String
        switch throttling {
        case .simulated:
            throttled = "network and CPU throttling simulated afterwards (\(DeveloperLighthouseLantern.Settings.lighthouse(formFactor).summary))."
        case .devtools:
            throttled = formFactor == .mobile ? "Slow 4G network throttling through the Network panel; no CPU throttling."
                : "no network or CPU throttling (Lighthouse's desktop DevTools throttling adds none)."
        case .none:
            throttled = "no network or CPU throttling."
        }
        return "\(formFactor.rawValue): \(formFactor.width)×\(formFactor.height) at \(formFactor.deviceScaleFactor.formatted())×\(ua), through the device toolbar. Cache disabled; " + throttled
    }

    /// DevTools throttling: the Network panel's Slow 4G for the load, as
    /// Lighthouse's mobile devtools settings ask (562.5 ms latency, 1.44 Mbps).
    private func throttleNetwork(_ session: DeveloperToolsSession) {
        let tools = session.networkTools
        let profile = tools.activeProfile.flatMap { id in tools.profiles.first { $0.id == id } }
        savedNetwork = (condition: session.throttle, profile: profile)
        tools.apply(.slow4G)
    }

    /// Clear storage: everything the site keeps but its cookies, as Lighthouse
    /// resets storage while leaving the user signed in. WebKit keeps the
    /// records by site (registrable domain), so the whole site's go.
    static func clearStorage(for page: URL, in store: WKWebsiteDataStore) async -> Bool {
        guard let host = page.host()?.lowercased(), !host.isEmpty else { return false }
        var types = WKWebsiteDataStore.allWebsiteDataTypes()
        types.remove(WKWebsiteDataTypeCookies)
        let records: [WKWebsiteDataRecord] = await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: types) { continuation.resume(returning: $0) }
        }
        let matching = records.filter { record in
            let name = record.displayName.lowercased()
            return host == name || host.hasSuffix("." + name)
        }
        guard !matching.isEmpty else { return true }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: types, for: matching) { continuation.resume() }
        }
        return true
    }

    /// Polls `condition` every 100 ms for up to `seconds`.
    private static func wait(seconds: Double = 3, until condition: () -> Bool) async -> Bool {
        for _ in 0..<Int(seconds * 10) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return false }
        }
        return condition()
    }

    /// Ends the run's Performance recording: its records, and Performance's
    /// own recording back as it was.
    private func stopTrace(_ session: DeveloperToolsSession) async -> [DeveloperToolsSession.Timing]? {
        guard recordingTrace else { return nil }
        recordingTrace = false
        guard session.recordingTimeline else { return nil }
        session.toggleTimeline()
        guard await Self.wait(seconds: 5, until: { !session.recordingTimeline }) else { return nil }
        let recorded = session.timeline
        if let previous = previousTimeline { session.loadTimeline(previous.timings, annotations: previous.annotations) }
        previousTimeline = nil
        return recorded
    }

    // MARK: View trace

    func hasTrace(_ report: DeveloperLighthouseReport) -> Bool { traces[report.id] != nil }

    /// Opens the run's recording in the Performance panel, in place of the one there.
    func viewTrace(_ report: DeveloperLighthouseReport) {
        guard let session, let trace = traces[report.id] else { return }
        guard !session.recordingTimeline else {
            problem = "Performance is recording: stop it first to view the trace."
            return
        }
        session.loadTimeline(trace)
        session.select(.performance)
    }

    private func install(on web: WKWebView, watchPermissions: Bool) {
        let script = WKUserScript(source: Self.observeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true,
                                  in: Self.world)
        web.configuration.userContentController.addUserScript(script)
        // Kept by Tab.arm through the reload, which says it is loading
        // before Tab.arm takes the scripts out.
        ArmedRiders.add(script, to: web.configuration.userContentController)
        userScript = script
        if watchPermissions {
            // The page's own world: the page's calls are what it watches.
            let watcher = WKUserScript(source: Self.permissionsScript, injectionTime: .atDocumentStart,
                                       forMainFrameOnly: true, in: .page)
            web.configuration.userContentController.addUserScript(watcher)
            ArmedRiders.add(watcher, to: web.configuration.userContentController)
            pageScript = watcher
        }
        observedWeb = web
        loadStarted = false
        // The tab puts its own scripts back as each navigation begins,
        // taking these with them: they go back in before the page commits.
        loading = web.observe(\.isLoading, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated {
                guard let self, let script = self.userScript, web.isLoading else { return }
                self.loadStarted = true
                let controller = web.configuration.userContentController
                for one in [script, self.pageScript].compactMap({ $0 })
                where !controller.userScripts.contains(where: { $0 === one }) {
                    controller.addUserScript(one)
                }
            }
        }
    }

    /// DNS lookup to connected, from WebKit's ResourceTiming (milliseconds
    /// after fetchStart, -1 for a phase that didn't happen): nil when the
    /// request reused a connection.
    nonisolated static func connectionTime(_ timing: [String: Double]) -> Double? {
        guard let end = timing["connectEnd"], end > 0 else { return nil }
        let start = [timing["domainLookupStart"], timing["connectStart"]].compactMap { $0 }.first { $0 >= 0 }
        guard let start, end > start else { return nil }
        return end - start
    }

    /// The text of the page's scripts and stylesheets, as WebKit holds them
    /// (unminified-*, valid-source-maps): up to 80 files, 8 MB each.
    static func contents(_ session: DeveloperToolsSession) async -> [DeveloperLighthouseContent]? {
        guard let tree = (try? await session.command("Page.getResourceTree"))?["frameTree"] as? [String: Any] else { return nil }
        var resources: [DeveloperToolsSession.Resource] = []
        DeveloperToolsSession.addResources(tree, to: &resources)
        var out: [DeveloperLighthouseContent] = []
        var seen = Set<String>()
        for resource in resources where ["Script", "Stylesheet"].contains(resource.type) && seen.insert(resource.url).inserted {
            guard out.count < 80, !resource.url.hasPrefix("data:"),
                  let reply = try? await session.command("Page.getResourceContent", ["frameId": resource.frame, "url": resource.url]),
                  let content = reply["content"] as? String, content.utf8.count <= 8 << 20 else { continue }
            let text: String
            if reply["base64Encoded"] as? Bool == true {
                guard let data = Data(base64Encoded: content), let decoded = String(data: data, encoding: .utf8) else { continue }
                text = decoded
            } else {
                text = content
            }
            out.append(DeveloperLighthouseContent(url: resource.url, kind: resource.type == "Script" ? .script : .stylesheet,
                                                  text: text))
        }
        return out
    }

    /// The origin's /robots.txt (robots-txt), fetched apart from the page so
    /// it doesn't show in the Network panel. Nil for a page that isn't http(s).
    static func robots(for page: URL) async -> DeveloperLighthouseRobots? {
        guard let scheme = page.scheme?.lowercased(), ["http", "https"].contains(scheme),
              var parts = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = "/robots.txt"
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        guard let address = parts.url else { return nil }
        let request = URLRequest(url: address, timeoutInterval: 8)
        guard let fetched = try? await DeveloperResourceRequest.data(for: request),
              let http = fetched.1 as? HTTPURLResponse else { return DeveloperLighthouseRobots(status: nil, content: nil) }
        let data = fetched.0
        let text = String(data: data.prefix(512 * 1_024), encoding: .utf8) ?? String(decoding: data.prefix(512 * 1_024), as: UTF8.self)
        return DeveloperLighthouseRobots(status: http.statusCode, content: text)
    }

    private func cleanUp() {
        loading?.invalidate()
        loading = nil
        if recordingTrace, let session {
            recordingTrace = false
            if session.recordingTimeline { session.toggleTimeline() }
            previousTimeline = nil
        }
        if let saved = savedNetwork, let tools = session?.networkTools {
            if let profile = saved.profile { tools.apply(profile) } else { tools.apply(saved.condition) }
            savedNetwork = nil
        }
        if capturingCoverage, let coverage = session?.coverage {
            capturingCoverage = false
            Task { await coverage.cancelLighthouseCapture() }
        }
        let ours = [userScript, pageScript].compactMap { $0 }
        for script in ours { ArmedRiders.remove(script) }
        if let web = observedWeb, userScript != nil {
            let controller = web.configuration.userContentController
            if controller.userScripts.contains(where: { one in ours.contains { $0 === one } }) {
                // WebKit takes user scripts out all at once; the tab's go back.
                let others = controller.userScripts.filter { one in !ours.contains { $0 === one } }
                controller.removeAllUserScripts()
                others.forEach(controller.addUserScript)
            }
            web.evaluateJavaScript("(() => { const s = window[Symbol.for('perch.lighthouse')]; if (s) s.stopped = true; return true; })()",
                                   in: nil, in: Self.world, completionHandler: nil)
        }
        if let web = observedWeb {
            web.evaluateJavaScript("(() => { const s = window[Symbol.for('\(Self.timespanKey)')]; if (s) s.stopped = true; return true; })()",
                                   in: nil, in: Self.world, completionHandler: nil)
        }
        userScript = nil
        pageScript = nil
        observedWeb = nil
        if let saved = savedDeviceMode {
            let device = DeveloperDeviceMode.shared
            device.settings = saved.settings
            device.on = saved.on
            savedDeviceMode = nil
        }
        if restoreCache {
            session?.setCacheDisabled(false)
            restoreCache = false
        }
    }

    private func waitForLoad(_ web: WKWebView) async -> Bool {
        for _ in 0..<50 where !loadStarted && !web.isLoading {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return false }
        }
        for _ in 0..<600 where web.isLoading {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return false }
        }
        return !web.isLoading
    }

    /// After the load: at least 1.5 s for the last paints, then until no
    /// request has been open for 1 s (Lighthouse's network quiet), up to 8 s.
    private func settle(_ session: DeveloperToolsSession) async {
        try? await Task.sleep(for: .milliseconds(1_500))
        var quiet = 0
        for _ in 0..<65 {
            if Task.isCancelled { return }
            let open = session.requests.contains { $0.ended == nil && $0.type != "WebSocket" && $0.type != "EventSource" }
            quiet = open ? 0 : quiet + 1
            if quiet >= 10 { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Reads what the observer measured. A Navigation run's observer is
    /// run once more first (it does nothing if it is there already); a
    /// timespan's isn't, as a fresh one would have seen nothing.
    private func readMetrics(_ web: WKWebView, key: String = "perch.lighthouse") async -> [String: Any]? {
        if key != Self.timespanKey {
            web.evaluateJavaScript(Self.observeScript, in: nil, in: Self.world, completionHandler: nil)
        }
        let result = try? await web.callAsyncJavaScript(Self.metricsScript, arguments: ["key": key], in: nil,
                                                        contentWorld: Self.world)
        return result as? [String: Any]
    }

    /// The observer, started in the page as it is: its own state, entries
    /// from now on only, watching for up to an hour.
    private func startTimespan(_ web: WKWebView) async -> Bool {
        let key = Self.timespanKey
        let source = """
            const options = Symbol.for("perch.lighthouse.options");
            const previous = window[Symbol.for("\(key)")];
            if (previous) { previous.stopped = true; delete window[Symbol.for("\(key)")]; }
            window[options] = { key: "\(key)", buffered: false, limit: 3600000 };
            try {
            """ + "\n" + Self.observeScript + "\n" + """
            } finally {
                delete window[options];
            }
            return !!window[Symbol.for("\(key)")];
            """
        let started = try? await web.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: Self.world)
        observedWeb = web
        return (started as? NSNumber)?.boolValue == true
    }

    private func scan(_ session: DeveloperToolsSession) async throws -> [String: Any] {
        // The last scan's holder is in the same object group: it has to be
        // released before this scan's is made, or the release (sent after
        // the evaluate) takes the new holder with it.
        await releaseNow()
        let target = session.runtimeTargetID
        let reply = try await session.command("Runtime.evaluate", [
            "expression": Self.collectScript, "objectGroup": Self.objectGroup,
            "doNotPauseOnExceptionsAndMuteConsole": true, "includeCommandLineAPI": false,
        ], targetID: target)
        if reply["wasThrown"] as? Bool == true {
            let description = (reply["result"] as? [String: Any])?["description"] as? String
            throw DeveloperLighthouseError(description ?? "The page refused the audit.")
        }
        guard let object = reply["result"] as? [String: Any], let id = object["objectId"] as? String else {
            throw DeveloperLighthouseError("The page sent nothing back.")
        }
        let data = try await session.command("Runtime.callFunctionOn", [
            "objectId": id, "functionDeclaration": "function() { return this.data; }", "returnByValue": true,
        ], targetID: target)
        guard let value = (data["result"] as? [String: Any])?["value"] as? [String: Any] else {
            throw DeveloperLighthouseError("The page's answer was too large to read back.")
        }
        holder = id
        holderTarget = target
        // WebKit's naturalWidth of a scaled-down image is its decoded size.
        var corrected = value
        if let images = value["images"] as? [[String: Any]], let web = session.web {
            let ratio = (value["dpr"] as? NSNumber)?.doubleValue ?? 1
            corrected["images"] = await DeveloperImageNaturalSize.correct(images, ratio: ratio, in: web)
        }
        return corrected
    }

    private func release() {
        hoverTask?.cancel()
        guard let session, holder != nil else { holder = nil; return }
        let target = holderTarget
        holder = nil
        holderReport = nil
        Task { _ = try? await session.command("Runtime.releaseObjectGroup", ["objectGroup": Self.objectGroup], targetID: target) }
    }

    /// As `release`, waiting for WebKit to have let the holder go.
    private func releaseNow() async {
        hoverTask?.cancel()
        guard let session, holder != nil else { holder = nil; return }
        let target = holderTarget
        holder = nil
        holderReport = nil
        _ = try? await session.command("Runtime.releaseObjectGroup", ["objectGroup": Self.objectGroup], targetID: target)
    }

    // MARK: Elements

    private func node(_ index: Int) async -> Int? {
        guard let session, let holder, live, index >= 0 else { return nil }
        let target = holderTarget
        guard let reply = try? await session.command("Runtime.callFunctionOn", [
            "objectId": holder, "functionDeclaration": "function(index) { return this.elements[index] || null; }",
            "arguments": [["value": index]],
        ], targetID: target),
            let object = (reply["result"] as? [String: Any])?["objectId"] as? String else { return nil }
        let node = try? await session.command("DOM.requestNode", ["objectId": object], targetID: session.domTargetID)
        _ = try? await session.command("Runtime.releaseObject", ["objectId": object], targetID: target)
        guard let id = (node?["nodeId"] as? NSNumber)?.intValue, id > 0 else { return nil }
        return id
    }

    /// An element hovered in a table: drawn on the page; nil hides it.
    func hover(_ index: Int?) {
        hoverTask?.cancel()
        guard let session else { return }
        guard let index else { session.hideHighlight(); return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, let node = await self?.node(index), !Task.isCancelled else { return }
            session.highlightNode(node)
        }
    }

    /// Shows the element in the Elements panel, once Elements has read the
    /// document afresh (as the CSS overview's reveal does).
    func reveal(_ index: Int) {
        guard let session, live else { return }
        hoverTask?.cancel()
        session.hideHighlight()
        let switching = session.panel != .elements
        let before = session.root
        session.select(.elements)
        Task { [weak self] in
            for _ in 0..<40 where switching {
                guard session.root == before || session.root == nil else { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let node = await self?.node(index) else { return }
            for _ in 0..<40 where session.nodes[node] == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            session.selectNode(node)
        }
    }

    // MARK: Export

    func export(_ report: DeveloperLighthouseReport) {
        guard let data = DeveloperLighthouseLHR.data(report) else {
            problem = "The report couldn't be written as JSON."
            return
        }
        let panel = NSSavePanel()
        let host = (URL(string: report.finalURL)?.host() ?? "report").replacingOccurrences(of: ":", with: "-")
        let stamp = report.fetchTime.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(host)-\(stamp).report.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let write = { [weak self] (url: URL) in
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                self?.problem = error.localizedDescription
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { write(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            write(url)
        }
    }

    /// Saves the report as one self-contained HTML page (DeveloperLighthouseHTML).
    func exportHTML(_ report: DeveloperLighthouseReport) {
        let data = Data(DeveloperLighthouseHTML.html(report).utf8)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(Self.fileStem(report)).report.html"
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        let write = { [weak self] (url: URL) in
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                self?.problem = error.localizedDescription
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { write(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            write(url)
        }
    }

    /// Writes the HTML report to a temporary file and opens it in a new tab.
    func openInBrowser(_ report: DeveloperLighthouseReport) {
        guard let session, let tab = session.tab, let browser = Browsers.browser(for: session.web?.window) else {
            problem = "There's no window to open the report in."
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Search Lighthouse", isDirectory: true)
        let file = folder.appendingPathComponent("\(Self.fileStem(report))-\(report.id.uuidString.prefix(8)).report.html")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(DeveloperLighthouseHTML.html(report).utf8).write(to: file, options: .atomic)
        } catch {
            problem = error.localizedDescription
            return
        }
        browser.open(file, foreground: true, from: tab)
    }

    private static func fileStem(_ report: DeveloperLighthouseReport) -> String {
        let host = (URL(string: report.finalURL)?.host() ?? "report").replacingOccurrences(of: ":", with: "-")
        let stamp = report.fetchTime.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        return "\(host)-\(stamp)"
    }

    func copyJSON(_ report: DeveloperLighthouseReport) {
        guard let data = DeveloperLighthouseLHR.data(report) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
    }
}

struct DeveloperLighthouseError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
