import CryptoKit
import Foundation
import WebKit

@MainActor
final class CustomFilters: ObservableObject {
    static let shared = CustomFilters()
    nonisolated static let identifierPrefix = "office-shield-custom-"
    private static let manifestKey = "shield.customLists"
    private static let day: TimeInterval = 24 * 60 * 60
    private nonisolated static let sizeLimit = 50_000_000

    @Published private(set) var enabled: Bool
    @Published private(set) var myFilters: String
    @Published private(set) var lists: [String]
    @Published private(set) var ruleCount = 0
    @Published private(set) var skippedCount = 0
    @Published private(set) var trouble: String?
    @Published private(set) var listTrouble: [String: String] = [:]
    @Published private(set) var lastUpdated: [String: Date] = [:]
    @Published private(set) var refreshing = false

    private let settings: UserDefaults
    private let cache: URL
    private let store: WKContentRuleListStore?
    private let shield: Shield
    private let onPrepare: () -> Void
    private let fetch: (URL) async throws -> Data
    private var attempts: [String: Double]
    private var compilation: Task<Void, Never>?
    private var startupManifest: Manifest?
    private var installed: [String: WKContentRuleList] = [:]
    private var revision = 0
    private var refresh: Task<Void, Never>?
    private var nextRefresh: Task<Void, Never>?

    private convenience init() {
        self.init(settings: Store.settings, cache: Store.file("Shield Filters"),
                  store: WKContentRuleListStore.default(), shield: .shared)
    }

    init(settings: UserDefaults, cache: URL, store: WKContentRuleListStore?, shield: Shield,
         onPrepare: @escaping () -> Void = {},
         fetch: @escaping (URL) async throws -> Data = CustomFilters.download) {
        self.settings = settings
        self.cache = cache
        self.store = store
        self.shield = shield
        self.onPrepare = onPrepare
        self.fetch = fetch
        enabled = settings.bool(forKey: "shield.custom")
        myFilters = settings.string(forKey: "shield.myFilters") ?? ""
        lists = (settings.stringArray(forKey: "shield.lists") ?? []).filter {
            Self.subscriptionURL($0) != nil
        }
        attempts = settings.dictionary(forKey: "shield.listAttempts") as? [String: Double] ?? [:]
    }

    func start() {
        guard enabled else { return }
        for list in lists { lastUpdated[list] = cachedDate(for: list) }
        if let data = settings.data(forKey: Self.manifestKey),
           let manifest = try? PropertyListDecoder().decode(Manifest.self, from: data),
           manifest.fingerprint == inputs().fingerprint {
            startupManifest = manifest
            shield.setRestoringCustomFilters(true)
        }
        compile()
        if startupManifest == nil { update(force: false) }
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        settings.set(value, forKey: "shield.custom")
        if value {
            start()
        } else {
            revision += 1
            nextRefresh?.cancel()
            refresh?.cancel()
            refresh = nil
            refreshing = false
            installed.removeAll()
            shield.setCustomList([])
            finishStartupLookup()
        }
    }

    func save(_ text: String) {
        guard text != myFilters else { return }
        myFilters = text
        settings.set(text, forKey: "shield.myFilters")
        compile()
    }

    nonisolated static func subscriptionURL(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        parts.scheme = "https"
        parts.host = host
        parts.fragment = nil
        if parts.port == 443 { parts.port = nil }
        if parts.path.isEmpty { parts.path = "/" }
        return parts.url
    }

    func add(_ url: URL) {
        guard let value = Self.subscriptionURL(url.absoluteString)?.absoluteString,
              !lists.contains(value) else { return }
        lists.append(value)
        settings.set(lists, forKey: "shield.lists")
        compile()
        update(force: false)
    }

    func remove(_ list: String) {
        guard let index = lists.firstIndex(of: list) else { return }
        lists.remove(at: index)
        settings.set(lists, forKey: "shield.lists")
        attempts[list] = nil
        settings.set(attempts, forKey: "shield.listAttempts")
        listTrouble[list] = nil
        lastUpdated[list] = nil
        try? FileManager.default.removeItem(at: cacheFile(for: list))
        compile()
        scheduleRefresh()
    }

    func updateNow() { update(force: true) }

    private func update(force: Bool) {
        guard enabled, refresh == nil else { return }
        let cutoff = Date().timeIntervalSince1970 - Self.day
        let due = lists.filter { force || (attempts[$0] ?? 0) <= cutoff }
        guard !due.isEmpty else { scheduleRefresh(); return }
        nextRefresh?.cancel()
        refreshing = true
        refresh = Task {
            // Compile from the cache first so a slow subscription never
            // holds up the rules already available on this Mac.
            for list in due {
                guard !Task.isCancelled else { return }
                guard lists.contains(list), let url = Self.subscriptionURL(list) else { continue }
                attempts[list] = Date().timeIntervalSince1970
                settings.set(attempts, forKey: "shield.listAttempts")
                do {
                    let data = try await fetch(url)
                    guard !Task.isCancelled else { return }
                    guard lists.contains(list) else { continue }
                    if data.count > Self.sizeLimit { throw FilterError.tooLarge }
                    guard String(data: data, encoding: .utf8) != nil else { throw FilterError.encoding }
                    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                    try data.write(to: cacheFile(for: list), options: .atomic)
                    lastUpdated[list] = cachedDate(for: list)
                    listTrouble[list] = nil
                    compile()
                } catch {
                    guard !Task.isCancelled else { return }
                    if lists.contains(list) { listTrouble[list] = error.localizedDescription }
                }
            }
            refresh = nil
            refreshing = false
            scheduleRefresh()
        }
    }

    private func scheduleRefresh() {
        nextRefresh?.cancel()
        guard enabled, refresh == nil,
              let earliest = lists.map({ attempts[$0] ?? 0 }).min() else { return }
        let seconds = max(0, earliest + Self.day - Date().timeIntervalSince1970)
        nextRefresh = Task {
            do { try await Task.sleep(for: .seconds(min(Self.day, seconds))) }
            catch { return }
            nextRefresh = nil
            update(force: false)
        }
    }

    private func cacheFile(for list: String) -> URL {
        cache.appendingPathComponent(Self.hash(Data(list.utf8)))
    }

    private func cachedDate(for list: String) -> Date? {
        try? cacheFile(for: list).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private struct Fingerprint: Codable, Equatable {
        struct Subscription: Codable, Equatable {
            let url: String
            let modified: Date?
            let size: Int?
            let fileNumber: UInt64?
        }

        // Bump when conversion changes so an old WebKit list is rebuilt.
        var format = 1
        let textHash: String
        let subscriptions: [Subscription]
    }

    private struct Manifest: Codable {
        let fingerprint: Fingerprint
        let identifiers: [String]
        let count: Int
        let skipped: Int
    }

    private func inputs() -> (files: [URL], fingerprint: Fingerprint) {
        let files = lists.map(cacheFile)
        let subscriptions = zip(lists, files).map { url, file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            return Fingerprint.Subscription(url: url, modified: attributes?[.modificationDate] as? Date,
                                            size: (attributes?[.size] as? NSNumber)?.intValue,
                                            fileNumber: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value)
        }
        return (files, Fingerprint(textHash: Self.hash(Data(myFilters.utf8)), subscriptions: subscriptions))
    }

    private func restore(_ manifest: Manifest) async -> [WKContentRuleList]? {
        guard Set(manifest.identifiers).count == manifest.identifiers.count else { return nil }
        var lists: [WKContentRuleList] = []
        for identifier in manifest.identifiers {
            guard identifier.hasPrefix(Self.identifierPrefix), let store,
                  let list = try? await store.contentRuleList(forIdentifier: identifier) else { return nil }
            lists.append(list)
        }
        return lists
    }

    private func finishStartupLookup() {
        guard startupManifest != nil else { return }
        startupManifest = nil
        shield.setRestoringCustomFilters(false)
        if enabled { update(force: false) }
    }

    private func install(_ lists: [WKContentRuleList], count: Int, skipped: Int) {
        installed = Dictionary(uniqueKeysWithValues: lists.map { ($0.identifier, $0) })
        shield.setCustomList(lists)
        ruleCount = count
        skippedCount = skipped
        trouble = nil
    }

    private struct Prepared: Sendable {
        struct Chunk: Sendable {
            let json: String
            let identifier: String
        }

        let count: Int
        let skipped: Int
        let chunks: [Chunk]

        init(text: String, files: [URL]) throws {
            let texts = [text] + files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            let result = FilterRules.convert(texts.joined(separator: "\n"))
            count = result.count
            skipped = result.skipped
            chunks = try result.chunks.enumerated().map { index, rules in
                let data = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
                let identifier = CustomFilters.identifierPrefix + CustomFilters.hash(data) + "-\(index + 1)"
                return Chunk(json: String(decoding: data, as: UTF8.self), identifier: identifier)
            }
        }
    }

    private func compile() {
        guard enabled else { return }
        revision += 1
        guard compilation == nil else { return }
        // Run one compile at a time so an obsolete job cannot remove the
        // identifiers just written by a newer job.
        compilation = Task {
            defer { compilation = nil }
            prepare: while enabled {
                let current = revision
                let text = myFilters
                let (files, fingerprint) = inputs()
                if let manifest = startupManifest {
                    let restored = manifest.fingerprint == fingerprint ? await restore(manifest) : nil
                    guard current == revision else { continue }
                    if let restored {
                        install(restored, count: manifest.count, skipped: manifest.skipped)
                    }
                    finishStartupLookup()
                    guard current == revision else { continue }
                    if restored != nil { break }
                }
                do {
                    onPrepare()
                    let prepared = try await Task.detached(priority: .utility) {
                        try Prepared(text: text, files: files)
                    }.value
                    guard current == revision else { continue }
                    var lists: [WKContentRuleList] = []
                    for chunk in prepared.chunks {
                        lists.append(try await compiledList(chunk))
                        guard current == revision else { continue prepare }
                    }
                    // Keep the last working set installed until every new
                    // chunk is ready, including the copies of the exceptions.
                    install(lists, count: prepared.count, skipped: prepared.skipped)
                    let manifest = Manifest(fingerprint: fingerprint, identifiers: lists.map(\.identifier),
                                            count: prepared.count, skipped: prepared.skipped)
                    if let data = try? PropertyListEncoder().encode(manifest) {
                        settings.set(data, forKey: Self.manifestKey)
                    }
                    if let store {
                        let identifiers = Set(installed.keys)
                        for old in await store.availableIdentifiers() ?? []
                            where old.hasPrefix(Self.identifierPrefix) && !identifiers.contains(old) {
                            try? await store.removeContentRuleList(forIdentifier: old)
                        }
                    }
                } catch {
                    guard current == revision else { continue }
                    trouble = error.localizedDescription
                }
                if current == revision { break }
            }
        }
    }

    private func compiledList(_ chunk: Prepared.Chunk) async throws -> WKContentRuleList {
        if let current = installed[chunk.identifier] { return current }
        guard let store else { throw FilterError.noRuleStore }
        if let found = try? await store.contentRuleList(forIdentifier: chunk.identifier) {
            return found
        }
        guard let list = try await store.compileContentRuleList(forIdentifier: chunk.identifier, encodedContentRuleList: chunk.json) else {
            throw FilterError.noCompiledList
        }
        return list
    }

    private nonisolated static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum FilterError: LocalizedError {
        case refused, tooLarge, encoding, noRuleStore, noCompiledList

        var errorDescription: String? {
            switch self {
            case .refused: return "The server refused the HTTPS download"
            case .tooLarge: return "Filter lists can be up to 50 MB"
            case .encoding: return "The list isn't UTF-8 text"
            case .noRuleStore: return "WebKit has nowhere to compile custom filters"
            case .noCompiledList: return "WebKit did not return the compiled custom filters"
            }
        }
    }

    private nonisolated static func download(_ url: URL) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        ProxyNetwork.stamp(config)
        let watcher = DownloadWatcher()
        let session = URLSession(configuration: config, delegate: watcher, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let result: (URL, URLResponse)
        do {
            result = try await session.download(from: url, delegate: watcher)
        } catch {
            if watcher.exceededLimit { throw FilterError.tooLarge }
            throw error
        }
        let (file, response) = result
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.url?.scheme?.lowercased() == "https" else { throw FilterError.refused }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= sizeLimit else { throw FilterError.tooLarge }
        return try Data(contentsOf: file)
    }

    private final class DownloadWatcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var tooLarge = false

        var exceededLimit: Bool { lock.withLock { tooLarge } }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, CustomFilters.subscriptionURL(url.absoluteString) != nil else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesWritten > Int64(CustomFilters.sizeLimit) || totalBytesExpectedToWrite > Int64(CustomFilters.sizeLimit) {
                lock.withLock { tooLarge = true }
                downloadTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
