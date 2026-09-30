import WebKit
import XCTest
@testable import Search

@MainActor
final class ProxyTests: XCTestCase {
    func testValidationAndSystemReset() {
        var value = ProxySettingsValue(mode: .http, host: "localhost", port: "7890")
        XCTAssertNil(value.validation)
        for port in ["", "0", "65536", "-1", "abc"] {
            value.port = port
            XCTAssertNotNil(value.validation)
        }
        value.port = "65535"
        for host in ["", "https://localhost", "localhost/path", "user@localhost", "local host"] {
            value.host = host
            XCTAssertNotNil(value.validation)
        }
        value.host = "::1"
        XCTAssertNil(value.validation)
        value.mode = .system
        XCTAssertTrue(value.configurations(password: "").isEmpty)
    }

    func testApplyPersistsAndUpdatesExistingAndFutureStores() throws {
        let name = "SearchProxyTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let proxy = BrowserProxy(defaults: defaults, password: "", savePassword: { _ in })
        let ordinary = WKWebsiteDataStore(forIdentifier: UUID())
        let privateStore = WKWebsiteDataStore.nonPersistent()
        proxy.attach(ordinary)
        proxy.attach(privateStore)
        for mode in [ProxySettingsValue.Mode.http, .socks5] {
            let value = ProxySettingsValue(mode: mode, host: "127.0.0.1", port: "7890", username: "test")
            try proxy.save(value, password: "secret")
            XCTAssertEqual(ordinary.proxyConfigurations.count, 1)
            XCTAssertEqual(privateStore.proxyConfigurations.count, 1)
            XCTAssertFalse(privateStore.proxyConfigurations[0].allowFailover)
            let restored = BrowserProxy(defaults: defaults, password: "secret", savePassword: { _ in })
            XCTAssertEqual(restored.value, value)
            let future = WKWebsiteDataStore.nonPersistent()
            restored.attach(future)
            XCTAssertEqual(future.proxyConfigurations.count, 1)
        }
        try proxy.save(.init(), password: "")
        XCTAssertTrue(ordinary.proxyConfigurations.isEmpty)
        XCTAssertTrue(privateStore.proxyConfigurations.isEmpty)
    }

    func testFailedSaveLeavesSettingsAndStoresAlone() throws {
        let name = "SearchProxyTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let proxy = BrowserProxy(defaults: defaults, password: "", savePassword: { _ in
            throw NSError(domain: "KeychainFixture", code: 1)
        })
        let store = WKWebsiteDataStore.nonPersistent()
        proxy.attach(store)
        XCTAssertThrowsError(try proxy.save(.init(mode: .http, host: "localhost", port: "7890"), password: "secret"))
        XCTAssertEqual(proxy.value.mode, .system)
        XCTAssertTrue(store.proxyConfigurations.isEmpty)
        XCTAssertNil(defaults.data(forKey: "network.proxy"))
    }
}
