import AppKit

// Email links, written in a webmail. A mailto: link — clicked in a page,
// from another app once Search is the Mac's email app, or Search's own Send
// Feedback — opens that webmail's compose page in a tab instead of the
// Mac's mail app, for whoever chose one in Settings › General › Email links
// open in. Off unless asked for: None keeps the Mac's mail app, as before.

/// The webmail email links open in (Settings › General).
enum Webmail: String, CaseIterable, Identifiable {
    case none, gmail, outlook, fastmail, proton

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Your mail app"
        case .gmail: return "Gmail"
        case .outlook: return "Outlook.com"
        case .fastmail: return "Fastmail"
        case .proton: return "Proton Mail"
        }
    }

    /// The compose page with the draft filled in, or nil for None.
    ///
    /// Gmail, Outlook and Fastmail take each field as its own parameter.
    /// Proton Mail takes a whole mailto: in the fragment, the way its own
    /// handler (`/inbox#mailto=%s`) does, and reads to, cc, bcc, subject and
    /// body out of it. Every value is percent-encoded down to the unreserved
    /// characters, so nothing in one field can start another.
    func compose(_ draft: MailDraft) -> URL? {
        let fitted = draft.fitted { compose(exactly: $0) }
        return compose(exactly: fitted)
    }

    private func compose(exactly draft: MailDraft) -> URL? {
        let to = draft.to.joined(separator: ","), cc = draft.cc.joined(separator: ","), bcc = draft.bcc.joined(separator: ",")
        func query(_ pairs: [(String, String)]) -> String {
            pairs.filter { !$0.1.isEmpty }.map { "\($0.0)=\(MailDraft.encode($0.1))" }.joined(separator: "&")
        }
        switch self {
        case .none:
            return nil
        case .gmail:
            let rest = query([("to", to), ("cc", cc), ("bcc", bcc), ("su", draft.subject), ("body", draft.body)])
            return URL(string: "https://mail.google.com/mail/?view=cm&fs=1" + (rest.isEmpty ? "" : "&" + rest))
        case .outlook:
            let rest = query([("to", to), ("cc", cc), ("bcc", bcc), ("subject", draft.subject), ("body", draft.body)])
            return URL(string: "https://outlook.live.com/mail/0/deeplink/compose" + (rest.isEmpty ? "" : "?" + rest))
        case .fastmail:
            // Fastmail's compose route takes to, cc, bcc, subject and body
            // from its query (the same route its own mailto handler,
            // /mail/compose?mailto=%s, goes through).
            let rest = query([("to", to), ("cc", cc), ("bcc", bcc), ("subject", draft.subject), ("body", draft.body)])
            return URL(string: "https://app.fastmail.com/mail/compose" + (rest.isEmpty ? "" : "?" + rest))
        case .proton:
            return URL(string: "https://mail.proton.me/inbox#mailto=" + MailDraft.encode(draft.mailto))
        }
    }
}

/// A mailto: link read as RFC 6068 has it: addresses before the `?`, comma
/// separated, then `to`, `cc`, `bcc`, `subject` and `body` fields, every part
/// percent-encoded. `+` is a plus (user+tag@example.com), never a space.
/// Other fields (In-Reply-To and the rest) are left out: a webmail's compose
/// page has nowhere to put them.
struct MailDraft: Equatable {
    var to: [String] = []
    var cc: [String] = []
    var bcc: [String] = []
    var subject = ""
    var body = ""

    /// Most of each kept, beyond which a link is no longer a draft someone
    /// wrote by hand but something stuffed: browsers and webmails start
    /// refusing addresses somewhere past 8 KB, Gmail around there.
    static let maxRecipients = 50
    static let maxSubject = 500
    static let maxLength = 8000

    init(to: [String] = [], cc: [String] = [], bcc: [String] = [], subject: String = "", body: String = "") {
        self.to = to; self.cc = cc; self.bcc = bcc; self.subject = subject; self.body = body
    }

    init?(_ url: URL) { self.init(string: url.absoluteString) }

    init?(string: String) {
        guard string.count >= 7, string.prefix(7).lowercased() == "mailto:" else { return nil }
        var rest = Substring(string.dropFirst(7))
        // A fragment means nothing to a mailto (RFC 6068 §2); a `#` in a
        // field is written %23.
        if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }
        let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        to = MailDraft.addresses(parts.first.map(String.init) ?? "")
        var subject: String?, body: String?
        if parts.count > 1 {
            for field in parts[1].split(separator: "&") {
                let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = MailDraft.decode(String(pair[0])).lowercased()
                let value = pair.count > 1 ? String(pair[1]) : ""
                switch name {
                case "to": to += MailDraft.addresses(value)
                case "cc": cc += MailDraft.addresses(value)
                case "bcc": bcc += MailDraft.addresses(value)
                // The first of each: a second subject can't be meant.
                case "subject": if subject == nil { subject = MailDraft.decode(value) }
                case "body": if body == nil { body = MailDraft.decode(value) }
                default: break
                }
            }
        }
        to = Array(to.prefix(MailDraft.maxRecipients))
        cc = Array(cc.prefix(MailDraft.maxRecipients))
        bcc = Array(bcc.prefix(MailDraft.maxRecipients))
        // One line: a subject has no line breaks to keep.
        self.subject = String((subject ?? "").replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines).joined(separator: " ").prefix(MailDraft.maxSubject))
        // Line breaks come as CRLF (%0D%0A); a webmail's text box wants \n.
        self.body = (body ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// The draft as a clean mailto: again, every value encoded (for Proton
    /// Mail, and for handing on).
    var mailto: String {
        var fields: [String] = []
        if !cc.isEmpty { fields.append("cc=" + MailDraft.encode(cc.joined(separator: ","), keeping: "@,+")) }
        if !bcc.isEmpty { fields.append("bcc=" + MailDraft.encode(bcc.joined(separator: ","), keeping: "@,+")) }
        if !subject.isEmpty { fields.append("subject=" + MailDraft.encode(subject)) }
        if !body.isEmpty { fields.append("body=" + MailDraft.encode(body.replacingOccurrences(of: "\n", with: "\r\n"))) }
        return "mailto:" + MailDraft.encode(to.joined(separator: ","), keeping: "@,+")
            + (fields.isEmpty ? "" : "?" + fields.joined(separator: "&"))
    }

    /// The draft with its body shortened, if it must be, until `build`
    /// makes an address no longer than maxLength. Never cut inside a
    /// character, and the rest of the draft as it was.
    func fitted(_ build: (MailDraft) -> URL?) -> MailDraft {
        func fits(_ draft: MailDraft) -> Bool { (build(draft)?.absoluteString.utf8.count ?? 0) <= MailDraft.maxLength }
        guard !fits(self) else { return self }
        var low = 0, high = body.count, best = self
        best.body = ""
        while low <= high {
            let mid = (low + high) / 2
            var trial = self
            trial.body = String(body.prefix(mid))
            if fits(trial) { best = trial; low = mid + 1 } else { high = mid - 1 }
        }
        return best
    }

    // MARK: - encoding

    private static func addresses(_ text: String) -> [String] {
        decode(text).split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            // An address has no line breaks or control characters in it.
            .filter { !$0.isEmpty && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
    }

    /// %XX decoded, UTF-8; text that isn't valid percent-encoding is kept
    /// as it came rather than lost.
    static func decode(_ text: String) -> String { text.removingPercentEncoding ?? text }

    /// Everything but the unreserved characters (RFC 3986) percent-encoded:
    /// `&`, `=`, `#`, `+`, `?`, `%` and spaces included, so a value can't
    /// end its parameter or start another.
    static func encode(_ text: String, keeping extra: String = "") -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        allowed.insert(charactersIn: extra)
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

/// Where an email link goes: the webmail chosen, or the Mac's mail app.
@MainActor
enum Mail {
    /// The compose pages opened, and the links handed to another app, on a
    /// test run (Bench's probe says them; Tests/webmail.py).
    static var seen: [String] = []

    static var webmail: Webmail { Shared.prefs.webmail }

    /// The webmail's compose page for `url`, or nil when none is chosen or
    /// it isn't a mailto: link.
    static func compose(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == "mailto", let draft = MailDraft(url) else { return nil }
        return webmail.compose(draft)
    }

    /// A mailto: Search was handed by macOS with no webmail chosen — it was
    /// made the Mac's email app, and then None picked. It goes to the next
    /// app that takes email links, never back to Search (any copy of it): the
    /// Mac's own default when that isn't Search, else Mail, else the first.
    static func handToSystem(_ url: URL) {
        guard let app = otherMailApp(for: url) else {
            if Store.testing { seen.append("system: none") }
            return
        }
        if Store.testing {
            seen.append("system: " + name(of: app))
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func otherMailApp(for url: URL) -> URL? {
        let ours = Bundle.main.bundleIdentifier ?? "com.officecommun.search"
        func isOurs(_ app: URL) -> Bool {
            app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
                || Bundle(url: app)?.bundleIdentifier.map { $0 == ours || $0.hasPrefix("com.officecommun.search") } == true
        }
        if let first = NSWorkspace.shared.urlForApplication(toOpen: url), !isOurs(first) { return first }
        let others = NSWorkspace.shared.urlsForApplications(toOpen: url).filter { !isOurs($0) }
        return others.first { Bundle(url: $0)?.bundleIdentifier == "com.apple.mail" } ?? others.first
    }

    // MARK: - being the email app

    private static let probe = URL(string: "mailto:someone@example.com")!

    /// The app the Mac sends email links to now, by name.
    static var handlerName: String? {
        NSWorkspace.shared.urlForApplication(toOpen: probe).map(name(of:))
    }

    /// True when this app is where email links from other apps go.
    static var isDefault: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Asks macOS to send mailto: here. Only from the button in Settings:
    /// macOS asks the person to confirm, and the answer comes through
    /// `done`, on the main thread. Never from a test run.
    static func becomeDefault(_ done: @escaping @MainActor (Bool) -> Void) {
        guard !Store.testing else { done(false); return }
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto") { error in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(error == nil) } }
        }
    }

    private static func name(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }
}

extension Browser {
    /// A mailto: clicked in one of this window's pages, written in the
    /// webmail: its compose page in a tab of its own beside the page, in
    /// front. Never a private tab, even from one: a webmail you write in is
    /// the one you're signed in to. A small window for links is for links
    /// from other apps; this is one from here.
    func openCompose(_ compose: URL, beside source: Tab?) {
        if Store.testing { Mail.seen.append("page: " + compose.absoluteString) }
        if websitePopup {
            Browsers.ensureWindow().openCompose(compose, beside: nil)
            return
        }
        open(compose, foreground: true, from: source?.shy == true ? nil : source, link: true)
    }
}
