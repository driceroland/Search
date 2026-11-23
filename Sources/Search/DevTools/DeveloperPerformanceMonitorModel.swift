import Foundation
import SwiftUI

/// The Performance monitor's state: a minute of every metric, read once a
/// second while the tool is shown. One per DevTools session, kept while
/// the drawer tab is closed and reopened; tracking stops while it's hidden.
@MainActor
final class DeveloperPerformanceMonitorModel: ObservableObject {
    @Published private(set) var history = DeveloperPerformanceHistory()
    /// The metrics with a chart, as checked in the list.
    @Published var enabled: Set<DeveloperPerformanceMetric> {
        didSet { Store.settings.set(enabled.map(\.rawValue).sorted(), forKey: Self.enabledKey) }
    }
    @Published private(set) var problem: String?
    @Published private(set) var running = false
    /// CPUProfiler or Memory tracking refused by this WebKit.
    @Published private(set) var cpuUnavailable = false
    @Published private(set) var heapUnavailable = false

    static let install = DevToolsResources.script("DeveloperPerformanceMonitor-install.js")
    private static let enabledKey = "developerTools.performanceMonitor.metrics"
    private static let objectGroup = "perch-performance-monitor"
    /// How often the page is sampled and the frontend's readings collected.
    static let interval: Duration = .seconds(1)

    private weak var session: DeveloperToolsSession?
    private var poll: Task<Void, Never>?
    /// The target tracking was asked of, so it's asked again after a swap.
    private var trackedTarget: String??
    private var address: URL?
    private var hookless = false
    private var lastCPU = 0.0
    private var lastHeap = 0.0
    private var trackingAsked = 0.0

    private static var models: [ObjectIdentifier: (session: WeakSession, model: DeveloperPerformanceMonitorModel)] = [:]
    struct WeakSession { weak var value: DeveloperToolsSession? }

    static func model(for session: DeveloperToolsSession) -> DeveloperPerformanceMonitorModel {
        models = models.filter { $0.value.session.value != nil }
        let key = ObjectIdentifier(session)
        if let found = models[key] { return found.model }
        let model = DeveloperPerformanceMonitorModel(session: session)
        models[key] = (WeakSession(value: session), model)
        return model
    }

    static func isRunning(for session: DeveloperToolsSession) -> Bool {
        models[ObjectIdentifier(session)]?.model.running == true
    }

    private init(session: DeveloperToolsSession) {
        self.session = session
        let saved = Store.settings.stringArray(forKey: Self.enabledKey)
        enabled = saved.map { Set($0.compactMap(DeveloperPerformanceMetric.init(rawValue:))) } ?? DeveloperPerformanceMetric.defaults
    }

    /// A steady clock in seconds, for the charts' time axis.
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    func toggle(_ metric: DeveloperPerformanceMetric) {
        if enabled.contains(metric) { enabled.remove(metric) } else { enabled.insert(metric) }
    }

    /// The newest reading, or nil (n/a).
    func latest(_ metric: DeveloperPerformanceMetric) -> Double? {
        history.latest(metric, now: Self.now())
    }

    /// Why a metric reads n/a now, if it does.
    func unavailableReason(_ metric: DeveloperPerformanceMetric) -> String? {
        if metric.neverAvailable { return metric.unavailableReason }
        if metric.needsTimeline, session?.recordingTimeline != true { return metric.unavailableReason }
        if metric == .cpu, cpuUnavailable || hookless { return "This version of WebKit doesn’t report CPU use to DevTools." }
        if metric == .jsHeap, heapUnavailable || hookless { return "This version of WebKit doesn’t report memory use to DevTools." }
        return nil
    }

    // MARK: Sampling

    /// While the tool is shown: tracking on, and a reading a second.
    func start() {
        guard poll == nil else { return }
        running = true
        poll = Task { [weak self] in
            // Ends with the model, should it go without stop().
            while !Task.isCancelled {
                guard let model = self else { return }
                await model.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// Hidden: the charts pause and WebKit stops tracking.
    func stop() {
        poll?.cancel()
        poll = nil
        running = false
        guard let session, trackedTarget != nil else { return }
        trackedTarget = nil
        Task {
            _ = try? await session.command("CPUProfiler.stopTracking")
            if !session.recordingTimelineMemory { _ = try? await session.command("Memory.stopTracking") }
            _ = try? await session.evaluateInFrontend("globalThis.perchPerformanceMonitor?.own(false);")
        }
    }

    /// Clears the charts.
    func clear() { history.removeAll() }

    private func tick() async {
        guard let session, session.ready else { return }
        if session.address != address {
            // A new page: its readings start afresh.
            if address != nil { history.removeAll() }
            address = session.address
        }
        let now = Self.now()
        if !hookless {
            do {
                let raw = try await session.evaluateInFrontend(
                    Self.install + "\nreturn {fresh, ...perchPerformanceMonitor.drain()};") as? [String: Any] ?? [:]
                let target = session.runtimeTargetID
                // Asked again when the frontend reloaded, the page moved to
                // another process, or no reading came for a while (someone
                // else stopped tracking).
                let quiet = !(cpuUnavailable && heapUnavailable)
                    && now - max(lastCPU, trackingAsked) > 4 && now - max(lastHeap, trackingAsked) > 4
                if raw["fresh"] as? Bool == true || trackedTarget != .some(target) || quiet {
                    await track(session, target: target, at: now)
                }
                apply(raw, now: Self.now())
                if problem != nil { problem = nil }
            } catch is CancellationError {
                return
            } catch {
                hookless = true
                problem = error.localizedDescription
            }
        }
        if hookless {
            history.add(.cpu, nil, at: now)
            history.add(.jsHeap, nil, at: now)
        }
        await samplePage(session, at: Self.now())
    }

    private func track(_ session: DeveloperToolsSession, target: String?, at now: Double) async {
        trackingAsked = now
        trackedTarget = .some(target)
        _ = try? await session.evaluateInFrontend("perchPerformanceMonitor.own(true);")
        do {
            _ = try await session.command("CPUProfiler.startTracking")
            cpuUnavailable = false
        } catch {
            cpuUnavailable = true
        }
        do {
            _ = try await session.command("Memory.startTracking")
            heapUnavailable = false
        } catch {
            heapUnavailable = true
        }
    }

    /// The frontend's CPU and heap readings, and the timeline's counts.
    private func apply(_ raw: [String: Any], now: Double) {
        let frontendNow = (raw["now"] as? NSNumber)?.doubleValue ?? 0
        func time(_ item: [String: Any]) -> Double {
            let at = (item["time"] as? NSNumber)?.doubleValue ?? frontendNow
            return now - max(0, frontendNow - at) / 1000
        }
        for item in raw["cpu"] as? [[String: Any]] ?? [] {
            guard let usage = (item["usage"] as? NSNumber)?.doubleValue else { continue }
            let at = time(item)
            history.add(.cpu, max(0, usage), at: at)
            lastCPU = max(lastCPU, at)
        }
        for item in raw["memory"] as? [[String: Any]] ?? [] {
            guard let size = (item["size"] as? NSNumber)?.doubleValue else { continue }
            let at = time(item)
            history.add(.jsHeap, max(0, size), at: at)
            lastHeap = max(lastHeap, at)
        }
        if cpuUnavailable { history.add(.cpu, nil, at: now) }
        if heapUnavailable { history.add(.jsHeap, nil, at: now) }
        // Only while the Performance panel records does WebKit send timeline records.
        let recording = session?.recordingTimeline == true
        history.addTimeline(layouts: recording ? (raw["layouts"] as? NSNumber)?.doubleValue : nil,
                            styles: recording ? (raw["styles"] as? NSNumber)?.doubleValue : nil, at: now)
    }

    /// The page's counts: nodes, documents, frames. Not while the debugger
    /// holds the page, which wouldn't answer.
    private func samplePage(_ session: DeveloperToolsSession, at now: Double) async {
        guard !session.paused else {
            history.addPage(DeveloperPageCounts(), at: now)
            return
        }
        let reply = try? await session.command("Runtime.evaluate", [
            "expression": DeveloperPageCounts.expression, "objectGroup": Self.objectGroup,
            "includeCommandLineAPI": false, "doNotPauseOnExceptionsAndMuteConsole": true, "returnByValue": true,
        ], targetID: session.runtimeTargetID)
        let value = (reply?["wasThrown"] as? Bool == true) ? nil : (reply?["result"] as? [String: Any])?["value"]
        history.addPage(DeveloperPageCounts(raw: value), at: now)
    }
}
