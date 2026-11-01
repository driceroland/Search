import Foundation
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
    /// The profile it is kept in (see Profiles.swift).
    var profile = Profile.personalID

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
    /// The profile it is kept in (see Profiles.swift).
    var profile = Profile.personalID

    var id: String { host + "\u{1}" + user }
}

enum Vault {
    /// What every item of ours is tagged with. A test run tags its own, so a
    /// password saved while trying something never sits among the real ones.
    private static let base = Store.world.map { "Shy (\($0))" } ?? "Shy"

    /// Each profile's drawer: Personal's is what every item was tagged with
    /// before there were profiles, so none of those moves.
    private static func label(_ profile: UUID) -> String {
        profile == Profile.personalID ? base : "\(base) · \(profile.uuidString)"
    }

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
    static func kept(for host: String, in profile: UUID) -> [Kept] {
        rows(where: [kSecAttrServer as String: host], in: profile).compactMap { kept(from: $0, in: profile) }
    }

    /// The keychain matches a server name exactly, and a sign-in rarely lives
    /// on the page you saved it from — accounts.example.com asks, and the
    /// password was kept for example.com. So the site is matched as a site:
    /// the host first, then anything sharing its registrable domain.
    static func kept(matching host: String, in profile: UUID) -> [Kept] {
        let domain = registrable(host)
        let exact = kept(for: host, in: profile)
        let wider = rows(where: [:], in: profile)
            .filter { ($0[kSecAttrServer as String] as? String).map { $0 != host && registrable($0) == domain } ?? false }
            .compactMap { kept(from: $0, in: profile) }
        return (exact + wider).sorted { ($0.used ?? .distantPast) > ($1.used ?? .distantPast) }
    }

    /// Everything this app holds, as the list needs it: no secrets. Each one
    /// is `secret(of:)`, a call of its own, and only when it is asked for.
    /// Read on demand and never kept in a property.
    static func all(in profile: UUID) -> [Kept] {
        rows(where: [:], in: profile).compactMap { kept(from: $0, in: profile) }
            .sorted { $0.host == $1.host ? $0.user < $1.user : $0.host < $1.host }
    }

    /// The items' attributes — no secrets — narrowed by whatever is given.
    private static func rows(where extra: [String: Any], in profile: UUID) -> [[String: Any]] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label(profile),
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
    private static func secret(host: String, user: String, in profile: UUID) -> String? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: label(profile),
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
    static func secret(of kept: Kept) -> String? { secret(host: kept.host, user: kept.user, in: kept.profile) }

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
        return Login(host: kept.host, user: kept.user, password: password, used: kept.used, clear: kept.clear, profile: kept.profile)
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
    private static func kept(from row: [String: Any], in profile: UUID) -> Kept? {
        guard let host = row[kSecAttrServer as String] as? String else { return nil }
        let user = account(of: row)
        let (used, clear) = noted(row)
        return Kept(host: host, user: user, used: used, clear: clear, profile: profile)
    }

    // MARK: - writing

    @discardableResult
    static func save(host: String, user: String, password: String, used: Date? = nil, clear: Bool = false, in profile: UUID) -> Bool {
        guard !host.isEmpty, !password.isEmpty,
              let data = password.data(using: .utf8)
        else { return false }

        // Ours only. Server and account alone also match what other apps
        // keep for the same site — git's token for github.com under your
        // username — and an update would write this password over it.
        var identity: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecAttrLabel as String: label(profile),
        ]
        // The keychain tells two items apart by server, account and the like,
        // not by label: another profile's for the same account would make
        // this one a duplicate. The profile's id, in a field that is part of
        // that key, keeps them apart. Personal's items have none, as before.
        if profile != Profile.personalID { identity[kSecAttrSecurityDomain as String] = profile.uuidString }
        // A web form's, which also keeps ours apart from another app's item
        // in the keychain's eyes: one for the same server, account and
        // protocol — git's — makes adding ours fail as a duplicate.
        var fields: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: label(profile),
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
        save(host: login.host, user: login.user, password: login.password, used: Date(), clear: login.clear, in: login.profile)
    }

    /// Whether the keychain let it go: Remove All… counts only those.
    @discardableResult
    static func forget(host: String, user: String, in profile: UUID) -> Bool {
        SecItemDelete([
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecAttrLabel as String: label(profile),
        ] as CFDictionary) == errSecSuccess
    }

    /// Every password a profile kept, gone with the profile. Never
    /// Personal's, whose drawer is the one there always was.
    static func forgetAll(in profile: UUID) {
        guard profile != Profile.personalID else { return }
        all(in: profile).forEach { forget(host: $0.host, user: $0.user, in: profile) }
    }

    // MARK: - sites that asked not to be asked

    /// Each profile's own, as its passwords are: Personal's under the key
    /// there always was, another's gone with it (SiteMemory.forget).
    private static func neverKey(_ profile: UUID) -> String { SiteMemory.key("passwords.never", profile) }

    static func never(in profile: UUID) -> Set<String> {
        Set(Store.settings.stringArray(forKey: neverKey(profile)) ?? [])
    }

    static func setNever(_ hosts: Set<String>, in profile: UUID) {
        Store.settings.set(Array(hosts).sorted(), forKey: neverKey(profile))
    }

    static func never(_ host: String, in profile: UUID) { setNever(never(in: profile).union([host]), in: profile) }
    static func isNever(_ host: String, in profile: UUID) -> Bool {
        let never = never(in: profile)
        return never.contains(host) || never.contains(registrable(host))
    }

    // MARK: - showing one

    /// A password is shown only to the person the Mac belongs to. Touch ID,
    /// the watch, or the account password — whatever the Mac itself takes.
    @MainActor static func prove(_ reason: String, _ done: @escaping (Bool) -> Void) {
        // A test run answers as it answers Ask.sure (`ui confirm on|off`).
        if Store.testing, let yes = Ask.testing {
            done(yes)
            return
        }
        let context = LAContext()
        var trouble: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &trouble) else {
            // No way to ask at all — a Mac with no password set. Then there is
            // nothing to prove. Anything else that stops the question is a no:
            // a password is never shown because the asking broke.
            done(trouble?.code == LAError.passcodeNotSet.rawValue)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { done(ok) }
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
    static func take(csv text: String, in profile: UUID) -> (kept: Int, skipped: Int) {
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
            save(host: host, user: row[userAt], password: password, clear: clear, in: profile) ? (kept += 1) : (skipped += 1)
        }
        return (kept, skipped)
    }

    /// Called on the import worker. Parsing finishes before any keychain
    /// writes; cancellation between writes preserves an exact partial count.
    static func take(csv text: String, control: ImportFile.Control, in profile: UUID) -> (kept: Int, skipped: Int) {
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
            save(host: host, user: row[userAt], password: password, clear: clear, in: profile) ? (kept += 1) : (skipped += 1)
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
