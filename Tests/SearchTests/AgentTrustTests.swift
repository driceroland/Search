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
    /// What Claude Code is checked against and remembered by: Search's own
    /// requirement for it (AgentLauncher.requirements).
    nonisolated static let claude = AgentLauncher.requirements["com.anthropic.claude-code"]!

    /// OpenCode's own, as `codesign -d -r-` gives it: the desktop app's
    /// sidecar, and the CLI npm and Homebrew install.
    nonisolated static let opencodeDesktop = AgentLauncher.requirements["opencode-cli"]!
    nonisolated static let opencodeCLI = AgentLauncher.requirements["opencode"]!

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
        // Only agents' own programs, by identifier and the team that signs
        // them: never an interpreter, a terminal, an editor or tmux, however
        // well signed.
        for (identifier, team, path) in [("python3", "BMM5U3QVKW", "/Library/Frameworks/Python.framework/Versions/3.14/bin/python3.14"),
                                         ("com.googlecode.iterm2", "H7V7XYVQ7D", "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
                                         ("com.microsoft.VSCode.helper", "UBF8T346G9", "/Applications/Visual Studio Code.app/x/Code Helper"),
                                         ("com.todesktop.230313mzl4w4u92.helper", "VDXQ22DGB9", "/Applications/Cursor.app/x/Cursor Helper"),
                                         ("tmux", "ABCDE12345", "/opt/homebrew/bin/tmux")] {
            XCTAssertNotNil(AgentLauncher.refusal(signed: true, adhoc: false, team: team, identifier: identifier, path: path),
                            "\(identifier) isn't an agent's own program")
        }
        XCTAssertNotNil(AgentLauncher.refusal(signed: true, adhoc: false, team: "EVILTEAM00", identifier: "com.anthropic.claude-code",
                                              path: "/tmp/claude"), "Claude Code's identifier, signed by someone else")
        XCTAssertNil(Self.signed().unrememberable, "Claude Code, signed by Anthropic, can be")
        XCTAssertEqual(Self.signed().who, "Anthropic PBC")
    }

    /// OpenCode, through either of the programs that run its client: the
    /// desktop app's sidecar and the CLI npm and Homebrew install are the
    /// same one, under two names, each signed by Anomaly Innovations.
    func testOpenCodeCanBeRememberedByEitherOfItsPrograms() {
        for (identifier, path, requirement) in [
            ("opencode-cli", "/Applications/OpenCode.app/Contents/MacOS/opencode-cli", Self.opencodeDesktop),
            ("opencode", "/opt/homebrew/bin/opencode", Self.opencodeCLI)
        ] {
            var launcher = AgentLauncher(path: path, identifier: identifier, team: "5NZ4Q7NXJ4",
                                         signer: "Developer ID Application: Anomaly Innovations, Inc. (5NZ4Q7NXJ4)",
                                         requirement: requirement, adhoc: false, signed: true)
            launcher.unrememberable = AgentLauncher.refusal(signed: true, adhoc: false, team: launcher.team,
                                                            identifier: identifier, path: path)
            XCTAssertNil(launcher.unrememberable, "\(identifier), signed by Anomaly Innovations, can be")
            XCTAssertEqual(launcher.allowlisted, requirement)
            XCTAssertEqual(launcher.who, "Anomaly Innovations, Inc.")
            XCTAssertNotNil(AgentLauncher.refusal(signed: true, adhoc: false, team: "EVILTEAM00",
                                                  identifier: identifier, path: path),
                            "\(identifier)'s identifier, signed by someone else")
        }
    }

    /// Nothing is offered that Search hasn't written what to check it
    /// against: a name in one list and not the other would ask every time.
    func testEveryProgramAllowedHasItsRequirement() {
        XCTAssertEqual(Set(AgentLauncher.allowed.keys), Set(AgentLauncher.requirements.keys))
        for (identifier, team) in AgentLauncher.allowed {
            let requirement = AgentLauncher.requirements[identifier] ?? ""
            XCTAssertTrue(requirement.contains("identifier \"\(identifier)\""), identifier)
            XCTAssertTrue(requirement.contains("certificate leaf[subject.OU] = \"\(team)\""), identifier)
        }
    }

    // MARK: - what is remembered

    func testRememberedIsLetInOnlyWithItsNameAndItsSignature() {
        let trust = AgentTrust(vault: MemoryVault())
        XCTAssertTrue(trust.remember(client: "Claude Code", launcher: Self.signed()))
        let launcher = Self.signed()
        let entry = AgentTrust.match(client: "Claude Code", launcher: launcher, passed: [Self.claude], among: trust.remembered, testing: false)
        XCTAssertNotNil(entry, "let in")
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
        XCTAssertFalse(trust.remember(client: "Claude Code", launcher: unsigned))
        XCTAssertTrue(trust.remembered.isEmpty)
    }

    func testForgottenIsAskedAgain() {
        let vault = MemoryVault()
        let trust = AgentTrust(vault: vault)
        trust.remember(client: "Claude Code", launcher: Self.signed())
        trust.remember(client: "Codex", launcher: Self.signed("identifier \"com.openai.codex\" and anchor apple generic"))
        XCTAssertEqual(trust.remembered.count, 2)
        trust.forget(trust.remembered[0].id)
        XCTAssertNil(AgentTrust.match(client: "Claude Code", launcher: Self.signed(), passed: [Self.claude], among: trust.remembered, testing: false))
        XCTAssertEqual(AgentTrust(vault: vault).remembered.map(\.client), ["Codex"], "forgotten for good, not only on screen")
    }

    func testTurningTheSettingOffForgetsEveryone() {
        let vault = MemoryVault()
        let trust = AgentTrust(vault: vault)
        trust.remember(client: "Claude Code", launcher: Self.signed())
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
            path: "/tmp/evil", added: Date(), used: Date())])
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
            XCTAssertFalse(trust.remember(client: "Claude Code", launcher: Self.signed()))
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
                                    signer: "a probe", path: "", added: Date(), used: Date(), simulated: true)
        var adhoc = Self.signed("cdhash H\"00\"")
        adhoc.unrememberable = "not signed"
        XCTAssertNil(AgentTrust.match(client: "Claude Code", launcher: adhoc, passed: ["cdhash H\"00\""], among: [entry], testing: false))
        XCTAssertNotNil(AgentTrust.match(client: "Claude Code", launcher: adhoc, passed: ["cdhash H\"00\""], among: [entry], testing: true))
    }

    // MARK: - Stop, time, your tabs

    func testStopSuspendsUntilAllowedAgain() {
        let vault = MemoryVault()
        let trust = AgentTrust(vault: vault)
        trust.remember(client: "Claude Code", launcher: Self.signed())
        trust.suspend(client: "Claude Code")
        XCTAssertNil(AgentTrust.match(client: "Claude Code", launcher: Self.signed(), passed: [Self.claude], among: trust.remembered, testing: false),
                     "stopped: asked again")
        XCTAssertEqual(trust.requirements(for: "Claude Code"), [], "not even checked")
        XCTAssertEqual(AgentTrust(vault: vault).remembered.first?.suspended, true, "and still after a relaunch")
        trust.resume(client: "Codex")
        XCTAssertEqual(trust.remembered.first?.suspended, true, "another name's Allow changes nothing")
        trust.resume(client: "Claude Code")
        XCTAssertNotNil(AgentTrust.match(client: "Claude Code", launcher: Self.signed(), passed: [Self.claude], among: trust.remembered, testing: false),
                        "allowed again in the question: let in again")
    }

    func testItRunsOut() {
        let vault = MemoryVault()
        let granted = Date().addingTimeInterval(-86_400 * 29)
        let trust = AgentTrust(vault: vault, now: granted)
        trust.remember(client: "Claude Code", launcher: Self.signed(), now: granted)
        let day: TimeInterval = 86_400
        func admitted(at now: Date) -> Bool {
            AgentTrust.match(client: "Claude Code", launcher: Self.signed(), passed: [Self.claude], among: trust.remembered,
                             testing: false, now: now) != nil
        }
        XCTAssertTrue(admitted(at: granted.addingTimeInterval(6 * day)))
        XCTAssertFalse(admitted(at: granted.addingTimeInterval(7 * day)), "7 days unused")
        // Used every few days: still 30 days at most from when it was granted.
        for days in stride(from: 5.0, through: 25.0, by: 5.0) { trust.used(trust.remembered[0], now: granted.addingTimeInterval(days * day)) }
        XCTAssertTrue(admitted(at: granted.addingTimeInterval(29 * day)))
        XCTAssertFalse(admitted(at: granted.addingTimeInterval(30 * day)), "30 days after it was granted")
        XCTAssertEqual(trust.remembered[0].expires, granted.addingTimeInterval(30 * day))
        // Read after it ran out: forgotten for good.
        XCTAssertTrue(AgentTrust(vault: vault, now: granted.addingTimeInterval(31 * day)).remembered.isEmpty)
        XCTAssertNil(vault.data)
    }

    func testYourTabsAreNeverRemembered() throws {
        let data = try JSONEncoder().encode([RememberedAgent(client: "Claude Code", requirement: Self.claude, team: "Q6L2SF6YDW",
                                                             identifier: "com.anthropic.claude-code", signer: "Anthropic PBC",
                                                             path: "", added: Date(), used: Date())])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Tabs"), "nothing about your tabs is kept")
        // And AgentControl lets a remembered agent in without them, whatever.
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/SearchTests/AgentTrustTests.swift",
                                                                                 with: "Sources/Search/AgentControl.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("session.consent.answer(allow: true, seesTabs: false)"))
    }

    func testTheKeychainItemNamesItsGroup() throws {
        // This runner has no application identifier: no group, and so
        // nowhere to keep anyone.
        if KeychainVault.group == nil {
            XCTAssertFalse(KeychainVault(service: "com.officecommun.search.agents.trusted.tests", account: "x").usable)
        }
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/SearchTests/AgentTrustTests.swift",
                                                                                 with: "Sources/Search/AgentTrust.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("out[kSecAttrAccessGroup as String] = group"))
    }

    // MARK: - the re-review

    /// Remembered by Search's requirement for Claude Code, never by the one
    /// the program declares for itself.
    func testRememberedByTheAllowlistsRequirement() throws {
        let trust = AgentTrust(vault: MemoryVault())
        XCTAssertTrue(trust.remember(client: "Claude Code", launcher: Self.signed("anchor apple generic")))
        XCTAssertEqual(trust.remembered.first?.requirement, Self.claude)
        var stranger = Self.signed("anchor apple generic")
        stranger.identifier = "com.example.agent"
        stranger.unrememberable = AgentLauncher.refusal(signed: true, adhoc: false, team: "ABCDE12345",
                                                        identifier: stranger.identifier, path: "/tmp/agent")
        XCTAssertNil(stranger.allowlisted)
        XCTAssertFalse(AgentTrust(vault: MemoryVault()).remember(client: "Claude Code", launcher: stranger))
        // And the requirement itself is one Security parses.
        var made: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(Self.claude as CFString, [], &made), errSecSuccess)
    }

    /// Always ticked, Allow, then Stop in that same session — nothing let it
    /// in automatically, and still the next connection is asked.
    func testStopSuspendsByNameInTheFirstSessionToo() {
        let trust = AgentTrust(vault: MemoryVault())
        trust.remember(client: "Claude Code", launcher: Self.signed())
        trust.remember(client: "Codex", launcher: Self.signed())
        trust.suspend(client: "Claude Code", also: nil)
        XCTAssertEqual(trust.remembered.filter { $0.suspended == true }.map(\.client), ["Claude Code"])
        XCTAssertNil(AgentTrust.match(client: "Claude Code", launcher: Self.signed(), passed: [Self.claude], among: trust.remembered, testing: false))
        XCTAssertNotNil(AgentTrust.match(client: "Codex", launcher: Self.signed(), passed: [Self.claude], among: trust.remembered, testing: false))
    }

    /// The keychain refusing the write: suspended anyway, until Search quits.
    func testASuspensionTheKeychainRefusesStillHolds() {
        let vault = MemoryVault()
        let trust = AgentTrust(vault: vault)
        trust.remember(client: "Claude Code", launcher: Self.signed())
        vault.refuses = true
        trust.suspend(client: "Claude Code")
        XCTAssertEqual(trust.remembered.first?.suspended, true)
        XCTAssertNil(AgentTrust.match(client: "Claude Code", launcher: Self.signed(), passed: [Self.claude], among: trust.remembered, testing: false))
        XCTAssertEqual(trust.requirements(for: "Claude Code"), [])
    }

    /// Only "Always allow" ticked again lifts a suspension; a one-off Allow
    /// doesn't, nor does the stand-in for a test harness outside a test run.
    func testOnlyAlwaysTickedAgainLiftsIt() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/SearchTests/AgentTrustTests.swift",
                                                                                 with: "Sources/Search/AgentControl.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("if allow, session.wantsAlways { AgentTrust.shared.resume(client: session.client) }"))
        XCTAssertFalse(source.contains("if allow { AgentTrust.shared.resume"))
        XCTAssertTrue(source.contains("AgentTrust.shared.suspend(client: session.client, also: session.admittedBy)"))
        XCTAssertTrue(source.contains("if allow, session.simulated, Store.testing,"))
        XCTAssertTrue(source.contains("browser.folded || browser.prefs.iconColumn ||"), "icons only: said as when folded")
    }

    /// Search's requirement for Claude Code passes the real `claude`, where
    /// one is installed (read only: nothing is run).
    func testTheRealClaudePassesIt() throws {
        let link = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/claude")
        let path = (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) ?? link
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "no claude here")
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code), errSecSuccess)
        var made: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(Self.claude as CFString, [], &made), errSecSuccess)
        XCTAssertEqual(SecStaticCodeCheckValidity(try XCTUnwrap(code), [], made), errSecSuccess)
    }

    /// Search's requirement for OpenCode passes the real `opencode-cli` the
    /// desktop app stages, where one is installed (read only: nothing is run).
    func testTheRealOpenCodePassesIt() throws {
        let support = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/ai.opencode.desktop/cli")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: support)) ?? []
        let path = versions.map { "\(support)/\($0)/opencode-cli" }
            .first { FileManager.default.fileExists(atPath: $0) }
        guard let path else { throw XCTSkip("no opencode-cli here") }
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code), errSecSuccess)
        var made: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(Self.opencodeDesktop as CFString, [], &made), errSecSuccess)
        XCTAssertEqual(SecStaticCodeCheckValidity(try XCTUnwrap(code), [], made), errSecSuccess)
    }
}
