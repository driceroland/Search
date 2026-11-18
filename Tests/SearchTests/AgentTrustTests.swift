import Foundation
import Security
import XCTest
@testable import Search

/// "Always allow" for a coding agent (AgentTrust): what is remembered is the
/// code signature of the program that started the client, never the name it
/// gives; checked again on every connection; kept only where Search alone
/// can write.
@MainActor
final class AgentTrustTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "agent-trust-\(getpid())", 1)
        super.setUp()
    }

    /// Claude Code's own, as `codesign -d -r-` gives it.
    nonisolated static let claude = #"identifier "com.anthropic.claude-code" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = Q6L2SF6YDW"#

    /// A launcher that could be remembered, as the signature would say.
    static func signed(_ requirement: String = claude) -> AgentLauncher {
        var out = AgentLauncher(path: "/Users/someone/.local/share/claude/versions/2.1.139",
                                identifier: "com.anthropic.claude-code", team: "Q6L2SF6YDW",
                                signer: "Developer ID Application: Anthropic PBC (Q6L2SF6YDW)",
                                requirement: requirement, adhoc: false, signed: true)
        out.unrememberable = AgentLauncher.refusal(signed: true, adhoc: false, team: out.team,
                                                   identifier: out.identifier, path: out.path)
        return out
    }

    private func ownRequirement() throws -> String {
        var me: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &me), errSecSuccess)
        var still: SecStaticCode?
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(me), [], &still), errSecSuccess)
        var requirement: SecRequirement?
        try XCTSkipUnless(SecCodeCopyDesignatedRequirement(try XCTUnwrap(still), [], &requirement) == errSecSuccess,
                          "the test runner has no designated requirement")
        var text: CFString?
        XCTAssertEqual(SecRequirementCopyString(try XCTUnwrap(requirement), [], &text), errSecSuccess)
        return try XCTUnwrap(text) as String
    }

    // MARK: - the signature

    func testMatchingAndNonMatchingRequirements() throws {
        let sleep = Process()
        sleep.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleep.arguments = ["10"]
        try sleep.run()
        defer { sleep.terminate() }
        let code = try XCTUnwrap(AgentIdentity.code(pid: sleep.processIdentifier))
        XCTAssertTrue(AgentIdentity.passes(code, #"identifier "com.apple.sleep" and anchor apple"#))
        XCTAssertFalse(AgentIdentity.passes(code, Self.claude), "macOS's sleep isn't Claude Code")
        XCTAssertFalse(AgentIdentity.passes(code, #"identifier "com.apple.sleep" and certificate leaf[subject.OU] = Q6L2SF6YDW"#))
        XCTAssertFalse(AgentIdentity.passes(code, "not a requirement ("), "a requirement that doesn't parse passes nothing")
        XCTAssertFalse(AgentIdentity.passes(code, ""))
        let said = AgentIdentity.describe(code)
        XCTAssertEqual(said.identifier, "com.apple.sleep")
        XCTAssertTrue(said.signed)
        XCTAssertNotNil(said.unrememberable, "one of macOS's own programs has no team: never remembered")
    }

    /// The whole chain, as a connection gives it: a client this test starts
    /// connects to a socket, and the program that started it — this test's
    /// runner — is the one examined, by the client's audit token.
    func testTheProgramThatStartedTheClient() throws {
        let mine = try ownRequirement()
        let path = NSTemporaryDirectory() + "agent-trust-\(getpid()).sock"
        unlink(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(listener); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { sun in
            sun.withMemoryRebound(to: CChar.self, capacity: 104) { strlcpy($0, path, 104) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(listener, 1), 0)
        let client = Process()
        client.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        client.arguments = ["-U", path]
        client.standardInput = Pipe()
        client.standardOutput = Pipe()
        try client.run()
        defer { client.terminate() }
        let fd = Darwin.accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let token = try XCTUnwrap(AgentIdentity.token(of: fd))
        XCTAssertEqual(AgentIdentity.pid(token), client.processIdentifier, "the token names the client")
        let seen = try XCTUnwrap(AgentIdentity.examine(token, against: [mine, Self.claude]))
        XCTAssertEqual(seen.passed, [mine], "the runner passes its own requirement, and not Claude Code's")
        XCTAssertEqual(seen.launcher.requirement, mine)
        XCTAssertFalse(seen.launcher.path.isEmpty)
        // Gone, it is examined as nothing at all.
        client.terminate()
        client.waitUntilExit()
        XCTAssertNil(AgentIdentity.examine(token, against: [mine]), "a client that is gone has no chain")
    }

    func testUnsignedOrSharedLaunchersAreNeverOffered() {
        XCTAssertNotNil(AgentLauncher.refusal(signed: false, adhoc: false, team: "", identifier: "", path: "/tmp/run"))
        XCTAssertNotNil(AgentLauncher.refusal(signed: true, adhoc: true, team: "", identifier: "run-55", path: "/tmp/run"),
                        "ad-hoc: anyone can sign so")
        XCTAssertNotNil(AgentLauncher.refusal(signed: true, adhoc: false, team: "", identifier: "com.apple.zsh", path: "/bin/zsh"),
                        "macOS's own, no team")
        for (identifier, path) in [("python3", "/Library/Frameworks/Python.framework/Versions/3.14/bin/python3.14"),
                                   ("org.python.python", "/usr/local/bin/python3"), ("node", "/opt/homebrew/bin/node"),
                                   ("com.example.bun", "/usr/local/bin/bun"), ("com.apple.bash", "/bin/bash")] {
            XCTAssertNotNil(AgentLauncher.refusal(signed: true, adhoc: false, team: "BMM5U3QVKW", identifier: identifier, path: path),
                            "\(identifier) runs anything it's given")
        }
        XCTAssertNil(Self.signed().unrememberable, "Claude Code, signed by Anthropic, can be")
        XCTAssertEqual(Self.signed().who, "Anthropic PBC")
    }

    // MARK: - what is remembered

    func testRememberedIsLetInOnlyWithItsNameAndItsSignature() {
        let trust = AgentTrust(vault: MemoryVault())
        XCTAssertTrue(trust.remember(client: "Claude Code", launcher: Self.signed(), seesTabs: true))
        let launcher = Self.signed()
        let entry = AgentTrust.match(client: "Claude Code", launcher: launcher, passed: [Self.claude], among: trust.remembered, testing: false)
        XCTAssertEqual(entry?.seesTabs, true, "let in, with your tabs as you ticked")
        XCTAssertNil(AgentTrust.match(client: "Codex", launcher: launcher, passed: [Self.claude], among: trust.remembered, testing: false),
                     "another name: asked")
        XCTAssertNil(AgentTrust.match(client: "Claude Code", launcher: launcher, passed: [], among: trust.remembered, testing: false),
                     "the program didn't pass the requirement: asked")
        XCTAssertNil(AgentTrust.match(client: "Claude Code", launcher: nil, passed: [Self.claude], among: trust.remembered, testing: false),
                     "the program couldn't be read: asked")
        var python = launcher
        python.unrememberable = "it was started by python3, which runs anything it's given"
        XCTAssertNil(AgentTrust.match(client: "Claude Code", launcher: python, passed: [Self.claude], among: trust.remembered, testing: false),
                     "no longer something that could be remembered: asked")
        XCTAssertEqual(trust.requirements(for: "Claude Code"), [Self.claude])
        XCTAssertEqual(trust.requirements(for: "Codex"), [])
    }

    func testOnlyALauncherThatCanBeIsRemembered() {
        let trust = AgentTrust(vault: MemoryVault())
        var unsigned = Self.signed("cdhash H\"0123\"")
        unsigned.adhoc = true
        unsigned.team = ""
        unsigned.unrememberable = AgentLauncher.refusal(signed: true, adhoc: true, team: "", identifier: "a.out", path: "/tmp/a.out")
        XCTAssertFalse(trust.remember(client: "Claude Code", launcher: unsigned, seesTabs: false))
        XCTAssertTrue(trust.remembered.isEmpty)
    }

    func testForgottenIsAskedAgain() {
        let vault = MemoryVault()
        let trust = AgentTrust(vault: vault)
        trust.remember(client: "Claude Code", launcher: Self.signed(), seesTabs: false)
        trust.remember(client: "Codex", launcher: Self.signed("identifier \"com.openai.codex\" and anchor apple generic"), seesTabs: false)
        XCTAssertEqual(trust.remembered.count, 2)
        trust.forget(trust.remembered[0].id)
        XCTAssertNil(AgentTrust.match(client: "Claude Code", launcher: Self.signed(), passed: [Self.claude], among: trust.remembered, testing: false))
        XCTAssertEqual(AgentTrust(vault: vault).remembered.map(\.client), ["Codex"], "forgotten for good, not only on screen")
    }

    func testTurningTheSettingOffForgetsEveryone() {
        let vault = MemoryVault()
        let trust = AgentTrust(vault: vault)
        trust.remember(client: "Claude Code", launcher: Self.signed(), seesTabs: true)
        trust.forgetAll()
        XCTAssertTrue(trust.remembered.isEmpty)
        XCTAssertNil(vault.data)
        XCTAssertTrue(AgentTrust(vault: vault).remembered.isEmpty)
    }

    func testTheSwitchForgetsWhenTurnedOffOrOn() throws {
        // Preferences' switch calls AgentTrust.shared.forgetAll(): checked
        // in its source, as a unit test has no keychain of Search's own.
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/SearchTests/AgentTrustTests.swift",
                                                                                 with: "Sources/Search/Prefs.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("if agents != oldValue { AgentTrust.shared.forgetAll() }"))
    }

    /// Written by some other program, where it can write: the defaults, a
    /// file beside the socket, or a store this copy can't vouch for. None of
    /// it lets anybody in.
    func testWhatIsWrittenBehindSearchsBackIsIgnored() throws {
        let forged = try JSONEncoder().encode([RememberedAgent(
            client: "Claude Code", requirement: "anchor apple generic", team: "EVIL", identifier: "evil", signer: "evil",
            path: "/tmp/evil", seesTabs: true, added: Date(), used: Date())])
        Store.settings.set(forged, forKey: "agents.trusted")
        Store.settings.set(String(decoding: forged, as: UTF8.self), forKey: "trusted")
        defer {
            Store.settings.removeObject(forKey: "agents.trusted")
            Store.settings.removeObject(forKey: "trusted")
        }
        try? FileManager.default.createDirectory(at: AgentControl.folder, withIntermediateDirectories: true)
        let file = AgentControl.folder.appendingPathComponent("trusted.json")
        try forged.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        // The keychain item, from a copy without Search's access group (this
        // test runner): nowhere safe, so nothing read, nothing kept, and no
        // falling back to the defaults.
        let keychain = KeychainVault(service: "com.officecommun.search.agents.trusted.tests", account: "trusted (\(getpid()))")
        let trust = AgentTrust(vault: keychain)
        if !trust.usable {
            XCTAssertTrue(trust.remembered.isEmpty)
            XCTAssertFalse(trust.remember(client: "Claude Code", launcher: Self.signed(), seesTabs: false))
            XCTAssertTrue(trust.remembered.isEmpty)
        } else {
            keychain.erase()
        }
        XCTAssertTrue(AgentTrust(vault: MemoryVault()).remembered.isEmpty, "only the vault is read")
        // A vault that can't be used reads as empty, even holding something.
        let shut = MemoryVault(forged)
        shut.usable = false
        XCTAssertTrue(AgentTrust(vault: shut).remembered.isEmpty)
        // Unreadable: nobody.
        XCTAssertTrue(AgentTrust(vault: MemoryVault(Data("[{".utf8))).remembered.isEmpty)
    }

    /// The bench's stand-in for a signed launcher is a test run's only.
    func testASimulatedEntryIsATestRunsOnly() {
        let entry = RememberedAgent(client: "Claude Code", requirement: "cdhash H\"00\"", team: "TESTTEAM", identifier: "probe",
                                    signer: "a probe", path: "", seesTabs: false, added: Date(), used: Date(), simulated: true)
        var adhoc = Self.signed("cdhash H\"00\"")
        adhoc.unrememberable = "not signed"
        XCTAssertNil(AgentTrust.match(client: "Claude Code", launcher: adhoc, passed: ["cdhash H\"00\""], among: [entry], testing: false))
        XCTAssertNotNil(AgentTrust.match(client: "Claude Code", launcher: adhoc, passed: ["cdhash H\"00\""], among: [entry], testing: true))
    }

    func testInterpretersByName() {
        for word in ["python3", "python3.14", "Python", "org.python.python", "node", "bash", "com.apple.zsh", "env", "osascript", "npx"] {
            XCTAssertTrue(AgentLauncher.interpreter(word), word)
        }
        for word in ["claude", "com.anthropic.claude-code", "codex", "com.openai.codex", "Cursor", "shortcuts"] {
            XCTAssertFalse(AgentLauncher.interpreter(word), word)
        }
    }
}
