import CryptoKit
import Foundation
import Security

// The words Apple's Passwords helper speaks (idea 260, #425): the helper the
// iCloud Passwords extension for Chrome talks to. Nothing here runs a
// program or touches a window — ApplePasswords.swift does that; this is the
// arithmetic and the shape of the messages, kept apart so it can be tested
// with made-up numbers.
//
// The pairing is SRP-6a over RFC 5054's 3072-bit group with SHA-256, the
// six-digit code the helper shows being the password. Once paired, each
// question and answer is AES-GCM under the first 16 bytes of the shared key.
// The details — which numbers are padded, which way round the IV goes —
// follow Apple's own extension, and the tests hold them to vectors made by
// it (Tests/SearchTests/ApplePasswordsTests.swift).

// MARK: - numbers

/// An unsigned number as big as SRP needs, in 32-bit limbs, least
/// significant first. Only the few operations the handshake uses.
struct SRPNumber: Equatable {
    /// No high zero limbs: zero is the empty array.
    private(set) var limbs: [UInt32]

    init(limbs: [UInt32]) {
        var limbs = limbs
        while limbs.last == 0 { limbs.removeLast() }
        self.limbs = limbs
    }

    init(_ value: UInt32) { self.init(limbs: [value]) }

    /// From big-endian bytes, as on the wire.
    init<Bytes: Collection>(bytes: Bytes) where Bytes.Element == UInt8 {
        var limbs: [UInt32] = []
        limbs.reserveCapacity(bytes.count / 4 + 1)
        var limb: UInt32 = 0
        var shift: UInt32 = 0
        for byte in bytes.reversed() {
            limb |= UInt32(byte) << shift
            shift += 8
            if shift == 32 {
                limbs.append(limb)
                limb = 0
                shift = 0
            }
        }
        if shift > 0 { limbs.append(limb) }
        self.init(limbs: limbs)
    }

    init?(hex: String) {
        var text = hex
        if text.hasPrefix("0x") { text.removeFirst(2) }
        guard let bytes = Data(hexString: text) else { return nil }
        self.init(bytes: bytes)
    }

    var isZero: Bool { limbs.isEmpty }

    /// Big-endian, no leading zero bytes (a zero is one zero byte), the way
    /// Apple's extension writes a number it hashes.
    var bytes: [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(limbs.count * 4)
        for limb in limbs.reversed() {
            out.append(UInt8(truncatingIfNeeded: limb >> 24))
            out.append(UInt8(truncatingIfNeeded: limb >> 16))
            out.append(UInt8(truncatingIfNeeded: limb >> 8))
            out.append(UInt8(truncatingIfNeeded: limb))
        }
        let first = out.firstIndex { $0 != 0 } ?? max(0, out.count - 1)
        return out.isEmpty ? [0] : Array(out[first...])
    }

    /// Big-endian, left-padded with zeros to `length` bytes.
    func padded(_ length: Int) -> [UInt8] {
        let raw = bytes
        guard raw.count < length else { return Array(raw.suffix(length)) }
        return [UInt8](repeating: 0, count: length - raw.count) + raw
    }

    var bitLength: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    func bit(_ index: Int) -> Bool {
        let limb = index / 32
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> UInt32(index % 32)) & 1 == 1
    }

    static func compare(_ a: SRPNumber, _ b: SRPNumber) -> Int {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count ? -1 : 1 }
        for i in stride(from: a.limbs.count - 1, through: 0, by: -1) where a.limbs[i] != b.limbs[i] {
            return a.limbs[i] < b.limbs[i] ? -1 : 1
        }
        return 0
    }

    static func < (a: SRPNumber, b: SRPNumber) -> Bool { compare(a, b) < 0 }

    static func + (a: SRPNumber, b: SRPNumber) -> SRPNumber {
        let count = max(a.limbs.count, b.limbs.count)
        var out = [UInt32](repeating: 0, count: count + 1)
        var carry: UInt64 = 0
        for i in 0..<count {
            let sum = UInt64(i < a.limbs.count ? a.limbs[i] : 0) + UInt64(i < b.limbs.count ? b.limbs[i] : 0) + carry
            out[i] = UInt32(truncatingIfNeeded: sum)
            carry = sum >> 32
        }
        out[count] = UInt32(carry)
        return SRPNumber(limbs: out)
    }

    /// a − b, for a ≥ b only.
    static func - (a: SRPNumber, b: SRPNumber) -> SRPNumber {
        precondition(compare(a, b) >= 0, "SRPNumber: negative difference")
        var out = a.limbs
        var borrow: Int64 = 0
        for i in 0..<out.count {
            var diff = Int64(out[i]) - Int64(i < b.limbs.count ? b.limbs[i] : 0) - borrow
            borrow = diff < 0 ? 1 : 0
            if diff < 0 { diff += 1 << 32 }
            out[i] = UInt32(diff)
        }
        return SRPNumber(limbs: out)
    }

    static func * (a: SRPNumber, b: SRPNumber) -> SRPNumber {
        guard !a.isZero, !b.isZero else { return SRPNumber(limbs: []) }
        var out = [UInt32](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            let x = UInt64(a.limbs[i])
            for j in 0..<b.limbs.count {
                let t = UInt64(out[i + j]) + x * UInt64(b.limbs[j]) + carry
                out[i + j] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
            }
            out[i + b.limbs.count] = UInt32(carry)
        }
        return SRPNumber(limbs: out)
    }
}

/// Multiplication and powers modulo one odd number, in Montgomery form, so
/// no long division is ever needed. Every input must already be below the
/// modulus.
struct SRPModulus {
    let n: SRPNumber
    private let size: Int
    private let inverse: UInt32
    private let r2: [UInt32]

    init(_ n: SRPNumber) {
        precondition(n.bit(0), "SRPModulus: the modulus must be odd")
        self.n = n
        size = n.limbs.count
        // −n⁻¹ mod 2³², by Newton's iteration.
        var inv: UInt32 = 1
        for _ in 0..<5 { inv = inv &* (2 &- n.limbs[0] &* inv) }
        inverse = 0 &- inv
        // R² mod n, R = 2^(32·size), by doubling 1 that many times.
        var x = SRPNumber(1)
        for _ in 0..<(64 * size) {
            x = x + x
            if SRPNumber.compare(x, n) >= 0 { x = x - n }
        }
        r2 = Self.fixed(x, size)
    }

    private static func fixed(_ x: SRPNumber, _ size: Int) -> [UInt32] {
        var limbs = x.limbs
        limbs += [UInt32](repeating: 0, count: max(0, size - limbs.count))
        return limbs
    }

    /// a·b·R⁻¹ mod n (CIOS).
    private func product(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        let s = size
        var t = [UInt32](repeating: 0, count: s + 2)
        n.limbs.withUnsafeBufferPointer { n in
            a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in
                    t.withUnsafeMutableBufferPointer { t in
                        for i in 0..<s {
                            var carry: UInt64 = 0
                            let bi = UInt64(b[i])
                            for j in 0..<s {
                                let x = UInt64(t[j]) + UInt64(a[j]) * bi + carry
                                t[j] = UInt32(truncatingIfNeeded: x)
                                carry = x >> 32
                            }
                            var x = UInt64(t[s]) + carry
                            t[s] = UInt32(truncatingIfNeeded: x)
                            t[s + 1] = UInt32(x >> 32)
                            let m = UInt64(t[0] &* inverse)
                            x = UInt64(t[0]) + m * UInt64(n[0])
                            carry = x >> 32
                            for j in 1..<s {
                                x = UInt64(t[j]) + m * UInt64(n[j]) + carry
                                t[j - 1] = UInt32(truncatingIfNeeded: x)
                                carry = x >> 32
                            }
                            x = UInt64(t[s]) + carry
                            t[s - 1] = UInt32(truncatingIfNeeded: x)
                            t[s] = t[s + 1] &+ UInt32(x >> 32)
                        }
                    }
                }
            }
        }
        var out = SRPNumber(limbs: Array(t[0...s]))
        if SRPNumber.compare(out, n) >= 0 { out = out - n }
        return Self.fixed(out, s)
    }

    private func into(_ x: SRPNumber) -> [UInt32] {
        precondition(SRPNumber.compare(x, n) < 0, "SRPModulus: input not reduced")
        return product(Self.fixed(x, size), r2)
    }

    private func out(_ x: [UInt32]) -> SRPNumber {
        var one = [UInt32](repeating: 0, count: size)
        one[0] = 1
        return SRPNumber(limbs: product(x, one))
    }

    func multiply(_ a: SRPNumber, _ b: SRPNumber) -> SRPNumber {
        out(product(into(a), into(b)))
    }

    /// base^exponent mod n; the exponent may be any size.
    func power(_ base: SRPNumber, _ exponent: SRPNumber) -> SRPNumber {
        let b = into(base)
        var r = into(SRPNumber(1))
        let bits = exponent.bitLength
        guard bits > 0 else { return SRPNumber(1) }
        for i in stride(from: bits - 1, through: 0, by: -1) {
            r = product(r, r)
            if exponent.bit(i) { r = product(r, b) }
        }
        return out(r)
    }

    /// a − b mod n, both below n.
    func subtract(_ a: SRPNumber, _ b: SRPNumber) -> SRPNumber {
        SRPNumber.compare(a, b) >= 0 ? a - b : (a + n) - b
    }
}

// MARK: - the handshake

enum ApplePasswordsError: Error, Equatable {
    /// The helper's numbers are not ones a real helper would send.
    case badHello(String)
    /// The code was wrong (or old): the helper wants a new handshake.
    case wrongCode
    /// The helper's proof didn't match ours: not the helper we paired with.
    case notTheHelper
    case malformed(String)
    case status(Int)
    case timedOut
    case gone
}

/// One pairing's secrets, held in memory only. A new one per handshake;
/// dropped with the connection.
struct SRPClient {
    static let group = SRPNumber(hex: """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B\
        302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE6\
        49286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D\
        670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718\
        3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7D\
        B3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200C\
        BBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
        """)!
    static let generator = SRPNumber(5)
    static let groupBytes = 384
    static let modulus = SRPModulus(group)

    /// Whether numbers go as base64 or as 0x-hex: the helper says which.
    let base64: Bool
    /// The session's name, as written on the wire and hashed.
    let tid: String
    private let a: SRPNumber
    let publicKey: SRPNumber

    /// `random` is for tests; a real pairing takes the system's.
    init(base64: Bool, random: (Int) -> [UInt8] = SRPClient.secureRandom) {
        self.base64 = base64
        var name = random(16)
        // A full sixteen bytes: Apple's side reads the name as a number.
        name[0] |= 0x80
        let serialized = base64 ? Data(name).base64EncodedString() : "0x" + Data(name).hexString
        tid = serialized
        a = SRPNumber(bytes: random(32))
        publicKey = SRPClient.modulus.power(SRPClient.generator, a)
    }

    static func secureRandom(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "No randomness")
        return bytes
    }

    func serialize(_ bytes: [UInt8], prefix: Bool = true) -> String {
        base64 ? Data(bytes).base64EncodedString() : (prefix ? "0x" : "") + Data(bytes).hexString
    }

    func deserialize(_ text: String) -> [UInt8]? {
        if base64 { return Data(base64Encoded: text).map { [UInt8]($0) } }
        var hex = text
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        return Data(hexString: hex).map { [UInt8]($0) }
    }

    /// What pairing yields: our proof for the helper, the proof we expect
    /// back, and the key for everything after.
    struct Proof {
        let m: [UInt8]
        let expected: [UInt8]
        let key: SymmetricKey
    }

    private static func hash(_ parts: [UInt8]...) -> [UInt8] {
        var hasher = SHA256()
        parts.forEach { hasher.update(data: $0) }
        return Array(hasher.finalize())
    }

    /// The helper's numbers and the code you typed, to the proof. Refuses
    /// numbers no honest helper sends (B ≡ 0, B ≥ N, u = 0).
    func prove(serverKey: [UInt8], salt: [UInt8], code: String) throws -> Proof {
        let n = SRPClient.group, g = SRPClient.generator, size = SRPClient.groupBytes
        let mod = SRPClient.modulus
        let b = SRPNumber(bytes: serverKey)
        guard !b.isZero, b < n else { throw ApplePasswordsError.badHello("server key out of range") }
        guard !salt.isEmpty else { throw ApplePasswordsError.badHello("no salt") }
        let u = SRPNumber(bytes: Self.hash(publicKey.padded(size), b.padded(size)))
        guard !u.isZero else { throw ApplePasswordsError.badHello("u is zero") }
        let k = SRPNumber(bytes: Self.hash(n.bytes, g.padded(size)))
        let x = SRPNumber(bytes: Self.hash(salt, Self.hash(Array("\(tid):\(code)".utf8))))
        let v = mod.power(g, x)
        let s = mod.power(mod.subtract(b, mod.multiply(k, v)), a + u * x)
        let key = Self.hash(s.bytes)
        let hn = Self.hash(n.bytes), hg = Self.hash(g.padded(size))
        let xored = zip(hn, hg).map { $0 ^ $1 }
        let m = Self.hash(xored, Self.hash(Array(tid.utf8)), salt, publicKey.bytes, b.bytes, key)
        let expected = Self.hash(publicKey.bytes, m, key)
        return Proof(m: m, expected: expected, key: SymmetricKey(data: key.prefix(16)))
    }
}

// MARK: - the sealed channel

/// What goes over the channel once paired.
enum SecretChannel {
    /// Our questions: ciphertext and tag, then the 16-byte IV.
    static func seal(_ plain: Data, key: SymmetricKey, iv: [UInt8]? = nil) throws -> [UInt8] {
        let iv = iv ?? SRPClient.secureRandom(16)
        let box = try AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(data: iv))
        return [UInt8](box.ciphertext) + [UInt8](box.tag) + iv
    }

    /// The helper's answers: the IV first, then ciphertext and tag. (Apple's
    /// two directions differ; its extension does the same.)
    static func open(_ sealed: [UInt8], key: SymmetricKey) throws -> Data {
        guard sealed.count >= 32 else { throw ApplePasswordsError.malformed("short answer") }
        let iv = Array(sealed.prefix(16)), rest = sealed.dropFirst(16)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: rest.dropLast(16), tag: rest.suffix(16))
        return try AES.GCM.open(box, using: key)
    }
}

// MARK: - the messages

/// The commands, by Apple's numbers.
enum AppleCommand: Int {
    case end = 0
    case handshake = 2
    case loginNames = 4
    case password = 5
    case passwordsDisabled = 9
    case reloginNeeded = 10
    case hello = 14
}

/// One account the helper knows for a site: the name only. Its password is
/// asked for on its own, once picked.
struct AppleLogin: Identifiable, Equatable, Hashable {
    let user: String
    /// The sites the helper keeps it for, as it says.
    let sites: [String]
    var id: String { "apple\u{1}" + user }
}

enum AppleMessages {
    /// What the helper is told it is talking to. Apple's extension sends
    /// its browser's name; Search passes as Chrome, whose extension id it
    /// also gives (see ApplePasswords.swift).
    static let browser = "Chrome"

    private static func json(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func b64json(_ object: Any) -> String {
        Data(json(object).utf8).base64EncodedString()
    }

    static func hello() -> [String: Any] { ["cmd": AppleCommand.hello.rawValue] }

    static func end() -> [String: Any] { ["cmd": AppleCommand.end.rawValue] }

    /// The opening of a pairing: the helper puts its code on screen.
    static func start(_ client: SRPClient) -> [String: Any] {
        let pake = b64json(["TID": client.tid, "MSG": 0, "A": client.serialize(client.publicKey.bytes),
                            "VER": "1.0", "PROTO": [1]] as [String: Any])
        return ["cmd": AppleCommand.handshake.rawValue,
                "msg": json(["QID": "m0", "PAKE": pake, "HSTBRSR": browser])]
    }

    static func verify(_ client: SRPClient, proof: SRPClient.Proof) -> [String: Any] {
        let pake = b64json(["TID": client.tid, "MSG": 2, "M": client.serialize(proof.m, prefix: false)] as [String: Any])
        return ["cmd": AppleCommand.handshake.rawValue, "msg": json(["QID": "m2", "PAKE": pake])]
    }

    /// A sealed question about one site.
    static func ask(_ command: AppleCommand, query: String, body: [String: Any], host: String, tab: Int,
                    client: SRPClient, key: SymmetricKey, iv: [UInt8]? = nil) throws -> [String: Any] {
        let sealed = try SecretChannel.seal(Data(json(body).utf8), key: key, iv: iv)
        let smsg = json(["TID": client.tid, "SDATA": client.serialize(sealed, prefix: false)])
        return ["cmd": command.rawValue, "url": host, "tabId": tab, "frameId": 0,
                "payload": json(["QID": query, "SMSG": smsg])]
    }

    static func loginNames(host: String, tab: Int, client: SRPClient, key: SymmetricKey) throws -> [String: Any] {
        try ask(.loginNames, query: "CmdGetLoginNames4URL", body: ["ACT": 5, "URL": host],
                host: host, tab: tab, client: client, key: key)
    }

    static func password(user: String, host: String, tab: Int, client: SRPClient, key: SymmetricKey) throws -> [String: Any] {
        try ask(.password, query: "CmdGetPassword4LoginName", body: ["ACT": 2, "URL": host, "USR": user],
                host: host, tab: tab, client: client, key: key)
    }

    // Reading.

    private static func object(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] { return dictionary }
        if let text = value as? String, let data = text.data(using: .utf8) {
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        return nil
    }

    private static func pake(_ reply: [String: Any], _ client: SRPClient) throws -> [String: Any] {
        guard let payload = object(reply["payload"]), let encoded = payload["PAKE"] as? String,
              let data = Data(base64Encoded: encoded),
              let pake = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw ApplePasswordsError.malformed("no PAKE") }
        guard (pake["TID"] as? String).flatMap(client.deserialize) == client.deserialize(client.tid) else {
            throw ApplePasswordsError.malformed("another session's message")
        }
        return pake
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// The helper's numbers, once it has put its code on screen.
    static func readStart(_ reply: [String: Any], _ client: SRPClient) throws -> (serverKey: [UInt8], salt: [UInt8]) {
        let pake = try pake(reply, client)
        if let error = int(pake["ErrCode"]) { throw ApplePasswordsError.badHello("error \(error)") }
        guard int(pake["MSG"]) == 1 else { throw ApplePasswordsError.badHello("unexpected message") }
        // Only the RFC's proof: an older, weaker one is refused rather than
        // fallen back to.
        guard int(pake["PROTO"]) == 1 else { throw ApplePasswordsError.badHello("unsupported protocol") }
        guard let b = (pake["B"] as? String).flatMap(client.deserialize),
              let s = (pake["s"] as? String).flatMap(client.deserialize)
        else { throw ApplePasswordsError.badHello("missing numbers") }
        return (b, s)
    }

    /// Whether the helper took the code, and is the helper we think.
    static func readVerify(_ reply: [String: Any], _ client: SRPClient, proof: SRPClient.Proof) throws {
        let pake = try pake(reply, client)
        guard int(pake["MSG"]) == 3 else { throw ApplePasswordsError.malformed("unexpected message") }
        switch int(pake["ErrCode"]) {
        case 0: break
        case 1: throw ApplePasswordsError.wrongCode
        case let code: throw ApplePasswordsError.badHello("error \(code.map(String.init) ?? "none")")
        }
        guard let hamk = (pake["HAMK"] as? String).flatMap(client.deserialize),
              hamk.count == proof.expected.count,
              zip(hamk, proof.expected).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0
        else { throw ApplePasswordsError.notTheHelper }
    }

    /// A sealed answer, opened.
    static func readSealed(_ reply: [String: Any], _ client: SRPClient, key: SymmetricKey) throws -> [String: Any] {
        guard let payload = object(reply["payload"]), let smsg = object(payload["SMSG"]),
              let sdata = (smsg["SDATA"] as? String).flatMap(client.deserialize)
        else { throw ApplePasswordsError.malformed("no SMSG") }
        guard (smsg["TID"] as? String).flatMap(client.deserialize) == client.deserialize(client.tid) else {
            throw ApplePasswordsError.malformed("another session's answer")
        }
        let plain = try SecretChannel.open(sdata, key: key)
        guard let answer = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else {
            throw ApplePasswordsError.malformed("unreadable answer")
        }
        return answer
    }

    /// The entries of an answer: under "Entries", or as Entry_0, Entry_1…
    private static func entries(_ answer: [String: Any]) -> [[String: Any]] {
        if let list = answer["Entries"] as? [[String: Any]] { return list }
        return answer.keys.filter { $0.hasPrefix("Entry_") }.sorted().compactMap { answer[$0] as? [String: Any] }
    }

    /// Names only. The helper's marker for a site you told never to save is
    /// not an account.
    static func readLoginNames(_ answer: [String: Any]) throws -> [AppleLogin] {
        switch int(answer["STATUS"]) {
        case 0:
            return entries(answer).compactMap { entry in
                guard let user = entry["USR"] as? String, user != "Passwords not saved" else { return nil }
                return AppleLogin(user: user, sites: entry["sites"] as? [String] ?? [])
            }
        case 3: return []
        case let status: throw ApplePasswordsError.status(status ?? -1)
        }
    }

    /// The one account asked for, with its password — or nothing.
    static func readPassword(_ answer: [String: Any], user: String) throws -> (user: String, password: String, sites: [String])? {
        switch int(answer["STATUS"]) {
        case 0:
            for entry in entries(answer) {
                guard let name = entry["USR"] as? String, name == user,
                      let password = entry["PWD"] as? String, !password.isEmpty, password != "Not Included"
                else { continue }
                return (name, password, entry["sites"] as? [String] ?? [])
            }
            return nil
        case 3: return nil
        case let status: throw ApplePasswordsError.status(status ?? -1)
        }
    }
}

// MARK: - hex

extension Data {
    init?(hexString: String) {
        var text = hexString
        if text.count % 2 == 1 { text = "0" + text }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
