import AuthenticationServices
import XCTest
@testable import Search

@available(macOS 14, *)
@MainActor
final class PasskeyAssertionTests: XCTestCase {
    func testSecurityKeyCanOmitUserHandle() throws {
        let reply = reply(from: Assertion())
        XCTAssertTrue(reply["userHandle"] is NSNull)
        XCTAssertEqual(reply["kind"] as? String, "get")
        XCTAssertEqual(reply["id"] as? String, "AQ")
        XCTAssertEqual(reply["clientDataJSON"] as? String, "Ag")
        XCTAssertEqual(reply["authenticatorData"] as? String, "Aw")
        XCTAssertEqual(reply["signature"] as? String, "BA")
        XCTAssertEqual(reply["attachment"] as? String, "cross-platform")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: reply))
    }

    func testReturnedUserHandleIsPreserved() {
        let assertion = Assertion()
        assertion.userID = Data([0xfb, 0xff])
        XCTAssertEqual(reply(from: assertion)["userHandle"] as? String, "-_8")
        assertion.userID = Data()
        XCTAssertEqual(reply(from: assertion)["userHandle"] as? String, "")
    }

    private func reply(from got: ASAuthorizationPublicKeyCredentialAssertion) -> [String: Any] {
        // Exercise the native protocol's implicitly unwrapped userID, as the delegate does.
        Passkeys.assertionReply(
            id: got.credentialID, clientData: got.rawClientDataJSON, authenticatorData: got.rawAuthenticatorData,
            signature: got.signature, user: got.userID, attachment: "cross-platform"
        )
    }
}

@available(macOS 14, *)
@objc(SearchTestPasskeyAssertion)
private final class Assertion: NSObject, ASAuthorizationPublicKeyCredentialAssertion {
    var credentialID = Data([1])
    var rawClientDataJSON = Data([2])
    var rawAuthenticatorData: Data! = Data([3])
    var signature: Data! = Data([4])
    var userID: Data!
    static var supportsSecureCoding: Bool { true }
    override init() { super.init() }
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {}
    func copy(with zone: NSZone? = nil) -> Any { self }
}
