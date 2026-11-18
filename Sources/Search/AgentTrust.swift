import Foundation
import OSLog
import Security

// "Always allow": an agent remembered, so its question isn't asked again.
//
// What is remembered is never the name a client gives itself, which is its
// own word. It is the program that started the client — Claude Code's
// `claude`, which runs ./search-mcp under Python — as its code signature
// says: the designated requirement macOS checks it against (for `claude`,
// its identifier and Anthropic's Developer ID team), with the name the
// client gave beside it. Python itself is never enough: anything can run it.
//
// How the program is found: the client's audit token, from the socket
// (LOCAL_PEERTOKEN), names the very process that connected, never a pid
// some other process has since been given. Its parent is looked up by pid,
// which has no token to be had; the chain is read again once the parent's
// signature has been checked: the client still alive by its token, its
// parent the same pid, started at the same moment. A parent that died
// leaves its children to launchd, so a pid given to someone else no longer
// reads as the parent.
//
// Offered only for a parent on a short list of agents' own programs, each
// signed by its maker's team (AgentLauncher.allowed: Claude Code's
// `claude`) — never a terminal, an editor, an interpreter or a shell, which
// run whatever they are given. Checked again on every connection: the
// parent must pass the requirement remembered, and the client give the same
// name; anything else and the question is asked. Stop suspends it (asked
// again until you allow it in the question), and it runs out by itself 30
// days after it was granted or 7 days after it was last used. It never
// carries "Let it see my open tabs": let in without asking, an agent sees
// only its own tabs.
//
// Kept in the keychain's data protection half, under Search's own access
// group, as the switch's mark is (SwitchMark): only an app signed as Search
// with its profile reads or writes it, so another program writing the
// defaults, or a file, adds nobody. A copy of Search built without the
// profile has nowhere safe to keep it, and doesn't offer it. Turning the
// setting off — or on — forgets everyone.
//
// Even remembered, it is the same connection: Stop shows for
// as long as it is there ("allowed automatically"), it works in tabs of its
// own, and every limit in AgentControl holds.

/// The program that started an agent's client, as its code signature says.
struct AgentLauncher: Equatable {
    /// Its executable, as it ran.
    var path = ""
    var identifier = ""
    var team = ""
    /// Who signed it, from its certificate: "Developer ID Application: Anthropic PBC (Q6L2SF6YDW)".
    var signer = ""
    /// Its designated requirement, as text.
    var requirement = ""
    var adhoc = false
    var signed = false
    /// Why it can't be remembered, or nil when it can (AgentLauncher.refusal).
    var unrememberable: String?

    var name: String { (path as NSString).lastPathComponent }

    /// The signer as a person would say it: "Anthropic PBC".
    var who: String {
        var text = signer
        for prefix in ["Developer ID Application: ", "Apple Development: ", "Apple Distribution: ", "Mac Developer: "]
        where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if let open = text.range(of: " (", options: .backwards), text.hasSuffix(")") { text = String(text[..<open.lowerBound]) }
        return text.isEmpty ? team : text
    }

    /// The only programs an agent can be remembered as started by: their
    /// signing identifier, and the team that must have signed it. Not a list
    /// of what to keep out — terminals, editors, Electron helpers, tmux,
    /// interpreters and shells all run anything they are given — but of what
    /// to let in: agents' own command-line programs, each signed by its
    /// maker. Codex's CLI isn't here: it ships unsigned through npm and
    /// Homebrew, so there is no signature to remember it by.
    static let allowed: [String: String] = [
        "com.anthropic.claude-code": "Q6L2SF6YDW",
    ]

    /// Why a launcher can't be remembered, or nil when it can.
    static func refusal(signed: Bool, adhoc: Bool, team: String, identifier: String, path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let called = name.isEmpty ? "the program that started it" : name
        guard signed else { return "\(called), which started it, isn't signed" }
        guard !adhoc, !team.isEmpty else { return "\(called), which started it, isn't signed by a named developer" }
        guard let expected = allowed[identifier], expected == team else {
            return "it was started by \(called), which isn't an agent's own program Search knows"
        }
        return nil
    }
}

// MARK: - the signature

enum AgentIdentity {
    static let log = Logger(subsystem: "com.officecommun.search", category: "Agent")

    /// The audit token of the process at the other end of a Unix socket: the
    /// process that connected, as the kernel knows it (pid and its version).
    static func token(of fd: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        // SOL_LOCAL, LOCAL_PEERTOKEN.
        guard getsockopt(fd, 0, 0x006, &token, &size) == 0, size == socklen_t(MemoryLayout<audit_token_t>.size) else { return nil }
        return token
    }

    static func pid(_ token: audit_token_t) -> pid_t { pid_t(bitPattern: token.val.5) }

    /// A running process's code: by its audit token, or by pid.
    static func code(token: audit_token_t) -> SecCode? {
        var token = token
        let data = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        return guest([kSecGuestAttributeAudit: data])
    }

    static func code(pid: pid_t) -> SecCode? { guest([kSecGuestAttributePid: NSNumber(value: pid)]) }

    private static func guest(_ attributes: [CFString: Any]) -> SecCode? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess else { return nil }
        return code
    }

    /// A process's parent and the moment it started.
    static func process(_ pid: pid_t) -> (parent: pid_t, started: timeval)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return (info.kp_eproc.e_ppid, info.kp_proc.p_starttime)
    }

    /// Whether running code passes a requirement written as text: its
    /// signature valid now, in the kernel's eyes and on disk, and the
    /// requirement met.
    static func passes(_ code: SecCode, _ requirement: String) -> Bool {
        var made: SecRequirement?
        guard !requirement.isEmpty, SecRequirementCreateWithString(requirement as CFString, [], &made) == errSecSuccess,
              let made else { return false }
        return SecCodeCheckValidity(code, [], made) == errSecSuccess
    }

    /// What a running process's signature says.
    static func describe(_ code: SecCode) -> AgentLauncher {
        var out = AgentLauncher()
        out.signed = SecCodeCheckValidity(code, [], nil) == errSecSuccess
        var staticCode: SecStaticCode?
        if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode {
            var path: CFURL?
            if SecCodeCopyPath(staticCode, [], &path) == errSecSuccess, let path { out.path = (path as URL).path }
            var info: CFDictionary?
            if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
               let info = info as? [String: Any] {
                out.identifier = info[kSecCodeInfoIdentifier as String] as? String ?? ""
                out.team = info[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
                let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
                out.adhoc = flags & SecCodeSignatureFlags.adhoc.rawValue != 0
                if let leaf = (info[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first {
                    out.signer = SecCertificateCopySubjectSummary(leaf) as String? ?? ""
                }
            }
            var requirement: SecRequirement?
            var text: CFString?
            if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
               SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text {
                out.requirement = text as String
            }
        }
        if out.requirement.isEmpty { out.signed = false }
        out.unrememberable = AgentLauncher.refusal(signed: out.signed, adhoc: out.adhoc, team: out.team,
                                                   identifier: out.identifier, path: out.path)
        return out
    }

    /// The program that started the client at the other end of `token`, and
    /// which of `requirements` it passes — or nil when the chain can't be
    /// read, or changed while it was being read. Slow (the signature is
    /// checked on disk): never on the main thread.
    static func examine(_ token: audit_token_t, against requirements: [String]) -> (launcher: AgentLauncher, passed: Set<String>)? {
        let peer = pid(token)
        // The client by its token: alive, and the very process that connected.
        guard peer > 0, code(token: token) != nil, let before = process(peer), before.parent > 1,
              let parentBefore = process(before.parent), let parent = code(pid: before.parent) else { return nil }
        let launcher = describe(parent)
        let passed = Set(requirements.filter { passes(parent, $0) })
        // The same chain afterwards: the client still the one that
        // connected, its parent the same pid, started at the same moment.
        guard code(token: token) != nil, let after = process(peer), after.parent == before.parent,
              let parentAfter = process(before.parent),
              parentAfter.started.tv_sec == parentBefore.started.tv_sec,
              parentAfter.started.tv_usec == parentBefore.started.tv_usec else {
            log.notice("the program that started an agent changed while it was being checked")
            return nil
        }
        return (launcher, passed)
    }
}

// MARK: - what is remembered

/// One agent you said to always allow.
struct RememberedAgent: Codable, Equatable, Identifiable {
    /// The name it gave itself, as shown ("Claude Code").
    var client: String
    /// The designated requirement the program that started it passed.
    var requirement: String
    var team: String
    var identifier: String
    /// "Anthropic PBC".
    var signer: String
    /// Where that program was, the last time: shown, not checked — an update
    /// moves it (~/.local/share/claude/versions/<version>).
    var path: String
    var added: Date
    var used: Date
    /// Stopped while let in without asking: asked again, until you allow it
    /// again in the question.
    var suspended: Bool?
    /// Put there by the bench in a probe's world (`agents trust`), for a
    /// program that couldn't otherwise be remembered. Never honoured outside
    /// a test run.
    var simulated: Bool?

    var id: String { client + "\n" + requirement }

    /// Remembered for this long after it was granted…
    static let lasts: TimeInterval = 30 * 86_400
    /// …and for this long after it was last let in, whichever ends first.
    static let idleLasts: TimeInterval = 7 * 86_400

    /// When it is forgotten by itself.
    var expires: Date { min(added.addingTimeInterval(Self.lasts), used.addingTimeInterval(Self.idleLasts)) }
    func expired(at now: Date) -> Bool { now >= expires }
}

/// Where the remembered agents are kept.
protocol AgentVault {
    /// There is somewhere safe to keep them.
    var usable: Bool { get }
    func read() -> Data?
    @discardableResult func write(_ data: Data) -> Bool
    func erase()
}

/// The keychain's data protection half, under Search's own access group: what
/// SwitchMark keeps the switch's mark in.
struct KeychainVault: AgentVault {
    let service: String
    let account: String

    /// Search's own access group, named outright: the application identifier
    /// this copy is signed with (TEAM.com.officecommun.search), from its own
    /// entitlements. A copy without one has no group, and nowhere to keep this.
    static let group: String? = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil)
        else { return nil }
        return value as? String
    }()

    static let agents = KeychainVault(service: "com.officecommun.search.agents.trusted",
                                      account: Store.world.map { "trusted (\($0))" } ?? "trusted")

    private var query: [String: Any] {
        var out: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecUseDataProtectionKeychain as String: true,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: account]
        if let group = Self.group { out[kSecAttrAccessGroup as String] = group }
        return out
    }

    /// A copy built without Search's profile has no access group: no.
    var usable: Bool {
        guard Self.group != nil else { return false }
        var asked = query
        asked[kSecReturnAttributes as String] = true
        let status = SecItemCopyMatching(asked as CFDictionary, nil)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func read() -> Data? {
        var asked = query
        asked[kSecReturnData as String] = true
        var found: CFTypeRef?
        guard SecItemCopyMatching(asked as CFDictionary, &found) == errSecSuccess else { return nil }
        return found as? Data
    }

    func write(_ data: Data) -> Bool {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func erase() {
        SecItemDelete(query as CFDictionary)
    }
}

/// For the tests: somewhere in memory.
final class MemoryVault: AgentVault {
    var data: Data?
    var usable = true
    init(_ data: Data? = nil) { self.data = data }
    func read() -> Data? { usable ? data : nil }
    func write(_ data: Data) -> Bool {
        guard usable else { return false }
        self.data = data
        return true
    }
    func erase() { data = nil }
}

@MainActor
final class AgentTrust: ObservableObject {
    static let shared = AgentTrust(vault: KeychainVault.agents)

    @Published private(set) var remembered: [RememberedAgent] = []
    private let vault: AgentVault
    /// Whether this copy can keep anyone, asked once.
    let usable: Bool

    init(vault: AgentVault, now: Date = Date()) {
        self.vault = vault
        usable = vault.usable
        if usable, let data = vault.read(),
           let found = try? JSONDecoder().decode([RememberedAgent].self, from: data) {
            remembered = found
            // What has run out is forgotten for good.
            if found.contains(where: { $0.expired(at: now) }) { _ = save(found.filter { !$0.expired(at: now) }) }
        }
    }

    /// Remembered as allowed, from now on: the client by its name, the
    /// program that started it by its signature. Only a launcher that can be.
    @discardableResult
    func remember(client: String, launcher: AgentLauncher, now: Date = Date()) -> Bool {
        guard usable, launcher.unrememberable == nil, !launcher.requirement.isEmpty else { return false }
        let entry = RememberedAgent(client: client, requirement: launcher.requirement, team: launcher.team,
                                    identifier: launcher.identifier, signer: launcher.who, path: launcher.path,
                                    added: now, used: now)
        return keep(entry)
    }

    /// Stopped while let in without asking: asked again from now on, until
    /// you allow it again in the question.
    func suspend(_ id: RememberedAgent.ID) {
        guard let index = remembered.firstIndex(where: { $0.id == id }) else { return }
        var next = remembered
        next[index].suspended = true
        _ = save(next)
    }

    /// You allowed it in the question: what was suspended under that name
    /// is let in again next time.
    func resume(client: String) {
        guard remembered.contains(where: { $0.client == client && $0.suspended == true }) else { return }
        _ = save(remembered.map { entry in
            var entry = entry
            if entry.client == client { entry.suspended = nil }
            return entry
        })
    }

    /// The bench's, in a probe's world only: a requirement remembered for a
    /// launcher that couldn't otherwise be — a test harness's own.
    @discardableResult
    func rememberSimulated(client: String, requirement: String, added: Date = Date()) -> Bool {
        guard Store.testing, usable else { return false }
        return keep(RememberedAgent(client: client, requirement: requirement, team: "TESTTEAM", identifier: "probe",
                                    signer: "a probe", path: "", added: added, used: added, simulated: true))
    }

    private func keep(_ entry: RememberedAgent) -> Bool {
        var next = remembered.filter { $0.id != entry.id }
        next.append(entry)
        return save(next)
    }

    /// Asked again from now on.
    func forget(_ id: RememberedAgent.ID) {
        _ = save(remembered.filter { $0.id != id })
    }

    func forgetAll() {
        vault.erase()
        remembered = []
    }

    /// Last let in now.
    func used(_ entry: RememberedAgent, now: Date = Date()) {
        guard let index = remembered.firstIndex(where: { $0.id == entry.id }) else { return }
        var next = remembered
        next[index].used = now
        next[index].path = entry.path
        _ = save(next)
    }

    private func save(_ next: [RememberedAgent]) -> Bool {
        guard usable, let data = try? JSONEncoder().encode(next) else { return false }
        if next.isEmpty {
            vault.erase()
        } else if !vault.write(data) {
            return false
        }
        remembered = next
        return true
    }

    /// The requirements to check a client by, before it is let in: those
    /// remembered under the name it gave.
    func requirements(for client: String, now: Date = Date()) -> [String] {
        remembered.filter { $0.client == client && $0.suspended != true && !$0.expired(at: now) }.map(\.requirement)
    }

    /// The entry that lets a connection in without asking, if one does: the
    /// same name, and the program that started it passing that entry's
    /// requirement (`passed`, from AgentIdentity.examine) and still one that
    /// could be remembered. Nothing read, nothing let in.
    static func match(client: String, launcher: AgentLauncher?, passed: Set<String>,
                      among remembered: [RememberedAgent], testing: Bool = Store.testing, now: Date = Date()) -> RememberedAgent? {
        guard let launcher else { return nil }
        return remembered.first { entry in
            guard entry.client == client, passed.contains(entry.requirement),
                  entry.suspended != true, !entry.expired(at: now) else { return false }
            if entry.simulated == true { return testing }
            return launcher.unrememberable == nil
        }
    }
}
