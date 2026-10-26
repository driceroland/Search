import AppKit
import Combine
import CryptoKit
import Foundation
import Security

// Apple Passwords under the sign-in box (idea 260, #425), the way Safari
// offers them, without the iCloud Passwords extension.
//
// There is no public way for a browser to ask the Mac's Passwords app for a
// site's accounts: AuthenticationServices hands an app only its own
// associated domains' passwords, and WebKit's AutoFill is Safari's. What
// Apple gives other browsers is a helper its Chrome extension talks to over
// native messaging. Search runs that helper itself, as Chrome would, and
// speaks the extension's protocol (ApplePasswordsProtocol.swift):
//
// - The helper only answers Apple's extension ids, so Search gives the
//   Chrome extension's. That is the unofficial part, and why this is off
//   unless turned on in Settings › Passwords.
// - Pairing is your doing: Connect… starts it, the helper shows its own
//   six-digit code, you type it into Search. The key it yields lives in
//   memory only and dies with the helper; next launch asks for a code again,
//   as the extension does. Nothing about it is written anywhere.
// - Only names are asked for, when the caret is in a sign-in box on an https
//   page of an ordinary tab. A password is asked for once you pick its
//   account, and macOS may ask for Touch ID then. It goes into the page's
//   own fields and is not kept.
// - Never in a private tab, never over plain http, never in a frame (the
//   form script is the main frame's only), and only for the site the page is
//   on: an account the helper keeps for another site is not offered.
//
// The helper is the one on the system volume, checked to be signed by Apple
// as that helper before it is run: a file somewhere else claiming the name
// is never started.

/// The two ends of a conversation with the helper: a program run with a
/// pipe, or (in tests) something that answers as it would.
protocol AppleLink: AnyObject {
    var onMessage: (([String: Any]) -> Void)? { get set }
    var onEnd: (() -> Void)? { get set }
    func start() throws
    func send(_ message: [String: Any]) throws
    func stop()
}

/// Apple's helper, run over Chrome's framing (HostPipe).
@available(macOS 15.4, *)
final class HelperLink: AppleLink {
    var onMessage: (([String: Any]) -> Void)?
    var onEnd: (() -> Void)?
    private let pipe: HostPipe

    init(program: URL, origin: String = AppleHelper.origin) {
        pipe = HostPipe(program: program, origin: origin)
        pipe.onMessage = { [weak self] message in
            guard let message = message as? [String: Any] else { return }
            DispatchQueue.main.async { self?.onMessage?(message) }
        }
        pipe.onExit = { [weak self] in
            DispatchQueue.main.async { self?.onEnd?() }
        }
    }

    func start() throws { try pipe.start() }
    func send(_ message: [String: Any]) throws { try pipe.write(message) }
    func stop() { pipe.stop() }
}

enum AppleHelper {
    /// Apple's iCloud Passwords extension for Chrome: the helper admits no
    /// other caller.
    static let origin = "chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/"
    static let identifier = "com.apple.PasswordManagerBrowserExtensionHelper"
    private static let places = [
        "/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app",
        "/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app",
    ]

    /// The helper's program, if this Mac has it and it is Apple's.
    static func program() -> URL? {
        places.lazy.compactMap { path -> URL? in
            let bundle = URL(fileURLWithPath: path)
            guard isApples(bundle) else { return nil }
            let program = bundle.appendingPathComponent("Contents/MacOS/PasswordManagerBrowserExtensionHelper")
            return FileManager.default.isExecutableFile(atPath: program.path) ? program : nil
        }.first
    }

    /// Signed by Apple, as that helper: its own designated requirement.
    static func isApples(_ bundle: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard FileManager.default.fileExists(atPath: bundle.path),
              SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("identifier \"\(identifier)\" and anchor apple" as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }
}

@MainActor
final class ApplePasswords: ObservableObject {
    static let shared = ApplePasswords(prefs: Shared.prefs)

    enum State: Equatable {
        /// Not talking to the helper.
        case idle
        /// Running it and starting a pairing.
        case starting
        /// The helper shows its code; waiting for you to type it.
        case code
        /// Checking the code typed.
        case checking
        /// Paired: names can be asked for.
        case paired
    }

    @Published private(set) var state: State = .idle
    /// Why the last attempt didn't work, in plain words; cleared by the next.
    @Published private(set) var trouble: String?

    private let makeLink: () throws -> AppleLink
    private var link: AppleLink?
    /// The bench's stand-in for the helper, kept to be asked how often it
    /// was started (Bench `appleoffer`).
    var standIn: AppleLink?
    private var client: SRPClient?
    private var numbers: (serverKey: [UInt8], salt: [UInt8])?
    private var key: SymmetricKey?
    private var waiters: [Int: (id: Int, continuation: CheckedContinuation<[String: Any], Error>)] = [:]
    private var nextWaiter = 0
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []
    private var tabNumbers: [UUID: Int] = [:]
    private var bag = Set<AnyCancellable>()

    struct Unavailable: LocalizedError {
        let errorDescription: String?
    }

    init(makeLink: (() throws -> AppleLink)? = nil, prefs: Preferences? = nil) {
        self.makeLink = makeLink ?? {
            // A test run never runs Apple's helper: it would put its window
            // on the screen of whoever is working beside it, and ask their
            // real Passwords app. Tests hand in a helper of their own.
            guard !Store.testing else { throw Unavailable(errorDescription: "Apple's Passwords helper isn't run in a test") }
            guard #available(macOS 15.4, *) else { throw Unavailable(errorDescription: "Needs macOS 15.4 or later") }
            guard let program = AppleHelper.program() else {
                throw Unavailable(errorDescription: "Apple's Passwords helper isn't on this Mac")
            }
            return HelperLink(program: program)
        }
        // Turned off: the helper is told goodbye and stopped, and the key
        // goes with it.
        prefs?.$applePasswords.dropFirst()
            .sink { [weak self] on in if !on { self?.disconnect() } }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.disconnect() } }
            .store(in: &bag)
    }

    // MARK: - pairing

    /// Runs the helper and starts a pairing: the helper puts its code on
    /// screen. Only ever from a click of yours.
    func connect() async {
        guard state == .idle else { return }
        trouble = nil
        state = .starting
        do {
            try await exclusive {
                if link == nil {
                    let link = try makeLink()
                    link.onMessage = { [weak self] in self?.received($0) }
                    link.onEnd = { [weak self] in self?.ended() }
                    self.link = link
                    try link.start()
                }
                let hello = try await request(AppleMessages.hello(), timeout: 5)
                let capabilities = hello["capabilities"] as? [String: Any] ?? [:]
                if let version = capabilities["secretSessionVersion"] as? Int, version != 1 {
                    throw Unavailable(errorDescription: "This Mac's Passwords helper is too old")
                }
                let client = SRPClient(base64: capabilities["shouldUseBase64"] as? Bool ?? false)
                let reply = try await request(AppleMessages.start(client), timeout: 15)
                numbers = try AppleMessages.readStart(reply, client)
                self.client = client
            }
            state = .code
        } catch {
            fail(error, stop: true)
        }
    }

    /// The code the helper shows, typed by you.
    func enter(_ code: String) async {
        let code = code.filter(\.isNumber)
        guard state == .code, code.count == 6, let client, let numbers else { return }
        state = .checking
        trouble = nil
        do {
            let proof = try await Task.detached(priority: .userInitiated) {
                try client.prove(serverKey: numbers.serverKey, salt: numbers.salt, code: code)
            }.value
            try await exclusive {
                let reply = try await request(AppleMessages.verify(client, proof: proof), timeout: 15)
                try AppleMessages.readVerify(reply, client, proof: proof)
            }
            key = proof.key
            self.numbers = nil
            state = .paired
        } catch ApplePasswordsError.wrongCode {
            // The helper is done with that code: a new pairing shows a new one.
            self.numbers = nil
            self.client = nil
            state = .idle
            trouble = "That code didn't match. Connect again for a new one."
        } catch {
            fail(error, stop: true)
        }
    }

    /// Back to nothing: the helper told goodbye and stopped, every secret
    /// dropped. Also when the switch goes off and when Search quits.
    func disconnect() {
        if let link {
            try? link.send(AppleMessages.end())
            link.onEnd = nil
            link.stop()
        }
        reset()
        state = .idle
    }

    // MARK: - asking

    /// The names the helper keeps for `host` (the page's own host, www and
    /// all). Usernames only; nothing secret.
    func logins(for host: String, tab: UUID, wanted: @MainActor () -> Bool = { true }) async -> [AppleLogin] {
        guard state == .paired else { return [] }
        do {
            return try await exclusive {
                guard wanted(), let client, let key else { return [] }
                let reply = try await request(
                    AppleMessages.loginNames(host: host, tab: number(of: tab), client: client, key: key), timeout: 8)
                return try AppleMessages.readLoginNames(AppleMessages.readSealed(reply, client, key: key))
            }
        } catch {
            dropIfSessionLost(error)
            return []
        }
    }

    /// The password of the account picked, for `host`. macOS may ask for
    /// Touch ID first; that can take a while, so no short timeout.
    func password(for user: String, host: String, tab: UUID) async -> (password: String, sites: [String])? {
        guard state == .paired else { return nil }
        do {
            return try await exclusive {
                guard let client, let key else { return nil }
                let reply = try await request(
                    AppleMessages.password(user: user, host: host, tab: number(of: tab), client: client, key: key), timeout: 120)
                return try AppleMessages.readPassword(AppleMessages.readSealed(reply, client, key: key), user: user)
                    .map { ($0.password, $0.sites) }
            }
        } catch {
            dropIfSessionLost(error)
            return nil
        }
    }

    // MARK: - the line

    /// One question at a time: the helper's answers carry no number to tell
    /// two of the same kind apart.
    private func exclusive<T>(_ work: () async throws -> T) async throws -> T {
        while busy { await withCheckedContinuation { queue.append($0) } }
        busy = true
        defer {
            busy = false
            if !queue.isEmpty { queue.removeFirst().resume() }
        }
        return try await work()
    }

    private func request(_ message: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        guard let link, let command = message["cmd"] as? Int else { throw ApplePasswordsError.gone }
        nextWaiter += 1
        let id = nextWaiter
        return try await withCheckedThrowingContinuation { continuation in
            waiters[command] = (id, continuation)
            do {
                try link.send(message)
            } catch {
                resolve(command, id: id, with: .failure(ApplePasswordsError.gone))
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.resolve(command, id: id, with: .failure(ApplePasswordsError.timedOut))
            }
        }
    }

    private func resolve(_ command: Int, id: Int? = nil, with result: Result<[String: Any], Error>) {
        guard let waiter = waiters[command], id == nil || waiter.id == id else { return }
        waiters[command] = nil
        waiter.continuation.resume(with: result)
    }

    private func received(_ message: [String: Any]) {
        guard let command = message["cmd"] as? Int else { return }
        switch command {
        case AppleCommand.passwordsDisabled.rawValue, AppleCommand.reloginNeeded.rawValue:
            // iCloud Keychain turned off, or signed out: the pairing is over.
            disconnect()
            trouble = "Apple Passwords needs you to sign in again"
        default:
            resolve(command, with: .success(message))
        }
    }

    /// The helper went: everything that was waiting fails, and the pairing
    /// with it.
    private func ended() {
        link = nil
        reset()
        state = .idle
    }

    private func reset() {
        let pending = waiters.values
        waiters = [:]
        pending.forEach { $0.continuation.resume(throwing: ApplePasswordsError.gone) }
        link = nil
        client = nil
        numbers = nil
        key = nil
        tabNumbers = [:]
    }

    private func fail(_ error: Error, stop: Bool) {
        trouble = Self.words(for: error)
        if stop { disconnect() } else { state = .idle }
    }

    private func dropIfSessionLost(_ error: Error) {
        switch error {
        case ApplePasswordsError.status(9), ApplePasswordsError.gone, ApplePasswordsError.notTheHelper:
            disconnect()
            trouble = "Apple Passwords was disconnected. Connect again to use it."
        default:
            break
        }
    }

    private func number(of tab: UUID) -> Int {
        if let known = tabNumbers[tab] { return known }
        let next = tabNumbers.count + 1
        tabNumbers[tab] = next
        return next
    }

    nonisolated static func words(for error: Error) -> String {
        switch error {
        case let error as Unavailable: return error.errorDescription ?? "Apple Passwords isn't available"
        case ApplePasswordsError.timedOut: return "Apple's Passwords helper didn't answer"
        case ApplePasswordsError.gone: return "Apple's Passwords helper wouldn't run for this copy of Search"
        case ApplePasswordsError.notTheHelper: return "The pairing couldn't be checked. Connect again."
        case ApplePasswordsError.badHello, ApplePasswordsError.malformed:
            return "Apple's Passwords helper answered in a way Search doesn't know"
        default: return "Apple Passwords isn't available on this Mac"
        }
    }

    // MARK: - which accounts a page gets

    /// Whether a page may be offered Apple Passwords at all: an ordinary
    /// tab, an https page, a host to ask about.
    nonisolated static func offers(on url: URL?, privateTab: Bool) -> String? {
        guard !privateTab, let url, url.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased(), !host.isEmpty
        else { return nil }
        return host
    }

    /// Only accounts kept for this site, as Search's own are matched: the
    /// host, or anything sharing its registrable domain. The helper may know
    /// wider ties (a company's several domains); those are not offered.
    /// `wide` false: the host alone, for a box that only might be a sign-in's.
    nonisolated static func belongs(_ sites: [String], to host: String, wide: Bool = true,
                                    registrable: (String) -> String = Vault.registrable) -> Bool {
        let domain = registrable(bare(host))
        return sites.contains { site in
            let site = bare(Vault.host(of: site).isEmpty ? site : Vault.host(of: site))
            return site == bare(host) || (wide && registrable(site) == domain)
        }
    }

    nonisolated private static func bare(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// What a page was filled with from the Passwords app, remembered only well
/// enough to recognise it being sent: the site, the name, and the password's
/// HMAC under a key made for this one fill and kept in memory.
struct AppleFill {
    let host: String
    let user: String
    private let key = SymmetricKey(size: .bits256)
    private let mark: Data

    init(host: String, user: String, password: String) {
        self.host = host
        self.user = user
        mark = Data(HMAC<SHA256>.authenticationCode(for: Data(password.utf8), using: key))
    }

    func matches(host: String, user: String, password: String) -> Bool {
        guard user == self.user, ApplePasswords.belongs([host], to: self.host) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mark, authenticating: Data(password.utf8), using: key)
    }
}
