import CryptoKit
import Foundation
import XCTest
@testable import Search

/// Apple Passwords (idea 260): the protocol pieces against synthetic vectors,
/// and the client's whole flow against made-up helpers — one in memory, one
/// a real process over a pipe. Apple's own helper is never run, no real code,
/// password or account is used, and nothing is written to a keychain.
@MainActor
final class ApplePasswordsTests: XCTestCase {
    private struct Vectors: Decodable {
        struct SRP: Decodable {
            let base64: Bool
            let pin, TID, a, I, salt, B, m0A, M, HAMK, channel: String
            let requestPlain, requestIV, requestSDATA, replyPlain, replySDATA: String
        }
        struct PowMod: Decodable { let base, exp, out: String }
        let srp: [SRP]
        let powmods: [PowMod]
    }

    private var vectors: Vectors {
        try! JSONDecoder().decode(Vectors.self, from: Data(ApplePasswordsVectors.json.utf8))
    }

    private func bytes(_ hex: String) -> [UInt8] { [UInt8](Data(hexString: hex)!) }

    // MARK: - numbers

    func testGroupIsRFC5054() {
        XCTAssertEqual(SRPClient.group.bitLength, 3072)
        XCTAssertEqual(SRPClient.group.bytes.count, 384)
        XCTAssertEqual(Data(SRPClient.group.bytes.prefix(8)).hexString, "ffffffffffffffff")
        XCTAssertEqual(Data(SRPClient.group.bytes.suffix(8)).hexString, "ffffffffffffffff")
    }

    func testPowersMatchReference() {
        for vector in vectors.powmods {
            let out = SRPClient.modulus.power(SRPNumber(bytes: bytes(vector.base)), SRPNumber(bytes: bytes(vector.exp)))
            XCTAssertEqual(Data(out.bytes).hexString, vector.out)
        }
    }

    func testArithmetic() {
        let a = SRPNumber(hex: "ffffffffffffffffffffffff")!, one = SRPNumber(1)
        XCTAssertEqual(Data((a + one).bytes).hexString, "01000000000000000000000000")
        XCTAssertEqual((a + one) - one, a)
        XCTAssertEqual(Data((a * a).bytes).hexString, "fffffffffffffffffffffffe000000000000000000000001")
        XCTAssertEqual(SRPNumber(bytes: [0, 0, 5]).bytes, [5])
        XCTAssertEqual(SRPNumber(limbs: []).bytes, [0])
        XCTAssertEqual(SRPNumber(5).padded(4), [0, 0, 0, 5])
        let n = SRPClient.group
        XCTAssertEqual(SRPClient.modulus.subtract(one, SRPNumber(2)), n - one)
        XCTAssertEqual(SRPClient.modulus.multiply(n - one, n - one), one)
    }

    // MARK: - the handshake, against Apple's own extension's numbers

    private func client(for vector: Vectors.SRP) -> SRPClient {
        var draws = [bytes(vector.I), bytes(vector.a)]
        return SRPClient(base64: vector.base64) { _ in draws.removeFirst() }
    }

    func testHandshakeMatchesApplesExtension() throws {
        XCTAssertEqual(vectors.srp.count, 3)
        for vector in vectors.srp {
            let client = client(for: vector)
            XCTAssertEqual(client.tid, vector.TID)
            XCTAssertEqual(client.serialize(client.publicKey.bytes), vector.m0A)
            let proof = try client.prove(serverKey: bytes(vector.B), salt: bytes(vector.salt), code: vector.pin)
            XCTAssertEqual(Data(proof.m).hexString, vector.M)
            XCTAssertEqual(Data(proof.expected).hexString, vector.HAMK)
            XCTAssertEqual(proof.key.withUnsafeBytes { Data($0).hexString }, vector.channel)
            // A wrong code proves something else.
            let wrong = try client.prove(serverKey: bytes(vector.B), salt: bytes(vector.salt), code: "111111")
            XCTAssertNotEqual(wrong.m, proof.m)
        }
    }

    func testSaltWithLeadingZeroKeepsItsZero() throws {
        let vector = vectors.srp[2]
        XCTAssertTrue(vector.salt.hasPrefix("00"))
        let proof = try client(for: vector).prove(serverKey: bytes(vector.B), salt: bytes(vector.salt), code: vector.pin)
        XCTAssertEqual(Data(proof.m).hexString, vector.M)
    }

    func testChannelMatchesApplesFraming() throws {
        for vector in vectors.srp {
            let client = client(for: vector)
            let key = SymmetricKey(data: bytes(vector.channel))
            // Ours: ciphertext and tag, then the IV.
            let sealed = try SecretChannel.seal(Data(vector.requestPlain.utf8), key: key, iv: bytes(vector.requestIV))
            XCTAssertEqual(client.serialize(sealed, prefix: false), vector.requestSDATA)
            XCTAssertEqual(Array(sealed.suffix(16)), bytes(vector.requestIV))
            // The helper's: the IV first.
            let reply = try SecretChannel.open(client.deserialize(vector.replySDATA)!, key: key)
            XCTAssertEqual(String(decoding: reply, as: UTF8.self), vector.replyPlain)
            // Tampered with, it doesn't open.
            var bad = client.deserialize(vector.replySDATA)!
            bad[bad.count - 1] ^= 1
            XCTAssertThrowsError(try SecretChannel.open(bad, key: key))
        }
    }

    func testRefusesNumbersNoHelperSends() {
        let client = SRPClient(base64: false)
        let n = SRPClient.group
        for b in [SRPNumber(limbs: []), n, n + SRPNumber(1)] {
            XCTAssertThrowsError(try client.prove(serverKey: b.bytes, salt: [1, 2, 3], code: "123456")) {
                guard case ApplePasswordsError.badHello = $0 else { return XCTFail("\($0)") }
            }
        }
        XCTAssertThrowsError(try client.prove(serverKey: [2], salt: [], code: "123456"))
    }

    // MARK: - the messages

    private func decode(_ text: Any?) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data((text as? String ?? "").utf8))) as? [String: Any] ?? [:]
    }

    private func pake(_ object: [String: Any]) -> String {
        Data(try! JSONSerialization.data(withJSONObject: object)).base64EncodedString()
    }

    func testStartAsksForRFCProofOnly() {
        let client = SRPClient(base64: false)
        let message = AppleMessages.start(client)
        XCTAssertEqual(message["cmd"] as? Int, 2)
        let msg = decode(message["msg"])
        XCTAssertEqual(msg["QID"] as? String, "m0")
        XCTAssertEqual(msg["HSTBRSR"] as? String, "Chrome")
        let inner = (try? JSONSerialization.jsonObject(with: Data(base64Encoded: msg["PAKE"] as! String)!)) as! [String: Any]
        XCTAssertEqual(inner["TID"] as? String, client.tid)
        XCTAssertEqual(inner["MSG"] as? Int, 0)
        XCTAssertEqual(inner["PROTO"] as? [Int], [1])
        XCTAssertEqual(inner["VER"] as? String, "1.0")
    }

    func testReadStartRefusesDowngradeErrorsAndStrangers() {
        let client = SRPClient(base64: false)
        func reply(_ fields: [String: Any]) -> [String: Any] {
            var all: [String: Any] = ["TID": client.tid, "MSG": 1, "B": "0x05", "s": "0x01", "PROTO": 1]
            fields.forEach { all[$0] = $1 }
            return ["cmd": 2, "payload": ["QID": "m0", "PAKE": pake(all)]]
        }
        XCTAssertNoThrow(try AppleMessages.readStart(reply([:]), client))
        XCTAssertThrowsError(try AppleMessages.readStart(reply(["PROTO": 0]), client))
        XCTAssertThrowsError(try AppleMessages.readStart(reply(["ErrCode": 2]), client))
        XCTAssertThrowsError(try AppleMessages.readStart(reply(["TID": "0x1234"]), client))
        XCTAssertThrowsError(try AppleMessages.readStart(reply(["MSG": 3]), client))
        XCTAssertThrowsError(try AppleMessages.readStart(["cmd": 2], client))
    }

    func testReadVerify() throws {
        let vector = vectors.srp[0]
        let client = client(for: vector)
        let proof = try client.prove(serverKey: bytes(vector.B), salt: bytes(vector.salt), code: vector.pin)
        func reply(_ fields: [String: Any]) -> [String: Any] {
            var all: [String: Any] = ["TID": client.tid, "MSG": 3, "ErrCode": 0, "HAMK": vector.HAMK]
            fields.forEach { all[$0] = $1 }
            return ["cmd": 2, "payload": ["QID": "m2", "PAKE": pake(all)]]
        }
        XCTAssertNoThrow(try AppleMessages.readVerify(reply([:]), client, proof: proof))
        XCTAssertThrowsError(try AppleMessages.readVerify(reply(["ErrCode": 1]), client, proof: proof)) {
            XCTAssertEqual($0 as? ApplePasswordsError, .wrongCode)
        }
        var hamk = bytes(vector.HAMK)
        hamk[0] ^= 1
        XCTAssertThrowsError(try AppleMessages.readVerify(reply(["HAMK": Data(hamk).hexString]), client, proof: proof)) {
            XCTAssertEqual($0 as? ApplePasswordsError, .notTheHelper)
        }
        XCTAssertThrowsError(try AppleMessages.readVerify(reply(["HAMK": NSNull()]), client, proof: proof))
    }

    func testReadingAnswers() throws {
        let names = try AppleMessages.readLoginNames(["STATUS": 0, "Entries": [
            ["USR": "ada@example.test", "sites": ["example.test"]],
            ["USR": "Passwords not saved", "sites": ["example.test"]],
        ]])
        XCTAssertEqual(names.map(\.user), ["ada@example.test"])
        let numbered = try AppleMessages.readLoginNames(["STATUS": 0, "Entry_1": ["USR": "b", "sites": []],
                                                         "Entry_0": ["USR": "a", "sites": []]])
        XCTAssertEqual(numbered.map(\.user), ["a", "b"])
        XCTAssertEqual(try AppleMessages.readLoginNames(["STATUS": 3]), [])
        XCTAssertThrowsError(try AppleMessages.readLoginNames(["STATUS": 9])) {
            XCTAssertEqual($0 as? ApplePasswordsError, .status(9))
        }
        let found = try AppleMessages.readPassword(["STATUS": 0, "Entries": [
            ["USR": "other", "PWD": "x", "sites": ["example.test"]],
            ["USR": "ada", "PWD": "made-up-secret", "sites": ["example.test"]],
        ]], user: "ada")
        XCTAssertEqual(found?.password, "made-up-secret")
        XCTAssertNil(try AppleMessages.readPassword(["STATUS": 0, "Entries": [["USR": "ada", "PWD": "Not Included"]]], user: "ada"))
        XCTAssertNil(try AppleMessages.readPassword(["STATUS": 0, "Entries": [["USR": "eve", "PWD": "x"]]], user: "ada"))
    }

    // MARK: - which pages, which accounts

    func testOffersOnlyHttpsInOrdinaryTabs() {
        XCTAssertEqual(ApplePasswords.offers(on: URL(string: "https://Accounts.Example.com/login"), privateTab: false), "accounts.example.com")
        XCTAssertNil(ApplePasswords.offers(on: URL(string: "https://example.com/"), privateTab: true))
        XCTAssertNil(ApplePasswords.offers(on: URL(string: "http://example.com/"), privateTab: false))
        XCTAssertNil(ApplePasswords.offers(on: URL(string: "file:///tmp/login.html"), privateTab: false))
        XCTAssertNil(ApplePasswords.offers(on: URL(string: "chrome-extension://abc/popup.html"), privateTab: false))
        XCTAssertNil(ApplePasswords.offers(on: nil, privateTab: false))
    }

    func testAccountsMatchTheSiteAsSearchsOwnDo() {
        let registrable: (String) -> String = { host in
            let parts = host.split(separator: ".")
            if host.hasSuffix(".co.uk") { return parts.suffix(3).joined(separator: ".") }
            return parts.suffix(2).joined(separator: ".")
        }
        func belongs(_ sites: [String], _ host: String) -> Bool { ApplePasswords.belongs(sites, to: host, registrable: registrable) }
        XCTAssertTrue(belongs(["example.com"], "accounts.example.com"))
        XCTAssertTrue(belongs(["www.example.com"], "example.com"))
        XCTAssertTrue(belongs(["https://login.example.com/"], "example.com"))
        XCTAssertTrue(belongs(["other.test", "example.com"], "example.com"))
        XCTAssertFalse(belongs(["example.net"], "example.com"))
        XCTAssertFalse(belongs(["evil-example.com"], "example.com"))
        XCTAssertFalse(belongs(["example.com.evil.test"], "example.com"))
        XCTAssertFalse(belongs(["bbc.co.uk"], "other.co.uk"))
        XCTAssertFalse(belongs([], "example.com"))
    }

    func testFillIsRecognisedWithoutKeepingThePassword() {
        let fill = AppleFill(host: "accounts.example.test", user: "ada", password: "made-up-secret")
        XCTAssertTrue(fill.matches(host: "accounts.example.test", user: "ada", password: "made-up-secret"))
        XCTAssertFalse(fill.matches(host: "accounts.example.test", user: "ada", password: "changed"))
        XCTAssertFalse(fill.matches(host: "accounts.example.test", user: "bob", password: "made-up-secret"))
        XCTAssertFalse(fill.matches(host: "elsewhere.test", user: "ada", password: "made-up-secret"))
        XCTAssertFalse(String(describing: fill).contains("made-up-secret"))
    }

    // MARK: - the helper on this Mac

    func testOnlyApplesSignedHelperIsRun() throws {
        // A bundle claiming the name, not signed by Apple, is never picked.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("apw-fake-\(UUID().uuidString)")
        let bundle = folder.appendingPathComponent("PasswordManagerBrowserExtensionHelper.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let program = bundle.appendingPathComponent("Contents/MacOS/PasswordManagerBrowserExtensionHelper")
        try "#!/bin/sh\n".write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        XCTAssertFalse(AppleHelper.isApples(bundle))
        // Apple's, where this Mac has it: only its signature is read, it is not run.
        let real = URL(fileURLWithPath: "/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app")
        if FileManager.default.fileExists(atPath: real.path) {
            XCTAssertTrue(AppleHelper.isApples(real))
            XCTAssertEqual(AppleHelper.program()?.lastPathComponent, "PasswordManagerBrowserExtensionHelper")
        }
        // Something Apple signed that isn't the helper doesn't pass either.
        XCTAssertFalse(AppleHelper.isApples(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
    }

    // MARK: - the whole flow, against a made-up helper in memory

    func testPairAskAndFill() async throws {
        let fake = FakeHelper(code: "246810")
        let apple = ApplePasswords(makeLink: { fake })
        await apple.connect()
        XCTAssertEqual(apple.state, .code)
        XCTAssertEqual(fake.handshakes, 1)
        // Names can't be asked for before pairing.
        let early = await apple.logins(for: "example.test", tab: UUID())
        XCTAssertEqual(early, [])

        await apple.enter("246810")
        XCTAssertEqual(apple.state, .paired)
        let tab = UUID()
        let names = await apple.logins(for: "accounts.example.test", tab: tab)
        XCTAssertEqual(names.map(\.user), ["ada@example.test"])
        XCTAssertEqual(fake.asked.last?["URL"] as? String, "accounts.example.test")
        XCTAssertEqual(fake.asked.last?["ACT"] as? Int, 5)
        XCTAssertNil(fake.asked.last?["PWD"])
        let found = await apple.password(for: "ada@example.test", host: "accounts.example.test", tab: tab)
        XCTAssertEqual(found?.password, "made-up-secret")
        XCTAssertEqual(fake.asked.last?["ACT"] as? Int, 2)
        let none = await apple.password(for: "nobody", host: "accounts.example.test", tab: tab)
        XCTAssertNil(none)

        // Off: the helper is told goodbye and stopped.
        apple.disconnect()
        XCTAssertEqual(apple.state, .idle)
        XCTAssertTrue(fake.ended)
        XCTAssertTrue(fake.stopped)
        let after = await apple.logins(for: "accounts.example.test", tab: tab)
        XCTAssertEqual(after, [])
    }

    func testWrongCodeNeedsANewPairing() async {
        let fake = FakeHelper(code: "246810")
        let apple = ApplePasswords(makeLink: { fake })
        await apple.connect()
        await apple.enter("135791")
        XCTAssertEqual(apple.state, .idle)
        XCTAssertNotNil(apple.trouble)
        // The old code can't be tried again: Connect starts a new handshake.
        await apple.enter("246810")
        XCTAssertEqual(apple.state, .idle)
        await apple.connect()
        XCTAssertEqual(fake.handshakes, 2)
        await apple.enter("246810")
        XCTAssertEqual(apple.state, .paired)
    }

    func testNotACodeIsNotSent() async {
        let fake = FakeHelper(code: "246810")
        let apple = ApplePasswords(makeLink: { fake })
        await apple.connect()
        await apple.enter("12345")
        await apple.enter("abcdef")
        XCTAssertEqual(apple.state, .code)
        XCTAssertEqual(fake.verifications, 0)
    }

    func testImpostorHelperIsRefused() async {
        let fake = FakeHelper(code: "246810")
        fake.lieAboutProof = true
        let apple = ApplePasswords(makeLink: { fake })
        await apple.connect()
        await apple.enter("246810")
        XCTAssertEqual(apple.state, .idle)
        XCTAssertTrue(fake.stopped)
    }

    func testSignedOutOrHelperGoneDropsThePairing() async {
        let fake = FakeHelper(code: "246810")
        let apple = ApplePasswords(makeLink: { fake })
        await apple.connect()
        await apple.enter("246810")
        XCTAssertEqual(apple.state, .paired)
        fake.onMessage?(["cmd": 10])
        XCTAssertEqual(apple.state, .idle)

        let again = FakeHelper(code: "111222")
        let other = ApplePasswords(makeLink: { again })
        await other.connect()
        await other.enter("111222")
        XCTAssertEqual(other.state, .paired)
        again.onEnd?()
        XCTAssertEqual(other.state, .idle)
        let after = await other.logins(for: "example.test", tab: UUID())
        XCTAssertEqual(after, [])
    }

    func testHelperThatWontRunSaysSo() async {
        let apple = ApplePasswords(makeLink: { throw ApplePasswords.Unavailable(errorDescription: "Apple's Passwords helper isn't on this Mac") })
        await apple.connect()
        XCTAssertEqual(apple.state, .idle)
        XCTAssertEqual(apple.trouble, "Apple's Passwords helper isn't on this Mac")
    }

    func testOldHelperIsRefused() async {
        let fake = FakeHelper(code: "246810")
        fake.sessionVersion = 0
        let apple = ApplePasswords(makeLink: { fake })
        await apple.connect()
        XCTAssertEqual(apple.state, .idle)
        XCTAssertEqual(fake.handshakes, 0)
    }

    // MARK: - over a real pipe, against a made-up helper in node

    @available(macOS 15.4, *)
    func testOverAPipeAgainstAnIndependentHelper() async throws {
        guard let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw XCTSkip("node isn't installed") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("apw-node-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("helper.js")
        try NodeHelper.source.write(to: script, atomically: true, encoding: .utf8)
        let launcher = folder.appendingPathComponent("helper")
        try "#!/bin/sh\nexec \(node) \(script.path) \"$@\"\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        for base64 in [false, true] {
            setenv("APW_FAKE_BASE64", base64 ? "1" : "0", 1)
            let apple = ApplePasswords(makeLink: { HelperLink(program: launcher) })
            await apple.connect()
            XCTAssertEqual(apple.state, .code, "base64 \(base64): \(apple.trouble ?? "")")
            await apple.enter("314159")
            XCTAssertEqual(apple.state, .paired, "base64 \(base64): \(apple.trouble ?? "")")
            let names = await apple.logins(for: "www.example.test", tab: UUID())
            XCTAssertEqual(names.map(\.user), ["ada@example.test", "bob@example.test"])
            let found = await apple.password(for: "bob@example.test", host: "www.example.test", tab: UUID())
            XCTAssertEqual(found?.password, "another-made-up-one")
            apple.disconnect()
        }
        unsetenv("APW_FAKE_BASE64")
    }
}

/// A helper made up in Swift: it pairs with `code`, keeps one account, and
/// says what it was asked. The server's side of SRP-6a: B = kv + gᵇ,

/// The code asked for where it is needed (Drice, 24 Oct): nothing runs the
/// helper until you choose Connect, and the code goes into a card under the
/// sign-in box instead of Settings, which goes once paired.
@MainActor
final class ApplePairingTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "sec-apw2-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() { _ = NSApplication.shared }

    func testNothingRunsUntilAsked() async {
        var made = 0
        let fake = FakeHelper(code: "246810")
        let apple = ApplePasswords(makeLink: { made += 1; return fake })
        // Asking for names unpaired, or a password, never starts a pairing.
        let names = await apple.logins(for: "example.test", tab: UUID())
        let found = await apple.password(for: "ada@example.test", host: "example.test", tab: UUID())
        XCTAssertEqual(names, [])
        XCTAssertNil(found)
        XCTAssertEqual(made, 0)
        XCTAssertEqual(fake.handshakes, 0)
        await apple.connect()
        XCTAssertEqual(made, 1)
        XCTAssertEqual(fake.handshakes, 1)
    }

    func testCardPairsAndGoes() async throws {
        let fake = FakeHelper(code: "246810")
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.applePasswords = ApplePasswords(makeLink: { fake })
        let tab = UUID()
        browser.beginApplePairing(on: tab, at: CGRect(x: 10, y: 20, width: 200, height: 30))
        XCTAssertEqual(browser.applePairing?.tab, tab)
        try await settle { browser.applePasswords.state == .code }
        XCTAssertEqual(fake.handshakes, 1)
        // A second Connect while one is under way starts no other handshake.
        browser.beginApplePairing(on: tab, at: .zero)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fake.handshakes, 1)
        await browser.applePasswords.enter("246810")
        XCTAssertEqual(browser.applePasswords.state, .paired)
        try await settle { browser.applePairing == nil }
        XCTAssertFalse(fake.stopped)
    }

    func testCancelStopsTheHelper() async throws {
        let fake = FakeHelper(code: "246810")
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.applePasswords = ApplePasswords(makeLink: { fake })
        browser.beginApplePairing(on: UUID(), at: .zero)
        try await settle { browser.applePasswords.state == .code }
        browser.endApplePairing(paired: false)
        XCTAssertNil(browser.applePairing)
        XCTAssertEqual(browser.applePasswords.state, .idle)
        XCTAssertTrue(fake.ended)
        XCTAssertTrue(fake.stopped)
    }

    func testCancelKeepsAPairingAlreadyMade() async throws {
        let fake = FakeHelper(code: "246810")
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.applePasswords = ApplePasswords(makeLink: { fake })
        await browser.applePasswords.connect()
        await browser.applePasswords.enter("246810")
        browser.beginApplePairing(on: UUID(), at: .zero)
        browser.endApplePairing(paired: false)
        XCTAssertEqual(browser.applePasswords.state, .paired)
        XCTAssertFalse(fake.stopped)
    }

    private func settle(_ done: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !done() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(done())
    }
}

/// S = (A·vᵘ)ᵇ.
private final class FakeHelper: AppleLink {
    var onMessage: (([String: Any]) -> Void)?
    var onEnd: (() -> Void)?
    let code: String
    var sessionVersion = 1
    var lieAboutProof = false
    private(set) var handshakes = 0
    private(set) var verifications = 0
    private(set) var asked: [[String: Any]] = []
    private(set) var ended = false
    private(set) var stopped = false
    private var tid = ""
    private var a = SRPNumber(1), b = SRPNumber(1), v = SRPNumber(1)
    private var salt: [UInt8] = []
    private var key: SymmetricKey?

    init(code: String) { self.code = code }

    func start() throws {}
    func stop() { stopped = true }

    private static func hash(_ parts: [UInt8]...) -> [UInt8] {
        var hasher = SHA256()
        parts.forEach { hasher.update(data: $0) }
        return Array(hasher.finalize())
    }

    private func json(_ text: Any?) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data((text as? String ?? "").utf8))) as? [String: Any] ?? [:]
    }

    private func b64(_ object: [String: Any]) -> String {
        try! JSONSerialization.data(withJSONObject: object).base64EncodedString()
    }

    private func answer(_ reply: [String: Any]) {
        DispatchQueue.main.async { self.onMessage?(reply) }
    }

    func send(_ message: [String: Any]) throws {
        let mod = SRPClient.modulus, n = SRPClient.group, g = SRPClient.generator
        switch message["cmd"] as? Int {
        case 14:
            answer(["cmd": 14, "capabilities": ["shouldUseBase64": false, "secretSessionVersion": sessionVersion]])
        case 0:
            ended = true
        case 2:
            let msg = json(message["msg"])
            let pake = (try? JSONSerialization.jsonObject(with: Data(base64Encoded: msg["PAKE"] as! String)!)) as! [String: Any]
            if msg["QID"] as? String == "m0" {
                handshakes += 1
                tid = pake["TID"] as! String
                a = SRPNumber(hex: pake["A"] as! String)!
                salt = SRPClient.secureRandom(16)
                b = SRPNumber(bytes: SRPClient.secureRandom(32))
                let x = SRPNumber(bytes: Self.hash(salt, Self.hash(Array("\(tid):\(code)".utf8))))
                v = mod.power(g, x)
                let k = SRPNumber(bytes: Self.hash(n.bytes, g.padded(384)))
                var bigB = mod.multiply(k, v) + mod.power(g, b)
                if !(bigB < n) { bigB = bigB - n }
                answer(["cmd": 2, "payload": ["QID": "m0", "PAKE": b64(["TID": tid, "MSG": 1, "B": "0x" + Data(bigB.bytes).hexString,
                                                                    "s": "0x" + Data(salt).hexString, "PROTO": 1, "VER": "1.0"])]])
            } else {
                verifications += 1
                let k = SRPNumber(bytes: Self.hash(n.bytes, g.padded(384)))
                let bigB = SRPNumber(bytes: {
                    var x = mod.multiply(k, v) + mod.power(g, b)
                    if !(x < n) { x = x - n }
                    return x.bytes
                }())
                let u = SRPNumber(bytes: Self.hash(a.padded(384), bigB.padded(384)))
                let s = mod.power(mod.multiply(a, mod.power(v, u)), b)
                let sessionKey = Self.hash(s.bytes)
                let hn = Self.hash(n.bytes), hg = Self.hash(g.padded(384))
                let m = Self.hash(zip(hn, hg).map { $0 ^ $1 }, Self.hash(Array(tid.utf8)), salt, a.bytes, bigB.bytes, sessionKey)
                let theirs = [UInt8](Data(hexString: pake["M"] as! String)!)
                guard theirs == m else {
                    answer(["cmd": 2, "payload": ["QID": "m2", "PAKE": b64(["TID": tid, "MSG": 3, "ErrCode": 1])]])
                    return
                }
                key = SymmetricKey(data: sessionKey.prefix(16))
                var hamk = Self.hash(a.bytes, m, sessionKey)
                if lieAboutProof { hamk[0] ^= 1 }
                answer(["cmd": 2, "payload": ["QID": "m2", "PAKE": b64(["TID": tid, "MSG": 3, "ErrCode": 0,
                                                                    "HAMK": Data(hamk).hexString])]])
            }
        case let command? where command == 4 || command == 5:
            guard let key else { return }
            let payload = json(message["payload"])
            let smsg = json(payload["SMSG"])
            let sealed = [UInt8](Data(hexString: smsg["SDATA"] as! String)!)
            let iv = Array(sealed.suffix(16)), body = sealed.dropLast(16)
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: body.dropLast(16), tag: body.suffix(16))
            let question = json(String(decoding: try AES.GCM.open(box, using: key), as: UTF8.self))
            asked.append(question)
            var reply: [String: Any] = ["STATUS": 3]
            if command == 4 {
                reply = ["STATUS": 0, "Entries": [["USR": "ada@example.test", "sites": ["example.test"]]]]
            } else if question["USR"] as? String == "ada@example.test" {
                reply = ["STATUS": 0, "Entries": [["USR": "ada@example.test", "PWD": "made-up-secret", "sites": ["example.test"]]]]
            }
            let replyIV = SRPClient.secureRandom(16)
            let out = try AES.GCM.seal(try JSONSerialization.data(withJSONObject: reply), using: key, nonce: AES.GCM.Nonce(data: replyIV))
            let framed = replyIV + [UInt8](out.ciphertext) + [UInt8](out.tag)
            answer(["cmd": command, "payload": ["QID": payload["QID"] ?? "", "SMSG": ["TID": tid, "SDATA": Data(framed).hexString]]])
        default:
            break
        }
    }
}

/// A made-up helper in node, independent of Search's arithmetic: BigInt
/// and node's own crypto. It pairs with the code 314159, speaks Chrome's
/// framing on stdin and stdout, and answers in hex or base64 as
/// APW_FAKE_BASE64 says.
private enum NodeHelper {
    static let source = #"""
    const crypto = require("node:crypto");
    const B64 = process.env.APW_FAKE_BASE64 === "1";
    const N = BigInt("0xFFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF");
    const g = 5n, CODE = "314159";
    const hex = (b) => Buffer.from(b).toString("hex");
    const big = (b) => BigInt("0x" + (hex(b) || "0"));
    const bytes = (n) => { let h = n.toString(16); if (h.length % 2) h = "0" + h; return Buffer.from(h, "hex"); };
    const pad = (b) => Buffer.concat([Buffer.alloc(384 - b.length), b]);
    const H = (...p) => crypto.createHash("sha256").update(Buffer.concat(p.map((x) => typeof x === "string" ? Buffer.from(x) : x))).digest();
    const pow = (b, e, m) => { let r = 1n; b %= m; while (e > 0n) { if (e & 1n) r = r * b % m; b = b * b % m; e >>= 1n; } return r; };
    const ser = (b, prefix = true) => B64 ? Buffer.from(b).toString("base64") : (prefix ? "0x" : "") + hex(b);
    const de = (s) => B64 ? Buffer.from(s, "base64") : Buffer.from(s.replace(/^0x/, ""), "hex");
    let st = {};
    function send(o) { const d = Buffer.from(JSON.stringify(o)); const h = Buffer.alloc(4); h.writeUInt32LE(d.length); process.stdout.write(Buffer.concat([h, d])); }
    function handle(m) {
      if (m.cmd === 14) return send({ cmd: 14, capabilities: { shouldUseBase64: B64, secretSessionVersion: 1 } });
      if (m.cmd === 0) return process.exit(0);
      if (m.cmd === 2) {
        const msg = JSON.parse(m.msg), p = JSON.parse(Buffer.from(msg.PAKE, "base64").toString());
        if (msg.QID === "m0") {
          if (msg.HSTBRSR !== "Chrome" || JSON.stringify(p.PROTO) !== "[1]") return send({ cmd: 2, payload: { QID: "m0", PAKE: Buffer.from(JSON.stringify({ TID: p.TID, ErrCode: 9 })).toString("base64") } });
          st = { TID: p.TID, A: big(de(p.A)), salt: crypto.randomBytes(16), b: big(crypto.randomBytes(32)) };
          const x = big(H(st.salt, H(st.TID + ":" + CODE)));
          st.v = pow(g, x, N);
          const k = big(H(bytes(N), pad(bytes(g))));
          st.B = (k * st.v + pow(g, st.b, N)) % N;
          return send({ cmd: 2, payload: { QID: "m0", PAKE: Buffer.from(JSON.stringify({ TID: st.TID, MSG: 1, B: ser(bytes(st.B)), s: ser(st.salt), PROTO: 1, VER: "1.0" })).toString("base64") } });
        }
        const u = big(H(pad(bytes(st.A)), pad(bytes(st.B))));
        const S = pow(st.A * pow(st.v, u, N) % N, st.b, N), K = H(bytes(S));
        const hNg = Buffer.from(H(bytes(N)).map((c, i) => c ^ H(pad(bytes(g)))[i]));
        const M = H(hNg, H(st.TID), st.salt, bytes(st.A), bytes(st.B), K);
        if (hex(de(p.M)) !== hex(M)) return send({ cmd: 2, payload: { QID: "m2", PAKE: Buffer.from(JSON.stringify({ TID: st.TID, MSG: 3, ErrCode: 1 })).toString("base64") } });
        st.key = K.subarray(0, 16);
        return send({ cmd: 2, payload: { QID: "m2", PAKE: Buffer.from(JSON.stringify({ TID: st.TID, MSG: 3, ErrCode: 0, HAMK: ser(H(bytes(st.A), M, K), false) })).toString("base64") } });
      }
      if (m.cmd === 4 || m.cmd === 5) {
        const payload = JSON.parse(m.payload), smsg = JSON.parse(payload.SMSG), sealed = de(smsg.SDATA);
        const iv = sealed.subarray(sealed.length - 16), body = sealed.subarray(0, sealed.length - 16);
        const d = crypto.createDecipheriv("aes-128-gcm", st.key, iv); d.setAuthTag(body.subarray(body.length - 16));
        const q = JSON.parse(Buffer.concat([d.update(body.subarray(0, body.length - 16)), d.final()]).toString());
        let r = { STATUS: 3 };
        if (m.cmd === 4 && q.ACT === 5 && q.URL === "www.example.test") r = { STATUS: 0, Entry_0: { USR: "ada@example.test", sites: ["example.test"] }, Entry_1: { USR: "bob@example.test", sites: ["www.example.test"] } };
        if (m.cmd === 5 && q.ACT === 2 && q.USR === "bob@example.test") r = { STATUS: 0, Entries: [{ USR: "bob@example.test", PWD: "another-made-up-one", sites: ["www.example.test"] }] };
        const riv = crypto.randomBytes(16), c = crypto.createCipheriv("aes-128-gcm", st.key, riv);
        const ct = Buffer.concat([c.update(JSON.stringify(r)), c.final(), c.getAuthTag()]);
        return send({ cmd: m.cmd, tabId: m.tabId, payload: { QID: payload.QID, SMSG: JSON.stringify({ TID: st.TID, SDATA: ser(Buffer.concat([riv, ct]), false) }) } });
      }
    }
    let buf = Buffer.alloc(0);
    process.stdin.on("data", (c) => { buf = Buffer.concat([buf, c]); while (buf.length >= 4) { const n = buf.readUInt32LE(0); if (buf.length < 4 + n) break; const m = JSON.parse(buf.subarray(4, 4 + n)); buf = buf.subarray(4 + n); handle(m); } });
    process.stdin.on("end", () => process.exit(0));
    """#
}
