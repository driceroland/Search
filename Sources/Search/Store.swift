import Foundation
import WebKit

// Where everything this browser keeps is kept.
//
// One place, and one rule: a run started for testing never touches the folder
// or the settings of the browser somebody is actually using. Sharing them once
// cost a person their pinned tabs, which is not a mistake worth being able to
// make twice.

enum Store {
    /// A personal build uses its own files and keychain labels, alongside Search.
    static let localProfile = Bundle.main.object(forInfoDictionaryKey: "SearchLocalProfile") as? String
    static var dataProfile: String? { world ?? localProfile }

    /// A run is a test run if it says so, or if it is being run straight out
    /// of the build folder rather than from an installed app. The second half
    /// is not belt and braces: a development build launched from a terminal
    /// once wrote over somebody's real session, and asking a person to
    /// remember a flag is not a safeguard.
    static var testing: Bool {
        if ProcessInfo.processInfo.environment["SEARCH_PROBE"] != nil { return true }
        return Bundle.main.executablePath?.contains("/.build/") == true
    }

    /// Which test world a test run lives in. SEARCH_PROBE=1, or a run from
    /// the build folder, is the test world, "Search (test)". SEARCH_PROBE=
    /// <name> is a world of its own, "Search (<name>)", with settings and
    /// WebKit stores of its own: two sessions testing at once, or a
    /// measurement that needs a browser nobody has installed anything in,
    /// never borrow each other's. Nil for the browser somebody is using.
    static let world: String? = {
        guard testing else { return nil }
        let asked = (ProcessInfo.processInfo.environment["SEARCH_PROBE"] ?? "").lowercased()
            .filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        return asked.isEmpty || asked == "1" || asked == "test" ? "test" : asked
    }()

    /// A test run there to be weighed and timed rather than driven
    /// (SEARCH_MEASURE beside SEARCH_PROBE). It keeps what the shipped
    /// browser does where test runs otherwise differ — hidden pages slowed
    /// the way WebKit slows them, App Nap left to macOS — so what gets
    /// measured is what people get.
    static var measuring: Bool {
        testing && ProcessInfo.processInfo.environment["SEARCH_MEASURE"] != nil
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
        let set = NSSelectorFromString("_setResourceLoadStatisticsEnabled:")
        guard store.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(store.method(for: set), to: Setter.self)(store, set, !keepsSignIns)
    }

    /// A test copy of the app under a bundle id of its own has a WebKit
    /// container of its own too, so it can use WebKit's default store and
    /// extension configuration — the ones the real browser uses, which
    /// differ from stores made by identifier in how long extension workers
    /// are let live.
    static var ownContainer: Bool {
        (Bundle.main.bundleIdentifier ?? "") != "com.officecommun.search"
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

    /// The app was called Office Browser until September 2026. Everything it
    /// kept — the session, the pins, the history, what is hidden on each site
    /// — moves to the new name the first time the new name runs, and the
    /// settings are copied across. Nothing is left to be lost.
    static let folder: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let home = support.appendingPathComponent(dataProfile.map { "Search (\($0))" } ?? "Search", isDirectory: true)
        if !testing, localProfile == nil {
            let old = support.appendingPathComponent("Office Browser", isDirectory: true)
            let files = FileManager.default
            if !files.fileExists(atPath: home.path), files.fileExists(atPath: old.path) {
                try? files.moveItem(at: old, to: home)
            }
        }
        return home
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

    /// Settings live apart too: a test that changes what the tabs wear or
    /// where the tabs go must not change yours.
    static let settings: UserDefaults = {
        guard testing else {
            if localProfile == nil { carryOver(into: .standard) }
            return .standard
        }
        let suite = world == "test" ? "com.officecommun.search.test" : "com.officecommun.search.test.\(world ?? "")"
        return UserDefaults(suiteName: suite) ?? .standard
    }()

    /// The old bundle's defaults, read once and written under the new one.
    private static func carryOver(into fresh: UserDefaults) {
        guard !fresh.bool(forKey: "carried"),
              let old = UserDefaults(suiteName: "com.driceroland.officebrowser")
        else { return }
        for (key, value) in old.dictionaryRepresentation()
        where fresh.object(forKey: key) == nil && !key.hasPrefix("NS") && !key.hasPrefix("Apple") {
            fresh.set(value, forKey: key)
        }
        // The window comes back where it was, under its new name.
        if let frame = old.string(forKey: "NSWindow Frame office-browser") {
            fresh.set(frame, forKey: "NSWindow Frame search")
        }
        fresh.set(true, forKey: "carried")
    }
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
    private static let queue = DispatchQueue(label: "search.disk", qos: .utility)
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

    /// Everything asked for so far, written — for the way out.
    static func drain() {
        queue.sync {}
    }
}
