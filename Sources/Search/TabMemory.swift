import Foundation
import SwiftUI
import WebKit
import Darwin

struct TabMemoryReading: Equatable {
    let bytes: UInt64?
    let estimatedSavingsBytes: UInt64?
    let isSharedProcess: Bool
    let isSleeping: Bool
}

/// Sampling is requested by the optional UI, not by an always-running timer.
/// A renderer footprint is not a measurement of system RAM freed by sleep.
@MainActor
final class TabMemoryMonitor: ObservableObject {
    static let shared = TabMemoryMonitor()
    @Published private(set) var totalBytes: UInt64?
    @Published private var readingsByID: [UUID: TabMemoryReading] = [:]
    private var identitiesByID: [UUID: SampleIdentity] = [:]
    private var generations: [UUID: UInt64] = [:]
    private var sharedSleep: Set<UUID> = []
    private var estimates = SleepEstimates()
    private var refreshGeneration: UInt64 = 0

    struct Sample: Sendable {
        let footprints: [Int32: UInt64]
        let totalBytes: UInt64?
    }
    typealias Sampler = @Sendable ([Int32]) async -> Sample
    private let sampler: Sampler

    init(sampler: @escaping Sampler = { ids in await TabMemoryMonitor.nativeSample(ids) }) { self.sampler = sampler }

    struct SampleIdentity: Equatable {
        let processID: Int32?
        let address: URL?
        let sleeping: Bool
        let generation: UInt64
    }
    static func sampleIsCurrent(_ sampled: SampleIdentity, current: SampleIdentity) -> Bool { sampled == current }

    struct SleepEstimates {
        private var values: [UUID: (pid: Int32, bytes: UInt64)] = [:]
        mutating func record(id: UUID, pid: Int32, bytes: UInt64) { if pid > 0 { values[id] = (pid, bytes) } }
        func savings(for id: UUID) -> UInt64? {
            guard let value = values[id], values.values.filter({ $0.pid == value.pid }).count == 1 else { return nil }
            return value.bytes
        }
        var total: UInt64? {
            let known = values.keys.compactMap { savings(for: $0) }
            return known.isEmpty ? nil : known.reduce(0, +)
        }
        mutating func remove(_ id: UUID) { values[id] = nil }
        mutating func retain(_ ids: Set<UUID>) { values = values.filter { ids.contains($0.key) } }
    }

    static func readings(tabIDs: [UUID], processIDs: [Int32?], footprints: [Int32: UInt64]) -> [TabMemoryReading] {
        let valid = processIDs.compactMap { $0 }.filter { $0 > 0 }
        let counts = Dictionary(grouping: valid, by: { $0 }).mapValues(\.count)
        return tabIDs.indices.map { index in
            let pid = index < processIDs.count ? processIDs[index].flatMap { $0 > 0 ? $0 : nil } : nil
            let shared = pid.map { counts[$0, default: 0] > 1 } ?? false
            return TabMemoryReading(bytes: shared ? nil : pid.flatMap { footprints[$0] }, estimatedSavingsBytes: nil,
                                    isSharedProcess: shared, isSleeping: false)
        }
    }

    var estimatedSavedBytes: UInt64? { estimates.total }

    func reading(for tab: Tab) -> TabMemoryReading {
        if tab.asleep {
            return TabMemoryReading(bytes: nil, estimatedSavingsBytes: estimates.savings(for: tab.id),
                                    isSharedProcess: sharedSleep.contains(tab.id), isSleeping: true)
        }
        guard let identity = identitiesByID[tab.id], Self.sampleIsCurrent(identity, current: self.identity(for: tab)),
              let reading = readingsByID[tab.id] else {
            return TabMemoryReading(bytes: nil, estimatedSavingsBytes: nil, isSharedProcess: false, isSleeping: false)
        }
        return reading
    }

    func forget(_ id: UUID) {
        generations[id, default: 0] &+= 1
        readingsByID[id] = nil
        identitiesByID[id] = nil
        estimates.remove(id)
        sharedSleep.remove(id)
    }

    func didSleep(_ tab: Tab, processID: Int32?, bytes: UInt64?, shared: Bool = false) {
        forget(tab.id)
        if shared { sharedSleep.insert(tab.id) }
        if !shared, let pid = processID, pid > 0, let bytes { estimates.record(id: tab.id, pid: pid, bytes: bytes) }
        readingsByID[tab.id] = TabMemoryReading(bytes: nil, estimatedSavingsBytes: estimates.savings(for: tab.id),
                                              isSharedProcess: shared, isSleeping: true)
    }
    func didWake(_ id: UUID) { forget(id) }

    func captureSleep(tab: Tab, web: WKWebView) {
        let pid = Self.processID(of: web)
        // Parked spaces and other windows can still share this renderer.
        let others = Browsers.all.flatMap { $0.tabs + $0.parkedTabs }.filter { $0 !== tab && !$0.asleep }
        let shared = pid.map { candidate in others.contains { other in other.built.flatMap(Self.processID) == candidate } } ?? false
        didSleep(tab, processID: pid, bytes: shared ? nil : pid.flatMap(Self.physicalFootprint), shared: shared)
    }

    private func identity(for tab: Tab) -> SampleIdentity {
        SampleIdentity(processID: tab.asleep ? nil : tab.built.flatMap(Self.processID), address: tab.address,
                       sleeping: tab.asleep, generation: generations[tab.id, default: 0])
    }

    private final class WeakTab {
        weak var value: Tab?
        init(_ tab: Tab) { value = tab }
    }

    func refresh(tabs: [Tab]) async {
        var seen: Set<UUID> = []
        let current = tabs.filter { seen.insert($0.id).inserted }
        let references = current.map(WeakTab.init)
        let ids = current.map(\.id)
        let snapshots = current.map { identity(for: $0) }
        refreshGeneration &+= 1
        let ticket = refreshGeneration
        let sample = await sampler(Array(Set(snapshots.compactMap(\.processID))))
        guard !Task.isCancelled, ticket == refreshGeneration else { return }
        let live = Set(references.compactMap { $0.value?.id })
        readingsByID = readingsByID.filter { live.contains($0.key) }
        identitiesByID = identitiesByID.filter { live.contains($0.key) }
        estimates.retain(live)
        sharedSleep.formIntersection(live)
        generations = generations.filter { live.contains($0.key) }
        let layouts = Self.readings(tabIDs: ids, processIDs: snapshots.map(\.processID), footprints: sample.footprints)
        for index in ids.indices {
            guard let tab = references[index].value,
                  Self.sampleIsCurrent(snapshots[index], current: identity(for: tab)) else { continue }
            identitiesByID[tab.id] = snapshots[index]
            if tab.asleep {
                readingsByID[tab.id] = TabMemoryReading(bytes: nil, estimatedSavingsBytes: estimates.savings(for: tab.id),
                                                      isSharedProcess: sharedSleep.contains(tab.id), isSleeping: true)
            } else { readingsByID[tab.id] = layouts[index] }
        }
        totalBytes = sample.totalBytes
    }

    private static func processID(of web: WKWebView) -> Int32? {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard web.responds(to: selector), let value = web.value(forKey: "_webProcessIdentifier") as? NSNumber,
              value.int32Value > 0 else { return nil }
        return value.int32Value
    }

    nonisolated static func physicalFootprint(of pid: Int32) -> UInt64? {
        guard pid > 0 else { return nil }
        var usage = rusage_info_v4()
        // libproc's C declaration says void**, but the kernel writes the
        // structure at buffer itself. Passing &aPointer corrupts the stack.
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            proc_pid_rusage(pid, RUSAGE_INFO_V4,
                           UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self))
        }
        return status == 0 ? usage.ri_phys_footprint : nil
    }

    nonisolated private static func nativeSample(_ rendererIDs: [Int32]) async -> Sample {
        await Task.detached(priority: .utility) {
            var footprints: [Int32: UInt64] = [:]
            for pid in rendererIDs { footprints[pid] = physicalFootprint(of: pid) }
            let root = getpid()
            guard let own = physicalFootprint(of: root) else { return Sample(footprints: footprints, totalBytes: nil) }
            let helpers = processIDs().filter { $0 != root && responsible(pid: $0) == root }
            let total = Set(helpers).reduce(own) { $0 + (physicalFootprint(of: $1) ?? 0) }
            return Sample(footprints: footprints, totalBytes: total)
        }.value
    }

    nonisolated private static func responsible(pid: Int32) -> Int32 {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return pid }
        typealias Function = @convention(c) (Int32) -> Int32
        return unsafeBitCast(symbol, to: Function.self)(pid)
    }

    nonisolated private static func processIDs() -> [Int32] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(bytes) / MemoryLayout<Int32>.size + 32)
        let used = pids.withUnsafeMutableBufferPointer {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count * MemoryLayout<Int32>.size))
        }
        return pids.prefix(max(0, Int(used)) / MemoryLayout<Int32>.size).filter { $0 > 0 }
    }
}
