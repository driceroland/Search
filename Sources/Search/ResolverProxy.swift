import Foundation
import Network

struct DNSSettingsValue: Codable, Equatable {
    enum Provider: String, Codable, CaseIterable, Identifiable {
        case system, cloudflare, google, quad9, adguard, custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return "Mac default"
            case .cloudflare: return "Cloudflare"
            case .google: return "Google"
            case .quad9: return "Quad9"
            case .adguard: return "AdGuard"
            case .custom: return "Custom"
            }
        }

        fileprivate var preset: (url: String, addresses: [String])? {
            switch self {
            case .system, .custom: return nil
            case .cloudflare:
                return ("https://cloudflare-dns.com/dns-query", ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"])
            case .google:
                return ("https://dns.google/dns-query", ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"])
            case .quad9:
                return ("https://dns.quad9.net/dns-query", ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"])
            case .adguard:
                return ("https://dns.adguard-dns.com/dns-query", ["94.140.14.14", "94.140.15.15", "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff"])
            }
        }
    }

    var provider: Provider = .system
    var customURL = ""

    var resolver: (url: URL, addresses: [NWEndpoint])? {
        if let preset = provider.preset, let url = URL(string: preset.url) {
            return (url, preset.addresses.map { .hostPort(host: .init($0), port: .https) })
        }
        guard provider == .custom,
              let url = URL(string: customURL.trimmingCharacters(in: .whitespacesAndNewlines), encodingInvalidCharacters: false),
              url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty,
              url.user() == nil, url.password() == nil, url.fragment() == nil else { return nil }
        return (url, [])
    }

    var validation: String? {
        guard provider == .custom, resolver == nil else { return nil }
        return "Enter an HTTPS DNS URL with a host, without credentials or a fragment."
    }
}

/// WebKit resolves pages in another process. A CONNECT tunnel brings the
/// hostname back to Search, where Network.framework can resolve it with
/// the selected encrypted resolver before opening the TCP connection.
final class ResolverProxy {
    static let loopback = NWEndpoint.Host.ipv4(.loopback)
    private static let headerLimit = 8 * 1024
    private static let headerEnd = Data("\r\n\r\n".utf8)
    private static let username = UUID().uuidString
    private static let password = UUID().uuidString
    static let expectedAuthorization = Data("\(username):\(password)".utf8)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "Search.ResolverProxy")
    // The listener and all its connections call back on this queue.
    private var tunnels: [ObjectIdentifier: Tunnel] = [:]

    let port: NWEndpoint.Port

    init(settings: DNSSettingsValue) throws {
        guard let resolver = settings.resolver else { throw Failure.unavailable }
        let privacy = NWParameters.PrivacyContext(description: "Search DNS")
        privacy.requireEncryptedNameResolution(true, fallbackResolver: .https(resolver.url, serverAddresses: resolver.addresses))

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: Self.loopback, port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        // Publish nothing until the OS has assigned the listener a port.
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        // A listener needs a connection handler before it can start.
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success, let port = listener.port else {
            listener.cancel()
            throw Failure.unavailable
        }
        self.port = port
        listener.newConnectionHandler = { [weak self] client in
            guard let self else { client.cancel(); return }
            let id = ObjectIdentifier(client)
            let tunnel = Tunnel(client: client, privacy: privacy, queue: self.queue) { [weak self] in
                self?.tunnels.removeValue(forKey: id)
            }
            self.tunnels[id] = tunnel
            tunnel.start()
        }
    }

    deinit { listener.cancel() }

    var configuration: ProxyConfiguration {
        let proxy = Self.configuration(port: port)
        proxy.applyCredential(username: Self.username, password: Self.password)
        return proxy
    }

    // If a saved DNS resolver cannot start, keep requests from going direct.
    static func configuration(port: NWEndpoint.Port) -> ProxyConfiguration {
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: loopback, port: port))
        proxy.allowFailover = false
        proxy.excludedDomains = ProxySettingsValue.direct
        return proxy
    }

    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { "Search couldn't start its encrypted DNS proxy." }
    }

    static func parseConnect(_ head: Data) -> (host: String, port: UInt16, auth: Data?)? {
        guard head.count <= headerLimit, head.suffix(headerEnd.count) == headerEnd,
              let text = String(data: head.dropLast(headerEnd.count), encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let request = first.split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[0] == "CONNECT", request[2] == "HTTP/1.1",
              let colon = request[1].lastIndex(of: ":") else { return nil }

        let authority = request[1][..<colon]
        let number = request[1][request[1].index(after: colon)...]
        guard !number.isEmpty, number.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = UInt16(number), port > 0 else { return nil }
        let host: String
        if authority.hasPrefix("["), authority.hasSuffix("]") {
            host = String(authority.dropFirst().dropLast())
            guard IPv6Address(host) != nil else { return nil }
        } else {
            guard !authority.isEmpty, authority.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || $0 == 45 || $0 == 46 || $0 == 95
            }) else { return nil }
            host = String(authority)
        }

        var authorization: Substring?
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":"), separator != line.startIndex,
                  !line.contains(where: { $0 == "\r" || $0 == "\n" }) else { return nil }
            if line[..<separator].lowercased() == "proxy-authorization" {
                guard authorization == nil else { return nil }
                authorization = line[line.index(after: separator)...]
            }
        }
        let fields = authorization?.split(whereSeparator: { $0 == " " || $0 == "\t" })
        let auth: Data?
        if let fields, fields.count == 2, fields[0].lowercased() == "basic" {
            auth = Data(base64Encoded: String(fields[1]))
        } else {
            auth = nil
        }
        return (host, port, auth)
    }

    private final class Tunnel {
        private enum Phase { case headers, connecting, relaying, closing, closed }

        private let client: NWConnection
        private let privacy: NWParameters.PrivacyContext
        private let queue: DispatchQueue
        private let finished: () -> Void
        private var server: NWConnection?
        private var phase = Phase.headers

        init(client: NWConnection, privacy: NWParameters.PrivacyContext, queue: DispatchQueue,
             finished: @escaping () -> Void) {
            self.client = client
            self.privacy = privacy
            self.queue = queue
            self.finished = finished
        }

        deinit {
            client.cancel()
            server?.cancel()
        }

        func start() {
            client.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.close() }
            }
            client.start(queue: queue)
            readHead(Data())
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                if self?.phase == .headers { self?.close() }
            }
        }

        private func readHead(_ buffered: Data) {
            client.receive(minimumIncompleteLength: 1, maximumLength: headerLimit - buffered.count) {
                [weak self] chunk, _, done, error in
                guard let self, self.phase == .headers else { return }
                if error != nil { self.close(); return }
                var bytes = buffered
                if let chunk { bytes.append(chunk) }
                if let end = bytes.range(of: headerEnd) {
                    self.connect(head: Data(bytes[..<end.upperBound]), trailing: Data(bytes[end.upperBound...]))
                } else if bytes.count == headerLimit || done {
                    self.reject("400 Bad Request")
                } else {
                    self.readHead(bytes)
                }
            }
        }

        private func connect(head: Data, trailing: Data) {
            guard let request = parseConnect(head), let port = NWEndpoint.Port(rawValue: request.port) else {
                reject("400 Bad Request")
                return
            }
            guard request.auth == expectedAuthorization else {
                reject("407 Proxy Authentication Required", header: "Proxy-Authenticate: Basic realm=\"Search DNS\"\r\n")
                return
            }

            let parameters = NWParameters.tcp
            parameters.setPrivacyContext(privacy)
            let server = NWConnection(host: .init(request.host), port: port, using: parameters)
            self.server = server
            phase = .connecting
            server.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready where self.phase == .connecting: self.established(trailing: trailing)
                case .failed where self.phase == .connecting: self.reject("502 Bad Gateway")
                case .failed where self.phase == .relaying: self.close()
                default: break
                }
            }
            server.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                if self?.phase == .connecting { self?.reject("502 Bad Gateway") }
            }
        }

        private func established(trailing: Data) {
            guard let server else { close(); return }
            phase = .relaying
            client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),
                        completion: .contentProcessed { [weak self] error in
                guard let self, self.phase == .relaying else { return }
                guard error == nil else { self.close(); return }
                self.pipe(from: server, to: self.client)
                self.forward(trailing, from: self.client, to: server, done: false)
            })
        }

        private func pipe(from source: NWConnection, to destination: NWConnection) {
            source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [weak self] data, _, done, error in
                guard let self, self.phase == .relaying else { return }
                guard error == nil else { self.close(); return }
                self.forward(data, from: source, to: destination, done: done)
            }
        }

        // Wait for each write before reading more, so a slow peer cannot
        // leave unbounded data queued between the two connections.
        private func forward(_ data: Data?, from source: NWConnection, to destination: NWConnection, done: Bool) {
            guard let data, !data.isEmpty else {
                if done { close() } else { pipe(from: source, to: destination) }
                return
            }
            destination.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, self.phase == .relaying else { return }
                if done || error != nil { self.close() } else { self.pipe(from: source, to: destination) }
            })
        }

        private func reject(_ status: String, header: String = "") {
            phase = .closing
            let response = "HTTP/1.1 \(status)\r\n\(header)Content-Length: 0\r\nConnection: close\r\n\r\n"
            client.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
                self?.close()
            })
        }

        private func close() {
            guard phase != .closed else { return }
            phase = .closed
            client.cancel()
            server?.cancel()
            finished()
        }
    }
}
