import AppKit
import UniformTypeIdentifiers
import WebKit

/// The Network panel's tools beyond the request list: request blocking,
/// the extra columns' data, page load marks, WebSocket messages, HAR
/// export and import, search across requests, replay and throttling
/// profiles. State lives in the inspector frontend (`searchNetwork`).
@MainActor
final class DeveloperNetworkTools: ObservableObject {
    private weak var session: DeveloperToolsSession?

    /// What the list's extra columns and filter keys read for a request.
    struct Extra: Equatable {
        var networkProtocol: String?
        var priority: String?
        var remoteAddress: String?
        var connection: String?
        var resourceSize: Int?
        var source: String?
        var requestHeaders: [String] = []
        var requestHeaderValues: [String: String] = [:]
        var responseHeaders: [String] = []
        /// The response headers' values by lowercased name, for the list's
        /// header columns.
        var responseHeaderValues: [String: String] = [:]
        /// Where the request was started from: the line WebKit reports with
        /// the initiator, and its call stack when a script made it.
        var initiatorLine: Int?
        var initiatorStack: [DeveloperRequestDetails.StackFrame] = []
        var cookies: [String] = []
        var setCookies: [String] = []
        var setCookieDomains: [String] = []
        /// The request's cookies with their values, and the domain and path
        /// the cookie jar keeps them under once looked up.
        var requestCookies: [Cookie] = []
        /// Whether `requestCookies` has been matched against the cookie jar.
        var requestCookiesResolved = true
        /// The cookies the response's Set-Cookie headers set.
        var responseCookies: [Cookie] = []
        var blocked = false
        /// Milliseconds a Request conditions row held the request for.
        var throttled: Double?
        /// Answered with Local Overrides' headers (DeveloperHeaderOverrides).
        var overridden = false
        /// Answered from a file in the Local Overrides folder.
        var contentFileOverridden = false
        /// Served with overrides: content, headers, or both, as Chrome's purple dot shows.
        var servedWithOverrides: Bool { overridden || source == "inspector-override" }
        /// The body came from Local Overrides.
        var overriddenContent: Bool { contentFileOverridden || (source == "inspector-override" && !overridden) }
        /// Headers came from a `.headers` file in Local Overrides.
        var overriddenHeaders: Bool { overridden }
        var frames = 0
        /// WebKit's ResourceTiming: fetchStart and startTime in seconds,
        /// the rest in milliseconds after fetchStart (-1 when absent).
        var timing: [String: Double] = [:]
    }

    /// One cookie as the cookie filters read it.
    struct Cookie: Equatable {
        var name: String
        var value: String
        var domain = ""
        var path = ""

        init(name: String, value: String, domain: String = "", path: String = "") {
            self.name = name
            self.value = value
            self.domain = domain
            self.path = path
        }

        init?(row: [String: Any]) {
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            self.init(name: name, value: row["value"] as? String ?? "", domain: row["domain"] as? String ?? "",
                      path: row["path"] as? String ?? "")
        }

        /// The domain and path the jar keeps each request cookie under: the
        /// jar's cookie of that name that the address would be sent, the most
        /// specific path first, as the browser picks what to send.
        static func resolve(_ cookies: [Cookie], url: String,
                            jar: [(name: String, domain: String, path: String)]) -> [Cookie] {
            guard let address = URLComponents(string: url), let host = address.host?.lowercased() else { return cookies }
            let path = address.percentEncodedPath.isEmpty ? "/" : address.percentEncodedPath
            return cookies.map { cookie in
                let candidates = jar.filter { stored in
                    guard stored.name == cookie.name else { return false }
                    var domain = stored.domain.lowercased()
                    if domain.hasPrefix(".") { domain.removeFirst() }
                    guard !domain.isEmpty, host == domain || host.hasSuffix("." + domain) else { return false }
                    let cookiePath = stored.path.isEmpty ? "/" : stored.path
                    return path.hasPrefix(cookiePath)
                }
                guard let best = candidates.max(by: { left, right in
                    left.path.count == right.path.count
                        ? left.domain.count < right.domain.count : left.path.count < right.path.count
                }) else { return cookie }
                var resolved = cookie
                resolved.domain = best.domain
                resolved.path = best.path.isEmpty ? "/" : best.path
                return resolved
            }
        }
    }

    /// One row of Request conditions: a pattern and what happens to the
    /// requests it matches, blocked or delayed by a throttling profile.
    struct BlockPattern: Codable, Identifiable, Equatable {
        var id = UUID()
        var pattern: String
        var enabled = true
        /// The throttling the row applies instead of blocking: a preset's
        /// name (`NetworkCondition.rawValue`) or a custom profile's id. Nil
        /// blocks, as rows saved before per-request throttling did.
        var throttling: String?

        init(pattern: String, enabled: Bool = true, throttling: String? = nil) {
            self.pattern = pattern
            self.enabled = enabled
            self.throttling = throttling
        }
    }

    /// What a Request conditions row does to a matching request.
    enum RequestCondition: Equatable {
        case block
        /// Held for this many milliseconds, then sent.
        case delay(Double)
        /// The row's profile no longer exists or adds no latency.
        case ignored
    }

    /// The presets a row can throttle with, as Chrome's Request conditions
    /// lists them; Offline is the same as blocking.
    static let conditionPresets: [DeveloperToolsSession.NetworkCondition] = [.fast4G, .slow4G, .threeG]

    /// What `item` does, with custom profiles looked up by id.
    static func condition(of item: BlockPattern, profiles: [ThrottlingProfile]) -> RequestCondition {
        guard let throttling = item.throttling else { return .block }
        let latency: Double
        if let preset = DeveloperToolsSession.NetworkCondition(rawValue: throttling) {
            if preset == .offline { return .block }
            latency = preset.latency
        } else if let profile = profiles.first(where: { $0.id.uuidString == throttling }) {
            latency = profile.latency
        } else {
            return .ignored
        }
        return latency > 0 ? .delay(min(5_000, latency)) : .ignored
    }

    /// The name a row's condition shows: Block, a preset or a profile.
    static func conditionName(of item: BlockPattern, profiles: [ThrottlingProfile]) -> String {
        guard let throttling = item.throttling else { return "Block" }
        if let preset = DeveloperToolsSession.NetworkCondition(rawValue: throttling) {
            return preset == .offline ? "Block" : preset.rawValue
        }
        return profiles.first { $0.id.uuidString == throttling }?.name ?? "Removed profile"
    }

    /// The options `searchNetwork.setBlocking` takes: blocked patterns and
    /// delayed ones, enabled rows only, in the list's order.
    static func blockingOptions(enabled: Bool, patterns: [BlockPattern],
                                profiles: [ThrottlingProfile]) -> [String: Any] {
        var blocked: [String] = []
        var throttled: [[String: Any]] = []
        for item in patterns where item.enabled {
            switch condition(of: item, profiles: profiles) {
            case .block: blocked.append(item.pattern)
            case .delay(let latency): throttled.append(["pattern": item.pattern, "latency": latency])
            case .ignored: break
            }
        }
        return ["enabled": enabled, "patterns": blocked, "throttled": throttled]
    }

    /// A Custom profile, as in Chrome's Settings › Throttling.
    struct ThrottlingProfile: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        /// kbit/s; 0 means no limit.
        var download: Double
        var upload: Double
        /// Milliseconds.
        var latency: Double
    }

    struct Frame: Identifiable, Equatable {
        enum Kind: String { case sent, received, error }
        let id: Int
        let kind: Kind
        let opcode: Int?
        let data: String
        let length: Int
        let time: Double?
        var eventID: String?
        var eventType: String?
        var binary: Bool { opcode == 2 }
        var control: Bool { (opcode ?? 1) >= 8 }
    }

    struct SearchHit: Identifiable, Equatable {
        let id = UUID()
        let request: String
        let place: String
        let line: Int
        let text: String
    }

    @Published private(set) var extras: [String: Extra] = [:] {
        didSet { extrasRevision &+= 1 }
    }
    /// Bumped on every change to `extras`, so the list can tell cheaply
    /// whether its cached rows still hold.
    private(set) var extrasRevision = 0
    @Published private(set) var domContentLoaded: Double?
    @Published private(set) var load: Double?
    @Published private(set) var blockingActive = false
    @Published var blockingEnabled = DevDefaults.store.object(forKey: blockingKey) as? Bool ?? true {
        didSet {
            DevDefaults.store.set(blockingEnabled, forKey: Self.blockingKey)
            syncBlocking()
        }
    }
    @Published var blockPatterns: [BlockPattern] = DeveloperNetworkTools.saved(patternsKey) ?? [] {
        didSet {
            Self.save(blockPatterns, Self.patternsKey)
            syncBlocking()
        }
    }
    @Published var profiles: [ThrottlingProfile] = DeveloperNetworkTools.saved(profilesKey) ?? [] {
        didSet {
            Self.save(profiles, Self.profilesKey)
            if blockPatterns.contains(where: { $0.throttling != nil }) { syncBlocking() }
        }
    }
    /// Nil uses WebKit's defaults; an empty selection requests identity.
    @Published var acceptedEncodings: Set<ContentEncoding>? {
        didSet { if acceptedEncodings != oldValue { syncBlocking() } }
    }
    @Published var disabledImageFormats: Set<ImageFormat> = [] {
        didSet { if disabledImageFormats != oldValue { syncBlocking() } }
    }

    enum ContentEncoding: String, CaseIterable, Identifiable {
        case deflate, gzip, br, zstd
        var id: Self { self }
    }

    enum ImageFormat: String, CaseIterable, Identifiable {
        case avif = "image/avif"
        case jpegXL = "image/jxl"
        case webP = "image/webp"

        var id: Self { self }

        var title: String {
            switch self {
            case .avif: "AVIF"
            case .jpegXL: "JPEG XL"
            case .webP: "WebP"
            }
        }
    }

    static func acceptEncoding(_ encodings: Set<ContentEncoding>?) -> String? {
        guard let encodings else { return nil }
        let names = ContentEncoding.allCases.filter(encodings.contains).map(\.rawValue)
        return names.isEmpty ? "identity" : names.joined(separator: ", ")
    }

    @Published private(set) var activeProfile: ThrottlingProfile.ID?
    /// Whether `Network.setEmulatedConditions` exists in this WebKit.
    @Published private(set) var bandwidthThrottling = false
    @Published var message: String?
    /// The page's frames, read for Group by frame.
    @Published private(set) var frames: [DeveloperToolsSession.ResourceFrame] = []
    var imported: [String: DeveloperRequestDetails] = [:]
    private var importedFrames: [String: [Frame]] = [:]
    /// Capture screenshots' frames, observed by the filmstrip alone so a
    /// new screenshot doesn't redraw the list.
    let filmstrip: DeveloperNetworkFilmstrip

    private static let blockingKey = "developerTools.network.blockingEnabled"
    private static let patternsKey = "developerTools.network.blockedPatterns"
    private static let profilesKey = "developerTools.network.throttlingProfiles"
    private var version = 0
    private var installed = false
    private var bandwidthApplied = false
    private var pendingInterception: Task<Void, Never>?

    init(session: DeveloperToolsSession) {
        self.session = session
        filmstrip = DeveloperNetworkFilmstrip()
    }

    private static func saved<Value: Decodable>(_ key: String) -> Value? {
        guard let data = DevDefaults.store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private static func save<Value: Encodable>(_ value: Value, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { DevDefaults.store.set(data, forKey: key) }
    }

    private func call(_ source: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        guard let session, session.ready else { throw ToolError.unavailable }
        if !installed {
            let ready = try await session.networkBridge("return " + DeveloperNetworkBridgeScript.source + ";")
            guard ready as? Bool == true else { throw ToolError.unavailable }
            installed = true
            _ = try? await session.networkBridge("return await searchNetwork.setBlocking(options);",
                                                 ["options": blockingOptions])
            if let state = try? await session.networkBridge("return searchNetwork.emulation();") as? [String: Any] {
                bandwidthThrottling = state["supported"] as? Bool == true
            }
        }
        return try await session.networkBridge(source, arguments)
    }

    // MARK: Polling

    /// Reads what changed since the last call: column data, blocked
    /// requests and the page's DOMContentLoaded and load times.
    func poll() async {
        guard let state = try? await call("return searchNetwork.state(since);", ["since": version]) as? [String: Any]
        else { return }
        version = state["version"] as? Int ?? version
        let page = state["page"] as? [String: Any]
        let ready = page?["domContentLoaded"] as? Double
        let loaded = page?["load"] as? Double
        if ready != domContentLoaded { domContentLoaded = ready }
        if loaded != load { load = loaded }
        let active = state["blockingActive"] as? Bool == true
        if active != blockingActive { blockingActive = active }
        let rows = state["rows"] as? [[String: Any]] ?? []
        guard !rows.isEmpty else { return }
        var next = extras
        var changed = false
        for row in rows {
            guard let id = row["id"] as? String else { continue }
            let previous = next[id]
            var extra = previous ?? Extra()
            extra.networkProtocol = row["protocol"] as? String ?? extra.networkProtocol
            extra.priority = row["priority"] as? String ?? extra.priority
            extra.remoteAddress = row["remoteAddress"] as? String ?? extra.remoteAddress
            extra.connection = row["connectionIdentifier"] as? String ?? extra.connection
            extra.resourceSize = row["decoded"] as? Int ?? extra.resourceSize
            extra.source = row["source"] as? String ?? extra.source
            extra.requestHeaders = row["requestHeaders"] as? [String] ?? extra.requestHeaders
            extra.requestHeaderValues = row["requestHeaderValues"] as? [String: String] ?? extra.requestHeaderValues
            extra.responseHeaders = row["responseHeaders"] as? [String] ?? extra.responseHeaders
            extra.responseHeaderValues = row["responseHeaderValues"] as? [String: String] ?? extra.responseHeaderValues
            extra.initiatorLine = row["initiatorLine"] as? Int ?? extra.initiatorLine
            if let stack = row["initiatorStack"] as? [[String: Any]] {
                extra.initiatorStack = stack.map(DeveloperRequestDetails.StackFrame.init)
            }
            extra.cookies = row["cookies"] as? [String] ?? extra.cookies
            if let cookies = row["setCookies"] as? [[String: Any]] {
                extra.setCookies = cookies.compactMap { $0["name"] as? String }
                extra.setCookieDomains = cookies.compactMap { $0["domain"] as? String }.filter { !$0.isEmpty }
                extra.responseCookies = cookies.compactMap(Cookie.init(row:))
            }
            if let cookies = row["requestCookies"] as? [[String: Any]] {
                let parsed = cookies.compactMap(Cookie.init(row:))
                let known = extra.requestCookies.map { Cookie(name: $0.name, value: $0.value) }
                if parsed != known {
                    extra.requestCookies = parsed
                    extra.requestCookiesResolved = parsed.isEmpty
                }
            }
            extra.blocked = extra.blocked || row["blocked"] as? Bool == true
            extra.throttled = row["throttled"] as? Double ?? extra.throttled
            extra.overridden = extra.overridden || row["overridden"] as? Bool == true
            if extra.source == "inspector-override", !extra.contentFileOverridden,
               let url = session?.requests.last(where: { $0.id == id })?.url {
                extra.contentFileOverridden = DeveloperLocalOverrides.shared.isOverridden(url)
            }
            extra.frames = row["frames"] as? Int ?? extra.frames
            if let timing = row["timing"] as? [String: Double] { extra.timing = timing }
            if extra != previous {
                next[id] = extra
                changed = true
            }
        }
        // The Cookie header has no domain or path: the jar has them, read
        // once for every request whose cookies are new.
        let unresolved = next.filter { !$0.value.requestCookiesResolved }.map(\.key)
        if !unresolved.isEmpty, let store = session?.web?.configuration.websiteDataStore.httpCookieStore {
            let jar = await store.allCookies().map { (name: $0.name, domain: $0.domain, path: $0.path) }
            let urls = Dictionary((session?.requests ?? []).map { ($0.id, $0.url) }, uniquingKeysWith: { _, last in last })
            for id in unresolved {
                guard var extra = next[id] else { continue }
                if let url = urls[id] { extra.requestCookies = Cookie.resolve(extra.requestCookies, url: url, jar: jar) }
                extra.requestCookiesResolved = true
                next[id] = extra
            }
            changed = true
        }
        if next.count > 1_500 {
            let live = Set(session?.requests.map(\.id) ?? [])
            let kept = next.filter { live.contains($0.key) }
            if kept.count != next.count {
                next = kept
                changed = true
            }
        }
        // Only a real change republishes, which rebuilds the Network list.
        if changed { extras = next }
    }

    /// Reads the frame tree, for the names Group by frame shows.
    func loadFrames() async {
        guard let session, session.ready,
              let result = try? await session.command("Page.getResourceTree"),
              let tree = result["frameTree"] as? [String: Any] else { return }
        let list = DeveloperNetworkFrameGroups.frames(in: tree)
        if list != frames { frames = list }
    }

    func clear() {
        extras = [:]
        imported = [:]
        importedFrames = [:]
        domContentLoaded = nil
        load = nil
        Task { _ = try? await call("searchNetwork.clear(); return true;") }
    }

    // MARK: Request blocking

    var blockingOptions: [String: Any] {
        var options = Self.blockingOptions(enabled: blockingEnabled, patterns: blockPatterns, profiles: profiles)
        options["acceptEncoding"] = Self.acceptEncoding(acceptedEncodings) ?? NSNull()
        options["disabledImageTypes"] = disabledImageFormats.map(\.rawValue).sorted()
        return options
    }

    private func syncBlocking() {
        let previous = pendingInterception
        pendingInterception = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let result = try await call("return await searchNetwork.setBlocking(options);", ["options": blockingOptions])
                blockingActive = (result as? [String: Any])?["active"] as? Bool == true
            } catch ToolError.unavailable {
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func waitForInterceptionSettings() async {
        await pendingInterception?.value
    }

    func pattern(_ text: String) -> BlockPattern? {
        blockPatterns.first { $0.pattern == text }
    }

    func toggleBlock(_ text: String) {
        if let index = blockPatterns.firstIndex(where: { $0.pattern == text }) {
            blockPatterns.remove(at: index)
        } else {
            blockPatterns.append(BlockPattern(pattern: text))
            blockingEnabled = true
        }
    }

    func addPattern(_ text: String) -> String? {
        let pattern = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern.isEmpty { return "Pattern input can’t be empty" }
        if blockPatterns.contains(where: { $0.pattern == pattern }) { return "Pattern already exists" }
        blockPatterns.append(BlockPattern(pattern: pattern))
        return nil
    }

    /// Chrome's "Block request URL": a URL Pattern for the whole address.
    static func urlPattern(for address: String) -> String? {
        guard let url = URLComponents(string: address), let host = url.host, !host.isEmpty else { return nil }
        var pattern = "*://" + escapeForURLPattern(host)
        if let port = url.port { pattern += ":\(port)" }
        pattern += escapeForURLPattern(url.percentEncodedPath)
        if let query = url.percentEncodedQuery { pattern += "?" + escapeForURLPattern(query) }
        if let fragment = url.percentEncodedFragment { pattern += "#" + escapeForURLPattern(fragment) }
        return pattern
    }

    /// Chrome's "Block request domain".
    static func domainPattern(for address: String) -> String? {
        guard let url = URLComponents(string: address), let host = url.host, !host.isEmpty else { return nil }
        return "*://" + escapeForURLPattern(host) + (url.port.map { ":\($0)" } ?? "")
    }

    static func escapeForURLPattern(_ text: String) -> String {
        var result = ""
        for character in text {
            if "?+*(){}\\:".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    // MARK: Throttling

    /// Presets with the bandwidth Chromium gives them, where WebKit can
    /// pace bytes; latency stays with request interception either way.
    func apply(_ condition: DeveloperToolsSession.NetworkCondition) {
        activeProfile = nil
        session?.setNetwork(condition)
        let bandwidth: Double = switch condition {
        case .fast4G: 9 * 1_000 * 1_000 / 8 * 0.9
        case .slow4G: 1.6 * 1_000 * 1_000 / 8 * 0.9
        case .threeG: 500 * 1_000 / 8 * 0.8
        default: 0
        }
        emulate(bandwidth: bandwidth)
    }

    func apply(_ profile: ThrottlingProfile) {
        guard let session else { return }
        session.setNetwork(.unrestricted)
        activeProfile = profile.id
        Task {
            do {
                if profile.latency > 0 {
                    _ = try await call("return await searchInspector.networkConditions(options);", [
                        "options": ["latency": min(5_000, max(0, profile.latency)), "offline": false],
                    ])
                }
                emulate(bandwidth: profile.download * 1_000 / 8)
            } catch {
                activeProfile = nil
                message = error.localizedDescription
            }
        }
    }

    var activeProfileName: String? {
        activeProfile.flatMap { id in profiles.first { $0.id == id }?.name }
    }

    private func emulate(bandwidth: Double) {
        guard bandwidthThrottling, bandwidth > 0 || bandwidthApplied else { return }
        Task {
            do {
                _ = try await call("return await searchNetwork.emulate(options);",
                                   ["options": ["bandwidth": bandwidth, "latency": 0]])
                bandwidthApplied = bandwidth > 0
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Checked when the menu opens; the frontend may not be ready earlier.
    func probeBandwidth() async {
        if let state = try? await call("return searchNetwork.emulation();") as? [String: Any] {
            bandwidthThrottling = state["supported"] as? Bool == true
        }
    }

    // MARK: WebSocket and EventSource messages

    func frames(for id: String, after count: Int) async -> (count: Int, frames: [Frame]) {
        if let retained = importedFrames[id] { return (retained.count, Array(retained.dropFirst(max(0, count)))) }
        guard let raw = try? await call("return searchNetwork.frames(id, after);", ["id": id, "after": count])
            as? [String: Any] else { return (count, []) }
        let list = raw["frames"] as? [[String: Any]] ?? []
        let frames = list.enumerated().map { offset, item in
            Frame(id: count + offset, kind: Frame.Kind(rawValue: item["type"] as? String ?? "") ?? .received,
                  opcode: item["opcode"] as? Int, data: item["data"] as? String ?? "",
                  length: item["length"] as? Int ?? 0, time: item["time"] as? Double)
        }
        return (raw["count"] as? Int ?? count + frames.count, frames)
    }

    /// EventSource messages that arrived in a burst too large to record.
    func droppedMessages(for id: String) -> Int {
        0
    }

    // MARK: Search

    func search(_ query: String, in requests: [DeveloperToolsSession.Request], caseSensitive: Bool,
                regex: Bool) async -> [SearchHit] {
        guard !query.isEmpty else { return [] }
        var hits: [SearchHit] = []
        let live = requests.filter { imported[$0.id] == nil }.map(\.id)
        let found = (try? await call("return await searchNetwork.search(ids, query, options);", [
            "ids": live, "query": query, "options": ["caseSensitive": caseSensitive, "regex": regex],
        ]) as? [[String: Any]]) ?? []
        for result in found {
            guard let id = result["id"] as? String else { continue }
            for hit in result["hits"] as? [[String: Any]] ?? [] {
                hits.append(SearchHit(request: id, place: hit["where"] as? String ?? "",
                                      line: hit["line"] as? Int ?? 1, text: hit["text"] as? String ?? ""))
            }
        }
        // Imported requests are searched here, with the same rules.
        let pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
        if let expression = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) {
            for request in requests {
                guard let details = imported[request.id] else { continue }
                for (place, text) in DeveloperNetworkSearch.fields(details) {
                    for (index, line) in text.components(separatedBy: .newlines).enumerated()
                    where expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                        hits.append(SearchHit(request: request.id, place: place, line: index + 1,
                                              text: String(line.prefix(300))))
                    }
                }
            }
        }
        return hits
    }

    // MARK: HAR

    /// The listed requests as a HAR log, built by WebKit's own
    /// WI.HARBuilder where the frontend still holds the resource.
    func har(for requests: [DeveloperToolsSession.Request], sanitize: Bool) async -> Data? {
        guard let session else { return nil }
        let ids = requests.map(\.id)
        var built: [String: [String: Any]] = [:]
        var log: [String: Any] = ["version": "1.2", "creator": ["name": "Search", "version": "1.0"], "pages": []]
        if let raw = try? await call("return await searchNetwork.har(ids);", ["ids": ids.filter { imported[$0] == nil }])
            as? [String: Any],
           let text = raw["archive"] as? String, let data = text.data(using: .utf8),
           let archive = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var archived = archive["log"] as? [String: Any] {
            for entry in archived["entries"] as? [[String: Any]] ?? [] {
                guard let id = entry["_requestId"] as? String else { continue }
                var entry = entry
                entry.removeValue(forKey: "_requestId")
                built[id] = entry
            }
            archived.removeValue(forKey: "entries")
            log.merge(archived) { $1 }
        }
        let clock = requests.compactMap { $0.ended ?? $0.started }.max() ?? 0
        var entries: [[String: Any]] = []
        var messageBytesRemaining = 4 * 1024 * 1024
        for request in requests {
            var entry: [String: Any]
            if let archived = built[request.id] {
                entry = archived
            } else if let details = await session.requestDetails(request.id) {
                entry = DeveloperHAR.entry(request, details: details, clock: clock)
            } else { continue }
            if !sanitize, request.type == "WebSocket", messageBytesRemaining > 0 {
                let messages = await frames(for: request.id, after: 0).frames.prefix(200).prefix { frame in
                    messageBytesRemaining -= frame.data.utf8.count
                    return messageBytesRemaining >= 0
                }
                if !messages.isEmpty { entry["_webSocketMessages"] = DeveloperHAR.socketMessages(Array(messages)) }
            }
            entries.append(sanitize ? DeveloperHAR.sanitized(entry) : entry)
        }
        log["entries"] = entries
        return try? JSONSerialization.data(withJSONObject: ["log": log],
                                           options: [.prettyPrinted, .withoutEscapingSlashes])
    }

    func exportHAR(_ requests: [DeveloperToolsSession.Request], sanitize: Bool, host: String) {
        Task {
            guard let data = await har(for: requests, sanitize: sanitize) else {
                NSSound.beep()
                return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = (host.isEmpty ? "Archive" : host) + ".har"
            panel.allowedContentTypes = [UTType(filenameExtension: "har") ?? .json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { try data.write(to: url) } catch { message = error.localizedDescription }
        }
    }

    /// Copy all as HAR, sanitized (without cookies and authorization
    /// headers) unless asked for the sensitive data too, as Chrome's pair.
    func copyHAR(_ requests: [DeveloperToolsSession.Request], sanitize: Bool = true) {
        Task {
            guard let data = await har(for: requests, sanitize: sanitize), let text = String(data: data, encoding: .utf8)
            else { return }
            Self.copy(text)
        }
    }

    /// Save as…: the response body as it came, named after the request.
    func saveResponse(_ request: DeveloperToolsSession.Request) {
        Task {
            guard let details = await session?.requestDetails(request.id), let data = details.bodyData else {
                NSSound.beep()
                return
            }
            let panel = NSSavePanel()
            let name = URL(string: request.url)?.lastPathComponent ?? ""
            panel.nameFieldStringValue = name.isEmpty || name == "/" ? "download" : name
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { try data.write(to: url) } catch { message = error.localizedDescription }
        }
    }

    func importHAR() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "har") ?? .json, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try importHAR(Data(contentsOf: url))
        } catch {
            message = "This file isn’t a HAR log: " + error.localizedDescription
        }
    }

    /// Imported requests replace the list, as one log on one clock.
    func importHAR(_ data: Data) throws {
        guard let session else { return }
        let log = try DeveloperHAR.read(data)
        session.clearNetwork()
        clear()
        var extra = extras
        for item in log {
            imported[item.request.id] = item.details
            if !item.frames.isEmpty { importedFrames[item.request.id] = item.frames }
            var row = item.extra
            for header in item.details.requestHeaders {
                let name = header.name.lowercased()
                if Self.showsRequestHeader(name), row.requestHeaderValues[name] == nil {
                    row.requestHeaderValues[name] = String(header.value.prefix(300))
                }
            }
            for header in item.details.responseHeaders where row.responseHeaderValues[header.name.lowercased()] == nil {
                row.responseHeaderValues[header.name.lowercased()] = header.value
            }
            extra[item.request.id] = row
        }
        extras = extra
        session.addImportedRequests(log.map(\.request))
    }

    private static func showsRequestHeader(_ name: String) -> Bool {
        !["cookie", "authorization", "proxy-authorization"].contains(name)
    }

    var requestHeaderNames: [String] {
        Set(extras.values.flatMap { $0.requestHeaderValues.keys }).sorted()
    }

    // MARK: Request actions

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copy(_ request: DeveloperToolsSession.Request, as format: @escaping (DeveloperRequestDetails) -> String) {
        Task {
            guard let details = await session?.requestDetails(request.id) else { return }
            Self.copy(format(details))
        }
    }

    func copyAll(_ requests: [DeveloperToolsSession.Request], separator: String,
                 as format: @escaping (DeveloperRequestDetails) -> String) {
        Task {
            var commands: [String] = []
            for request in requests where !request.url.hasPrefix("blob:") {
                if let details = await session?.requestDetails(request.id) { commands.append(format(details)) }
            }
            Self.copy(commands.joined(separator: separator))
        }
    }

    func copyResponse(_ request: DeveloperToolsSession.Request) {
        copy(request) { $0.bodyText ?? $0.body ?? "" }
    }

    func openInNewTab(_ request: DeveloperToolsSession.Request) {
        guard let url = URL(string: request.url) else { return }
        DevHost.open(url)
    }

    /// Sends the request again from the page's origin, in its own world,
    /// as Replay XHR does.
    func replay(_ request: DeveloperToolsSession.Request) {
        Task {
            guard let session, let web = session.web, let details = await session.requestDetails(request.id) else { return }
            let options = DeveloperRequestCopy.replayOptions(details)
            do {
                _ = try await web.callAsyncJavaScript("""
                    try { await fetch(url, options); } catch {}
                    return true;
                    """, arguments: ["url": details.url, "options": options], in: nil,
                    contentWorld: DevHost.world)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func clearBrowserCache() {
        confirm("Are you sure you want to clear browser cache?") { store in
            await store.removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                             WKWebsiteDataTypeFetchCache], modifiedSince: .distantPast)
        }
    }

    func clearBrowserCookies() {
        confirm("Are you sure you want to clear browser cookies?") { store in
            await store.removeData(ofTypes: [WKWebsiteDataTypeCookies], modifiedSince: .distantPast)
        }
    }

    private func confirm(_ question: String, _ action: @escaping @MainActor (WKWebsiteDataStore) async -> Void) {
        guard let store = session?.web?.configuration.websiteDataStore else { return }
        let alert = NSAlert()
        alert.messageText = question
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await action(store) }
    }

    private enum ToolError: LocalizedError {
        case unavailable
        var errorDescription: String? { "The page’s inspector isn’t ready." }
    }
}

enum DeveloperNetworkSearch {
    /// Where ⌘F looks in one request, with the label each match shows.
    static func fields(_ details: DeveloperRequestDetails) -> [(String, String)] {
        var fields = [("url", details.url)]
        fields += details.requestHeaders.map { ("request header", $0.name + ": " + $0.value) }
        fields += details.responseHeaders.map { ("response header", $0.name + ": " + $0.value) }
        if let post = details.postData { fields.append(("payload", post)) }
        if let body = details.bodyText { fields.append(("response", String(body.prefix(1_048_576)))) }
        return fields
    }
}
