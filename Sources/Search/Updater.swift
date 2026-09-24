import AppKit
import Combine
import CryptoKit
import Security

// Knowing when there is a newer one, and having it ready.
//
// No framework, no background daemon: one small JSON file next to the
// download, read once a day and whenever asked. If it names a build newer
// than this one, the ZIP it points at is fetched quietly, checked, and put
// where this bundle is — so the next time the app opens, it is the new one.
// Chrome's way, without Chrome's machinery. Nothing relaunches on its own; a
// page you are reading is not interrupted by a browser that wants to be
// newer.
//
// What the updater leaves alone, on purpose: everything in
// ~/Library/Application Support/Search, the defaults under
// com.officecommun.search, and the keychain. The session, the pins, the
// history, the passwords — none of it is read, moved or rewritten here. Only
// the bundle changes hands, and it keeps its bundle id and its signing
// identity, so the keychain items the old build made open for the new one.
// The updater deletes only what it made: its own scratch folder and the
// `.old` bundle it set aside.
//
// build.sh writes the file (build/appcast.json) at the same time as the DMG
// and the ZIP; publish.sh puts all three where `feed` points.

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// Where the file lives. SEARCH_FEED, for a test run, points somewhere
    /// else — and is the only way plain http is accepted, so a build that
    /// was not handed the variable only ever listens to the real site.
    static let feed: URL = {
        if let set = ProcessInfo.processInfo.environment["SEARCH_FEED"], let url = URL(string: set) {
            return url
        }
        return URL(string: "https://officecommun.com/search/appcast.json")!
    }()

    private static var overridden: Bool {
        ProcessInfo.processInfo.environment["SEARCH_FEED"] != nil
    }

    struct Release: Equatable {
        let version: String
        let build: Int
        /// The ZIP, for the updater.
        let archive: URL
        /// The disk image, for people.
        let dmg: URL
        /// Hex of the ZIP, when the feed gives one.
        let sha256: String?
        let notes: String?
        let minimumSystemVersion: String?

        /// A release that wants a newer macOS than this one is not newer for
        /// this Mac, and is not offered.
        var runsHere: Bool {
            guard let need = minimumSystemVersion else { return true }
            let parts = need.split(separator: ".").map { Int($0) ?? 0 }
            let least = OperatingSystemVersion(
                majorVersion: parts.count > 0 ? parts[0] : 0,
                minorVersion: parts.count > 1 ? parts[1] : 0,
                patchVersion: parts.count > 2 ? parts[2] : 0
            )
            return ProcessInfo.processInfo.isOperatingSystemAtLeast(least)
        }
    }

    /// How far along the newer build is, when there is one.
    enum Stage: Equatable {
        /// None known, or this is the latest.
        case none
        /// The ZIP is on its way, or being looked over.
        case fetching(Release)
        /// Swapped in; it runs at the next launch.
        case ready(Release)
        /// Couldn't be swapped in from here, so the disk image is offered
        /// instead — the same as the first time.
        case offered(Release)
    }

    @Published private(set) var stage: Stage = .none
    /// True while the file is being fetched.
    @Published private(set) var checking = false
    /// When the file was last read, for the line in Settings.
    @Published private(set) var lastChecked: Date?

    /// What this app is: the version people read, and the build that
    /// decides whether another is newer.
    nonisolated static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    nonisolated static var build: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    private var lastKey: String { "update.checked" }
    /// Where a line goes when there is one to say, handed over at launch.
    private var say: ((String) -> Void)?

    private init() {
        // The bundle a swap set aside goes once this process is done with
        // it — see Swap.sweep for why not sooner.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in Swap.sweep() }
    }

    /// At launch: once a day, quietly. A test run, pointed at its own feed,
    /// checks every time.
    func checkIfDue(then say: @escaping (String) -> Void) {
        self.say = say
        Swap.sweep()
        // And again every hour for as long as the app is up — a browser that
        // is left open for a week would otherwise never look.
        if clock == nil {
            clock = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkIfDue() }
            }
            clock?.tolerance = 60 * 5
        }
        checkIfDue()
    }

    private var clock: Timer?

    private func checkIfDue() {
        let last = Store.settings.object(forKey: lastKey) as? Date ?? .distantPast
        guard Updater.overridden || Date().timeIntervalSince(last) > 60 * 60 * 20 else { return }
        check { _ in }
    }

    /// Now, because somebody asked. `done` gets the newer build the feed
    /// names, or nil when this is the latest; what becomes of it after that
    /// is said through the line handed to `checkIfDue`.
    func check(then done: @escaping (Release?) -> Void) {
        guard !checking else { return }
        checking = true
        Task { [weak self] in
            let found = await Updater.fetch()
            guard let self else { return }
            checking = false
            lastChecked = Date()
            Store.settings.set(Date(), forKey: lastKey)
            guard let found, found.build > Updater.build, found.runsHere else {
                // A build already swapped in stays ready whatever the feed
                // says now.
                if case .ready = stage {} else { stage = .none }
                done(nil)
                return
            }
            done(found)
            take(found)
        }
    }

    /// Fetch it, check it, swap it in — unless one is already on its way,
    /// or one is already in place. A second swap in the same run would pull
    /// the bundle this process is running from out from under it, so the
    /// next launch takes the next one.
    private func take(_ release: Release) {
        switch stage {
        case .fetching, .ready: return
        case .none, .offered: break
        }
        stage = .fetching(release)
        Task.detached(priority: .utility) {
            let worked: Bool
            do {
                try await Swap.install(release)
                worked = true
            } catch {
                worked = false
            }
            await MainActor.run { [weak self] in self?.landed(release, worked: worked) }
        }
    }

    private func landed(_ release: Release, worked: Bool) {
        guard case .fetching(let fetching) = stage, fetching == release else { return }
        stage = worked ? .ready(release) : .offered(release)
        say?(worked
            ? "Search \(release.version) is ready — it's there the next time you open it"
            : "Search \(release.version) is out — it's in Settings")
    }

    /// Quit, and come back as the new one. A shell waits for this process
    /// to be gone before asking macOS to open the bundle again — `open` on a
    /// running app only brings it forward. Quitting goes through NSApp so
    /// everything that is written on the way out is written, the same as ⌘Q.
    func relaunch() {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; shift; exec \"$@\"",
            "sh", String(ProcessInfo.processInfo.processIdentifier),
        ] + Updater.reopen
        try? waiter.run()
        NSApp.terminate(nil)
    }

    /// `open` and what to give it: the bundle, and — for a test run — the
    /// variables that made it a test run, since `open` starts from a fresh
    /// environment and a relaunch must not land on the real data.
    private static var reopen: [String] {
        var arguments = ["/usr/bin/open"]
        for key in ["SEARCH_PROBE", "SEARCH_FEED"] {
            if let value = ProcessInfo.processInfo.environment[key] {
                arguments += ["--env", "\(key)=\(value)"]
            }
        }
        return arguments + [Bundle.main.bundleURL.path]
    }

    private static func fetch() async -> Release? {
        var request = URLRequest(url: feed)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String,
              let build = (json["build"] as? Int) ?? Int(json["build"] as? String ?? ""),
              let archive = link(json["url"]),
              let dmg = link(json["dmg"])
        else { return nil }
        let sha = (json["sha256"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let notes = (json["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Release(
            version: version,
            build: build,
            archive: archive,
            dmg: dmg,
            sha256: sha.flatMap { $0.isEmpty ? nil : $0 },
            notes: notes.flatMap { $0.isEmpty ? nil : $0 },
            minimumSystemVersion: json["minimumSystemVersion"] as? String
        )
    }

    /// An address from the feed: https, unless the feed itself was pointed
    /// at a test server, and on the feed's own host. The ZIP is checked
    /// again by hash and signature before it is ever run, but the DMG is
    /// only ever offered, under the app's own "is out" line - so a feed
    /// that a compromised host or a hijacked DNS answer could redirect must
    /// not be able to point that line at some other address.
    private static func link(_ value: Any?) -> URL? {
        guard let url = (value as? String).flatMap(URL.init(string:)) else { return nil }
        guard url.scheme == "https" || (overridden && url.scheme == "http") else { return nil }
        guard url.host == feed.host else { return nil }
        return url
    }
}

/// The part that touches the disk, off the main thread. Every step checks
/// before anything changes, and the only two things ever removed are the
/// scratch folder it made and the `.old` bundle it set aside.
private enum Swap {
    enum Refused: Error {
        case unsignedHere, readOnly, download, hash, archive, plist, wrongApp, notNewer, unsigned, wrongTeam, move
    }

    /// Where the bundle lives, and so where the new one goes.
    static var target: URL { Bundle.main.bundleURL }

    /// The bundle set aside during a swap: a sibling, so the move is a rename
    /// on the same volume and not a copy.
    static var aside: URL {
        target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".old")
    }

    static func install(_ release: Updater.Release) async throws {
        let files = FileManager.default
        // No Team ID on this build means it was signed ad hoc — a development
        // build. Nothing is ever swapped in under an app that could not be
        // told apart from anything else.
        guard let team = teamID(of: target) else { throw Refused.unsignedHere }
        // The folder the app is in has to take a rename, or nothing here can
        // be done: /Applications owned by another account, a disk image.
        guard files.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw Refused.readOnly
        }

        // A scratch folder on the same volume as the app, so the last move is
        // a rename too. Cleared whatever happens.
        let scratch = (try? files.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true
        )) ?? files.temporaryDirectory.appendingPathComponent("search-update-\(release.build)", isDirectory: true)
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }

        let zip = scratch.appendingPathComponent("Search.zip")
        try await download(release.archive, to: zip)
        if let expected = release.sha256 {
            guard try digest(of: zip) == expected else { throw Refused.hash }
        }
        let unpacked = scratch.appendingPathComponent("unpacked", isDirectory: true)
        try extract(zip, into: unpacked)
        guard let fresh = try files.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" })
        else { throw Refused.archive }
        try verify(fresh, team: team)
        try swap(fresh)
    }

    private static func download(_ url: URL, to file: URL) async throws {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        let (got, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
            throw Refused.download
        }
        // The session's copy lasts only until this returns.
        try FileManager.default.moveItem(at: got, to: file)
    }

    private static func digest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sha = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            sha.update(data: chunk)
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// ditto, the way Archive Utility does it: permissions kept. Quarantine
    /// never comes into it — the app declares no LSFileQuarantineEnabled, so
    /// nothing it downloads carries the flag, and there is none to strip.
    /// Keep it that way: the checking is done here, in verify, not by
    /// Gatekeeper at the next launch.
    private static func extract(_ zip: URL, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw Refused.archive }
    }

    /// A bundle is not trusted because it arrived. It is trusted because it
    /// is this app, newer, with a signature that holds up under the strict
    /// check for every architecture, from the same team as the one running.
    private static func verify(_ bundle: URL, team: String) throws {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw Refused.plist }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw Refused.wrongApp
        }
        guard Int(info["CFBundleVersion"] as? String ?? "") ?? 0 > Updater.build else {
            throw Refused.notNewer
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            throw Refused.unsigned
        }
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(code, strict, nil) == errSecSuccess else { throw Refused.unsigned }
        guard teamID(of: bundle) == team else { throw Refused.wrongTeam }
    }

    /// The team that signed a bundle, as the system reads it — nil for an
    /// ad-hoc signature, or none.
    private static func teamID(of bundle: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            return nil
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let signing = info as? [String: Any]
        else { return nil }
        return signing[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Two renames, and the first one undone if the second fails. The app
    /// that is running keeps its files: the kernel follows the rename, so it
    /// goes on running from `.old` — and validating as itself, which is what
    /// its keychain items are checked against — until it quits.
    private static func swap(_ fresh: URL) throws {
        let files = FileManager.default
        sweep()
        guard !files.fileExists(atPath: aside.path) else { throw Refused.move }
        try files.moveItem(at: target, to: aside)
        do {
            try files.moveItem(at: fresh, to: target)
        } catch {
            try? files.moveItem(at: aside, to: target)
            throw Refused.move
        }
    }

    /// Removes the bundle a swap set aside, once nothing runs from it any
    /// more: at quit, and at the next launch in case the quit was not a
    /// clean one. Only ever a `.old` that is this app; nothing else is ever
    /// deleted here.
    static func sweep() {
        let plist = aside.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier
        else { return }
        try? FileManager.default.removeItem(at: aside)
    }
}
