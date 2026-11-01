import CryptoKit
import Foundation
import WebKit

// Where everything this browser keeps is kept.
//
// One place, and one rule: a run started for testing never touches the folder
// or the settings of the browser somebody is actually using. Sharing them once
// cost a person their pinned tabs, which is not a mistake worth being able to
// make twice.

enum Store {
    /// A run is a test run if it says so, or if it is being run straight out
    /// of the build folder rather than from an installed app. The second half
    /// is not belt and braces: a development build launched from a terminal
    /// once wrote over somebody's real session, and asking a person to
    /// remember a flag is not a safeguard.
    static var testing: Bool {
        if ProcessInfo.processInfo.environment["SHY_PROBE"] != nil { return true }
        // `swift test` runs inside Xcode's xctest, not out of .build: a test
        // class that set no SHY_PROBE wrote to the real browser's settings.
        if NSClassFromString("XCTestCase") != nil { return true }
        return Bundle.main.executablePath?.contains("/.build/") == true
    }

    /// Which test world a test run lives in. SHY_PROBE=1, or a run from
    /// the build folder, is the test world, "Shy (test)". SHY_PROBE=
    /// <name> is a world of its own, "Shy (<name>)", with settings and
    /// WebKit stores of its own: two sessions testing at once, or a
    /// measurement that needs a browser nobody has installed anything in,
    /// never borrow each other's. Nil for the browser somebody is using.
    static let world: String? = {
        guard testing else { return nil }
        let asked = (ProcessInfo.processInfo.environment["SHY_PROBE"] ?? "").lowercased()
            .filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        return asked.isEmpty || asked == "1" || asked == "test" ? "test" : asked
    }()

    /// A test run there to be weighed and timed rather than driven
    /// (SHY_MEASURE beside SHY_PROBE). It keeps what the shipped
    /// browser does where test runs otherwise differ — hidden pages slowed
    /// the way WebKit slows them, App Nap left to macOS — so what gets
    /// measured is what people get.
    static var measuring: Bool {
        testing && ProcessInfo.processInfo.environment["SHY_MEASURE"] != nil
    }

    /// Cookies, sign-ins, caches. WebKit keeps its default store per bundle,
    /// not per folder, so a test run got every site already signed in — and
    /// "sign out of everything" in a test run signed the real browser out.
    /// A test run gets a store of its own, under a fixed name so it persists
    /// between probes the way the real one does. Wiping the test store is
    /// then as safe as wiping its folder.
    static var websites: WKWebsiteDataStore {
        guard testing, !ownContainer else { return .default() }
        return WKWebsiteDataStore(forIdentifier: probeStore(1))
    }

    /// Settings › Privacy › Prevent cross-site tracking, turned off. WebKit's
    /// tracking prevention, as in Safari, clears what a site it has seen
    /// redirect you — a sign-in through Google or Apple, say — left in local
    /// storage once you haven't opened it for a week or a month of use, and a
    /// site it counts as a tracker loses its cookies too: you are signed out.
    /// Turned off, that stops, and so does the rest of it: a site framed in
    /// another gets its cookies again, so trackers can follow you across
    /// sites, as in Chrome. On unless turned off; until then its flag is not
    /// touched.
    @MainActor static var keepsSignIns = false {
        didSet {
            guard keepsSignIns != oldValue else { return }
            Spaces.everyStore.forEach(followSignIns)
        }
    }

    /// The switch through a name outside the public framework — Safari's
    /// "Prevent cross-site tracking" is the same one.
    @MainActor static func followSignIns(_ store: WKWebsiteDataStore) {
        followCookies(store)
        let set = NSSelectorFromString("_setResourceLoadStatisticsEnabled:")
        guard store.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(store.method(for: set), to: Setter.self)(store, set, !keepsSignIns)
    }

    /// Off, the store's cookie policy is Always too: left as it was, it took
    /// cookies only from the page's own site, and a site framed in another —
    /// a Kaltura video in a Brightspace course — still got none. WebKit keeps
    /// the policy with the store, so it is set back when the switch is on, and
    /// at launch for every store, which an earlier run may have left at Always.
    @MainActor static func followCookies(_ store: WKWebsiteDataStore) {
        let jar = store.httpCookieStore
        let policy = NSSelectorFromString("_setCookieAcceptPolicy:completionHandler:")
        guard jar.responds(to: policy) else { return }
        typealias Policy = @convention(c) (AnyObject, Selector, UInt, @escaping @convention(block) () -> Void) -> Void
        let accept: HTTPCookie.AcceptPolicy = keepsSignIns ? .always : .onlyFromMainDocumentDomain
        unsafeBitCast(jar.method(for: policy), to: Policy.self)(jar, policy, accept.rawValue) {}
    }

    /// A test copy of the app under a bundle id of its own has a WebKit
    /// container of its own too, so it can use WebKit's default store and
    /// extension configuration — the ones the real browser uses, which
    /// differ from stores made by identifier in how long extension workers
    /// are let live.
    static var ownContainer: Bool {
        (Bundle.main.bundleIdentifier ?? "") != "io.github.nxcco.shy"
    }

    /// The fixed identifiers of a test world's WebKit stores: 1 for websites,
    /// 2 for extensions. The test world's are 5E4C0000-0000-4000-8000-00000000000k,
    /// the ones fresh.sh wipes; a named world puts a hash of its name (FNV-1a,
    /// 32 bits) in place of the second and third groups of zeros, so each
    /// keeps its own from one run to the next.
    static func probeStore(_ kind: UInt32) -> UUID {
        var hash: UInt32 = 0
        if let world, world != "test" {
            hash = 2_166_136_261
            for byte in world.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        }
        let text = String(format: "5E4C%04X-%04X-4000-8000-%012X", hash >> 16, hash & 0xFFFF, kind)
        return UUID(uuidString: text)!
    }

    /// The WebKit store a profile or a space keeps its sign-ins in. WebKit
    /// keeps stores made by identifier per bundle, not per folder, so a test
    /// world holding a real profile's or space's id — its profiles.json or
    /// spaces.json copied in — would have opened that one's real cookies,
    /// and the bench could drive them. A test world's are named instead from
    /// the world and the id through SHA-256, which nothing can turn back into
    /// a real one. A copy under a bundle id of its own has a WebKit folder of
    /// its own, and keeps the ids as they are.
    static func webKitID(_ id: UUID) -> UUID {
        guard testing, !ownContainer, let world else { return id }
        var bytes = Array(SHA256.hash(data: Data("shy-store:\(world):\(id.uuidString)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Application Support/Shy, or "Shy (<world>)" for a test world. Shy
    /// starts with a folder of its own: nothing is carried over from another
    /// browser's.
    static let folder: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(world.map { "Shy (\($0))" } ?? "Shy", isDirectory: true)
    }()

    static func file(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    /// A file that didn't decode is set aside rather than overwritten the
    /// next time something is saved over it — bookmarks, history and a
    /// session are the kind of thing nobody wants to lose to a bad read with
    /// no trace of what was there. Failing to move it is fine: the read
    /// already came back empty either way, and there's nothing further to
    /// do about a folder that won't take a rename.
    static func quarantine(_ file: URL) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = file.deletingLastPathComponent()
            .appendingPathComponent("\(file.deletingPathExtension().lastPathComponent).unreadable-\(stamp).json")
        try? FileManager.default.moveItem(at: file, to: aside)
    }

    /// The copies `quarantine` set aside whose names pass `matching`, gone:
    /// for Clear History, and for a profile deleted (its id in the name).
    static func forgetUnreadable(_ matching: (String) -> Bool) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.contains(".unreadable-") && matching(name) {
            try? FileManager.default.removeItem(at: file(name))
        }
    }

    /// Settings live apart too: a test that changes what the tabs wear or
    /// where the tabs go must not change yours.
    static let settings: UserDefaults = {
        guard testing else { return .standard }
        let suite = world == "test" ? "io.github.nxcco.shy.test" : "io.github.nxcco.shy.test.\(world ?? "")"
        return UserDefaults(suiteName: suite) ?? .standard
    }()
}

/// Files written in the background, one at a time and the newest last.
///
/// Each save used to go to a concurrent queue on its own: two saves of the
/// same file a moment apart could land in either order, and the session
/// written at quit could be overwritten by an older one still on its way —
/// yesterday's tabs coming back instead of today's. Here every write joins
/// one serial queue, and a write that a newer one of the same file has
/// overtaken is dropped, including when the newer one was written at once
/// on the way out.
enum Disk {
    private static let queue = DispatchQueue(label: "shy.disk", qos: .utility)
    private static let lock = NSLock()
    /// The newest write asked for, by file.
    nonisolated(unsafe) private static var newest: [URL: Int] = [:]
    nonisolated(unsafe) private static var count = 0

    /// `encode` runs where the write does. `now` writes on the calling
    /// thread: quitting doesn't wait for a queue.
    static func write(_ file: URL, now: Bool = false, _ encode: @escaping @Sendable () -> Data?) {
        lock.lock()
        count += 1
        let turn = count
        newest[file] = turn
        lock.unlock()
        let put: @Sendable () -> Void = {
            guard let data = encode() else { return }
            lock.lock()
            defer { lock.unlock() }
            // Overtaken: something newer of this file was asked for since.
            guard newest[file] == turn else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        if now { put() } else { queue.async(execute: put) }
    }

    /// The file gone, after any write of it already asked for — and none
    /// asked for before this lands it again.
    static func remove(_ file: URL) {
        lock.lock()
        count += 1
        let turn = count
        newest[file] = turn
        lock.unlock()
        queue.async {
            lock.lock()
            defer { lock.unlock() }
            guard newest[file] == turn else { return }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Everything asked for so far, written — for the way out.
    static func drain() {
        queue.sync {}
    }
}
