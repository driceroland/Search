import Foundation

// iCloud played by a folder, for Tests/icloud_two_macs.py: two hidden probes,
// two test worlds, standing for two Macs on one iCloud account. Each runs a
// Sync with iCloud of its own (ICloudSync with this Mac's real side,
// MacSide, so pins, folders and rows go where they really go) over this
// engine instead of CloudKit: a record saved is a file in the shared
// folder, a fetch reads the files another probe wrote. CloudKit is never
// reached, nothing is signed in, and the real ICloudSync.shared stays off.
// Test runs only: the bench refuses it anywhere else.

@MainActor
final class ICloudFolderEngine: ICloudEngine {
    private struct Stored: Codable {
        var data: Data
        var at: Date
    }

    weak var owner: ICloudSync?
    let folder: URL
    /// The next fetches take only records whose names start so: a record
    /// held back, as iCloud may hand them over in any order.
    var only: String?
    private var due: [String] = []
    /// Each record as last read or written, so a fetch hands over only
    /// what changed.
    private var seen: [String: Data] = [:]

    init(folder: URL) { self.folder = folder }

    private func file(_ key: String) -> URL { folder.appendingPathComponent(key + ".json") }

    func save(_ keys: [String]) {
        for key in keys where !due.contains(key) { due.append(key) }
    }

    func delete(_ keys: [String]) {
        for key in keys {
            due.removeAll { $0 == key }
            try? FileManager.default.removeItem(at: file(key))
            seen[key] = nil
        }
    }

    func fetch() async throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names.sorted() where name.hasSuffix(".json") {
            let key = String(name.dropLast(".json".count))
            if let only, !key.hasPrefix(only) { continue }
            guard let raw = try? Data(contentsOf: file(key)), seen[key] != raw,
                  let stored = try? JSONDecoder().decode(Stored.self, from: raw) else { continue }
            seen[key] = raw
            owner?.arrived(key, data: stored.data, at: stored.at, fields: nil)
        }
    }

    /// Everything due, written; the keys written, in order.
    @discardableResult
    func flush() -> [String] {
        let keys = due
        due = []
        var written: [String] = []
        for key in keys {
            guard let out = owner?.outgoing(key), let raw = try? JSONEncoder().encode(Stored(data: out.data, at: out.at)) else { continue }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard (try? raw.write(to: file(key), options: .atomic)) != nil else { continue }
            seen[key] = raw
            owner?.saved(key, fields: nil)
            written.append(key)
        }
        return written
    }

    func send() async throws { flush() }
    func eraseZone() async throws {}
    func account() async -> ICloudSync.Account { .signedIn }
    func close() {}
}
