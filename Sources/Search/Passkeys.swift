import AuthenticationServices
import OSLog
import WebKit

// Passkeys and security keys, for a browser that isn't Safari.
//
// Left to WebKit, a sign-in page that offers your passkey under its name
// field (conditional mediation) has WebKit open an AutoFill operation with
// macOS's AuthenticationServicesAgent, held for as long as the page waits.
// If Search dies meanwhile — quit, crash, killed — the agent never lets go of
// it, and refuses every passkey request Search makes after that, before any
// sheet: "Request already in progress for specified application identifier"
// (AuthenticationServicesCore.AuthorizationError 1). "Authentication failed"
// on every site, until the agent restarts with the Mac. Found 24 Sep 2026 on
// an agent that had held one for a day.
//
// So Search carries the ceremony itself, as Chrome and Firefox do on the Mac,
// and never opens that operation: it takes the request from the page, checks
// it against the frame it came from, and hands it to AuthenticationServices
// through the API made for browsers, with client data it writes — the origin
// in it is the one WebKit reports for the frame, never one the page states.
// A page's navigator.credentials answers any request for a public key from
// here: the Mac's own sheet, with Touch ID and the passkeys in iCloud Keychain
// or a password app, an iPhone nearby over the QR code, or a security key.
// What comes back goes to the page as the credential WebKit would have made.
//
// Not yet: the Mac's passkeys offered under the name field as a sign-in page
// loads. Pages are told the field has none to offer, so they show their own
// passkey button — unless a password manager extension that keeps passkeys
// is there to offer its own. A request made that way is the extension's to
// answer; what it leaves to Search just waits, as it does while nobody picks
// one, never reaching macOS.
@MainActor
final class Passkeys: NSObject {
    static let shared = Passkeys()

    private static let log = Logger(subsystem: "com.officecommun.search", category: "Passkeys")

    // MARK: - the Mac's permission

    /// Whether this Mac lets Search use its passkeys at all: a question
    /// macOS puts once to a browser other than Safari, the answer kept in
    /// System Settings › Privacy & Security.
    static var access: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState {
        ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials
    }

    /// Everyone waiting on that question while it is on screen.
    private static var waiting: [() -> Void]?

    /// Asked before the first ceremony, where it makes sense — a site has
    /// just asked for a passkey — and then never again.
    private static func ensure(_ then: @escaping () -> Void) {
        guard Preferences.entitledToPasskeys, access == .notDetermined else { return then() }
        if waiting != nil {
            waiting?.append(then)
            return
        }
        waiting = [then]
        ASAuthorizationWebBrowserPublicKeyCredentialManager().requestAuthorizationForPublicKeyCredentials { _ in
            DispatchQueue.main.async {
                let everyone = waiting ?? []
                waiting = nil
                everyone.forEach { $0() }
            }
        }
    }

    // MARK: - a ceremony

    /// How many a page has asked for, and the last as it was checked — for
    /// the bench.
    private(set) static var asked = 0
    private(set) static var last: [String: Any] = [:]

    /// The one on screen, and whom to answer when it ends. A new request
    /// ends the one before, as a page asking twice gets in any browser.
    private var controller: ASAuthorizationController?
    private var token: String?
    private var answer: (([String: Any]) -> Void)?
    private weak var anchor: NSWindow?
    /// Called off by its page before it could start.
    private var withdrawn: String?

    /// Where a request came from, as WebKit knows it rather than as the
    /// page says.
    struct Caller {
        let origin: WKSecurityOrigin
        let mainFrame: Bool
        /// The host of the page the frame is in.
        let pageHost: String?
        let window: NSWindow?
    }

    func cancel(token: String?) {
        guard let token else { return }
        if token == self.token { controller?.cancel() } else { withdrawn = token }
    }

    func perform(_ body: [String: Any], from caller: Caller, answer: @escaping ([String: Any]) -> Void) {
        // Switched off in Settings: what reaches here came through an
        // extension's page script, which the patch runs ahead of whatever the
        // setting — the site hears no, as it would from a browser without them.
        guard FormRelay.passkeysOffered else {
            return refuse(answer, "NotAllowedError", "The operation either timed out or was not allowed.")
        }
        let kind = body["kind"] as? String ?? ""
        let scheme = caller.origin.protocol.lowercased()
        let host = caller.origin.host.lowercased()
        let local = host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"
        guard !host.isEmpty, scheme == "https" || (scheme == "http" && local) else {
            return refuse(answer, "NotAllowedError", "Passkeys need a secure page.")
        }
        // The page in front of you only: a tab behind, a window behind, or
        // Search itself behind doesn't get to bring up the Mac's sheet over
        // what you're looking at. A test run is always behind.
        guard Store.testing || (NSApp.isActive && caller.window?.isKeyWindow == true) else {
            return refuse(answer, "NotAllowedError", "The document is not focused.")
        }
        // A frame from another site can't ask on the page's behalf.
        guard caller.mainFrame || caller.pageHost?.lowercased() == host else {
            return refuse(answer, "NotAllowedError", "Passkeys can't be asked for from another site's frame.")
        }
        let named = kind == "create" ? (body["rp"] as? [String: Any])?["id"] as? String : body["rpId"] as? String
        let rp = (named.flatMap { $0.isEmpty ? nil : $0 } ?? host).lowercased()
        guard Passkeys.fits(rp, host) else {
            return refuse(answer, "SecurityError", "The relying party ID is not a registrable domain suffix of, nor equal to the current domain.")
        }
        guard let challenge = Passkeys.data(body["challenge"]), !challenge.isEmpty else {
            return refuse(answer, "TypeError", "A challenge is required.")
        }
        let port = caller.origin.port
        let origin = "\(scheme)://\(host.contains(":") ? "[\(host)]" : host)" + (port == 0 ? "" : ":\(port)")
        let clientData = ASPublicKeyCredentialClientData(challenge: challenge, origin: origin)

        let requests: [ASAuthorizationRequest]
        switch kind {
        case "get":
            requests = assertion(body, rp: rp, clientData: clientData)
        case "create":
            guard let made = registration(body, rp: rp, clientData: clientData) else {
                return refuse(answer, "TypeError", "The request names no user, or one too long.")
            }
            requests = made
        default:
            return refuse(answer, "NotSupportedError", "Not a passkey request.")
        }
        guard !requests.isEmpty else {
            return refuse(answer, "NotSupportedError", "No authenticator here can make that kind of key.")
        }

        Passkeys.asked += 1
        Passkeys.last = ["kind": kind, "rp": rp, "origin": origin, "requests": requests.count]
        Passkeys.log.notice("\(kind, privacy: .public) for \(rp, privacy: .public) from \(origin, privacy: .public)")
        // A test run never shows the sheet: it would open on the screen of
        // whoever is working beside it. It gets a credential made up on the
        // spot instead, so the checks above and the page's side are still
        // what they are for real.
        if Store.testing {
            return answer(Passkeys.rehearsal(kind, rp: rp, origin: origin, challenge: challenge))
        }

        let token = body["token"] as? String
        Passkeys.ensure { [weak self] in
            guard let self else { return }
            if let token, token == self.withdrawn {
                self.withdrawn = nil
                return answer(Passkeys.failure("AbortError", "The operation was aborted."))
            }
            self.begin(requests, token: token, in: caller.window, answer: answer)
        }
    }

    private func begin(_ requests: [ASAuthorizationRequest], token: String?, in window: NSWindow?, answer: @escaping ([String: Any]) -> Void) {
        if let running = controller {
            let previous = self.answer
            clear()
            running.cancel()
            previous?(Passkeys.failure("NotAllowedError", "A newer request took its place."))
        }
        let controller = ASAuthorizationController(authorizationRequests: requests)
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        self.token = token
        self.answer = answer
        self.anchor = window
        controller.performRequests()
    }

    // MARK: - requests

    private func assertion(_ body: [String: Any], rp: String, clientData: ASPublicKeyCredentialClientData) -> [ASAuthorizationRequest] {
        let allowed = Passkeys.descriptors(body["allowCredentials"])
        let verification = Passkeys.verification(body["userVerification"])
        let platform = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rp)
            .createCredentialAssertionRequest(clientData: clientData)
        platform.allowedCredentials = allowed.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0.id) }
        platform.userVerificationPreference = verification
        var requests: [ASAuthorizationRequest] = [platform]
        if #available(macOS 14.4, *) {
            let key = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: rp)
                .createCredentialAssertionRequest(clientData: clientData)
            key.allowedCredentials = allowed.map {
                ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(credentialID: $0.id, transports: $0.transports)
            }
            key.userVerificationPreference = verification
            requests.append(key)
        }
        return requests
    }

    private func registration(_ body: [String: Any], rp: String, clientData: ASPublicKeyCredentialClientData) -> [ASAuthorizationRequest]? {
        guard let user = body["user"] as? [String: Any],
              let userID = Passkeys.data(user["id"]), (1...64).contains(userID.count),
              let name = user["name"] as? String
        else { return nil }
        let display = (user["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        let verification = Passkeys.verification(body["userVerification"])
        let attestation = Passkeys.attestation(body["attestation"])
        let excluded = Passkeys.descriptors(body["excludeCredentials"])
        let attachment = body["authenticatorAttachment"] as? String
        // No list means ES256 or RS256, as the standard has it.
        let algorithms = (body["algorithms"] as? [Int]).flatMap { $0.isEmpty ? nil : $0 } ?? [-7, -257]
        var requests: [ASAuthorizationRequest] = []

        // A passkey from the Mac is always ES256: offered only to a site that takes it.
        if attachment != "cross-platform", algorithms.contains(-7) {
            let platform = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rp)
                .createCredentialRegistrationRequest(clientData: clientData, name: name, userID: userID)
            platform.displayName = display
            platform.userVerificationPreference = verification
            platform.attestationPreference = attestation
            if #available(macOS 14.4, *) {
                platform.excludedCredentials = excluded.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0.id) }
            }
            requests.append(platform)
        }
        if attachment != "platform", #available(macOS 14.4, *) {
            let key = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: rp)
                .createCredentialRegistrationRequest(clientData: clientData, displayName: display, name: name, userID: userID)
            key.credentialParameters = algorithms.map {
                ASAuthorizationPublicKeyCredentialParameters(algorithm: ASCOSEAlgorithmIdentifier(rawValue: $0))
            }
            key.userVerificationPreference = verification
            key.attestationPreference = attestation
            switch body["residentKey"] as? String {
            case "required": key.residentKeyPreference = .required
            case "preferred": key.residentKeyPreference = .preferred
            default: key.residentKeyPreference = .discouraged
            }
            key.excludedCredentials = excluded.map {
                ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(credentialID: $0.id, transports: $0.transports)
            }
            requests.append(key)
        }
        return requests
    }

    // MARK: - answers

    private func finish(_ value: [String: Any]) {
        let answer = self.answer
        clear()
        answer?(value)
    }

    private func clear() {
        controller = nil
        token = nil
        answer = nil
    }

    private func refuse(_ answer: ([String: Any]) -> Void, _ name: String, _ message: String) {
        Passkeys.log.notice("refused: \(message, privacy: .public)")
        answer(Passkeys.failure(name, message))
    }

    private static func failure(_ name: String, _ message: String) -> [String: Any] {
        ["error": name, "message": message]
    }

    static func assertionReply(id: Data, clientData: Data, authenticatorData: Data, signature: Data, user: Data, attachment: String) -> [String: Any] {
        [
            "kind": "get", "id": text(id), "clientDataJSON": text(clientData),
            "authenticatorData": text(authenticatorData), "signature": text(signature),
            "userHandle": text(user), "attachment": attachment,
        ]
    }

    static func registrationReply(id: Data, clientData: Data, attestation: Data, transports: [String], attachment: String) -> [String: Any] {
        var reply: [String: Any] = [
            "kind": "create", "id": text(id), "clientDataJSON": text(clientData),
            "attestationObject": text(attestation), "transports": transports, "attachment": attachment,
        ]
        if let data = authenticatorData(inAttestation: attestation) {
            reply["authenticatorData"] = text(data)
            if let key = publicKey(inAuthenticatorData: data) {
                reply["publicKeyAlgorithm"] = key.algorithm
                if let der = key.der { reply["publicKey"] = text(der) }
            }
        }
        return reply
    }

    /// For a test run: a credential in the shape the sheet gives, made up
    /// from the request — a P-256 key and all, with nothing signed.
    private static func rehearsal(_ kind: String, rp: String, origin: String, challenge: Data) -> [String: Any] {
        let client = Data(#"{"type":"webauthn.\#(kind)","challenge":"\#(text(challenge))","origin":"\#(origin)","crossOrigin":false}"#.utf8)
        let id = Data((0..<16).map { UInt8($0) })
        // Where the relying party's hash would be, then the flags and the count.
        var auth = Data(count: 32) + Data([kind == "get" ? 0x05 : 0x45]) + Data(count: 4)
        guard kind == "create" else {
            return assertionReply(id: id, clientData: client, authenticatorData: auth, signature: Data([0x30, 0]), user: Data("user".utf8), attachment: "platform")
        }
        auth += Data(count: 16) + Data([0, UInt8(id.count)]) + id
        auth += Data([0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20]) + Data(repeating: 1, count: 32)
        auth += Data([0x22, 0x58, 0x20]) + Data(repeating: 2, count: 32)
        var object = Data([0xA3, 0x63]) + Data("fmt".utf8) + Data([0x64]) + Data("none".utf8)
        object += Data([0x67]) + Data("attStmt".utf8) + Data([0xA0])
        object += Data([0x68]) + Data("authData".utf8) + Data([0x59, UInt8(auth.count >> 8), UInt8(auth.count & 0xFF)]) + auth
        return registrationReply(id: id, clientData: client, attestation: object, transports: ["hybrid", "internal"], attachment: "platform")
    }

    // MARK: - checks

    /// The relying party is the page's own host, or a domain above it that is
    /// still a site of its own: never another site, never an address, and
    /// never a suffix anyone can register under — com, co.uk, github.io.
    static func fits(_ rp: String, _ host: String) -> Bool {
        if rp == host { return true }
        let address = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
        guard !address, host.hasSuffix("." + rp), rp.contains("."), let suffix = publicSuffix else { return false }
        return !suffix(rp as CFString)
    }

    /// WebKit's own test for a public suffix, from the list macOS keeps.
    /// Private to CFNetwork: without it, a page's own host is the only
    /// relying party it gets.
    nonisolated static let publicSuffix: (@convention(c) (CFString) -> Bool)? = {
        guard let symbol = dlsym(dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork", RTLD_NOW), "_CFHostIsDomainTopLevel")
        else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (CFString) -> Bool).self)
    }()

    // MARK: - bytes

    static func data(_ value: Any?) -> Data? {
        guard var text = value as? String else { return nil }
        text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text)
    }

    static func text(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func descriptors(_ value: Any?) -> [(id: Data, transports: [ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport])] {
        (value as? [[String: Any]] ?? []).compactMap { item in
            guard let id = data(item["id"]) else { return nil }
            let named = (item["transports"] as? [String] ?? []).compactMap { name -> ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport? in
                switch name {
                case "usb": return .usb
                case "nfc": return .nfc
                case "ble": return .bluetooth
                default: return nil
                }
            }
            return (id, named.isEmpty ? ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported : named)
        }
    }

    private static func verification(_ value: Any?) -> ASAuthorizationPublicKeyCredentialUserVerificationPreference {
        switch value as? String {
        case "required": return .required
        case "discouraged": return .discouraged
        default: return .preferred
        }
    }

    private static func attestation(_ value: Any?) -> ASAuthorizationPublicKeyCredentialAttestationKind {
        switch value as? String {
        case "direct": return .direct
        case "indirect": return .indirect
        case "enterprise": return .enterprise
        default: return .none
        }
    }

    /// The authenticator data inside an attestation object — a CBOR map with
    /// it under "authData" — for the pages that ask for it directly.
    static func authenticatorData(inAttestation object: Data) -> Data? {
        var reader = CBOR(bytes: [UInt8](object))
        guard let pairs = reader.mapCount() else { return nil }
        for _ in 0..<pairs {
            guard let key = reader.text() else { return nil }
            if key == "authData" { return reader.blob().map { Data($0) } }
            guard reader.skip() else { return nil }
        }
        return nil
    }

    /// The new credential's public key, from its authenticator data: the
    /// algorithm, and the key as getPublicKey() hands it over — DER, for the
    /// two kinds passkeys and security keys make, P-256 and Ed25519. For any
    /// other the site reads it out of the attestation object itself.
    static func publicKey(inAuthenticatorData data: Data) -> (algorithm: Int, der: Data?)? {
        let bytes = [UInt8](data)
        // The relying party's hash, the flags — with a credential in it — the
        // count, the model's ID, and the credential ID's length.
        guard bytes.count > 55, bytes[32] & 0x40 != 0 else { return nil }
        let start = 55 + (Int(bytes[53]) << 8 | Int(bytes[54]))
        guard start < bytes.count else { return nil }
        var reader = CBOR(bytes: Array(bytes[start...]))
        guard let pairs = reader.mapCount() else { return nil }
        var fields: [Int: Any] = [:]
        for _ in 0..<pairs {
            guard let key = reader.int() else { return nil }
            switch reader.major {
            case 0, 1: fields[key] = reader.int()
            case 2: fields[key] = reader.blob()
            default: guard reader.skip() else { return nil }
            }
        }
        guard let algorithm = fields[3] as? Int else { return nil }
        let x = fields[-2] as? [UInt8]
        switch (fields[1] as? Int, fields[-1] as? Int) {
        case (2, 1):
            guard let x, x.count == 32, let y = fields[-3] as? [UInt8], y.count == 32 else { return (algorithm, nil) }
            let head: [UInt8] = [
                0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04,
            ]
            return (algorithm, Data(head + x + y))
        case (1, 6):
            guard let x, x.count == 32 else { return (algorithm, nil) }
            return (algorithm, Data([0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00] + x))
        default:
            return (algorithm, nil)
        }
    }
}

extension Passkeys: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        anchor ?? NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard controller === self.controller else { return }
        let credential = authorization.credential
        if let got = credential as? ASAuthorizationPublicKeyCredentialAssertion {
            let attachment = (credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion)?.attachment
            Passkeys.log.notice("signed in")
            finish(Passkeys.assertionReply(
                id: got.credentialID, clientData: got.rawClientDataJSON, authenticatorData: got.rawAuthenticatorData,
                signature: got.signature, user: got.userID,
                attachment: attachment == .platform ? "platform" : "cross-platform"
            ))
        } else if let made = credential as? ASAuthorizationPublicKeyCredentialRegistration {
            let platform = credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration
            Passkeys.log.notice("made one")
            finish(Passkeys.registrationReply(
                id: made.credentialID, clientData: made.rawClientDataJSON, attestation: made.rawAttestationObject ?? Data(),
                transports: platform == nil ? ["usb"] : ["hybrid", "internal"],
                attachment: platform?.attachment == .platform ? "platform" : "cross-platform"
            ))
        } else {
            finish(Passkeys.failure("NotAllowedError", "The authenticator answered with something else."))
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard controller === self.controller else { return }
        Passkeys.log.notice("failed: \(String(describing: error), privacy: .public)")
        // A credential it already holds is what a site is told; anything else
        // — no, the sheet closed, the time ran out — a site may not tell apart.
        if (error as NSError).domain == ASAuthorizationError.errorDomain, (error as NSError).code == 1006 {
            finish(Passkeys.failure("InvalidStateError", "The authenticator already holds a credential for this account."))
        } else {
            finish(Passkeys.failure("NotAllowedError", "The operation either timed out or was not allowed."))
        }
    }
}

/// Just enough CBOR to read an attestation object: maps, numbers, text and
/// byte strings, and a step over anything else.
private struct CBOR {
    let bytes: [UInt8]
    var at = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    var major: UInt8? { at < bytes.count ? bytes[at] >> 5 : nil }

    private mutating func head() -> (major: UInt8, value: UInt64)? {
        guard at < bytes.count else { return nil }
        let first = bytes[at]
        at += 1
        let info = first & 0x1F
        switch info {
        case 0..<24:
            return (first >> 5, UInt64(info))
        case 24...27:
            let size = 1 << Int(info - 24)
            guard at + size <= bytes.count else { return nil }
            let value = bytes[at..<(at + size)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            at += size
            return (first >> 5, value)
        default:
            return nil
        }
    }

    mutating func mapCount() -> Int? {
        guard let (major, value) = head(), major == 5, value < 1024 else { return nil }
        return Int(value)
    }

    mutating func int() -> Int? {
        guard let (major, value) = head(), value < UInt64(Int.max) else { return nil }
        switch major {
        case 0: return Int(value)
        case 1: return -1 - Int(value)
        default: return nil
        }
    }

    mutating func text() -> String? {
        guard let (major, value) = head(), major == 3, value <= UInt64(bytes.count - at) else { return nil }
        defer { at += Int(value) }
        return String(bytes: bytes[at..<(at + Int(value))], encoding: .utf8)
    }

    mutating func blob() -> [UInt8]? {
        guard let (major, value) = head(), major == 2, value <= UInt64(bytes.count - at) else { return nil }
        defer { at += Int(value) }
        return Array(bytes[at..<(at + Int(value))])
    }

    mutating func skip(depth: Int = 0) -> Bool {
        guard depth < 16, let (major, value) = head() else { return false }
        switch major {
        case 0, 1, 7:
            return true
        case 2, 3:
            guard value <= UInt64(bytes.count - at) else { return false }
            at += Int(value)
            return true
        case 4:
            guard value < 1024 else { return false }
            return (0..<value).allSatisfy { _ in skip(depth: depth + 1) }
        case 5:
            guard value < 1024 else { return false }
            return (0..<value).allSatisfy { _ in skip(depth: depth + 1) && skip(depth: depth + 1) }
        case 6:
            return skip(depth: depth + 1)
        default:
            return false
        }
    }
}

/// The page's side: requests handed over, answers handed back.
final class PasskeyRelay: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "officePasskeys"
    /// The page's word to Search's side, and the answer back (see `bridge`).
    static let asked = "search-passkeys-ask"
    static let answered = "search-passkeys-answer"

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any] else { return replyHandler(nil, "Not a request") }
            if body["kind"] as? String == "cancel" {
                Passkeys.shared.cancel(token: body["token"] as? String)
                return replyHandler(true, nil)
            }
            let caller = Passkeys.Caller(
                origin: message.frameInfo.securityOrigin,
                mainFrame: message.frameInfo.isMainFrame,
                pageHost: message.webView?.url?.host(),
                window: message.webView?.window
            )
            Passkeys.shared.perform(body, from: caller) { replyHandler($0, nil) }
        }
    }

    /// In the page, before anything of the site's runs: navigator.credentials
    /// answers requests for a public key from here, and anything else it is
    /// asked — a stored password — as it always did. On the prototype: WebKit
    /// makes navigator.credentials anew whenever nothing holds it, and what
    /// was set on the old one goes with it.
    ///
    /// It has to be in the page's own world to stand in for the page's
    /// functions, and nothing of Search's is there for a page to find — no
    /// window.webkit, no global of its own. Requests go to Search's side as
    /// events on the window (see `bridge`).
    static let page = """
    (function () {
      if (!window.PublicKeyCredential || !window.CredentialsContainer) return;
      var proto = CredentialsContainer.prototype;
      // In once, whichever copy comes first — an extension's (see
      // ExtensionShims.passkeys) or Search's own — and marked on the prototype
      // rather than on the window. The mark holds navigator.credentials too:
      // held, WebKit keeps it, and an extension's own get and create on it
      // with it.
      var mark = Symbol.for('search.passkeys');
      if (proto[mark]) return;
      try { Object.defineProperty(proto, mark, { value: navigator.credentials }); } catch (e) { return; }
      var nativeGet = proto.get, nativeCreate = proto.create;
      var refused = 'The operation either timed out or was not allowed.';

      function bytes(source) {
        if (source instanceof ArrayBuffer) return new Uint8Array(source);
        if (ArrayBuffer.isView(source)) return new Uint8Array(source.buffer, source.byteOffset, source.byteLength);
        throw new TypeError('Expected an ArrayBuffer or a view of one.');
      }
      function encode(source) {
        var b = bytes(source), s = '';
        for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
        return btoa(s).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
      }
      function decode(text) {
        var s = (text || '').replace(/-/g, '+').replace(/_/g, '/');
        while (s.length % 4) s += '=';
        var raw = atob(s), out = new Uint8Array(raw.length);
        for (var i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
        return out.buffer;
      }
      function descriptors(list) {
        return Array.prototype.map.call(list || [], function (c) {
          return { id: encode(c.id), transports: Array.prototype.slice.call(c.transports || []) };
        });
      }
      function aborted(signal) {
        return signal.reason !== undefined ? signal.reason : new DOMException('The operation was aborted.', 'AbortError');
      }
      function define(target, values, hidden) {
        Object.keys(values).forEach(function (k) {
          Object.defineProperty(target, k, { value: values[k], enumerable: !hidden, configurable: true });
        });
        return target;
      }

      function credential(reply, extensions) {
        var response, made = reply.kind === 'create';
        if (made) {
          response = Object.create(AuthenticatorAttestationResponse.prototype);
          define(response, { clientDataJSON: decode(reply.clientDataJSON), attestationObject: decode(reply.attestationObject) });
          define(response, {
            getTransports: function () { return (reply.transports || []).slice(); },
            getAuthenticatorData: function () { return decode(reply.authenticatorData); },
            getPublicKey: function () { return reply.publicKey ? decode(reply.publicKey) : null; },
            getPublicKeyAlgorithm: function () { return reply.publicKeyAlgorithm != null ? reply.publicKeyAlgorithm : -7; }
          }, true);
        } else {
          response = Object.create(AuthenticatorAssertionResponse.prototype);
          define(response, {
            clientDataJSON: decode(reply.clientDataJSON),
            authenticatorData: decode(reply.authenticatorData),
            signature: decode(reply.signature),
            userHandle: reply.userHandle ? decode(reply.userHandle) : null
          });
        }
        // A passkey from the Mac is always one the site can find without
        // naming it; the site may have asked whether it is.
        var results = {};
        if (made && extensions && extensions.credProps && reply.attachment === 'platform') results.credProps = { rk: true };
        var attachment = reply.attachment || null;
        var json = { id: reply.id, rawId: reply.id, type: 'public-key', authenticatorAttachment: attachment, clientExtensionResults: results };
        json.response = made
          ? { clientDataJSON: reply.clientDataJSON, attestationObject: reply.attestationObject, authenticatorData: reply.authenticatorData,
              transports: (reply.transports || []).slice(), publicKeyAlgorithm: reply.publicKeyAlgorithm != null ? reply.publicKeyAlgorithm : -7 }
          : { clientDataJSON: reply.clientDataJSON, authenticatorData: reply.authenticatorData, signature: reply.signature };
        if (made && reply.publicKey) json.response.publicKey = reply.publicKey;
        if (!made && reply.userHandle) json.response.userHandle = reply.userHandle;
        var result = Object.create(PublicKeyCredential.prototype);
        define(result, { id: reply.id, rawId: decode(reply.id), type: 'public-key', authenticatorAttachment: attachment, response: response });
        return define(result, {
          getClientExtensionResults: function () { return JSON.parse(JSON.stringify(results)); },
          toJSON: function () { return JSON.parse(JSON.stringify(json)); }
        }, true);
      }

      var waiting = {};
      window.addEventListener('\(answered)', function (event) {
        var data;
        try { data = JSON.parse(event.detail); } catch (e) { return; }
        var done = data && waiting[data.token];
        if (!done) return;
        delete waiting[data.token];
        done(data.reply);
      });
      function ask(message) {
        return new Promise(function (resolve) {
          if (message.kind === 'cancel') resolve(true); else waiting[message.token] = resolve;
          window.dispatchEvent(new CustomEvent('\(asked)', { detail: JSON.stringify(message) }));
        });
      }

      function send(request, signal, extensions) {
        if (signal && signal.aborted) return Promise.reject(aborted(signal));
        request.token = Math.random().toString(36).slice(2);
        return new Promise(function (resolve, reject) {
          if (signal) signal.addEventListener('abort', function () {
            ask({ kind: 'cancel', token: request.token });
            reject(aborted(signal));
          }, { once: true });
          ask(request).then(function (reply) {
            if (!reply || reply.error) {
              var name = (reply && reply.error) || 'NotAllowedError';
              var message = (reply && reply.message) || refused;
              return reject(name === 'TypeError' ? new TypeError(message) : new DOMException(message, name));
            }
            resolve(credential(reply, extensions));
          }, function () { reject(new DOMException(refused, 'NotAllowedError')); });
        });
      }

      function replace(target, name, value) {
        try { Object.defineProperty(target, name, { value: value, configurable: true, writable: true }); } catch (e) {}
      }

      replace(proto, 'get', function get(options) {
        if (!options || !options.publicKey) return nativeGet.apply(this, arguments);
        var signal = options.signal, pk = options.publicKey, request;
        if (options.mediation === 'conditional') {
          // Nothing of the Mac's is offered under the field yet: the request
          // waits, as it does while nobody picks a passkey, until the page
          // lets it go.
          return new Promise(function (resolve, reject) {
            if (!signal) return;
            if (signal.aborted) return reject(aborted(signal));
            signal.addEventListener('abort', function () { reject(aborted(signal)); }, { once: true });
          });
        }
        try {
          request = {
            kind: 'get', challenge: encode(pk.challenge), rpId: pk.rpId || null,
            allowCredentials: descriptors(pk.allowCredentials),
            userVerification: pk.userVerification || 'preferred'
          };
        } catch (e) { return Promise.reject(e); }
        return send(request, signal, pk.extensions);
      });

      replace(proto, 'create', function create(options) {
        if (!options || !options.publicKey) return nativeCreate.apply(this, arguments);
        var pk = options.publicKey, selection = pk.authenticatorSelection || {}, request;
        // A passkey made quietly after a password sign-in: not something
        // this browser does yet, so the site hears no, as it would if you had.
        if (options.mediation === 'conditional') return Promise.reject(new DOMException(refused, 'NotAllowedError'));
        try {
          request = {
            kind: 'create', challenge: encode(pk.challenge),
            rp: { id: (pk.rp && pk.rp.id) || null },
            user: { id: encode(pk.user.id), name: String(pk.user.name), displayName: pk.user.displayName ? String(pk.user.displayName) : '' },
            algorithms: Array.prototype.map.call(pk.pubKeyCredParams || [], function (p) { return p.alg; }),
            excludeCredentials: descriptors(pk.excludeCredentials),
            authenticatorAttachment: selection.authenticatorAttachment || null,
            residentKey: selection.residentKey || (selection.requireResidentKey ? 'required' : 'discouraged'),
            userVerification: selection.userVerification || 'preferred',
            attestation: pk.attestation || 'none'
          };
        } catch (e) { return Promise.reject(e); }
        return send(request, options.signal, pk.extensions);
      });

      // A password manager that keeps passkeys — 1Password, Bitwarden — puts
      // its own get and create on navigator.credentials, or asks from its own
      // script, and offers its passkeys under the name field to the sites that
      // ask for them that way. Once one is there, pages hear the field can.
      var claimed = false;
      function extensionAnswers() {
        if (claimed) return true;
        try {
          if (navigator.credentials && Object.getOwnPropertyDescriptor(navigator.credentials, 'get')) claimed = true;
          else if ((new Error().stack || '').indexOf('-extension://') >= 0) claimed = true;
        } catch (e) {}
        return claimed;
      }

      // What this browser can and can't do, for the pages that ask first:
      // passkeys from the Mac, a phone or a key — not yet under the field,
      // and none of what WebKit would have answered for itself.
      var P = PublicKeyCredential;
      replace(P, 'isUserVerifyingPlatformAuthenticatorAvailable', function () { return Promise.resolve(true); });
      replace(P, 'isConditionalMediationAvailable', function () { return Promise.resolve(extensionAnswers()); });
      var nativeCapabilities = P.getClientCapabilities;
      if (typeof nativeCapabilities === 'function') {
        replace(P, 'getClientCapabilities', function () {
          var field = extensionAnswers();
          function ours(c) {
            c = Object.assign({}, c);
            Object.keys(c).forEach(function (k) { if (k.indexOf('extension:') === 0 && k !== 'extension:credProps') c[k] = false; });
            return Object.assign(c, {
              conditionalCreate: false, conditionalGet: field, conditionalMediation: field, relatedOrigins: false,
              signalAllAcceptedCredentials: false, signalCurrentUserDetails: false, signalUnknownCredential: false,
              hybridTransport: true, passkeyPlatformAuthenticator: true, userVerifyingPlatformAuthenticator: true
            });
          }
          return nativeCapabilities.call(P).then(ours, function () { return ours({}); });
        });
      }
    })();
    """

    /// Search's side of it, in Search's own world (Web.world), where the
    /// handler is and a page can't look. A request the page dispatches is
    /// handed over as it is — the frame it comes from is WebKit's to say, not
    /// the event's — and the answer dispatched back for the page to pick up.
    static let bridge = """
    (function () {
      var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(name);
      if (!handler || window.__bridged) return;
      window.__bridged = true;
      window.addEventListener('\(asked)', function (event) {
        var message;
        try { message = JSON.parse(event.detail); } catch (e) { return; }
        if (!message || typeof message !== 'object' || typeof message.token !== 'string') return;
        function answer(reply) {
          window.dispatchEvent(new CustomEvent('\(answered)', { detail: JSON.stringify({ token: message.token, reply: reply }) }));
        }
        handler.postMessage(message).then(function (reply) {
          if (message.kind !== 'cancel') answer(reply);
        }, function () {
          if (message.kind !== 'cancel') answer(null);
        });
      });
    })();
    """
}
