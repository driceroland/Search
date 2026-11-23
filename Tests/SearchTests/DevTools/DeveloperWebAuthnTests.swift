import CryptoKit
import XCTest
@testable import Search

final class DeveloperWebAuthnTests: XCTestCase {
    func testCBOREncodesTheSpecsExamples() {
        XCTAssertEqual([UInt8](DeveloperCBOR.encode(.int(10))), [0x0a])
        XCTAssertEqual([UInt8](DeveloperCBOR.encode(.int(-7))), [0x26])
        XCTAssertEqual([UInt8](DeveloperCBOR.encode(.int(500))), [0x19, 0x01, 0xf4])
        XCTAssertEqual([UInt8](DeveloperCBOR.encode(.text("fmt"))), [0x63, 0x66, 0x6d, 0x74])
        XCTAssertEqual([UInt8](DeveloperCBOR.encode(.bytes(Data([1, 2])))), [0x42, 1, 2])
        XCTAssertEqual([UInt8](DeveloperCBOR.encode(.map([]))), [0xa0])
        XCTAssertEqual([UInt8](DeveloperCBOR.encode(.bytes(Data(count: 40)))).prefix(2), [0x58, 40])
    }

    func testCOSEKeyIsAnES256EC2Key() {
        let key = P256.Signing.PrivateKey().publicKey
        let cose = [UInt8](DeveloperWebAuthn.coseKey(key))
        // map(5) {1: 2, 3: -7, -1: 1, -2: bytes(32), -3: bytes(32)}
        XCTAssertEqual(Array(cose.prefix(7)), [0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01])
        XCTAssertEqual(cose.count, 7 + 3 + 32 + 3 + 32)
    }

    func testClientDataIsInTheSpecsOrder() throws {
        let data = DeveloperWebAuthn.clientDataJSON(type: "webauthn.get", challenge: Data([0xfb, 0xff]), origin: "https://a.example")
        XCTAssertEqual(String(data: data, encoding: .utf8),
                       #"{"type":"webauthn.get","challenge":"-_8","origin":"https://a.example","crossOrigin":false}"#)
        XCTAssertEqual(DeveloperWebAuthn.data(base64url: "-_8"), Data([0xfb, 0xff]))
    }

    func testRPIDMustBeTheHostOrASuffixOfIt() {
        XCTAssertTrue(DeveloperWebAuthn.rpID("example.com", validFor: "login.example.com"))
        XCTAssertTrue(DeveloperWebAuthn.rpID("login.example.com", validFor: "login.example.com"))
        XCTAssertTrue(DeveloperWebAuthn.rpID("localhost", validFor: "localhost"))
        XCTAssertFalse(DeveloperWebAuthn.rpID("other.com", validFor: "login.example.com"))
        XCTAssertFalse(DeveloperWebAuthn.rpID("ample.com", validFor: "example.com"))
        XCTAssertFalse(DeveloperWebAuthn.rpID("com", validFor: "example.com"))
    }

    func testCreateThenGetSignsWhatARelyingPartyVerifies() throws {
        var authenticator = DeveloperVirtualAuthenticator(name: "A", transport: .internal, residentKeys: true, userVerification: true)
        let challenge = DeveloperWebAuthn.base64url(Data("challenge".utf8))
        let made = try DeveloperWebAuthn.create([
            "rp": ["id": "example.com", "name": "Example"], "challenge": challenge,
            "user": ["id": DeveloperWebAuthn.base64url(Data([7, 7])), "name": "ada"],
            "pubKeyCredParams": [["type": "public-key", "alg": -7]],
            "authenticatorSelection": ["residentKey": "required", "userVerification": "required"],
        ], origin: "https://login.example.com", host: "login.example.com", authenticator: &authenticator)
        XCTAssertEqual(authenticator.credentials.count, 1)
        XCTAssertTrue(authenticator.credentials[0].isResident)
        let authData = try XCTUnwrap(DeveloperWebAuthn.data(base64url: made["authenticatorData"] as! String))
        XCTAssertEqual(authData.prefix(32), Data(SHA256.hash(data: Data("example.com".utf8))))
        XCTAssertEqual(authData[32], 0x45)  // UP | UV | AT
        let publicKey = try P256.Signing.PublicKey(derRepresentation: XCTUnwrap(DeveloperWebAuthn.data(base64url: made["publicKey"] as! String)))

        let assertion = try DeveloperWebAuthn.get(["challenge": challenge, "rpId": "example.com"],
                                                  origin: "https://login.example.com", host: "login.example.com",
                                                  authenticator: &authenticator)
        let assertionData = try XCTUnwrap(DeveloperWebAuthn.data(base64url: assertion["authenticatorData"] as! String))
        let clientData = try XCTUnwrap(DeveloperWebAuthn.data(base64url: assertion["clientDataJSON"] as! String))
        let signature = try P256.Signing.ECDSASignature(derRepresentation: XCTUnwrap(DeveloperWebAuthn.data(base64url: assertion["signature"] as! String)))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: assertionData + Data(SHA256.hash(data: clientData))))
        XCTAssertEqual(Array(assertionData[33..<37]), [0, 0, 0, 1])
        XCTAssertEqual(assertion["userHandle"] as? String, DeveloperWebAuthn.base64url(Data([7, 7])))
    }

    func testRefusalsUseTheSpecsErrorNames() {
        var u2f = DeveloperVirtualAuthenticator(name: "U", protocolKind: .u2f, residentKeys: true, userVerification: true)
        let base: [String: Any] = ["challenge": "AA", "user": ["id": "AQ", "name": "a"]]
        func name(_ request: [String: Any], host: String = "example.com") -> String? {
            do { _ = try DeveloperWebAuthn.create(request, origin: "https://\(host)", host: host, authenticator: &u2f); return nil }
            catch let failure as DeveloperWebAuthn.Failure { return failure.name } catch { return "\(error)" }
        }
        XCTAssertEqual(name(base.merging(["authenticatorSelection": ["residentKey": "required"]]) { $1 }), "NotAllowedError")
        XCTAssertEqual(name(base.merging(["pubKeyCredParams": [["alg": -35]]]) { $1 }), "NotSupportedError")
        XCTAssertEqual(name(base.merging(["rp": ["id": "other.com"]]) { $1 }), "SecurityError")
        XCTAssertNil(name(base))
        let id = u2f.credentials[0].idString
        XCTAssertEqual(name(base.merging(["excludeCredentials": [["id": id]]]) { $1 }), "InvalidStateError")
        XCTAssertThrowsError(try DeveloperWebAuthn.get(["challenge": "AA"], origin: "https://example.com", host: "example.com",
                                                       authenticator: &u2f), "no resident credential to discover")
    }

    private func register(_ algorithm: Int, attestation: String? = nil, on authenticator: inout DeveloperVirtualAuthenticator) throws -> [String: Any] {
        var request: [String: Any] = ["rp": ["id": "example.com"], "challenge": "AQID", "user": ["id": "Bw", "name": "ada"],
                                      "pubKeyCredParams": [["alg": -999], ["alg": algorithm], ["alg": -7]]]
        if let attestation { request["attestation"] = attestation }
        return try DeveloperWebAuthn.create(request, origin: "https://example.com", host: "example.com", authenticator: &authenticator)
    }

    private func assertion(_ authenticator: inout DeveloperVirtualAuthenticator, _ id: String) throws -> (signed: Data, signature: Data) {
        let got = try DeveloperWebAuthn.get(["challenge": "BAU", "allowCredentials": [["id": id]]], origin: "https://example.com",
                                            host: "example.com", authenticator: &authenticator)
        let authData = try XCTUnwrap(DeveloperWebAuthn.data(base64url: got["authenticatorData"] as! String))
        let clientData = try XCTUnwrap(DeveloperWebAuthn.data(base64url: got["clientDataJSON"] as! String))
        return (authData + Data(SHA256.hash(data: clientData)), try XCTUnwrap(DeveloperWebAuthn.data(base64url: got["signature"] as! String)))
    }

    func testEdDSACredentialsSignWithEd25519() throws {
        var authenticator = DeveloperVirtualAuthenticator(name: "A")
        let made = try register(-8, on: &authenticator)
        XCTAssertEqual(made["publicKeyAlgorithm"] as? Int, -8, "the RP's first listed algorithm the authenticator has")
        let spki = try XCTUnwrap(DeveloperWebAuthn.data(base64url: made["publicKey"] as! String))
        XCTAssertEqual(spki.count, 44)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: spki.suffix(32))
        let (signed, signature) = try assertion(&authenticator, made["id"] as! String)
        XCTAssertTrue(key.isValidSignature(signature, for: signed))
        XCTAssertTrue(authenticator.credentials[0].pem.hasPrefix("-----BEGIN PRIVATE KEY-----\n"))
    }

    func testRS256CredentialsSignWithRSA() throws {
        var authenticator = DeveloperVirtualAuthenticator(name: "A")
        let made = try register(-257, on: &authenticator)
        XCTAssertEqual(made["publicKeyAlgorithm"] as? Int, -257)
        let spki = try XCTUnwrap(DeveloperWebAuthn.data(base64url: made["publicKey"] as! String))
        guard case .rs256(let privateKey) = authenticator.credentials[0].key else { return XCTFail("not RSA") }
        let pkcs1 = try XCTUnwrap(SecKeyCopyPublicKey(privateKey).flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? })
        XCTAssertTrue(spki.suffix(pkcs1.count) == pkcs1, "SubjectPublicKeyInfo wraps the RSAPublicKey")
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        let key = try XCTUnwrap(SecKeyCreateWithData(spki.suffix(pkcs1.count) as CFData, attributes as CFDictionary, nil))
        let (signed, signature) = try assertion(&authenticator, made["id"] as! String)
        XCTAssertTrue(SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil))
        // COSE: {1: 3 (RSA), 3: -257, -1: n (256 bytes), -2: e}
        let authData = try XCTUnwrap(DeveloperWebAuthn.data(base64url: made["authenticatorData"] as! String))
        let cose = [UInt8](authData.suffix(from: 37 + 16 + 2 + 16))
        XCTAssertEqual(Array(cose.prefix(7)), [0xa4, 0x01, 0x03, 0x03, 0x39, 0x01, 0x00])
        XCTAssertEqual(Array(cose[7...10]), [0x20, 0x59, 0x01, 0x00], "a 2048-bit modulus")
    }

    func testDirectAttestationIsPackedSelfAttestation() throws {
        var authenticator = DeveloperVirtualAuthenticator(name: "A")
        let made = try register(-7, attestation: "direct", on: &authenticator)
        let object = [UInt8](try XCTUnwrap(DeveloperWebAuthn.data(base64url: made["attestationObject"] as! String)))
        // {"fmt": "packed", "attStmt": {"alg": -7, "sig": …}, …}
        let packed: [UInt8] = [0xa3, 0x63] + Array("fmt".utf8) + [0x66] + Array("packed".utf8)
        XCTAssertEqual(Array(object.prefix(packed.count)), packed)
        let afterStmt = packed.count + 8 /* text "attStmt" */
        XCTAssertEqual(object[afterStmt], 0xa2)
        // The sig verifies over authData ‖ SHA-256(clientDataJSON) with the credential key.
        let key = try P256.Signing.PublicKey(derRepresentation: XCTUnwrap(DeveloperWebAuthn.data(base64url: made["publicKey"] as! String)))
        let sigStart = afterStmt + 1 + 4 /* "alg" */ + 1 /* -7 */ + 4 /* "sig" */
        XCTAssertEqual(object[sigStart] >> 5, 2, "sig is a byte string")
        let length = object[sigStart] & 0x1f == 24 ? Int(object[sigStart + 1]) : Int(object[sigStart] & 0x1f)
        let offset = object[sigStart] & 0x1f == 24 ? 2 : 1
        let signature = try P256.Signing.ECDSASignature(derRepresentation: Data(object[(sigStart + offset)..<(sigStart + offset + length)]))
        let authData = try XCTUnwrap(DeveloperWebAuthn.data(base64url: made["authenticatorData"] as! String))
        let clientData = try XCTUnwrap(DeveloperWebAuthn.data(base64url: made["clientDataJSON"] as! String))
        XCTAssertTrue(key.isValidSignature(signature, for: authData + Data(SHA256.hash(data: clientData))))
        XCTAssertTrue(String(decoding: Data(object), as: UTF8.self).contains("none") == false)
    }
}
