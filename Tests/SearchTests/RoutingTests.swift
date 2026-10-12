import XCTest
@testable import Search

final class RoutingTests: XCTestCase {
    func testDomainsAreNormalizedAndRejectURLsAndInvalidLabels() {
        XCTAssertEqual(RoutingConfig.domain(" Example.COM. \n"), "example.com")
        for input in ["https://example.com", "example.com/path", "example.com:443", "*.example.com",
                      "example..com", "-example.com", "example-.com", "localhost:3000", "192.168.1.1", "::2",
                      String(repeating: "a", count: 64) + ".com"] {
            XCTAssertNil(RoutingConfig.domain(input), input)
        }
    }

    func testLocalHostsAndPorts() {
        for host in ["localhost", "127.0.0.1", "::1"] {
            let broad = RoutingRule(domain: host, spaceID: UUID(), spaceName: "Personal")
            let specific = RoutingRule(domain: host, port: 3000, spaceID: UUID(), spaceName: "Work")
            var config = RoutingConfig(enabled: true, rules: [specific, broad])
            let urlHost = host.contains(":") ? "[" + host + "]" : host
            XCTAssertEqual(config.match(URL(string: "http://\(urlHost):3000")!), specific)
            XCTAssertEqual(config.match(URL(string: "http://\(urlHost):3001")!), broad)
            config.rules = [specific]
            XCTAssertNil(config.match(URL(string: "http://\(urlHost):3001")!))
            XCTAssertNil(config.match(URL(string: "http://spoof.localhost:3000")!))
        }
        let invalid = RoutingRule(domain: "localhost", port: 0, spaceID: UUID(), spaceName: "Work")
        XCTAssertNil(RoutingConfig(enabled: true, rules: [invalid]).match(URL(string: "http://localhost")!))
        XCTAssertEqual(RoutingConfig.domain("[::1]"), "::1")
        for invalid in ["0", "65536", "-1", "+80", " 80", "８０", "80.0"] { XCTAssertNil(RoutingConfig.port(invalid)) }
        XCTAssertEqual(RoutingConfig.port("65535"), 65535)
        let http = RoutingRule(domain: "example.com", port: 80, spaceID: UUID(), spaceName: "Work")
        let https = RoutingRule(domain: "example.com", port: 443, spaceID: UUID(), spaceName: "Personal")
        let narrow = RoutingRule(domain: "docs.example.com", spaceID: UUID(), spaceName: "Research")
        let config = RoutingConfig(enabled: true, rules: [http, https, narrow])
        XCTAssertEqual(config.match(URL(string: "http://example.com")!), http)
        XCTAssertEqual(config.match(URL(string: "http://example.com:80")!), http)
        XCTAssertEqual(config.match(URL(string: "https://example.com")!), https)
        XCTAssertEqual(config.match(URL(string: "https://example.com:443")!), https)
        XCTAssertEqual(config.match(URL(string: "http://docs.example.com:80")!), narrow)
    }

    func testMostSpecificEnabledDomainWinsWithoutMatchingLookalikes() {
        let broad = RoutingRule(domain: "example.com", spaceID: UUID(), spaceName: "Work")
        let narrow = RoutingRule(domain: "docs.example.com", spaceID: UUID(), spaceName: "Research")
        var config = RoutingConfig(enabled: true, rules: [narrow, broad])
        XCTAssertEqual(config.match(URL(string: "https://a.docs.example.com/page")!), narrow)
        XCTAssertEqual(config.match(URL(string: "https://example.com")!), broad)
        XCTAssertNil(config.match(URL(string: "https://notexample.com")!))
        XCTAssertNil(config.match(URL(string: "https://example.com.invalid")!))
        XCTAssertNil(config.match(URL(string: "ftp://example.com")!))
        config.rules[0].enabled = false
        XCTAssertEqual(config.match(URL(string: "https://docs.example.com")!), broad)
        config.enabled = false
        XCTAssertNil(config.match(URL(string: "https://example.com")!))
    }

    @MainActor
    func testPersistenceStartsDisabledAndEmptyAndKeepsEmptyAndCorruptSettingsSafe() throws {
        let suite = "Search.routing.tests." + UUID().uuidString
        let settings = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let routing = Routing(settings: settings)
        XCTAssertEqual(routing.config, RoutingConfig(enabled: false, rules: []))
        let space = Space(id: UUID(), name: "Personal", colour: 0)
        XCTAssertTrue(routing.save(id: nil, domain: "EXAMPLE.COM", space: space))
        XCTAssertFalse(routing.save(id: nil, domain: "example.com", space: space))
        routing.setEnabled(true)
        let restored = Routing(settings: settings)
        XCTAssertEqual(restored.config, routing.config)
        XCTAssertEqual(restored.config.rules.first?.spaceID, space.id)
        XCTAssertTrue(restored.save(id: nil, domain: "localhost", space: space))
        XCTAssertTrue(restored.save(id: nil, domain: "localhost", port: 3000, space: space))
        XCTAssertTrue(restored.save(id: nil, domain: "localhost", port: 3001, space: space))
        XCTAssertFalse(restored.save(id: nil, domain: "localhost", port: 3000, space: space))
        XCTAssertEqual(Routing(settings: settings).config, restored.config)
        for rule in restored.config.rules { restored.remove(rule.id) }
        XCTAssertTrue(Routing(settings: settings).config.rules.isEmpty)
        settings.set(Data("invalid".utf8), forKey: Routing.key)
        XCTAssertEqual(Routing(settings: settings).config, RoutingConfig())
    }
    func testOlderJSONKeepsEnabledRulesAndDefaultsInternalRouting() throws {
        let ruleID = UUID(), spaceID = UUID()
        let json = """
        {"enabled":true,"rules":[{"id":"\(ruleID)","domain":"example.com",
        "spaceID":"\(spaceID)","spaceName":"Personal","enabled":false}]}
        """
        let config = try JSONDecoder().decode(RoutingConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.internalPolicy, .current)
        XCTAssertEqual(config.rules.count, 1)
        XCTAssertEqual(config.rules[0].id, ruleID)
        XCTAssertEqual(config.rules[0].spaceID, spaceID)
        XCTAssertFalse(config.rules[0].enabled)
        XCTAssertEqual(config.rules[0].internalPolicy, .inherit)
        XCTAssertNil(config.rules[0].port)
        XCTAssertEqual(try JSONDecoder().decode(RoutingConfig.self, from: JSONEncoder().encode(config)), config)
    }

    func testInternalOverrideDoesNotChangeExternalMatch() {
        var rule = RoutingRule(domain: "example.com", spaceID: UUID(), spaceName: "Work")
        var config = RoutingConfig(enabled: true, rules: [rule], internalPolicy: .ask)
        XCTAssertEqual(config.policy(for: rule), .ask)
        for policy in InternalRoutingOverride.allCases {
            rule.internalPolicy = policy
            config.rules = [rule]
            XCTAssertEqual(config.policy(for: rule), InternalRoutingPolicy(rawValue: policy.rawValue) ?? .ask)
            XCTAssertEqual(config.match(URL(string: "https://example.com")!)?.spaceID, rule.spaceID)
        }
        config.enabled = false
        XCTAssertNil(config.match(URL(string: "https://example.com")!))
    }

}
