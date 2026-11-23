import Foundation
import AppKit
import Security
import LocalAuthentication

// Where passwords live: the macOS keychain, under this app's own name, as
// internet passwords keyed by site and account. Nothing is written to disk by
// this app in any other form, and nothing is ever logged.
//
// This is the same coffer Safari's are in, but not the same drawer: Apple keeps
// Safari's behind an entitlement no other browser gets. So these are Office
// Browser's — in the system's vault, unlocked with the Mac, shown with Touch ID.

struct Login: Identifiable, Equatable, Hashable {
    var host: String
    var user: String
    var password: String
    /// When it was last used to sign in, if known. Newest first in lists.
    var used: Date?
    /// Kept from a page sent in the clear, over plain http. Only these are
    /// offered on such a page: one kept from https, or from before this was
    /// written down, is never handed to a page anyone on the way could have
    /// written.
    var clear = false

    var id: String { host + "\u{1}" + user }
}

/// One item as a list needs it: the site, the account, and when it was last
/// used, without the secret. Reading a secret is one keychain call, and the
/// list asks for one only when a password is shown or copied: a drawer of four
/// hundred kept passwords would otherwise be four hundred calls before the
/// panel could draw itself. Nothing that writes a password or fills one into a
/// page takes this type, so a row cannot be handed on as though it held one.
struct Kept: Identifiable, Equatable, Hashable {
    var host: String
    var user: String
    /// When it was last used to sign in, if known. Newest first in lists.
    var used: Date?
    /// Kept from a page sent in the clear, over plain http. See `Login`.
    var clear = false

    var id: String { host + "\u{1}" + user }
}

enum Vault {
    /// What every item of ours is tagged with. A test run tags its own, so a
    /// password saved while trying something never sits among the real ones.
    private static let label = Store.world.map { "Search (\($0))" } ?? "Search"

    // MARK: - reading

    /// The keychain will list many items, or hand over one secret — not
    /// both in one call. Asked for every item's data at once it answers
    /// errSecParam, and it did so quietly enough that for a while this app
    /// saved passwords it could never read back. So: the list first, without
    /// secrets, then each secret on its own.

    /// What is kept for a host, exactly, without secrets. See
    /// `kept(matching:)` for the version that also looks across a site's
    /// subdomains.
    ///
    /// No secret is read here, and none is read for a list. Every secret
    /// read is the keychain's to allow: one kept by a build signed by
    /// someone else — the release, before a build of your own — asks for
    /// the login password, once per item, and a Deny is never remembered.
    /// Reading every account's secret to draw the list under a sign-in box
    /// asked for each of them each time the caret went in.
    static func kept(for host: String) -> [Kept] {
        rows(where: [kSecAttrServer as String: host]).compactMap(kept(from:))
    }

    /// Whether an account kept for `server` is offered on `host`: the same
    /// host, or with `wide`, another host of the same site.
    static func belongs(_ server: String, to host: String, wide: Bool = true, domain: String? = nil) -> Bool {
        server == host || (wide && registrable(server) == (domain ?? registrable(host)))
    }

    /// The keychain matches a server name exactly, and a sign-in rarely lives
    /// on the page you saved it from — accounts.example.com asks, and the
    /// password was kept for example.com. So the site is matched as a site:
    /// the host first, then anything sharing its registrable domain.
    ///
    /// `wide` false: the host alone. For a box that only might be a sign-in's
    /// — accounts.google.com's Gmail account has nothing to do in a project's
    /// name on console.cloud.google.com.
    static func kept(matching host: String, wide: Bool = true) -> [Kept] {
        let domain = registrable(host)
        let exact = kept(for: host)
        let wider = !wide ? [] : rows(where: [:])
            .filter { ($0[kSecAttrServer as String] as? String).map { $0 != host && belongs($0, to: host, domain: domain) } ?? false }
            .compactMap(kept(from:))
        // The host's own accounts first, the site's others after them: each
        // group newest first.
        let newest: (Kept, Kept) -> Bool = { ($0.used ?? .distantPast) > ($1.used ?? .distantPast) }
        return exact.sorted(by: newest) + wider.sorted(by: newest)
    }

    /// Everything this app holds, as the list needs it: no secrets. Each one
    /// is `secret(of:)`, a call of its own, and only when it is asked for.
    /// Read on demand and never kept in a property.
    static func all() -> [Kept] {
        rows(where: [:]).compactMap(kept(from:))
            .sorted { $0.host == $1.host ? $0.user < $1.user : $0.host < $1.host }
    }

    /// The items' attributes — no secrets — narrowed by whatever is given.
    private static func rows(where extra: [String: Any]) -> [[String: Any]] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        extra.forEach { query[$0] = $1 }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else {
            // Nothing kept reads as "not found"; anything else is worth a
            // line in the log, because the panel will only say "nothing".
            if status != errSecItemNotFound { NSLog("Vault: keychain list failed (%d)", status) }
            return []
        }
        return rows
    }

    /// One item's secret, by the two things that name it.
    private static func secret(host: String, user: String) -> String? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            if status != errSecItemNotFound { NSLog("Vault: keychain read failed (%d)", status) }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// One item's secret, where a list holds only the item: read when a
    /// password is shown or copied, and never as part of a list.
    static func secret(of kept: Kept) -> String? { secret(host: kept.host, user: kept.user) }

    /// What an item's attributes say beyond its name: when it was last used,
    /// and whether it was kept from a page sent in the clear.
    private static func noted(_ row: [String: Any]) -> (used: Date?, clear: Bool) {
        // The keychain has no "last used" of its own; it rides in the comment.
        let used = (row[kSecAttrComment as String] as? String)
            .flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        let clear = (row[kSecAttrProtocol as String] as? String) == (kSecAttrProtocolHTTP as String)
        return (used, clear)
    }

    /// One item with its secret, for the paths that hand a password over:
    /// filling a sign-in in, and telling whether one is already kept. One
    /// keychain read, for the one account picked.
    static func login(_ kept: Kept) -> Login? {
        guard let password = secret(of: kept) else { return nil }
        return Login(host: kept.host, user: kept.user, password: password, used: kept.used, clear: kept.clear)
    }

    /// The account an item is kept under. A sign-in with a password box
    /// alone — an access code, a dashboard's — is kept under no name, and
    /// the keychain lists such an item with no account at all, not an
    /// empty one: read as missing, it was saved and never offered again,
    /// nor shown in Settings, nor forgotten.
    private static func account(of row: [String: Any]) -> String {
        row[kSecAttrAccount as String] as? String ?? ""
    }

    /// One item without its secret, for the list.
    private static func kept(from row: [String: Any]) -> Kept? {
        guard let host = row[kSecAttrServer as String] as? String else { return nil }
        let user = account(of: row)
        let (used, clear) = noted(row)
        return Kept(host: host, user: user, used: used, clear: clear)
    }

    // MARK: - writing

    @discardableResult
    static func save(host: String, user: String, password: String, used: Date? = nil, clear: Bool = false) -> Bool {
        guard !host.isEmpty, !password.isEmpty,
              let data = password.data(using: .utf8)
        else { return false }

        // Ours only. Server and account alone also match what other apps
        // keep for the same site — git's token for github.com under your
        // username — and an update would write this password over it.
        let identity: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecAttrLabel as String: label,
        ]
        // A web form's, which also keeps ours apart from another app's item
        // in the keychain's eyes: one for the same server, account and
        // protocol — git's — makes adding ours fail as a duplicate.
        var fields: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: label,
            kSecAttrAuthenticationType as String: kSecAttrAuthenticationTypeHTMLForm,
            kSecAttrProtocol as String: clear ? kSecAttrProtocolHTTP : kSecAttrProtocolHTTPS,
        ]
        if let used { fields[kSecAttrComment as String] = String(used.timeIntervalSince1970) }

        let status = SecItemUpdate(identity as CFDictionary, fields as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var fresh = identity.merging(fields) { _, new in new }
        fresh[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(fresh as CFDictionary, nil) == errSecSuccess
    }

    /// It was just used to sign in. Lists put it first from now on.
    static func touch(_ login: Login) {
        save(host: login.host, user: login.user, password: login.password, used: Date(), clear: login.clear)
    }

    /// Whether the keychain let it go: Remove All… counts only those.
    @discardableResult
    static func forget(host: String, user: String) -> Bool {
        SecItemDelete([
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecAttrLabel as String: label,
        ] as CFDictionary) == errSecSuccess
    }

    // MARK: - sites that asked not to be asked

    private static let neverKey = "passwords.never"

    static var never: Set<String> {
        get { Set(Store.settings.stringArray(forKey: neverKey) ?? []) }
        set { Store.settings.set(Array(newValue).sorted(), forKey: neverKey) }
    }

    static func never(_ host: String) { never.insert(host) }
    static func isNever(_ host: String) -> Bool { never.contains(host) || never.contains(registrable(host)) }

    // MARK: - showing one

    /// A password is shown only to the person the Mac belongs to. Touch ID,
    /// the watch, or the account password — whatever the Mac itself takes.
    @MainActor static func prove(_ reason: String, _ done: @escaping (Bool) -> Void) {
        // A test run may stand in for the Mac saying it can't ask (bench
        // `accounts` "proveError"), to see which of those lets it through.
        if Store.testing, let code = cannotAsk {
            done(nothingToProve(NSError(domain: LAErrorDomain, code: code.rawValue)))
            return
        }
        // A test run answers as it answers Ask.sure (`ui confirm on|off`).
        if Store.testing, let yes = Ask.testing {
            done(yes)
            return
        }
        let context = LAContext()
        var trouble: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &trouble) else {
            done(nothingToProve(trouble))
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }

    /// When the Mac can't ask at all, only a Mac with no password set has
    /// nothing to prove. Any other reason it gives refuses: an error is
    /// never taken for a yes.
    nonisolated static func nothingToProve(_ trouble: NSError?) -> Bool {
        trouble?.domain == LAErrorDomain && trouble?.code == LAError.Code.passcodeNotSet.rawValue
    }

    /// A test run's stand-in for `canEvaluatePolicy` failing with this.
    @MainActor static var cannotAsk: LAError.Code?

    // MARK: - before a fill

    /// Settings › Passwords › Ask for Touch ID before filling (idea 993):
    /// one of Search's own passwords goes into a page only once the Mac's
    /// owner has said so — Touch ID, the watch, or the Mac's password where
    /// there is no Touch ID — as Safari's "Use Touch ID to AutoFill" and
    /// Chrome's "Use your screen lock when filling passwords" ask. Off unless
    /// turned on. Apple Passwords' rows and extensions' fills are theirs to
    /// guard, not this.
    ///
    /// One yes holds for `grace`, Chrome's minute, so a sign-in that wants
    /// its password again a moment later, or a second tab of the same site,
    /// isn't asked twice: for that site alone (its registrable domain), and
    /// for private tabs or ordinary ones, whichever it was said in, never
    /// both. It ends early when the screens sleep or lock, or the session
    /// switches away. Every fill of a kept password goes through
    /// `Browser.choose(_: Kept)`, by click, by Return or by a test's pick,
    /// and that is where it asks: nothing is ever filled on page load.
    @MainActor enum FillProof {
        static let grace: TimeInterval = 60
        /// When the owner last said yes, by site (`key`).
        private static var provenAt: [String: Date] = [:]
        /// A question is up: a second pick meanwhile fills nothing.
        private(set) static var asking = false
        /// How many times a fill asked, for a test run's bench `accounts`.
        private(set) static var asked = 0
        private static var watching = false

        /// What a yes covers: the site's registrable domain, in private
        /// tabs or in ordinary ones.
        static func key(_ host: String, shy: Bool) -> String {
            (shy ? "private " : "") + Vault.registrable(host)
        }

        /// Whether a yes for this site still holds; with no site, whether
        /// any does (a test run's bench `accounts`).
        static func fresh(_ host: String? = nil, shy: Bool = false, at now: Date = Date()) -> Bool {
            let times = host.map { [provenAt[key($0, shy: shy)]].compactMap { $0 } } ?? Array(provenAt.values)
            return times.contains { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) < grace }
        }

        /// `done(true)` once proven, or still within the grace for this site;
        /// `false` for a cancel, a failure, or a question already up.
        static func ask(_ host: String, shy: Bool, _ done: @escaping (Bool) -> Void) {
            if fresh(host, shy: shy) { done(true); return }
            guard !asking else { done(false); return }
            watch()
            asking = true
            if Store.testing { asked += 1 }
            let answered: (Bool) -> Void = { ok in
                asking = false
                if ok { provenAt[key(host, shy: shy)] = Date() }
                done(ok)
            }
            // A test run never puts the Mac's own question on the screen: it
            // answers as `ui confirm on|off` says, and no with nothing set.
            if Store.testing, Ask.testing == nil { answered(false); return }
            Vault.prove("fill your password for \(host)", answered)
        }

        /// The yes is spent: the next fill asks again.
        static func forget() { provenAt = [:] }

        /// A test run's, to look at the grace's end without waiting for it.
        static func age(_ seconds: TimeInterval) {
            guard Store.testing else { return }
            for site in provenAt.keys { provenAt[site] = Date().addingTimeInterval(-seconds) }
        }

        private static func watch() {
            guard !watching else { return }
            watching = true
            let spend: (Notification) -> Void = { _ in MainActor.assumeIsolated { forget() } }
            let workspace = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                         NSWorkspace.sessionDidResignActiveNotification] {
                workspace.addObserver(forName: name, object: nil, queue: .main, using: spend)
            }
            DistributedNotificationCenter.default().addObserver(
                forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: spend)
        }
    }

    // MARK: - the site behind a host

    /// example.com for www.example.com and accounts.example.com; bbc.co.uk
    /// stays bbc.co.uk.
    static func registrable(_ host: String) -> String {
        Registrable.domain(of: host, isSuffix: Passkeys.publicSuffix.map { test in { test($0 as CFString) } })
    }

    static func host(of text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if !value.contains("://") { value = "https://" + value }
        // A website's, and nothing else: an Android app's login in an export
        // (android://…@com.vendor.app/) names a package, which can read as a
        // domain somebody else owns — com.vendor.app, .shopping… — and would
        // be offered to them.
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host()?.lowercased()
        else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - taking in an export

    /// A CSV as Google Password Manager, Chrome or Dia write it: name, url,
    /// username, password, note. Read once, put in the keychain, and the file
    /// is yours to delete — this never keeps a copy of it.
    static func take(csv text: String) -> (kept: Int, skipped: Int) {
        var rows = parse(csv: text)
        guard !rows.isEmpty else { return (0, 0) }

        let header = rows.removeFirst().map { $0.lowercased() }
        func column(_ names: [String]) -> Int? {
            header.firstIndex { names.contains($0) }
        }
        guard let urlAt = column(["url", "login_uri", "website", "site"]),
              let userAt = column(["username", "login_username", "user", "email"]),
              let passAt = column(["password", "login_password"])
        else { return (0, rows.count) }

        var kept = 0, skipped = 0
        for row in rows {
            guard row.count > max(urlAt, max(userAt, passAt)) else {
                skipped += 1
                continue
            }
            let host = self.host(of: row[urlAt])
            let password = row[passAt]
            guard !host.isEmpty, !password.isEmpty else {
                skipped += 1
                continue
            }
            let clear = row[urlAt].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://")
            save(host: host, user: row[userAt], password: password, clear: clear) ? (kept += 1) : (skipped += 1)
        }
        return (kept, skipped)
    }

    /// Called on the import worker. Parsing finishes before any keychain
    /// writes; cancellation between writes preserves an exact partial count.
    static func take(csv text: String, control: ImportFile.Control) -> (kept: Int, skipped: Int) {
        guard !control.isCancelled else { return (0, 0) }
        control.report(.init(message: "Reading password CSV…", completed: 0))
        var rows = parse(csv: text, control: control)
        guard !rows.isEmpty, !control.isCancelled else { return (0, 0) }
        let header = rows.removeFirst().map { $0.lowercased() }
        func column(_ names: [String]) -> Int? { header.firstIndex { names.contains($0) } }
        guard let urlAt = column(["url", "login_uri", "website", "site"]),
              let userAt = column(["username", "login_username", "user", "email"]),
              let passAt = column(["password", "login_password"])
        else { return (0, rows.count) }
        var kept = 0, skipped = 0
        control.report(.init(message: "Saving passwords…", completed: 0, total: rows.count))
        for (index, row) in rows.enumerated() {
            if control.isCancelled { break }
            defer {
                if (index + 1) % 25 == 0 || index + 1 == rows.count {
                    control.report(.init(message: "Saving passwords…", completed: index + 1, total: rows.count))
                }
            }
            guard row.count > max(urlAt, max(userAt, passAt)) else { skipped += 1; continue }
            let host = self.host(of: row[urlAt])
            let password = row[passAt]
            guard !host.isEmpty, !password.isEmpty else { skipped += 1; continue }
            let clear = row[urlAt].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://")
            save(host: host, user: row[userAt], password: password, clear: clear) ? (kept += 1) : (skipped += 1)
        }
        return (kept, skipped)
    }

    /// Quoted fields, doubled quotes inside them, and newlines inside those —
    /// all three turn up in a real export.
    private static func parse(csv text: String, control: ImportFile.Control? = nil) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex
        var scanned = 0

        while index < text.endIndex {
            scanned += 1
            if scanned % 8192 == 0, let control {
                if control.isCancelled { return [] }
                control.report(.init(message: "Reading password CSV…", completed: scanned))
            }
            let c = text[index]
            if quoted {
                if c == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n", "\r\n", "\r":
                    row.append(field)
                    field = ""
                    if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                    row = []
                default: field.append(c)
                }
            }
            index = text.index(after: index)
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        if let control {
            if control.isCancelled { return [] }
            control.report(.init(message: "Reading password CSV…", completed: scanned))
        }
        return rows
    }
}
