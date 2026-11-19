import Network
import WebKit
import XCTest
@testable import Search

/// The proxy's own rules, without a proxy running: what a typed setting is
/// allowed to be, which addresses stay direct, what the stores and Search's
/// own sessions are given, and where the password lives.
///
/// Built on the checks in #510 (@standby2025), with the review's cases added:
/// a port smuggled into the host field, an IPv6 address in brackets, and the
/// password gone when the proxy is turned off. That local addresses stay
/// direct is not here: the excluded domains never read back, so it is proven
/// against a running proxy instead (Tests/proxy_live.py).
@MainActor
final class ProxyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // The keychain here must be the in-memory one: a test binary has no
        // entitlement for the real item and would be refused (-34018).
        setenv("SEARCH_PROBE", "proxy-\(getpid())", 1)
    }

    private func settings(_ name: String = #function) throws -> (UserDefaults, String) {
        let suite = "SearchProxyTests.\(name).\(UUID())"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testAPortInTheHostFieldIsRefusedRatherThanLoadingNothing() {
        // It passed every check before, then resolved to nothing at all, so
        // the browser looked broken with a proxy that was never reached.
        var value = ProxySettingsValue(mode: .http, host: "localhost:8080", port: "7890")
        XCTAssertNotNil(value.validation)
        XCTAssertNil(value.bare)
        XCTAssertNil(value.configuration(password: ""))

        value.host = "localhost"
        XCTAssertNil(value.validation)
        XCTAssertEqual(value.bare, "localhost")
    }

    func testAnIPv6AddressIsTakenInBracketsOrWithout() {
        for host in ["::1", "[::1]", "fe80::1", "[fe80::1]"] {
            let value = ProxySettingsValue(mode: .socks5, host: host, port: "1080")
            XCTAssertNil(value.validation, host)
            XCTAssertEqual(value.bare, host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), host)
            XCTAssertNotNil(value.configuration(password: ""), host)
        }
        // A colon is only ever an address's, never a port's.
        for host in ["example.com:3128", "[::1]:1080", "::1:bad:"] {
            XCTAssertNotNil(ProxySettingsValue(mode: .socks5, host: host, port: "1080").validation, host)
        }
    }

    func testAHalfFilledSettingProxiesNothing() {
        for (host, port) in [("", "7890"), ("127.0.0.1", ""), ("127.0.0.1", "0"),
                             ("127.0.0.1", "65536"), ("127.0.0.1", "abc"),
                             ("https://127.0.0.1", "7890"), ("127.0.0.1/path", "7890"),
                             ("user@127.0.0.1", "7890"), ("127.0.0.1 2", "7890")] {
            let value = ProxySettingsValue(mode: .http, host: host, port: port)
            XCTAssertNotNil(value.validation, "\(host):\(port)")
            XCTAssertNil(value.configuration(password: ""), "\(host):\(port)")
        }
        // Off is not half-filled, it is off.
        let off = ProxySettingsValue(mode: .system, host: "127.0.0.1", port: "7890")
        XCTAssertNil(off.validation)
        XCTAssertNil(off.configuration(password: ""))
    }

    func testAProxyThatCannotBeReachedFailsRatherThanGoingDirect() throws {
        for mode in [ProxySettingsValue.Mode.http, .socks5] {
            let value = ProxySettingsValue(mode: mode, host: "127.0.0.1", port: "7890")
            let proxy = try XCTUnwrap(value.configuration(password: ""))
            XCTAssertFalse(proxy.allowFailover, "\(mode)")
        }
    }

    func testEveryStoreItWasPutOnFollowsASavedChange() throws {
        let (defaults, suite) = try settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let proxy = BrowserProxy(defaults: defaults, password: "", keep: { _ in }, forget: {})

        let space = WKWebsiteDataStore(forIdentifier: UUID())
        let shy = WKWebsiteDataStore.nonPersistent()
        proxy.attach(space)
        proxy.attach(shy)
        XCTAssertTrue(space.proxyConfigurations.isEmpty)

        try proxy.save(ProxySettingsValue(mode: .socks5, host: "127.0.0.1", port: "1080"), password: "")
        // A private tab's store is left out of Spaces.everyStore on purpose,
        // so it has to be followed here or a private tab would go direct.
        XCTAssertEqual(space.proxyConfigurations.count, 1)
        XCTAssertEqual(shy.proxyConfigurations.count, 1)

        try proxy.save(ProxySettingsValue(mode: .system), password: "")
        XCTAssertTrue(space.proxyConfigurations.isEmpty)
        XCTAssertTrue(shy.proxyConfigurations.isEmpty)
    }

    func testAStoreMadeAfterwardsIsGivenTheProxyToo() throws {
        let (defaults, suite) = try settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let proxy = BrowserProxy(defaults: defaults, password: "", keep: { _ in }, forget: {})
        try proxy.save(ProxySettingsValue(mode: .http, host: "127.0.0.1", port: "7890"), password: "")

        let later = WKWebsiteDataStore(forIdentifier: UUID())
        proxy.attach(later)
        XCTAssertEqual(later.proxyConfigurations.count, 1)
    }

    func testASavedSettingComesBackButAnInvalidOneIsRefused() throws {
        let (defaults, suite) = try settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let proxy = BrowserProxy(defaults: defaults, password: "", keep: { _ in }, forget: {})

        XCTAssertThrowsError(try proxy.save(ProxySettingsValue(mode: .http, host: "", port: ""), password: ""))
        XCTAssertEqual(proxy.value.mode, .system)

        try proxy.save(ProxySettingsValue(mode: .socks5, host: "10.0.0.2", port: "1080", username: "me"), password: "")
        let again = BrowserProxy(defaults: defaults, password: "", keep: { _ in }, forget: {})
        XCTAssertEqual(again.value, ProxySettingsValue(mode: .socks5, host: "10.0.0.2", port: "1080", username: "me"))
    }

    func testThePasswordIsKeptOnlyWhileAProxyNamesAUser() throws {
        let (defaults, suite) = try settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        var kept: [String] = []
        var forgotten = 0
        let proxy = BrowserProxy(defaults: defaults, password: "",
                                 keep: { kept.append($0) }, forget: { forgotten += 1 })

        // No user, so nothing to keep even when a password is typed.
        try proxy.save(ProxySettingsValue(mode: .http, host: "127.0.0.1", port: "7890"), password: "secret")
        XCTAssertEqual(kept, [""])
        XCTAssertEqual(proxy.savedPassword, "")

        try proxy.save(ProxySettingsValue(mode: .http, host: "127.0.0.1", port: "7890", username: "me"),
                       password: "secret")
        XCTAssertEqual(kept.last, "secret")
        XCTAssertEqual(proxy.savedPassword, "secret")

        // Turned off: gone, and not merely overwritten with an empty one.
        try proxy.save(ProxySettingsValue(mode: .system), password: "secret")
        XCTAssertEqual(forgotten, 1)
        XCTAssertEqual(proxy.savedPassword, "")
    }

    func testAKeychainThatRefusesLeavesTheProxyAsItWas() throws {
        let (defaults, suite) = try settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let proxy = BrowserProxy(defaults: defaults, password: "",
                                 keep: { _ in throw CocoaError(.fileWriteUnknown) }, forget: {})
        let store = WKWebsiteDataStore(forIdentifier: UUID())
        proxy.attach(store)

        XCTAssertThrowsError(try proxy.save(
            ProxySettingsValue(mode: .http, host: "127.0.0.1", port: "7890", username: "me"), password: "secret"))
        XCTAssertEqual(proxy.value.mode, .system)
        XCTAssertTrue(store.proxyConfigurations.isEmpty)
        XCTAssertNil(defaults.data(forKey: "network.proxy"))
    }

    func testATestRunKeepsThePasswordInMemoryAndLeavesTheKeychainAlone() throws {
        XCTAssertTrue(Store.testing, "these tests run with SEARCH_PROBE set")
        ProxySecret.forget()
        XCTAssertEqual(ProxySecret.read(), "")
        try ProxySecret.write("secret")
        XCTAssertEqual(ProxySecret.read(), "secret")
        ProxySecret.forget()
        XCTAssertEqual(ProxySecret.read(), "")
    }

    func testSearchsOwnRequestsCarryTheProxyAndOneSessionIsReused() throws {
        let (defaults, suite) = try settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let proxy = BrowserProxy(defaults: defaults, password: "", keep: { _ in }, forget: {})
        defer { try? proxy.save(ProxySettingsValue(mode: .system), password: "") }

        let before = URLSessionConfiguration.ephemeral
        ProxyNetwork.stamp(before)
        XCTAssertTrue(before.proxyConfigurations.isEmpty)

        try proxy.save(ProxySettingsValue(mode: .socks5, host: "127.0.0.1", port: "1080"), password: "")
        let after = URLSessionConfiguration.ephemeral
        ProxyNetwork.stamp(after)
        XCTAssertEqual(after.proxyConfigurations.count, 1)

        // The session standing in for URLSession.shared is made once and kept
        // until the proxy changes, so a favicon doesn't open a new one each time.
        let first = ProxyNetwork.session
        XCTAssertTrue(first === ProxyNetwork.session)
        try proxy.save(ProxySettingsValue(mode: .http, host: "127.0.0.1", port: "7890"), password: "")
        XCTAssertFalse(first === ProxyNetwork.session)

        // The password alone changing is the case a session kept by what the
        // proxy says about itself would miss: two credentials, one and the
        // same description, and the old session goes on sending the old one.
        let named = ProxySettingsValue(mode: .http, host: "127.0.0.1", port: "7890", username: "me")
        try proxy.save(named, password: "one")
        let withOne = ProxyNetwork.session
        try proxy.save(named, password: "two")
        XCTAssertFalse(withOne === ProxyNetwork.session)
    }
}
