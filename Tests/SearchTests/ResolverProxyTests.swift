import Darwin
import Network
import WebKit
import XCTest
@testable import Search

final class ResolverProxyTests: XCTestCase {
    func testConnectAuthorityAndBasicAuthorization() throws {
        let auth = Data("test:secret".utf8)
        let head = "CONNECT example.com:443 HTTP/1.1\r\npRoXy-AuThOrIzAtIoN: bAsIc \(auth.base64EncodedString())\r\n\r\n"
        let domain = try XCTUnwrap(ResolverProxy.parseConnect(Data(head.utf8)))
        XCTAssertEqual(domain.host, "example.com")
        XCTAssertEqual(domain.port, 443)
        XCTAssertEqual(domain.auth, auth)

        let ipv6 = try XCTUnwrap(ResolverProxy.parseConnect(Data("CONNECT [::1]:80 HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertEqual(ipv6.host, "::1")
        XCTAssertEqual(ipv6.port, 80)
        XCTAssertNil(ipv6.auth)
    }

    func testRejectsMalformedAndOversizedConnect() {
        for request in [
            "CONNECT example.com HTTP/1.1", "GET example.com:443 HTTP/1.1",
            "CONNECT example.com:0 HTTP/1.1", "CONNECT example.com:65536 HTTP/1.1",
            "CONNECT ::1:443 HTTP/1.1", "CONNECT [example.com]:443 HTTP/1.1",
            "CONNECT example.com:443 HTTP/1.0", "CONNECT example.com/path:443 HTTP/1.1",
        ] {
            XCTAssertNil(ResolverProxy.parseConnect(Data("\(request)\r\n\r\n".utf8)), request)
        }
        let prefix = "CONNECT example.com:443 HTTP/1.1\r\nX-Padding: "
        let exactLimit = prefix + String(repeating: "x", count: 8192 - prefix.utf8.count - 4)
        XCTAssertNotNil(ResolverProxy.parseConnect(Data("\(exactLimit)\r\n\r\n".utf8)))
        XCTAssertNil(ResolverProxy.parseConnect(Data("\(exactLimit)x\r\n\r\n".utf8)))
    }

    func testBadAuthorizationDoesNotProduceACredential() throws {
        for header in ["", "Proxy-Authorization: Basic !!!\r\n", "Proxy-Authorization: Bearer abc\r\n"] {
            let head = Data("CONNECT example.com:443 HTTP/1.1\r\n\(header)\r\n".utf8)
            XCTAssertNil(try XCTUnwrap(ResolverProxy.parseConnect(head)).auth)
        }
    }

    func testCustomDNSValidationAndPresetEndpoints() throws {
        for url in ["", "http://dns.example/dns-query", "https:///dns-query",
                    "https://user:password@dns.example/dns-query", "https://user@dns.example/",
                    "https://dns.example/dns-query#fragment"] {
            XCTAssertNotNil(DNSSettingsValue(provider: .custom, customURL: url).validation, url)
        }
        let custom = DNSSettingsValue(provider: .custom, customURL: " https://dns.example:8443/dns-query ")
        XCTAssertNil(custom.validation)
        let resolver = try XCTUnwrap(custom.resolver)
        XCTAssertEqual(resolver.url.absoluteString, "https://dns.example:8443/dns-query")
        XCTAssertTrue(resolver.addresses.isEmpty)

        let hosts: [DNSSettingsValue.Provider: String] = [
            .cloudflare: "cloudflare-dns.com", .google: "dns.google", .quad9: "dns.quad9.net",
            .adguard: "dns.adguard-dns.com",
        ]
        for (provider, host) in hosts {
            let preset = DNSSettingsValue(provider: provider)
            XCTAssertNil(preset.validation)
            let resolver = try XCTUnwrap(preset.resolver)
            XCTAssertEqual(resolver.url.absoluteString, "https://\(host)/dns-query")
            XCTAssertFalse(resolver.addresses.isEmpty)
            for address in resolver.addresses {
                guard case let .hostPort(host, port) = address else { return XCTFail("Expected an IP and port") }
                XCTAssertEqual(port, .https)
                switch host {
                case .ipv4, .ipv6: break
                default: XCTFail("Expected a bootstrap IP literal")
                }
            }
        }
    }

    @MainActor
    func testProxyPrecedenceAndDNSPersistence() throws {
        TestWorld.enter()
        let suite = "ResolverProxyTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let proxy = BrowserProxy(defaults: defaults, password: "", keep: { _ in }, forget: {})
        let store = WKWebsiteDataStore.nonPersistent()
        proxy.attach(store)
        XCTAssertNil(proxy.effectiveConfiguration)
        XCTAssertTrue(store.proxyConfigurations.isEmpty)

        let user = ProxySettingsValue(mode: .socks5, host: "127.0.0.1", port: "1080")
        try proxy.save(user, password: "")
        let userRoute = try XCTUnwrap(proxy.effectiveConfiguration).debugDescription
        let dns = DNSSettingsValue(provider: .quad9)
        try proxy.saveDNS(dns)
        XCTAssertEqual(proxy.dns, dns)
        XCTAssertEqual(proxy.effectiveConfiguration?.debugDescription, userRoute)
        XCTAssertEqual(ProxyNetwork.configuration?.debugDescription, userRoute)

        let restarted = BrowserProxy(defaults: defaults, password: "", keep: { _ in }, forget: {})
        XCTAssertEqual(restarted.dns, dns)
        XCTAssertEqual(restarted.effectiveConfiguration?.debugDescription, userRoute)

        try proxy.save(.init(), password: "")
        let dnsRoute = try XCTUnwrap(proxy.effectiveConfiguration)
        XCTAssertNotEqual(dnsRoute.debugDescription, userRoute)
        XCTAssertFalse(dnsRoute.allowFailover)
        XCTAssertEqual(ProxyNetwork.configuration?.debugDescription, dnsRoute.debugDescription)
        XCTAssertEqual(store.proxyConfigurations.count, 1)

        try proxy.saveDNS(.init())
        XCTAssertNil(proxy.effectiveConfiguration)
        XCTAssertNil(ProxyNetwork.configuration)
        XCTAssertTrue(store.proxyConfigurations.isEmpty)
    }

    func testLoopbackConnectAuthenticatesAndRelaysTrailingBytes() throws {
        let queue = DispatchQueue(label: "ResolverProxyTests.echo")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: ResolverProxy.loopback, port: .any)
        let echo = try NWListener(using: parameters)
        defer { echo.cancel() }
        let ready = expectation(description: "echo listening")
        echo.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        echo.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Self.echo(connection)
        }
        echo.start(queue: queue)
        wait(for: [ready], timeout: 2)
        let port = try XCTUnwrap(echo.port)
        let proxy = try ResolverProxy(settings: .init(provider: .quad9))

        let request = "CONNECT 127.0.0.1:\(port.rawValue) HTTP/1.1\r\n"
        let unauthenticated = try Socket(port: proxy.port)
        let wrong = Data("wrong:password".utf8).base64EncodedString()
        try unauthenticated.write(request + "Proxy-Authorization: Basic \(wrong)\r\n\r\n")
        XCTAssertTrue(try unauthenticated.read(through: "\r\n\r\n").hasPrefix("HTTP/1.1 407 "))
        let missing = try Socket(port: proxy.port)
        try missing.write(request + "\r\n")
        XCTAssertTrue(try missing.read(through: "\r\n\r\n").hasPrefix("HTTP/1.1 407 "))

        let client = try Socket(port: proxy.port)
        try client.write(request)
        let auth = ResolverProxy.expectedAuthorization.base64EncodedString()
        try client.write("Proxy-Authorization: Basic \(auth)\r\n\r\nearly payload")
        XCTAssertEqual(try client.read(through: "early payload"),
                       "HTTP/1.1 200 Connection Established\r\n\r\nearly payload")
        try client.write("later payload")
        XCTAssertEqual(try client.read(through: "later payload"), "later payload")
    }

    private static func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { bytes, _, done, error in
            guard let bytes, error == nil else { connection.cancel(); return }
            connection.send(content: bytes, completion: .contentProcessed { error in
                if done || error != nil { connection.cancel() } else { echo(connection) }
            })
        }
    }

    private final class Socket {
        private let fd: Int32

        init(port: NWEndpoint.Port) throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Self.failure() }
            do {
                var timeout = timeval(tv_sec: 3, tv_usec: 0)
                guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
                else { throw Self.failure() }
                var noSignal: Int32 = 1
                guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0
                else { throw Self.failure() }
                let size = MemoryLayout<sockaddr_in>.size
                var address = sockaddr_in(sin_len: UInt8(size), sin_family: sa_family_t(AF_INET),
                                          sin_port: port.rawValue.bigEndian,
                                          sin_addr: in_addr(s_addr: INADDR_LOOPBACK.bigEndian),
                                          sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(size)) }
                }
                guard result == 0 else { throw Self.failure() }
            } catch {
                close(fd)
                throw error
            }
            self.fd = fd
        }

        deinit { close(fd) }

        func write(_ text: String) throws {
            try Data(text.utf8).withUnsafeBytes { bytes in
                guard let start = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let sent = send(fd, start + offset, bytes.count - offset, 0)
                    guard sent > 0 else { throw Self.failure() }
                    offset += sent
                }
            }
        }

        func read(through ending: String) throws -> String {
            let marker = Data(ending.utf8)
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 1024)
            while data.range(of: marker) == nil {
                let count = recv(fd, &chunk, chunk.count, 0)
                guard count > 0 else {
                    if count == 0 { throw POSIXError(.ECONNRESET) }
                    throw Self.failure()
                }
                data.append(contentsOf: chunk.prefix(count))
            }
            return String(decoding: data, as: UTF8.self)
        }

        private static func failure() -> POSIXError {
            POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
