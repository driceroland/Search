import AppKit
import Network
import Security
import WebKit
import XCTest
import os
@testable import Search

/// Mixed content on a real HTTPS page: a page served over TLS (a throwaway
/// self-signed certificate the test's web view is told to trust) asking for
/// an image and a script over plain HTTP from the Mac's own LAN address —
/// loopback HTTP counts as secure, so it can't stand in. WebKit's
/// MixedContentChecker reports both; the Issues tool groups them.
@MainActor
final class DeveloperMixedContentLiveTests: XCTestCase {
    func testAnHTTPSPagesInsecureImageAndScriptBecomeMixedContentIssues() async throws {
        guard let lan = Self.lanAddress() else { throw XCTSkip("No LAN address to serve plain HTTP from.") }
        let identity = try Self.identity()
        let insecure = try await TinyServer.start(tls: nil) { path in
            path.hasSuffix(".js") ? ("text/javascript", "window.insecureRan = true;") : ("image/svg+xml", "<svg xmlns='http://www.w3.org/2000/svg'/>")
        }
        defer { insecure.stop() }
        let base = "http://\(lan):\(insecure.port)"
        let secure = try await TinyServer.start(tls: identity) { _ in
            ("text/html", """
            <!doctype html><title>Mixed fixture</title>
            <img src="\(base)/pixel.svg"><script src="\(base)/active.js"></script>
            """)
        }
        defer { secure.stop() }

        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let trust = Trusting()
        page.navigationDelegate = trust
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        defer { window.close() }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        try await DeveloperTestSupport.wait("inspector", seconds: 10, in: "DeveloperMixedContentLiveTests") { session.ready }

        page.load(URLRequest(url: URL(string: "https://127.0.0.1:\(secure.port)/")!))
        try await DeveloperTestSupport.wait("the HTTPS page", seconds: 10, in: "DeveloperMixedContentLiveTests") {
            page.title == "Mixed fixture" && !page.isLoading
        }
        let ran = try await page.callAsyncJavaScript("return window.insecureRan === true;", arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertEqual(ran, false, "WebKit blocks the insecure script")
        let model = DeveloperIssuesModel.model(for: session)
        try await DeveloperTestSupport.wait("mixed content issues", seconds: 10, in: "DeveloperMixedContentLiveTests", state: {
            "groups \(model.groups.map { "\($0.code): \($0.count)" }); console \(session.console.map(\.text).suffix(6))"
        }) {
            model.groups.contains { $0.code == .mixedContent && $0.count >= 1 }
        }
        let group = try XCTUnwrap(model.groups.first { $0.code == .mixedContent })
        print("[DeveloperMixedContentLiveTests] \(group.count) mixed content issue(s): \(session.console.filter { $0.text.contains("insecure") }.map(\.text))")
        await DeveloperTestSupport.finish(session, page: page, keeping: tab, trust)
    }

    private final class Trusting: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if let trust = challenge.protectionSpace.serverTrust, challenge.protectionSpace.host == "127.0.0.1" {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    /// The first IPv4 address of an up, non-loopback interface.
    static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(item.pointee.ifa_flags)
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let text = String(cString: host)
            if !text.hasPrefix("169.254.") { return text }
        }
        return nil
    }

    /// A throwaway self-signed identity for 127.0.0.1, made with openssl
    /// and kept in memory only.
    static func identity() throws -> SecIdentity {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perch-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func run(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = arguments
            process.currentDirectoryURL = dir
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw XCTSkip("openssl \(arguments.first ?? "") failed") }
        }
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "key.pem", "-out", "cert.pem", "-days", "1",
                 "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1"])
        try run(["pkcs12", "-export", "-inkey", "key.pem", "-in", "cert.pem", "-out", "id.p12", "-passout", "pass:perch",
                 "-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1"])
        let data = try Data(contentsOf: dir.appendingPathComponent("id.p12"))
        var items: CFArray?
        guard #available(macOS 15, *) else { throw XCTSkip("An in-memory import needs macOS 15.") }
        let options: [String: Any] = [kSecImportExportPassphrase as String: "perch", kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else { throw XCTSkip("The identity couldn't be imported (\(status)).") }
        return identity as! SecIdentity
    }
}

/// A one-response-per-connection HTTP server on every interface, over TLS
/// when given an identity.
final class TinyServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

    private init(listener: NWListener, port: UInt16) { self.listener = listener; self.port = port }

    static func start(tls identity: SecIdentity?, respond: @escaping @Sendable (String) -> (String, String)) async throws -> TinyServer {
        let parameters: NWParameters
        if let identity, let secIdentity = sec_identity_create(identity) {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "perch.tiny-server")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let (type, body) = respond(path)
                let bytes = Data(body.utf8)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                resumed.withLock { done in
                    guard !done else { return }
                    switch state {
                    case .ready:
                        done = true
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    case .failed(let error):
                        done = true
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            listener.start(queue: queue)
        }
        return TinyServer(listener: listener, port: port)
    }

    func stop() { listener.cancel() }
}
