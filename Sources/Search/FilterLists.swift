import Foundation
import WebKit

// The filter lists people bring to the blocker: EasyList, a regional list, a
// hosts file, their own. Each is fetched (or read from its file), turned into
// WebKit's rules by FilterList, compiled once and kept. A compiled list comes
// back from WebKit's store in a fraction of a millisecond, so launching costs
// nothing; adding or updating one costs WebKit's compile, a few seconds for
// EasyList, off the main thread.
//
// Each refreshes on its own as often as it says it goes stale ("! Expires:
// 4 days"), daily when it doesn't say. Whatever fails — the address is down,
// the file moved, the list is past WebKit's limit — the last good version
// keeps blocking, and the row in Settings says what happened.

@MainActor
final class FilterLists: ObservableObject {
    static let shared = FilterLists()

    struct Source: Codable, Identifiable, Equatable {
        var id = UUID()
        /// An https address, or a file's path.
        var origin: String
        var name: String
        var on = true
        var fetched: Date?
        /// How long it says it stays good, in seconds.
        var keeps: TimeInterval = 24 * 60 * 60
        var rules: Int?
        var used: Int?
        var dropped: [String: Int] = [:]
        /// Why it isn't up to date, or isn't blocking at all.
        var trouble: String?

        var isFile: Bool { origin.hasPrefix("/") }
        var skipped: Int { dropped.values.reduce(0, +) }
        var identifier: String { "filterlist-\(id.uuidString)" }
        var due: Bool { fetched.map { Date().timeIntervalSince($0) >= keeps } ?? true }
        /// Within a tenth of what WebKit takes from one list.
        var nearLimit: Bool { (rules ?? 0) >= FilterList.limit * 9 / 10 }
    }

    @Published private(set) var sources: [Source]
    /// The ones being fetched, converted or compiled right now.
    @Published private(set) var working: Set<UUID> = []
    /// Compiled, by source. A list keeps its last good version here while a
    /// newer one fails.
    private var compiled: [UUID: WKContentRuleList] = [:]
    private var clock: Timer?

    nonisolated static let key = "shield.lists"
    nonisolated static let day: TimeInterval = 24 * 60 * 60

    private init() {
        sources = Store.settings.data(forKey: FilterLists.key)
            .flatMap { try? JSONDecoder().decode([Source].self, from: $0) } ?? []
    }

    /// At launch: each list back from WebKit's store, or made again if WebKit
    /// lost it; then the clock that keeps them fresh.
    func start() {
        guard clock == nil else { return }
        for source in sources where source.on { restore(source) }
        clock = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { FilterLists.shared.refreshDue() }
        }
        refreshDue()
    }

    // MARK: - what Settings does

    /// What's wrong with an address or path someone typed, or nil to add it.
    func problem(with typed: String) -> String? {
        guard let origin = FilterLists.origin(typed) else {
            return "An https:// address or a file"
        }
        if sources.contains(where: { $0.origin == origin }) { return "Already added" }
        return nil
    }

    func add(_ typed: String) {
        guard problem(with: typed) == nil, let origin = FilterLists.origin(typed) else { return }
        // Until the list's own `! Title:` says otherwise.
        let name = origin.hasPrefix("/") ? (origin as NSString).lastPathComponent : URL(string: origin)?.host() ?? origin
        let source = Source(origin: origin, name: name)
        sources.append(source)
        save()
        refresh(source.id)
    }

    func remove(_ id: UUID) {
        guard let source = sources.first(where: { $0.id == id }) else { return }
        sources.removeAll { $0.id == id }
        compiled[id] = nil
        attach()
        save()
        WKContentRuleListStore.default()?.removeContentRuleList(forIdentifier: source.identifier) { _ in }
        Disk.remove(FilterLists.copy(of: id))
    }

    /// Whether a compiled version of it is there to block with: after a
    /// failed update, the last good one is.
    func compiled(_ id: UUID) -> Bool { compiled[id] != nil }

    func turn(_ id: UUID, on: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].on = on
        save()
        if on, compiled[id] == nil { restore(sources[index]) }
        attach()
    }

    /// Fetched or read again now, whatever its schedule says.
    func refresh(_ id: UUID) {
        guard let source = sources.first(where: { $0.id == id }), !working.contains(id) else { return }
        working.insert(id)
        Task {
            do {
                let text = try await FilterLists.read(source.origin)
                // Kept, so a list WebKit loses can be made again without
                // the network.
                Disk.write(FilterLists.copy(of: id)) { Data(text.utf8) }
                await make(id, from: text)
            } catch {
                update(id) { $0.trouble = FilterLists.say(error) }
                working.remove(id)
            }
        }
    }

    func refreshDue() {
        for source in sources where source.on && source.due { refresh(source.id) }
    }

    // MARK: - making a list

    /// The list WebKit kept from last time, or failing that the copy kept
    /// here, or failing that the list itself again.
    private func restore(_ source: Source) {
        guard let store = WKContentRuleListStore.default() else { return }
        store.lookUpContentRuleList(forIdentifier: source.identifier) { list, _ in
            MainActor.assumeIsolated {
                let id = source.id
                if let list {
                    self.compiled[id] = list
                    self.attach()
                } else if let data = try? Data(contentsOf: FilterLists.copy(of: id)), !self.working.contains(id) {
                    self.working.insert(id)
                    Task { await self.make(id, from: String(decoding: data, as: UTF8.self)) }
                } else {
                    self.refresh(id)
                }
            }
        }
    }

    private func make(_ id: UUID, from text: String) async {
        defer { working.remove(id) }
        let converted = await Task.detached(priority: .utility) { FilterList.convert(text) }.value
        let header = FilterLists.header(of: text)
        update(id) {
            if let title = header.title { $0.name = title }
            $0.keeps = header.keeps ?? FilterLists.day
            $0.fetched = Date()
            $0.rules = converted.rules
            $0.used = converted.used
            $0.dropped = converted.dropped
        }
        if converted.used == 0 {
            return update(id) { $0.trouble = "Nothing in it is a filter Search can use" }
        }
        if converted.rules > FilterList.limit {
            return update(id) {
                $0.trouble = "\(converted.rules.formatted()) rules is past WebKit's limit of \(FilterList.limit.formatted()) for one list"
            }
        }
        guard let source = sources.first(where: { $0.id == id }), let store = WKContentRuleListStore.default() else { return }
        do {
            let list = try await store.compileContentRuleList(forIdentifier: source.identifier,
                                                              encodedContentRuleList: converted.json)
            // Removed while WebKit was compiling it: nothing to attach.
            guard sources.contains(where: { $0.id == id }) else {
                try? await store.removeContentRuleList(forIdentifier: source.identifier)
                return
            }
            compiled[id] = list
            update(id) { $0.trouble = nil }
            attach()
        } catch {
            update(id) { $0.trouble = "WebKit couldn't compile it: \(error.localizedDescription)" }
        }
    }

    /// The lists that are on, to the blocker.
    private func attach() {
        Shield.shared.use(sources.filter(\.on).compactMap { compiled[$0.id] })
    }

    private func update(_ id: UUID, _ change: (inout Source) -> Void) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        change(&sources[index])
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        Store.settings.set(data, forKey: FilterLists.key)
    }

    // MARK: - reading

    /// What was typed, as an origin: an https address, or a file's full path.
    static func origin(_ typed: String) -> String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/") || text.hasPrefix("~") {
            return (text as NSString).expandingTildeInPath
        }
        if let url = URL(string: text), url.isFileURL { return url.path }
        let address = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host(), host.contains(".") else { return nil }
        return url.absoluteString
    }

    struct Trouble: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Lists are text; anything past this is something else.
    static let largest = 50 * 1024 * 1024

    static func read(_ origin: String) async throws -> String {
        let data: Data
        if origin.hasPrefix("/") {
            data = try await Task.detached { try Data(contentsOf: URL(fileURLWithPath: origin)) }.value
        } else {
            guard let url = URL(string: origin) else { throw Trouble("Not an address") }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            request.setValue("text/plain", forHTTPHeaderField: "Accept")
            let (body, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw Trouble("The address answered \(http.statusCode)")
            }
            data = body
        }
        guard data.count <= largest else { throw Trouble("Over 50 MB: not a filter list") }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let start = text.prefix(200).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if start.hasPrefix("<!doctype html") || start.hasPrefix("<html") {
            throw Trouble("A web page came back, not a list")
        }
        return text
    }

    static func say(_ error: Error) -> String {
        if let trouble = error as? Trouble { return trouble.errorDescription ?? "Couldn't update" }
        if (error as NSError).domain == NSCocoaErrorDomain { return "The file can't be read: moved, or gone" }
        return "Couldn't update: \(error.localizedDescription)"
    }

    /// A list's own name and how long it stays good, from the comments at its
    /// top: `! Title: EasyList`, `! Expires: 4 days (update frequency)`.
    static func header(of text: String) -> (title: String?, keeps: TimeInterval?) {
        var title: String?
        var keeps: TimeInterval?
        for line in text.split(separator: "\n", maxSplits: 60).prefix(60) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("!") || line.hasPrefix("#") else { continue }
            let body = line.drop { $0 == "!" || $0 == "#" || $0 == " " }
            if body.lowercased().hasPrefix("title:") {
                let name = body.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { title = String(name.prefix(60)) }
            } else if body.lowercased().hasPrefix("expires:") {
                let words = body.dropFirst(8).split(separator: " ")
                if let count = words.first.flatMap({ Double($0) }), let unit = words.dropFirst().first?.lowercased() {
                    let seconds = unit.hasPrefix("hour") ? count * 3600 : unit.hasPrefix("day") ? count * day : nil
                    // An hour at least, a fortnight at most, whatever it says.
                    keeps = seconds.map { min(max($0, 3600), 14 * day) }
                }
            }
        }
        return (title, keeps)
    }

    static func copy(of id: UUID) -> URL {
        Store.file("Filter Lists").appendingPathComponent("\(id.uuidString).txt")
    }
}
