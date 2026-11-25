import Foundation
import Network
import XCTest
@testable import Search

/// chrome.proxy.settings as Search follows it (ExtensionProxy.swift): the
/// rules read from what an extension set, its PAC script run, and the relay
/// that every store is pointed at while an extension holds the proxy.
final class ExtensionProxyTests: XCTestCase {

    // MARK: - rules

    func testPACAnswersAreReadInOrderAndWhatCantBeFollowedIsSkipped() {
        XCTAssertEqual(ProxyRoute.parse(pac: "PROXY 127.0.0.1:8080; SOCKS5 proxy.example:1080; DIRECT"),
                       [.http("127.0.0.1", 8080), .socks5("proxy.example", 1080), .direct])
        XCTAssertEqual(ProxyRoute.parse(pac: "HTTPS secure.example:443; PROXY [::1]:3128"), [.http("::1", 3128)])
        XCTAssertEqual(ProxyRoute.parse(pac: "SOCKS socks.example"), [.socks5("socks.example", 1080)])
        XCTAssertEqual(ProxyRoute.parse(pac: "QUIC q.example:443"), [], "nothing usable is no way out, not direct")
        XCTAssertEqual(ProxyRoute.parse(pac: "PROXY bad:port"), [])
    }

    func testSystemAndAutoDetectLeaveTheProxyToSearch() throws {
        XCTAssertNil(try ExtensionProxyRules.read(["mode": "system"]))
        XCTAssertNil(try ExtensionProxyRules.read(["mode": "auto_detect"]))
        XCTAssertNil(try ExtensionProxyRules.read(nil))
    }

    func testWhatCantBeFollowedIsRefusedWhenSet() {
        XCTAssertThrowsError(try ExtensionProxyRules.read(["mode": "pac_script", "pacScript": ["url": "https://example.com/proxy.pac"]]))
        XCTAssertThrowsError(try ExtensionProxyRules.read(["mode": "fixed_servers", "rules": ["singleProxy": ["scheme": "quic", "host": "q"]]]))
        XCTAssertThrowsError(try ExtensionProxyRules.read(["mode": "fixed_servers", "rules": [:]]))
        XCTAssertThrowsError(try ExtensionProxyRules.read(["mode": "nonsense"]))
    }

    func testFixedServersWithBypassList() async throws {
        let rules = try XCTUnwrap(try ExtensionProxyRules.read([
            "mode": "fixed_servers",
            "rules": [
                "proxyForHttps": ["scheme": "socks5", "host": "s.example", "port": 1081],
                "proxyForHttp": ["host": "h.example", "port": 3128],
                "bypassList": ["<local>", "*.corp.example", "10.0.0.0/8", "intranet.example:8080"],
            ],
        ]))
        var routes = await rules.routes(url: "https://news.example/", host: "news.example")
        XCTAssertEqual(routes, [.socks5("s.example", 1081)])
        routes = await rules.routes(url: "http://news.example/", host: "news.example")
        XCTAssertEqual(routes, [.http("h.example", 3128)])
        for host in ["printer", "a.corp.example", "corp.example", "10.1.2.3", "intranet.example"] {
            routes = await rules.routes(url: "https://\(host)/", host: host)
            XCTAssertEqual(routes, [.direct], host)
        }
        routes = await rules.routes(url: "https://11.1.2.3/", host: "11.1.2.3")
        XCTAssertEqual(routes, [.socks5("s.example", 1081)])
    }

    /// What Tailchrome sets while its helper's sign-in is still to come:
    /// everything to a port nothing listens on, but its probe to the helper.
    static let tailchrome = #"""
    function FindProxyForURL(url, host) {
      if (host === "tailchrome-proxy-auth.invalid") return "PROXY 127.0.0.1:62351";
      host = host.toLowerCase().replace(/\.$/, "");
      if (host.charAt(0) === "[" && host.charAt(host.length - 1) === "]") host = host.slice(1, -1);
      var proxy = "PROXY 127.0.0.1:1";
      var isIPv4 = /^\d{1,3}(?:\.\d{1,3}){3}$/.test(host);
      if (dnsDomainIs(host, ".tail0000.ts.net") || host === "tail0000.ts.net") return proxy;
      if (isIPv4 && isInNet(host, "100.64.0.0", "255.192.0.0")) return proxy;
      return "DIRECT";
    }
    """#

    func testTailchromesPACScript() async throws {
        let rules = try XCTUnwrap(try ExtensionProxyRules.read(["mode": "pac_script", "pacScript": ["data": Self.tailchrome, "mandatory": true]]))
        XCTAssertTrue(rules.mandatory)
        var routes = await rules.routes(url: "http://tailchrome-proxy-auth.invalid/", host: "tailchrome-proxy-auth.invalid")
        XCTAssertEqual(routes, [.http("127.0.0.1", 62351)])
        routes = await rules.routes(url: "https://nas.tail0000.ts.net/", host: "nas.tail0000.ts.net")
        XCTAssertEqual(routes, [.http("127.0.0.1", 1)])
        routes = await rules.routes(url: "https://100.80.1.2/", host: "100.80.1.2")
        XCTAssertEqual(routes, [.http("127.0.0.1", 1)])
        routes = await rules.routes(url: "https://example.com/", host: "example.com")
        XCTAssertEqual(routes, [.direct])
    }

    func testABrokenMandatoryScriptStopsEverythingAndAnOptionalOneGoesDirect() async throws {
        let broken = "function FindProxyForURL(url, host) { throw new Error('no'); }"
        let mandatory = try XCTUnwrap(try ExtensionProxyRules.read(["mode": "pac_script", "pacScript": ["data": broken, "mandatory": true]]))
        let optional = try XCTUnwrap(try ExtensionProxyRules.read(["mode": "pac_script", "pacScript": ["data": broken]]))
        let none = await mandatory.routes(url: "https://example.com/", host: "example.com")
        let direct = await optional.routes(url: "https://example.com/", host: "example.com")
        XCTAssertEqual(none, [])
        XCTAssertEqual(direct, [.direct])
    }

    func testPACHelpers() {
        let script = PACScript("""
        function FindProxyForURL(url, host) {
          return [isPlainHostName(host), dnsDomainIs(host, ".example.com"), shExpMatch(url, "*://*.example.com/*"),
                  localHostOrDomainIs(host, "www.example.com"), dnsDomainLevels(host),
                  isInNet("192.168.1.20", "192.168.0.0", "255.255.0.0"), isInNet("10.0.0.1", "192.168.0.0", "255.255.0.0"),
                  typeof myIpAddress(), weekdayRange("SUN", "SAT"), timeRange(0, 23)].join(",");
        }
        """)
        XCTAssertEqual(script.findNow(url: "https://a.example.com/x", host: "a.example.com"),
                       "false,true,true,false,2,true,false,string,true,true")
        XCTAssertEqual(script.findNow(url: "http://www/", host: "www")?.prefix(5), "true,")
        XCTAssertNil(PACScript("not javascript (").findNow(url: "https://a/", host: "a"))
        XCTAssertNil(PACScript("function FindProxyForURL() { return 1; }").findNow(url: "https://a/", host: "a"))
    }

    func testRequestHeads() throws {
        let connect = try XCTUnwrap(ExtensionProxyRelay.Head.read(Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".utf8)))
        XCTAssertEqual(connect.host, "example.com")
        XCTAssertEqual(connect.port, 443)
        XCTAssertEqual(connect.url, "https://example.com/")
        XCTAssertNil(connect.forward)
        let v6 = try XCTUnwrap(ExtensionProxyRelay.Head.read(Data("CONNECT [fd7a:115c:a1e0::1]:8443 HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertEqual(v6.host, "fd7a:115c:a1e0::1")
        XCTAssertEqual(v6.url, "https://[fd7a:115c:a1e0::1]:8443/")
        let plain = try XCTUnwrap(ExtensionProxyRelay.Head.read(Data(
            "GET http://nas.local:8080/a?b=1 HTTP/1.1\r\nHost: nas.local:8080\r\nProxy-Connection: keep-alive\r\n\r\n".utf8)))
        XCTAssertEqual(plain.url, "http://nas.local:8080/a?b=1")
        XCTAssertEqual(String(decoding: try XCTUnwrap(plain.forward), as: UTF8.self),
                       "GET /a?b=1 HTTP/1.1\r\nHost: nas.local:8080\r\n\r\n", "origin form, the Proxy- headers left behind")
        XCTAssertNil(ExtensionProxyRelay.Head.read(Data("GET / HTTP/1.1\r\n\r\n".utf8)))
    }

    func testChallengeRealm() {
        let head = Data("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"tailchrome\"\r\n\r\n".utf8)
        XCTAssertEqual(ExtensionProxyRelay.status(head), 407)
        let (scheme, realm) = ExtensionProxyRelay.challenge(head)
        XCTAssertEqual(scheme, "basic")
        XCTAssertEqual(realm, "tailchrome")
    }

    // MARK: - the relay, end to end

    /// A TCP server on 127.0.0.1 that runs `handle` for each connection.
    final class Server: @unchecked Sendable {
        let listener: NWListener
        let queue = DispatchQueue(label: "test-server")
        var port: UInt16 = 0
        var connections: [NWConnection] = []

        init(_ handle: @escaping @Sendable (NWConnection) async -> Void) throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.connections.append(connection)
                connection.start(queue: self?.queue ?? .main)
                Task { await handle(connection) }
            }
        }

        func start() async throws {
            let ready = Once()
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: ready.run { done.resume() }
                    case .failed(let error): ready.run { done.resume(throwing: error) }
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
            port = listener.port?.rawValue ?? 0
        }

        deinit { listener.cancel(); connections.forEach { $0.cancel() } }
    }

    /// Answers whatever it is sent with the same bytes.
    private func echo() async throws -> Server {
        let server = try Server { connection in
            while let data = try? await connection.receiveSome(), !data.isEmpty {
                try? await connection.sendAll(data)
            }
        }
        try await server.start()
        return server
    }

    /// An HTTP CONNECT proxy that wants Basic user:secret, and tunnels to
    /// the echo server whatever is asked for.
    private func signedProxy(to echo: UInt16, seen: Counter) async throws -> Server {
        let server = try Server { connection in
            guard let (head, _) = try? await connection.readHead() else { return }
            let text = String(decoding: head, as: UTF8.self)
            seen.add(text)
            let expected = "Proxy-Authorization: Basic " + Data("user:secret".utf8).base64EncodedString()
            guard text.hasPrefix("CONNECT "), text.contains(expected) else {
                try? await connection.sendAll(Data("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"helper\"\r\nContent-Length: 0\r\n\r\n".utf8))
                connection.cancel()
                return
            }
            let onward = NWConnection(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: echo)!), using: .tcp)
            guard (try? await onward.ready(on: .global())) != nil else { return }
            try? await connection.sendAll(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
            Task { while let d = try? await connection.receiveSome(), !d.isEmpty { try? await onward.sendAll(d) } }
            while let d = try? await onward.receiveSome(), !d.isEmpty { try? await connection.sendAll(d) }
        }
        try await server.start()
        return server
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var heads: [String] = []
        func add(_ head: String) { lock.withLock { heads.append(head) } }
        var all: [String] { lock.withLock { heads } }
    }

    private func start(_ relay: ExtensionProxyRelay) async throws -> UInt16 {
        let port: UInt16? = await withCheckedContinuation { done in relay.start { done.resume(returning: $0) } }
        return try XCTUnwrap(port)
    }

    /// Opens a tunnel through the relay and says "ping" down it.
    private func ping(through relay: UInt16, to target: String) async throws -> (String, String) {
        let client = NWConnection(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: relay)!), using: .tcp)
        defer { client.cancel() }
        try await client.ready(on: .global())
        try await client.sendAll(Data("CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n".utf8))
        let (head, _) = try await client.readHead()
        let status = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        guard status.contains(" 200 ") else { return (status, "") }
        try await client.sendAll(Data("ping".utf8))
        let back = try await client.readExactly(4)
        return (status, String(decoding: back, as: UTF8.self))
    }

    func testRelayAsksTheExtensionWhenItsProxyWantsASignIn() async throws {
        let echo = try await echo()
        let seen = Counter()
        let proxy = try await signedProxy(to: echo.port, seen: seen)
        let asked = Counter()
        let relay = ExtensionProxyRelay { challenge in
            asked.add("\(challenge.proxyHost):\(challenge.proxyPort) \(challenge.realm) \(challenge.url)")
            return ProxyCredentials(username: "user", password: "secret")
        }
        relay.rules = try ExtensionProxyRules.read(["mode": "pac_script", "pacScript": [
            "data": "function FindProxyForURL(url, host) { return 'PROXY 127.0.0.1:\(proxy.port)'; }", "mandatory": true]])
        let port = try await start(relay)
        defer { relay.stop() }

        var (status, back) = try await ping(through: port, to: "tailchrome-proxy-auth.invalid:443")
        XCTAssertTrue(status.contains("200"), status)
        XCTAssertEqual(back, "ping")
        XCTAssertEqual(asked.all, ["127.0.0.1:\(proxy.port) helper https://tailchrome-proxy-auth.invalid/"])
        XCTAssertEqual(seen.all.count, 2, "once without a sign-in, once with")

        // The sign-in is kept for that proxy: the next tunnel isn't asked about.
        (status, back) = try await ping(through: port, to: "nas.tail0000.ts.net:443")
        XCTAssertEqual(back, "ping")
        XCTAssertEqual(asked.all.count, 1)
        XCTAssertTrue(seen.all.last?.hasPrefix("CONNECT nas.tail0000.ts.net:443 ") == true)
    }

    func testNoSignInIsA407AndABlockedRouteIsA502() async throws {
        let echo = try await echo()
        let proxy = try await signedProxy(to: echo.port, seen: Counter())
        let relay = ExtensionProxyRelay { _ in nil }
        relay.rules = try ExtensionProxyRules.read(["mode": "pac_script", "pacScript": ["data": """
            function FindProxyForURL(url, host) {
              return host === "blocked.example" ? "PROXY 127.0.0.1:1" : "PROXY 127.0.0.1:\(proxy.port)";
            }
            """, "mandatory": true]])
        let port = try await start(relay)
        defer { relay.stop() }
        var (status, _) = try await ping(through: port, to: "example.com:443")
        XCTAssertTrue(status.contains("407"), status)
        (status, _) = try await ping(through: port, to: "blocked.example:443")
        XCTAssertTrue(status.contains("502"), status)
    }

    func testAbsoluteForm() throws {
        let made = try XCTUnwrap(ExtensionProxyRelay.absolute(
            Data("HEAD / HTTP/1.1\r\nHost: tailchrome-proxy-auth.invalid\r\nConnection: keep-alive\r\n\r\n".utf8),
            host: "tailchrome-proxy-auth.invalid", port: 80, credentials: ProxyCredentials(username: "u", password: "p")))
        XCTAssertEqual(String(decoding: made, as: UTF8.self),
                       "HEAD http://tailchrome-proxy-auth.invalid/ HTTP/1.1\r\nHost: tailchrome-proxy-auth.invalid\r\n"
                       + "Connection: close\r\nProxy-Authorization: Basic dTpw\r\n\r\n")
        let socket = try XCTUnwrap(ExtensionProxyRelay.absolute(
            Data("GET /ws HTTP/1.1\r\nHost: h:8080\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n".utf8),
            host: "h", port: 8080, credentials: nil))
        XCTAssertTrue(String(decoding: socket, as: UTF8.self).hasPrefix("GET http://h:8080/ws HTTP/1.1\r\n"))
        XCTAssertTrue(String(decoding: socket, as: UTF8.self).contains("Connection: Upgrade"), "an upgrade keeps its connection")
        XCTAssertTrue(ExtensionProxyRelay.whole(Data("POST / HTTP/1.1\r\nContent-Length: 3\r\n\r\n".utf8), Data("abc".utf8)))
        XCTAssertFalse(ExtensionProxyRelay.whole(Data("POST / HTTP/1.1\r\nContent-Length: 9\r\n\r\n".utf8), Data("abc".utf8)))
    }

    /// A plain http:// page, which WebKit asks for with CONNECT to port 80,
    /// reaches an HTTP proxy as Chrome sends it: the request in absolute
    /// form, signed in after a 407 — how Tailchrome's helper answers its probe.
    func testPlainHTTPGoesToTheProxyInAbsoluteForm() async throws {
        let seen = Counter()
        let proxy = try Server { connection in
            guard let (head, _) = try? await connection.readHead() else { return }
            let text = String(decoding: head, as: UTF8.self)
            seen.add(text.components(separatedBy: "\r\n").first ?? "")
            let signed = text.contains("Proxy-Authorization: Basic " + Data("user:secret".utf8).base64EncodedString())
            let answer = signed
                ? "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
                : "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"Tailchrome\"\r\nContent-Length: 0\r\n\r\n"
            try? await connection.sendAll(Data(answer.utf8))
            connection.cancel()
        }
        try await proxy.start()
        let relay = ExtensionProxyRelay { challenge in
            challenge.realm == "Tailchrome" ? ProxyCredentials(username: "user", password: "secret") : nil
        }
        relay.rules = try ExtensionProxyRules.read(["mode": "pac_script", "pacScript": [
            "data": "function FindProxyForURL(url, host) { return 'PROXY 127.0.0.1:\(proxy.port)'; }", "mandatory": true]])
        let port = try await start(relay)
        defer { relay.stop() }

        let client = NWConnection(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!), using: .tcp)
        defer { client.cancel() }
        try await client.ready(on: .global())
        try await client.sendAll(Data("CONNECT tailchrome-proxy-auth.invalid:80 HTTP/1.1\r\nHost: tailchrome-proxy-auth.invalid:80\r\n\r\n".utf8))
        let (tunnel, _) = try await client.readHead()
        XCTAssertTrue(String(decoding: tunnel, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        try await client.sendAll(Data("HEAD / HTTP/1.1\r\nHost: tailchrome-proxy-auth.invalid\r\n\r\n".utf8))
        let (answer, _) = try await client.readHead()
        XCTAssertTrue(String(decoding: answer, as: UTF8.self).hasPrefix("HTTP/1.1 204"), String(decoding: answer, as: UTF8.self))
        XCTAssertEqual(seen.all, Array(repeating: "HEAD http://tailchrome-proxy-auth.invalid/ HTTP/1.1", count: 2))
    }

    func testDirectAndSOCKS5() async throws {
        let echo = try await echo()
        // A SOCKS5 server without sign-in that joins every request to echo.
        let socks = try Server { connection in
            guard let hello = try? await connection.readExactly(3), hello == Data([5, 1, 0]) else { return }
            try? await connection.sendAll(Data([5, 0]))
            guard let head = try? await connection.readExactly(5) else { return }
            _ = try? await connection.readExactly(Int(head[4]) + 2)
            let onward = NWConnection(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: echo.port)!), using: .tcp)
            guard (try? await onward.ready(on: .global())) != nil else { return }
            try? await connection.sendAll(Data([5, 0, 0, 1, 127, 0, 0, 1, 0, 0]))
            Task { while let d = try? await connection.receiveSome(), !d.isEmpty { try? await onward.sendAll(d) } }
            while let d = try? await onward.receiveSome(), !d.isEmpty { try? await connection.sendAll(d) }
        }
        try await socks.start()
        let relay = ExtensionProxyRelay { _ in nil }
        relay.rules = try ExtensionProxyRules.read(["mode": "pac_script", "pacScript": ["data": """
            function FindProxyForURL(url, host) {
              return host === "127.0.0.1" ? "DIRECT" : "SOCKS5 127.0.0.1:\(socks.port)";
            }
            """]])
        let port = try await start(relay)
        defer { relay.stop() }
        var (_, back) = try await ping(through: port, to: "127.0.0.1:\(echo.port)")
        XCTAssertEqual(back, "ping", "direct")
        (_, back) = try await ping(through: port, to: "somewhere.example:443")
        XCTAssertEqual(back, "ping", "through SOCKS5")
    }
}
