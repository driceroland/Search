import Foundation
import Network
import SwiftUI

// News by email, and the iPhone beta: an email field, never more.
//
// Three places offer it: a block at the foot of the What's New card, a page
// at the end of the welcome, and Settings › About › News by email. Nothing
// is sent until a button is pressed, nothing is sent again by itself, and a
// failure says so and waits for another press.
//
// What goes, as JSON in one HTTPS POST to searchbrowser.app (the site's
// api/mac-list.js and api/ios-beta.js, open source beside this):
//   email, a fixed source ("app-whats-new", "app-welcome" or
//   "app-settings"), for the updates list which Mac build this is ("apple"
//   or "intel"), and — from the card and the welcome — whether the iPhone
//   beta was ticked. No identifier, no version, no cookies: the session is
//   ephemeral and the User-Agent and language headers are fixed words.
//
// What stays: two booleans in the settings, "joined the updates list" and
// "asked for the iPhone beta". The address itself is never written to
// disk; it lives in the field while the view does.

enum OptIn {
    /// Where the sign-up was pressed: the site keeps this word with the row.
    enum Source: String, CaseIterable {
        case whatsNew = "app-whats-new"
        case welcome = "app-welcome"
        case settings = "app-settings"
    }

    /// Which list a press joins.
    enum List: Equatable {
        /// News about Search, and — when ticked — the iPhone beta too, in
        /// the same press (the site adds the address to both).
        case news(iPhoneBeta: Bool)
        /// The iPhone beta alone (Settings).
        case iPhoneBeta
    }

    nonisolated static let joinedKey = "optin.joined"
    nonisolated static let betaKey = "optin.iphoneBeta"

    static let privacy = URL(string: "https://searchbrowser.app/privacy")!

    /// The site. SEARCH_OPTIN_URL points a test run at a server of its own;
    /// the browser people use only ever talks to searchbrowser.app.
    static var base: URL {
        if Store.testing, let set = ProcessInfo.processInfo.environment["SEARCH_OPTIN_URL"], let url = URL(string: set) {
            return url
        }
        return URL(string: "https://searchbrowser.app/api/")!
    }

    /// Which download this is, as the site names them.
    static var arch: String {
        #if arch(x86_64)
        return "intel"
        #else
        return "apple"
        #endif
    }

    // MARK: - what is remembered

    /// Whether an email was given for the updates list, on this Mac.
    static func joined(_ store: UserDefaults = Store.settings) -> Bool { store.bool(forKey: joinedKey) }
    /// Whether the iPhone beta was asked for, on this Mac.
    static func askedBeta(_ store: UserDefaults = Store.settings) -> Bool { store.bool(forKey: betaKey) }

    /// Whether the card and the welcome offer the field: until an email has
    /// been given once. Closing the card without one changes nothing, so
    /// the next version's card offers it again.
    static func offered(_ store: UserDefaults = Store.settings) -> Bool { !joined(store) }

    /// After a press the site said yes to: the booleans, and nothing else.
    static func remember(_ list: List, in store: UserDefaults = Store.settings) {
        switch list {
        case .news(let beta):
            store.set(true, forKey: joinedKey)
            if beta { store.set(true, forKey: betaKey) }
        case .iPhoneBeta:
            store.set(true, forKey: betaKey)
        }
    }

    // MARK: - the request

    /// The address as the site will keep it, if it looks like one. The same
    /// rule as the site's, so a typo is caught before anything is sent.
    static func cleaned(_ email: String) -> String? {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.count <= 254,
              email.range(of: #"^[^\s@<>()\[\]\\,;:"]+@[^\s@<>()\[\]\\,;:"]+\.[a-z]{2,}$"#, options: .regularExpression) != nil
        else { return nil }
        return email
    }

    /// The body, and only that: the email, the source and — for the
    /// updates list — the build and the iPhone tick.
    static func body(email: String, list: List, source: Source) -> [String: Any] {
        switch list {
        case .news(let beta):
            var body: [String: Any] = ["email": email, "source": source.rawValue, "arch": arch]
            if beta { body["ios_beta"] = true }
            return body
        case .iPhoneBeta:
            return ["email": email, "source": source.rawValue]
        }
    }

    static func request(email: String, list: List, source: Source, base: URL = OptIn.base) -> URLRequest {
        let path: String
        switch list {
        case .news: path = "mac-list"
        case .iPhoneBeta: path = "ios-beta"
        }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Fixed words where CFNetwork would put the app's build, the
        // Darwin version and the Mac's languages.
        request.setValue("Search", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body(email: email, list: list, source: source), options: [.sortedKeys])
        return request
    }

    /// No cookies, no cache, no credentials kept: nothing of the request
    /// stays on disk.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    enum Failure: Error, Equatable {
        case notAnEmail
        case tooMany
        case unreachable

        var line: String {
            switch self {
            case .notAnEmail: return "That doesn't look like an email address."
            case .tooMany: return "Too many tries just now. Wait a few minutes."
            case .unreachable: return "Couldn't reach searchbrowser.app. Try again in a moment."
            }
        }
    }

    /// One POST, once, answered on the main queue. Never retried here: a
    /// failure waits for the person to press again.
    static func send(email: String, list: List, source: Source, base: URL = OptIn.base, session: URLSession = OptIn.session,
                     done: @escaping (Result<Void, Failure>) -> Void) {
        guard let email = cleaned(email) else { done(.failure(.notAnEmail)); return }
        let request = request(email: email, list: list, source: source, base: base)
        session.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let outcome: Result<Void, Failure>
            if error == nil, status == 200 { outcome = .success(()) }
            else if status == 400 { outcome = .failure(.notAnEmail) }
            else if status == 429 { outcome = .failure(.tooMany) }
            else { outcome = .failure(.unreachable) }
            DispatchQueue.main.async { done(outcome) }
        }.resume()
    }

    // MARK: - online or not

    /// Whether the Mac has a way out. The card leaves the field off while it
    /// hasn't, so a press can't fail for a reason the card doesn't show.
    @MainActor final class Reach: ObservableObject {
        static let shared = Reach()
        @Published private(set) var online = true
        private let monitor = NWPathMonitor()

        private init() {
            monitor.pathUpdateHandler = { [weak self] path in
                let online = path.status == .satisfied
                DispatchQueue.main.async { if self?.online != online { self?.online = online } }
            }
            monitor.start(queue: .global(qos: .utility))
        }
    }
}

// MARK: - the form

/// The field, the button, and what comes after: a thank-you, or a gentle
/// line and the same button again. Used by the card, the welcome and
/// Settings, each with its own source.
struct OptInForm: View {
    enum Phase: Equatable { case idle, sending, failed(OptIn.Failure), done }

    let source: OptIn.Source
    /// The updates list, with the iPhone tick; or the iPhone beta alone.
    let betaOnly: Bool
    let button: String
    /// The tick for the iPhone beta, offered beside the updates list.
    let offersBeta: Bool
    let store: UserDefaults
    let compact: Bool
    /// When the site said yes.
    let joined: (Bool) -> Void

    // The address lives here, in memory, and nowhere else.
    @State private var email: String
    @State private var beta: Bool
    @State private var phase: Phase
    @State private var betaSent: Bool
    /// "Did you mean …?", and the address it was shown for: the next press
    /// with that address sends it as typed.
    @State private var suggestion: String?
    @State private var suggestedFor: String?

    /// `start` and `email`: where the form starts, for pictures.
    init(source: OptIn.Source, betaOnly: Bool = false, button: String = "Join", offersBeta: Bool = true,
         store: UserDefaults = Store.settings, compact: Bool = false,
         start: Phase = .idle, email: String = "", beta: Bool = true,
         joined: @escaping (Bool) -> Void = { _ in }) {
        self.source = source
        self.betaOnly = betaOnly
        self.button = button
        self.offersBeta = offersBeta
        self.store = store
        self.compact = compact
        self.joined = joined
        _email = State(initialValue: email)
        _beta = State(initialValue: beta)
        _phase = State(initialValue: start)
        _betaSent = State(initialValue: start == .done && beta && offersBeta && !betaOnly)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if phase == .done {
                thanks
            } else {
                HStack(spacing: 8) {
                    field
                    Pill(phase == .sending ? "Joining…" : (isFailed ? "Try again" : button), filled: true, action: send)
                        .disabled(phase == .sending || email.trimmingCharacters(in: .whitespaces).isEmpty)
                        .opacity(email.trimmingCharacters(in: .whitespaces).isEmpty ? 0.55 : 1)
                }
                if let suggestion {
                    hint(suggestion)
                }
                if offersBeta && !betaOnly {
                    Tick(on: $beta, title: "Also send me the iPhone beta")
                }
                if case .failed(let failure) = phase {
                    Text(failure.line)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.unsafe)
                        .transition(.opacity)
                }
            }
        }
        .animation(Motion.settle, value: phase)
        .onChange(of: email) { _, now in
            if now.trimmingCharacters(in: .whitespacesAndNewlines) != suggestedFor {
                suggestion = nil
                suggestedFor = nil
            }
        }
    }

    /// One quiet line under the field; the address in it fills the field.
    private func hint(_ better: String) -> some View {
        HStack(spacing: 0) {
            Text("Did you mean ")
            Button { email = better } label: {
                Text(verbatim: better).underline().foregroundStyle(Palette.ink)
            }
            .buttonStyle(.plain)
            Text("?")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Palette.muted)
        .lineLimit(1)
        .truncationMode(.middle)
        .transition(.opacity)
    }

    private var isFailed: Bool { if case .failed = phase { return true } else { return false } }

    private var field: some View {
        ZStack(alignment: .leading) {
            if email.isEmpty {
                Text(verbatim: "you@example.com").foregroundStyle(Palette.muted.opacity(0.75))
            }
            TextField("", text: $email)
                .textFieldStyle(.plain)
                .foregroundStyle(Palette.ink)
                .textContentType(.emailAddress)
                .disableAutocorrection(true)
                .onSubmit(send)
                .accessibilityLabel("Email address")
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: compact ? 260 : .infinity)
    }

    private var thanks: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.safe)
            Text(thanksLine)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.opacity)
    }

    private var thanksLine: String {
        if betaOnly { return "Thanks. We'll email you when your iPhone beta spot opens." }
        return betaSent
            ? "Thanks, you're on the list. We'll email you when your iPhone beta spot opens."
            : "Thanks, you're on the list."
    }

    private func send() {
        guard phase != .sending, phase != .done else { return }
        if let better = EmailTypo.hold(email, shownFor: suggestedFor) {
            suggestion = better
            suggestedFor = email.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        suggestion = nil
        let list: OptIn.List = betaOnly ? .iPhoneBeta : .news(iPhoneBeta: offersBeta && beta)
        phase = .sending
        let store = store
        OptIn.send(email: email, list: list, source: source) { outcome in
            switch outcome {
            case .success:
                OptIn.remember(list, in: store)
                if case .news(let b) = list { betaSent = b }
                phase = .done
                joined(betaSent || betaOnly)
            case .failure(let failure):
                phase = .failed(failure)
            }
        }
    }

    /// A checkbox in the app's own ink.
    private struct Tick: View {
        @Binding var on: Bool
        let title: String
        var body: some View {
            Button { on.toggle() } label: {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(on ? Palette.ink : Palette.ground)
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(on ? .clear : Palette.faint, lineWidth: 1))
                        .overlay {
                            if on {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(Palette.ground)
                            }
                        }
                        .frame(width: 14, height: 14)
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? [.isSelected] : [])
            .accessibilityLabel(title)
        }
    }
}

/// The quiet line under every form: how to stop, and the privacy page.
struct OptInFinePrint: View {
    var open: (URL) -> Void
    var body: some View {
        HStack(spacing: 4) {
            Text("Unsubscribe anytime. Your email is used for nothing else.")
            Button { open(OptIn.privacy) } label: {
                Text("Privacy").underline()
            }
            .buttonStyle(.plain)
            .help(OptIn.privacy.absoluteString)
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The block pinned at the foot of the What's New card.
struct OptInBlock: View {
    let source: OptIn.Source
    var open: (URL) -> Void
    var start: OptInForm.Phase = .idle
    var startEmail = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Get Search for iPhone early")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("Leave your email for the iPhone beta. After that, rare emails: only useful new features and big updates.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            OptInForm(source: source, start: start, email: startEmail)
            OptInFinePrint(open: open)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.wash.opacity(0.55), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

/// The welcome's last page, for a new install: the same field, skippable
/// like every page there.
struct OptInWelcomePage: View {
    var start: OptInForm.Phase = .idle
    var startEmail = ""
    /// For pictures: drawn as online whatever the Mac is.
    var forceOnline = false
    var open: (URL) -> Void
    @ObservedObject private var reach = OptIn.Reach.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Search for iPhone, early.")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text("Leave your email and get the iPhone beta before everyone else. After that, rare emails: only useful new features and big updates.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if reach.online || forceOnline || start != .idle {
                VStack(alignment: .leading, spacing: 10) {
                    OptInForm(source: .welcome, start: start, email: startEmail)
                        .frame(maxWidth: 420, alignment: .leading)
                    OptInFinePrint(open: open)
                }
            } else {
                Text("You're offline. Settings › About has the same field for later.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.faint)
            }
        }
    }
}

/// Settings › About › News by email: one field per list, or a calm line
/// once this Mac has given an address, with a way to add another.
struct OptInSettingsField: View {
    let betaOnly: Bool
    @State private var another = false
    @State private var given = false
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }

    var body: some View {
        let remembered = betaOnly ? OptIn.askedBeta() : OptIn.joined()
        VStack(alignment: .leading, spacing: 8) {
            if remembered && !another && !given {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.safe)
                    Text(betaOnly ? "You've asked for the beta." : "You're on the list.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                    Quick(betaOnly ? "Ask for another address" : "Add another address") { another = true }
                }
            } else {
                OptInForm(source: .settings, betaOnly: betaOnly, button: betaOnly ? "Ask" : "Join", offersBeta: false, compact: true) { _ in
                    given = true
                }
                if !betaOnly { OptInFinePrint(open: open) }
            }
        }
    }
}
