import CryptoKit
import Foundation

// Chromium's WebAuthn panel: a virtual authenticator environment. WebKit has
// no WebAuthn domain and no virtual authenticators, so Search makes its own:
// DeveloperWebAuthn-hooks.js answers navigator.credentials.create() and
// get() in the page by asking Search, which plays the authenticator here —
// ES256, EdDSA or RS256 keys made and held in Search, "none" attestation or
// "packed" self attestation when asked for, so a relying party verifies
// what it gets as it would from a real one.

/// Just enough CBOR (RFC 8949) for attestation objects and COSE keys.
enum DeveloperCBOR {
    indirect enum Value {
        case int(Int)
        case bytes(Data)
        case text(String)
        case map([(Value, Value)])
    }

    static func encode(_ value: Value) -> Data {
        var out = Data()
        func head(_ major: UInt8, _ n: UInt64) {
            switch n {
            case 0..<24: out.append(major << 5 | UInt8(n))
            case 24..<256: out.append(major << 5 | 24); out.append(UInt8(n))
            case 256..<65_536: out.append(major << 5 | 25); out.append(contentsOf: withUnsafeBytes(of: UInt16(n).bigEndian, Array.init))
            default: out.append(major << 5 | 26); out.append(contentsOf: withUnsafeBytes(of: UInt32(truncatingIfNeeded: n).bigEndian, Array.init))
            }
        }
        func write(_ value: Value) {
            switch value {
            case .int(let n): n >= 0 ? head(0, UInt64(n)) : head(1, UInt64(-1 - n))
            case .bytes(let data): head(2, UInt64(data.count)); out.append(data)
            case .text(let text): let utf8 = Data(text.utf8); head(3, UInt64(utf8.count)); out.append(utf8)
            case .map(let pairs): head(5, UInt64(pairs.count)); for (key, item) in pairs { write(key); write(item) }
            }
        }
        write(value)
        return out
    }
}

/// A credential's private key: ES256 (P-256), EdDSA (Ed25519) or RS256
/// (RSA 2048), the algorithms Chrome's virtual authenticators offer.
enum DeveloperWebAuthnKey {
    case es256(P256.Signing.PrivateKey)
    case eddsa(Curve25519.Signing.PrivateKey)
    case rs256(SecKey)

    static let algorithms = [DeveloperWebAuthn.es256, DeveloperWebAuthn.eddsa, DeveloperWebAuthn.rs256]

    init?(algorithm: Int) {
        switch algorithm {
        case DeveloperWebAuthn.es256: self = .es256(P256.Signing.PrivateKey())
        case DeveloperWebAuthn.eddsa: self = .eddsa(Curve25519.Signing.PrivateKey())
        case DeveloperWebAuthn.rs256:
            let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
            guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil) else { return nil }
            self = .rs256(key)
        default: return nil
        }
    }

    var algorithm: Int {
        switch self {
        case .es256: DeveloperWebAuthn.es256
        case .eddsa: DeveloperWebAuthn.eddsa
        case .rs256: DeveloperWebAuthn.rs256
        }
    }

    var name: String {
        switch self {
        case .es256: "ES256"
        case .eddsa: "EdDSA"
        case .rs256: "RS256"
        }
    }

    func sign(_ data: Data) throws -> Data {
        switch self {
        case .es256(let key): return try key.signature(for: data).derRepresentation
        case .eddsa(let key): return try key.signature(for: data)
        case .rs256(let key):
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error) else {
                throw error!.takeRetainedValue() as Error
            }
            return signature as Data
        }
    }

    /// The public key as a COSE_Key.
    var coseKey: Data {
        switch self {
        case .es256(let key): return DeveloperWebAuthn.coseKey(key.publicKey)
        case .eddsa(let key):
            return DeveloperCBOR.encode(.map([(.int(1), .int(1)), (.int(3), .int(DeveloperWebAuthn.eddsa)), (.int(-1), .int(6)),
                                              (.int(-2), .bytes(key.publicKey.rawRepresentation))]))
        case .rs256:
            let (n, e) = rsaModulusAndExponent
            return DeveloperCBOR.encode(.map([(.int(1), .int(3)), (.int(3), .int(DeveloperWebAuthn.rs256)),
                                              (.int(-1), .bytes(n)), (.int(-2), .bytes(e))]))
        }
    }

    /// SubjectPublicKeyInfo DER, as AuthenticatorAttestationResponse.getPublicKey() gives it.
    var spki: Data {
        switch self {
        case .es256(let key): return key.publicKey.derRepresentation
        case .eddsa(let key): return Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00]) + key.publicKey.rawRepresentation
        case .rs256(let key):
            let pkcs1 = SecKeyCopyPublicKey(key).flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? } ?? Data()
            let algorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
            return DeveloperDER.sequence(algorithm + DeveloperDER.element(0x03, Data([0]) + pkcs1))
        }
    }

    /// PKCS #8 PEM, as Chrome's Export gives a credential's key.
    var pem: String {
        switch self {
        case .es256(let key): return key.pemRepresentation
        case .eddsa(let key):
            let der = Data([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]) + key.rawRepresentation
            return DeveloperDER.pem(der, label: "PRIVATE KEY")
        case .rs256(let key):
            let pkcs1 = (SecKeyCopyExternalRepresentation(key, nil) as Data?) ?? Data()
            let algorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
            return DeveloperDER.pem(DeveloperDER.sequence(Data([0x02, 0x01, 0x00]) + algorithm + DeveloperDER.element(0x04, pkcs1)),
                                    label: "PRIVATE KEY")
        }
    }

    /// RSAPublicKey's modulus and exponent, leading zero bytes dropped.
    private var rsaModulusAndExponent: (Data, Data) {
        guard case .rs256(let key) = self, let pub = SecKeyCopyPublicKey(key),
              let der = SecKeyCopyExternalRepresentation(pub, nil) as Data?,
              let items = DeveloperDER.integers(inSequence: der), items.count == 2 else { return (Data(), Data()) }
        func trimmed(_ data: Data) -> Data { Data(data.drop { $0 == 0 }) }
        return (trimmed(items[0]), trimmed(items[1]))
    }
}

/// The few DER pieces the keys above need.
enum DeveloperDER {
    static func length(_ n: Int) -> Data {
        if n < 128 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var value = n
        while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func element(_ tag: UInt8, _ body: Data) -> Data { Data([tag]) + length(body.count) + body }
    static func sequence(_ body: Data) -> Data { element(0x30, body) }

    static func pem(_ der: Data, label: String) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(base64)\n-----END \(label)-----"
    }

    /// The INTEGERs directly inside a SEQUENCE.
    static func integers(inSequence der: Data) -> [Data]? {
        let bytes = [UInt8](der)
        func readLength(_ at: inout Int) -> Int? {
            guard at < bytes.count else { return nil }
            let first = Int(bytes[at]); at += 1
            if first < 128 { return first }
            let count = first & 0x7f
            guard count <= 4, at + count <= bytes.count else { return nil }
            var value = 0
            for _ in 0..<count { value = value << 8 | Int(bytes[at]); at += 1 }
            return value
        }
        var at = 0
        guard bytes.first == 0x30 else { return nil }
        at = 1
        guard let total = readLength(&at), at + total <= bytes.count else { return nil }
        var out: [Data] = []
        let end = at + total
        while at < end {
            guard bytes[at] == 0x02 else { return nil }
            at += 1
            guard let size = readLength(&at), at + size <= end else { return nil }
            out.append(Data(bytes[at..<at + size]))
            at += size
        }
        return out
    }
}

struct DeveloperWebAuthnCredential: Identifiable {
    let id: Data
    let rpID: String
    let userHandle: Data?
    let userName: String
    let isResident: Bool
    var signCount: UInt32
    let key: DeveloperWebAuthnKey

    var idString: String { DeveloperWebAuthn.base64url(id) }
    /// The private key as Chrome's Export gives it: PKCS #8 PEM.
    var pem: String { key.pem }
}

struct DeveloperVirtualAuthenticator: Identifiable {
    enum ProtocolKind: String, CaseIterable, Identifiable { case ctap2, u2f; var id: String { rawValue } }
    enum Transport: String, CaseIterable, Identifiable { case usb, nfc, ble, `internal`; var id: String { rawValue } }

    let id = UUID()
    var name: String
    var protocolKind = ProtocolKind.ctap2
    var transport = Transport.usb
    var residentKeys = false
    var userVerification = false
    /// The answer to user verification, when it is supported.
    var userVerified = true
    var credentials: [DeveloperWebAuthnCredential] = []

    var attachment: String { transport == .internal ? "platform" : "cross-platform" }
    /// U2F authenticators keep no resident keys and can't verify the user.
    var supportsResidentKeys: Bool { protocolKind == .ctap2 && residentKeys }
    var supportsUserVerification: Bool { protocolKind == .ctap2 && userVerification }
}

enum DeveloperWebAuthn {
    struct Failure: Error, Equatable {
        let name: String
        let message: String
    }

    static let es256 = -7
    static let eddsa = -8
    static let rs256 = -257

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64url text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    /// CollectedClientData, serialized in the spec's order.
    static func clientDataJSON(type: String, challenge: Data, origin: String) -> Data {
        func quoted(_ text: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])
            return data.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        }
        return Data(#"{"type":\#(quoted(type)),"challenge":\#(quoted(base64url(challenge))),"origin":\#(quoted(origin)),"crossOrigin":false}"#.utf8)
    }

    /// Whether `rpID` is the origin's host or a registrable suffix of it.
    static func rpID(_ rpID: String, validFor host: String) -> Bool {
        let rpID = rpID.lowercased(), host = host.lowercased()
        guard !rpID.isEmpty, !rpID.hasPrefix("."), rpID.contains(".") || rpID == "localhost" || rpID == host else { return false }
        return host == rpID || host.hasSuffix("." + rpID)
    }

    static func coseKey(_ key: P256.Signing.PublicKey) -> Data {
        let point = key.x963Representation  // 0x04 | x | y
        return DeveloperCBOR.encode(.map([
            (.int(1), .int(2)), (.int(3), .int(es256)), (.int(-1), .int(1)),
            (.int(-2), .bytes(point.subdata(in: 1..<33))), (.int(-3), .bytes(point.subdata(in: 33..<65))),
        ]))
    }

    struct Flags: OptionSet {
        let rawValue: UInt8
        static let userPresent = Flags(rawValue: 0x01)
        static let userVerified = Flags(rawValue: 0x04)
        static let attested = Flags(rawValue: 0x40)
    }

    static func authenticatorData(rpID: String, flags: Flags, counter: UInt32,
                                  credential: (id: Data, cose: Data)? = nil) -> Data {
        var data = Data(SHA256.hash(data: Data(rpID.utf8)))
        data.append(flags.rawValue)
        data.append(contentsOf: withUnsafeBytes(of: counter.bigEndian, Array.init))
        if let credential {
            data.append(Data(count: 16))  // AAGUID: none
            data.append(contentsOf: withUnsafeBytes(of: UInt16(credential.id.count).bigEndian, Array.init))
            data.append(credential.id)
            data.append(credential.cose)
        }
        return data
    }

    private static func bytes(_ value: Any?) -> Data? { (value as? String).flatMap { data(base64url: $0) } }

    private static func ids(_ value: Any?) -> [Data] {
        (value as? [[String: Any]] ?? []).compactMap { bytes($0["id"]) }
    }

    /// navigator.credentials.create(): a new credential on `authenticator`.
    static func create(_ request: [String: Any], origin: String, host: String,
                       authenticator: inout DeveloperVirtualAuthenticator) throws -> [String: Any] {
        let rp = request["rp"] as? [String: Any] ?? [:]
        let rpID = (rp["id"] as? String) ?? host
        guard Self.rpID(rpID, validFor: host) else {
            throw Failure(name: "SecurityError", message: "The relying party ID '\(rpID)' isn't a registrable suffix of '\(host)'.")
        }
        guard let challenge = bytes(request["challenge"]) else { throw Failure(name: "TypeError", message: "No challenge.") }
        let user = request["user"] as? [String: Any] ?? [:]
        guard let userHandle = bytes(user["id"]), (1...64).contains(userHandle.count) else {
            throw Failure(name: "TypeError", message: "user.id must be 1 to 64 bytes.")
        }
        // The first algorithm the relying party lists that the authenticator has.
        let algorithms = (request["pubKeyCredParams"] as? [[String: Any]] ?? []).compactMap { ($0["alg"] as? NSNumber)?.intValue }
        guard let algorithm = algorithms.isEmpty ? es256 : algorithms.first(where: DeveloperWebAuthnKey.algorithms.contains) else {
            throw Failure(name: "NotSupportedError", message: "The virtual authenticator supports ES256 (-7), EdDSA (-8) and RS256 (-257).")
        }
        let selection = request["authenticatorSelection"] as? [String: Any] ?? [:]
        if let attachment = selection["authenticatorAttachment"] as? String, attachment != authenticator.attachment {
            throw Failure(name: "NotAllowedError", message: "The active authenticator is \(authenticator.attachment), not \(attachment).")
        }
        let residentKey = selection["residentKey"] as? String
            ?? ((selection["requireResidentKey"] as? Bool) == true ? "required" : "discouraged")
        if residentKey == "required", !authenticator.supportsResidentKeys {
            throw Failure(name: "NotAllowedError", message: "The active authenticator doesn't support resident keys.")
        }
        let uv = selection["userVerification"] as? String ?? "preferred"
        if uv == "required", !(authenticator.supportsUserVerification && authenticator.userVerified) {
            throw Failure(name: "NotAllowedError", message: "The active authenticator can't verify the user.")
        }
        let excluded = Set(ids(request["excludeCredentials"]))
        if authenticator.credentials.contains(where: { excluded.contains($0.id) && $0.rpID == rpID }) {
            throw Failure(name: "InvalidStateError", message: "The authenticator already holds an excluded credential.")
        }
        guard let key = DeveloperWebAuthnKey(algorithm: algorithm) else {
            throw Failure(name: "UnknownError", message: "The key couldn't be made.")
        }
        var id = Data(count: 16)
        id.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let resident = authenticator.supportsResidentKeys && (residentKey == "required" || residentKey == "preferred")
        var flags: Flags = [.userPresent, .attested]
        if authenticator.supportsUserVerification && authenticator.userVerified { flags.insert(.userVerified) }
        let authData = authenticatorData(rpID: rpID, flags: flags, counter: 0, credential: (id, key.coseKey))
        let clientData = clientDataJSON(type: "webauthn.create", challenge: challenge, origin: origin)
        // Asked for attestation: "packed" self attestation, signed with the
        // credential's own key (no certificate: there's no real device).
        let format: String
        let statement: DeveloperCBOR.Value
        switch request["attestation"] as? String {
        case "direct", "indirect", "enterprise":
            format = "packed"
            let signature = try key.sign(authData + Data(SHA256.hash(data: clientData)))
            statement = .map([(.text("alg"), .int(key.algorithm)), (.text("sig"), .bytes(signature))])
        default:
            format = "none"
            statement = .map([])
        }
        let attestation = DeveloperCBOR.encode(.map([
            (.text("fmt"), .text(format)), (.text("attStmt"), statement), (.text("authData"), .bytes(authData)),
        ]))
        let userName = user["name"] as? String ?? ""
        authenticator.credentials.append(DeveloperWebAuthnCredential(
            id: id, rpID: rpID, userHandle: resident ? userHandle : nil, userName: userName, isResident: resident,
            signCount: 0, key: key))
        return [
            "id": base64url(id), "rawId": base64url(id),
            "clientDataJSON": base64url(clientData),
            "attestationObject": base64url(attestation), "authenticatorData": base64url(authData),
            "publicKey": base64url(key.spki), "publicKeyAlgorithm": key.algorithm,
            "transports": [authenticator.transport.rawValue], "attachment": authenticator.attachment,
        ]
    }

    /// navigator.credentials.get(): an assertion from `authenticator`.
    static func get(_ request: [String: Any], origin: String, host: String,
                    authenticator: inout DeveloperVirtualAuthenticator) throws -> [String: Any] {
        let rpID = (request["rpId"] as? String) ?? host
        guard Self.rpID(rpID, validFor: host) else {
            throw Failure(name: "SecurityError", message: "The relying party ID '\(rpID)' isn't a registrable suffix of '\(host)'.")
        }
        guard let challenge = bytes(request["challenge"]) else { throw Failure(name: "TypeError", message: "No challenge.") }
        let uv = request["userVerification"] as? String ?? "preferred"
        if uv == "required", !(authenticator.supportsUserVerification && authenticator.userVerified) {
            throw Failure(name: "NotAllowedError", message: "The active authenticator can't verify the user.")
        }
        let allowed = ids(request["allowCredentials"])
        guard let index = authenticator.credentials.firstIndex(where: { credential in
            credential.rpID == rpID && (allowed.isEmpty ? credential.isResident : allowed.contains(credential.id))
        }) else {
            throw Failure(name: "NotAllowedError", message: "The active authenticator holds no credential for \(rpID).")
        }
        authenticator.credentials[index].signCount += 1
        let credential = authenticator.credentials[index]
        var flags: Flags = [.userPresent]
        if authenticator.supportsUserVerification && authenticator.userVerified { flags.insert(.userVerified) }
        let authData = authenticatorData(rpID: rpID, flags: flags, counter: credential.signCount)
        let clientData = clientDataJSON(type: "webauthn.get", challenge: challenge, origin: origin)
        let signature = try credential.key.sign(authData + Data(SHA256.hash(data: clientData)))
        var result: [String: Any] = [
            "id": credential.idString, "rawId": credential.idString,
            "clientDataJSON": base64url(clientData), "authenticatorData": base64url(authData),
            "signature": base64url(signature), "attachment": authenticator.attachment,
        ]
        if let handle = credential.userHandle { result["userHandle"] = base64url(handle) }
        return result
    }
}
