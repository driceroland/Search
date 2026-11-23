import AppKit
import Security
import SwiftUI
import WebKit
import XCTest
@testable import Search

/// The Security panel's model: origins grouped as Chrome groups them, mixed
/// content, the connection's parts and the certificate's fields.
@MainActor
final class DeveloperSecurityTests: XCTestCase {
    private func request(_ id: String, _ url: String, status: Int? = 200, failure: String? = nil,
                         security: DeveloperSecurity.ResponseSecurity? = nil) -> DeveloperToolsSession.Request {
        var request = DeveloperToolsSession.Request(id: id, url: url, method: "GET", type: "Other", loader: nil, started: 1)
        request.status = status
        request.failure = failure
        request.security = security
        return request
    }

    func testOriginsAreGroupedAsChromeGroupsThem() {
        let tls = DeveloperSecurity.ResponseSecurity(networkProtocol: "TLS 1.3", cipher: "TLS_AES_128_GCM_SHA256")
        let requests = [
            request("1", "https://example.test/", security: tls),
            request("2", "https://cdn.example.test/app.js"),
            request("3", "http://ads.example.test/pixel.gif"),
            request("4", "https://gone.example.test/x", status: nil, failure: "Cancelled"),
            request("5", "https://example.test:8443/api"),
            request("6", "data:image/png;base64,AAAA"),
            request("7", "https://cdn.example.test/app.css"),
            request("8", "wss://socket.example.test/live"),
        ]
        let origins = DeveloperSecurity.origins(requests, page: URL(string: "https://example.test/home"))
        let groups = DeveloperSecurity.grouped(origins)
        XCTAssertEqual(groups.map(\.group), [.main, .secure, .nonSecure, .unknown])
        XCTAssertEqual(groups.map { $0.group.rawValue },
                       ["Main origin", "Secure origins", "Non-secure origins", "Unknown / canceled"])
        XCTAssertEqual(groups[0].origins.map(\.origin), ["https://example.test"])
        XCTAssertEqual(groups[0].origins.first?.security, tls)
        XCTAssertEqual(groups[1].origins.map(\.origin),
                       ["https://cdn.example.test", "https://example.test:8443", "wss://socket.example.test"])
        XCTAssertEqual(groups[1].origins.first?.requestIDs, ["2", "7"])
        XCTAssertEqual(groups[2].origins.map(\.origin), ["http://ads.example.test"])
        XCTAssertEqual(groups[3].origins.map(\.origin), ["https://gone.example.test"])
        XCTAssertEqual(DeveloperSecurity.networkFilter(for: groups[1].origins[0]), "domain:cdn.example.test")

        // The page's origin is the main one even before Network saw its document.
        let early = DeveloperSecurity.origins([request("1", "http://other.test/a")], page: URL(string: "http://page.test/"))
        XCTAssertEqual(early.map(\.origin), ["http://page.test", "http://other.test"])
        XCTAssertEqual(early.map(\.group), [.main, .nonSecure])
        XCTAssertNil(DeveloperSecurity.origin(of: "about:blank"))
        XCTAssertEqual(DeveloperSecurity.origin(of: "HTTPS://Example.TEST:443/x")?.origin, "https://example.test")
        XCTAssertEqual(DeveloperSecurity.origin(of: "http://example.test:8080/")?.origin, "http://example.test:8080")
    }

    func testMixedContentIsHTTPOnAnHTTPSPage() {
        let requests = [
            request("1", "https://example.test/"),
            request("2", "http://images.example.test/a.png"),
            request("3", "http://localhost:8000/dev.js"),
            request("4", "ws://socket.example.test/"),
            request("5", "https://cdn.example.test/b.js"),
        ]
        let page = URL(string: "https://example.test/")
        XCTAssertEqual(DeveloperSecurity.mixedContent(requests, page: page).map(\.id), ["2", "4"])
        XCTAssertEqual(DeveloperSecurity.mixedContent(requests, page: URL(string: "http://example.test/")).count, 0)

        XCTAssertEqual(DeveloperSecurity.summary(page: page, trusted: true, mixed: false).title,
                       "This page is secure (valid HTTPS)")
        XCTAssertEqual(DeveloperSecurity.summary(page: page, trusted: true, mixed: true), .mixedContent)
        XCTAssertEqual(DeveloperSecurity.summary(page: page, trusted: true, mixed: true).title, "This page is not secure")
        XCTAssertEqual(DeveloperSecurity.summary(page: page, trusted: false, mixed: false).title,
                       "This page is not secure (broken HTTPS)")
        XCTAssertEqual(DeveloperSecurity.summary(page: URL(string: "http://example.test/"), trusted: nil, mixed: false).title,
                       "This page is not secure")
    }

    func testConnectionIsSplitAsChromeShowsIt() {
        let tls12 = DeveloperSecurity.connection(protocol: "TLSv1.2", cipher: "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256")
        XCTAssertEqual(tls12, .init(networkProtocol: "TLS 1.2", keyExchange: "ECDHE_RSA", cipher: "AES_128_GCM"))
        XCTAssertEqual(tls12.settings, "TLS 1.2, ECDHE_RSA, and AES_128_GCM")
        let tls13 = DeveloperSecurity.connection(protocol: "TLS 1.3", cipher: "TLS_AES_256_GCM_SHA384")
        XCTAssertEqual(tls13, .init(networkProtocol: "TLS 1.3", keyExchange: nil, cipher: "AES_256_GCM"))
        XCTAssertEqual(tls13.settings, "TLS 1.3 and AES_256_GCM")
        let cbc = DeveloperSecurity.connection(protocol: "TLS 1.0", cipher: "TLS_RSA_WITH_AES_128_CBC_SHA")
        XCTAssertEqual(cbc.cipher, "AES_128_CBC with HMAC-SHA1")
        XCTAssertEqual(cbc.keyExchange, "RSA")
        XCTAssertEqual(DeveloperSecurity.connection(protocol: nil, cipher: nil).settings, "")

        let parsed = DeveloperSecurity.ResponseSecurity([
            "protocol": "TLS 1.3", "cipher": "TLS_AES_128_GCM_SHA256",
            "certificate": ["subject": "example.test", "validFrom": 1_795_375_221.0, "validUntil": 2_110_735_221.0,
                            "dnsNames": ["example.test", "www.example.test"], "ipAddresses": ["127.0.0.1"]] as [String: Any],
        ])
        XCTAssertEqual(parsed?.networkProtocol, "TLS 1.3")
        XCTAssertEqual(parsed?.certificate?.subject, "example.test")
        XCTAssertEqual(parsed?.certificate?.names, ["example.test", "www.example.test", "127.0.0.1"])
        XCTAssertEqual(parsed?.certificate?.validFrom, Date(timeIntervalSince1970: 1_795_375_221))
        XCTAssertNil(DeveloperSecurity.ResponseSecurity([:]))
        XCTAssertNil(DeveloperSecurity.ResponseSecurity(nil))
    }

    /// A self-signed P-256 certificate: CN=perch.test, O=Perch Tests,
    /// SAN DNS:perch.test, DNS:www.perch.test, IP:127.0.0.1, valid
    /// 2026-11-22 19:20:21 to 2036-11-19 19:20:21 GMT.
    static let fixture = """
        MIIBfDCCASKgAwIBAgIJAMh0GJgLp3wGMAoGCCqGSM49BAMCMCsxEzARBgNVBAMMCnBlcmNoLnRlc3QxFDASBgNVBAoMC1BlcmNoIFRlc3Rz\
        MB4XDTI2MTEyMjE5MjAyMVoXDTM2MTExOTE5MjAyMVowKzETMBEGA1UEAwwKcGVyY2gudGVzdDEUMBIGA1UECgwLUGVyY2ggVGVzdHMwWTAT\
        BgcqhkjOPQIBBggqhkjOPQMBBwNCAATmezNzZcTXrJvoF64kt7FJYtOpqylLpzmimR5YuzonQ0svfoAwuR1Q8DTT4Qi4+MozwCKhPWEoDv99\
        0OxTgsy7oy8wLTArBgNVHREEJDAiggpwZXJjaC50ZXN0gg53d3cucGVyY2gudGVzdIcEfwAAATAKBggqhkjOPQQDAgNIADBFAiBGfLKm2upW\
        zEhd86DxgV13+2PG4rx8S5kdpGoMW1pGcgIhAIGUhHVDuK1sn4gQj0EQvAzk83GPMSP6jOEzZ0ypQ1Z3
        """

    func testCertificateFieldsComeFromTheCertificate() throws {
        let data = try XCTUnwrap(Data(base64Encoded: Self.fixture))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
        let fields = DeveloperSecurity.fields(certificate)
        XCTAssertEqual(fields.subject, "perch.test")
        XCTAssertEqual(fields.issuer, "perch.test")
        XCTAssertEqual(fields.alternativeNames, ["perch.test", "www.perch.test", "127.0.0.1"])
        XCTAssertEqual(fields.validFrom, Date(timeIntervalSince1970: 1_795_375_221))
        XCTAssertEqual(fields.validUntil, Date(timeIntervalSince1970: 2_110_735_221))
        XCTAssertEqual(DeveloperSecurity.formatted(fields.validFrom), "Sun, 22 Nov 2026 19:20:21 GMT")
        XCTAssertEqual(DeveloperSecurity.formatted(nil), "—")
    }
}

/// The Security panel on a real http page: not secure, and an image from a
/// second http origin listed under Non-secure origins.
@MainActor
final class DeveloperSecurityLiveTests: XCTestCase {
    func testHTTPPageIsNotSecureAndItsOriginsAreNonSecure() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: "<!doctype html><title>Security fixture</title><p>Plain http"),
            "/pixel.gif": .init(type: "image/gif", body: "GIF89a"),
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = PageView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        defer { window.close() }
        page.load(URLRequest(url: server.url("/")))
        try await DeveloperTestSupport.wait("page to load", in: "DeveloperSecurityLiveTests") { page.title == "Security fixture" }

        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        let panel = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 700, height: 400),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        do {
            try await DeveloperTestSupport.wait("inspector", in: "DeveloperSecurityLiveTests") { session.ready }
            session.select(.security)
            panel.contentView = NSHostingView(rootView: DeveloperSecurityView(session: session) { _ in })
            panel.orderFrontRegardless()

            // An image from the same server under another name: a second, non-secure origin.
            let other = "http://localhost:\(server.port)/pixel.gif"
            _ = try await page.evaluateJavaScript("new Image().src = \"\(other)\"; 0")
            try await DeveloperTestSupport.wait("image request", in: "DeveloperSecurityLiveTests", state: {
                session.requests.map { "\($0.url) \($0.status ?? -1)" }.joined(separator: ", ")
            }) {
                session.requests.contains { $0.url == other && $0.status != nil }
            }

            let address = try XCTUnwrap(session.address)
            XCTAssertEqual(DeveloperSecurity.summary(page: address, trusted: nil, mixed: false).title, "This page is not secure")
            let groups = DeveloperSecurity.grouped(DeveloperSecurity.origins(session.requests, page: address))
            XCTAssertEqual(groups.first?.group, .main)
            XCTAssertEqual(groups.first?.origins.map(\.origin), ["http://127.0.0.1:\(server.port)"])
            let nonSecure = groups.first { $0.group == .nonSecure }?.origins.map(\.origin) ?? []
            XCTAssertEqual(nonSecure, ["http://localhost:\(server.port)"])
            XCTAssertTrue(DeveloperSecurity.mixedContent(session.requests, page: address).isEmpty)
            panel.contentView?.layoutSubtreeIfNeeded()
        } catch {
            await DeveloperTestSupport.finish(session, page: page, keeping: tab, server, panel)
            throw error
        }
        panel.contentView = nil
        await DeveloperTestSupport.finish(session, page: page, keeping: tab, server, panel)
    }
}
