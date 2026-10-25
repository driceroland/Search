import XCTest
@testable import Search

/// Unlike VaultAndUpdaterTests, this one does touch the keychain, under the
/// label a test run keeps for itself, and forgets what it saved.
final class VaultMatchingTests: XCTestCase {
    func testTheHostsOwnAccountsComeBeforeTheSites() throws {
        let own = "admin.vault-test.example", qa = "admin-qa.vault-test.example", other = "accounts.vault-test.example"
        defer { [own, qa].forEach { _ = Vault.forget(host: $0, user: "ada") } }
        guard Vault.save(host: own, user: "ada", password: "x"), Vault.save(host: qa, user: "ada", password: "x") else {
            throw XCTSkip("no keychain here")
        }
        XCTAssertEqual(Vault.kept(matching: own).map(\.host), [own])
        XCTAssertEqual(Vault.kept(matching: qa).map(\.host), [qa])
        XCTAssertEqual(Set(Vault.kept(matching: other).map(\.host)), [own, qa], "no account of its own: the site's")
        XCTAssertTrue(Vault.kept(matching: other, wide: false).isEmpty)
    }
}
