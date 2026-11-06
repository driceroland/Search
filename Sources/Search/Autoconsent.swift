import Foundation
import OSLog
import WebKit

// Cookie banners, answered No.
//
// With Settings › Privacy › Refuse cookie banners on, a site's consent pop-up
// is answered the way you would answer it — reject all, or only what is
// needed — and closed, usually before it has been seen. The work is
// DuckDuckGo's autoconsent, the one DuckDuckGo's own Mac and iPhone browsers
// run in a WKWebView like this one. It knows the consent platforms most sites
// use — OneTrust, Cookiebot, Didomi, Sourcepoint, Usercentrics, Quantcast and
// a few hundred more, some site by site — by their own markup, and what to
// click, in what order, to say no.
//
// Its script ships in the app (Autoconsent/, MPL-2.0, as published; see
// Autoconsent/update.sh). Its rules don't: they change every week, and
// someone who never turns this on shouldn't carry them. They are fetched
// when it is turned on, and again once a week (see ConsentRules).
//
// Only pop-ups it knows. Its heuristic mode, which guesses at a banner by the
// words on its buttons, stays off: a wrong guess there is a click on Accept,
// which is worse than doing nothing. A pop-up it doesn't know is left as it
// is, for ⇧⌘H; so is a site that offers no way to say no.
//
// It runs in every frame — Sourcepoint and TrustArc show theirs in a frame of
// their own — in a world of its own, so the page sees none of it. What it
// can't do from there, asking a platform's own JavaScript (Didomi's
// setUserDisagreeToAll()), it hands to Search, which runs it in that frame's
// page world and answers whether it worked. That code is always the shipped
// script's own: a rule only names one of the script's snippets, so a rules
// file, fetched or not, can't carry code, and a page has no way to reach this
// world or its handler.

final class Autoconsent: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = Autoconsent()
    static let name = "searchConsent"
    @MainActor static let world = WKContentWorld.world(name: "Search Consent")

    /// Settings' switch. Off unless turned on.
    @MainActor static var on = false

    static let log = Logger(subsystem: "com.officecommun.search", category: "Consent")

    private static func shipped(_ name: String, _ kind: String?) -> URL? {
        Bundle.main.url(forResource: name, withExtension: kind, subdirectory: "Autoconsent")
    }

    /// For each page and frame: two lines of Search's, then DuckDuckGo's
    /// script as it comes. Nil in a build without Autoconsent/, which then
    /// simply goes without.
    @MainActor static let script: WKUserScript? = {
        guard let url = shipped("autoconsent", "js"), let library = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return WKUserScript(source: glue + library, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }()

    /// The release the script is from (Autoconsent/VERSION): its rules are
    /// fetched for the same major version.
    static let version: String? = shipped("VERSION", nil).flatMap {
        try? String(contentsOf: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the script says goes to Search; an answer, when there is one,
    /// comes straight back to it.
    static let glue = """
    window.autoconsentSendMessage = function (message) {
      window.webkit.messageHandlers.\(name).postMessage(message).then(function (reply) {
        if (reply) window.autoconsentReceiveMessage(reply);
      }, function () {});
    };

    """

    /// DuckDuckGo's defaults, said out loud: refuse without asking, hide a
    /// known pop-up's box while it is looked for so it doesn't flash, and no
    /// heuristics (see above). The page's console hears nothing.
    static let config: [String: Any] = [
        "enabled": true,
        "autoAction": "optOut",
        "disabledCmps": [String](),
        "enablePrehide": true,
        "prehideTimeout": 2000,
        "enableCosmeticRules": true,
        "enableGeneratedRules": true,
        "enableHeuristicDetection": false,
        "heuristicMode": "off",
        "detectRetries": 20,
        "isMainWorld": false,
        "logs": ["lifecycle": false, "rulesteps": false, "detectionsteps": false, "evals": false,
                 "errors": false, "messages": false, "waits": false],
    ]

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        MainActor.assumeIsolated {
            // Switched off while a page was up: its script asks, and is told nothing.
            guard Autoconsent.on, let body = message.body as? [String: Any], let type = body["type"] as? String
            else { return replyHandler(nil, nil) }
            switch type {
            case "init":
                guard let url = body["url"] as? String, url.hasPrefix("http") else { return replyHandler(nil, nil) }
                // No rules yet, the first copy still on its way: this page
                // goes without.
                guard let book = ConsentRules.shared.inUse() else { return replyHandler(nil, nil) }
                let main = message.frameInfo.isMainFrame
                DispatchQueue.global(qos: .userInitiated).async {
                    let rules = book.rules(for: url, mainFrame: main)
                    DispatchQueue.main.async {
                        replyHandler([
                            "type": "initResp",
                            "config": Autoconsent.config,
                            "rules": ["autoconsent": [Any](), "compact": rules],
                        ], nil)
                    }
                }
            case "eval":
                guard let id = body["id"] as? String, let code = body["code"] as? String, let web = message.webView
                else { return replyHandler(nil, nil) }
                // Each snippet is one call, `(() => …)()`, answering true or
                // false; one that throws didn't work.
                let js = "(() => { try { return !!(\(code)); } catch (e) { return false; } })();"
                web.evaluateJavaScript(js, in: message.frameInfo, in: .page) { result in
                    let worked = (try? result.get()) as? Bool ?? false
                    replyHandler(["type": "evalResp", "id": id, "result": worked], nil)
                }
            case "autoconsentDone":
                let cmp = body["cmp"] as? String ?? "?"
                Autoconsent.log.info("Refused \(cmp, privacy: .public) on \(message.frameInfo.securityOrigin.host, privacy: .private)")
                replyHandler(nil, nil)
            case "optOutResult" where body["result"] as? Bool == false:
                let cmp = body["cmp"] as? String ?? "?"
                Autoconsent.log.info("Couldn't refuse \(cmp, privacy: .public) on \(message.frameInfo.securityOrigin.host, privacy: .private)")
                replyHandler(nil, nil)
            default:
                replyHandler(nil, nil)
            }
        }
    }
}

/// DuckDuckGo's rules, fetched rather than shipped. Turned on, the copy kept
/// on this Mac is read, and a new one fetched when there is none or it is a
/// week old; a copy that doesn't read as rules the script can take is thrown
/// away and the last good one kept. The request is a plain GET of a public
/// file, with no cookies and nothing of yours in it; nothing else is sent,
/// and with the switch off nothing is fetched at all.
@MainActor
final class ConsentRules: ObservableObject {
    static let shared = ConsentRules()

    /// jsDelivr's copy of DuckDuckGo's npm release, held to the major version
    /// of the script in the app, so the two stay a pair. A test run can point
    /// it at a local stand-in (`test.consentRules` in the test settings).
    static var source: URL? {
        if Store.testing, let test = Store.settings.string(forKey: "test.consentRules") { return URL(string: test) }
        return address(for: Autoconsent.version)
    }

    nonisolated static func address(for version: String?) -> URL? {
        guard let major = version?.split(separator: ".").first, Int(major) != nil else { return nil }
        return URL(string: "https://cdn.jsdelivr.net/npm/@duckduckgo/autoconsent@\(major)/rules/compact-rules.json")
    }

    static let file = Store.file("Cookie banner rules.json")
    /// How old a copy may get before a new one is fetched.
    nonisolated static let week: TimeInterval = 7 * 24 * 60 * 60
    /// How long after a fetch that didn't work before pages ask again.
    nonisolated static let pause: TimeInterval = 60 * 60

    /// Said under the switch while there are no rules to use: the first copy
    /// on its way, or not had.
    enum Trouble { case fetching, failed }
    @Published private(set) var trouble: Trouble?

    private var book: Rulebook?
    private var fetched: Date?
    private var tried: Date?
    private var reading = false
    private var fetching = false

    /// The rules for a page, when there are any. A page asking is also when
    /// a copy left a week, or a fetch that failed, is seen to.
    func inUse() -> Rulebook? {
        if !reading { fetchIfDue() }
        return book
    }

    /// Turned on, or started with it on: the copy kept here read, a new one
    /// fetched if it is due.
    func prepare() {
        guard book == nil, !reading else { return fetchIfDue() }
        reading = true
        let file = Self.file
        Task.detached(priority: .utility) {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let kept = (try? Data(contentsOf: file)).flatMap(Rulebook.init)
            await MainActor.run {
                self.reading = false
                if let kept, self.book == nil { self.book = kept; self.fetched = date }
                self.fetchIfDue()
            }
        }
    }

    /// Settings' Try again: fetched now, whatever the dates say.
    func retry() {
        tried = nil
        fetch()
    }

    private func fetchIfDue() {
        guard !fetching, Self.due(fetched: book == nil ? nil : fetched, tried: tried, now: Date()) else { return }
        fetch()
    }

    /// A copy is due when there is none, or it is a week old — but not again
    /// within the hour after a fetch that didn't work.
    nonisolated static func due(fetched: Date?, tried: Date?, now: Date) -> Bool {
        if let tried, now.timeIntervalSince(tried) < pause { return false }
        guard let fetched else { return true }
        return now.timeIntervalSince(fetched) >= week
    }

    private func fetch() {
        guard Autoconsent.on, !fetching, let source = Self.source else { return }
        fetching = true
        if book == nil { trouble = .fetching }
        let file = Self.file
        Task.detached(priority: .utility) {
            let outcome = await Self.download(source, to: file)
            await MainActor.run {
                self.fetching = false
                switch outcome {
                case .success(let fresh):
                    self.book = fresh
                    self.fetched = Date()
                    self.tried = nil
                    self.trouble = nil
                case .failure(let why):
                    self.tried = Date()
                    Autoconsent.log.error("Couldn't fetch the rules: \(why.localizedDescription, privacy: .public)")
                    if self.book == nil { self.trouble = .failed }
                }
            }
        }
    }

    private enum Refused: LocalizedError {
        case status(Int), notRules
        var errorDescription: String? {
            switch self {
            case .status(let code): return "the server answered \(code)"
            case .notRules: return "what came back isn't rules the script can read"
            }
        }
    }

    /// Fetched, read, and only then kept, in place of the last copy.
    nonisolated private static func download(_ source: URL, to file: URL) async -> Result<Rulebook, Error> {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(from: source)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Refused.status(http.statusCode) }
            // The whole set is half a megabyte; anything ten times that isn't it.
            guard data.count < 5_000_000, let book = Rulebook(data) else { throw Refused.notRules }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return .success(book)
        } catch {
            return .failure(error)
        }
    }
}

/// DuckDuckGo's rules in their compact form (rules/compact-rules.json): the
/// strings every rule points into, the rules, and where each kind starts —
/// those for any site, those for a frame, those for one site. For each frame,
/// cut down to what can apply there, as autoconsent's own filterCompactRules
/// does, so an ad's frame isn't handed 900 sites' rules.
final class Rulebook: @unchecked Sendable {
    /// The compact format the shipped script reads (its decodeRules refuses
    /// anything newer).
    static let format = 1

    private let version: Int
    private let strings: [Any]
    private let rules: [[Any]]
    private let generic: Range<Int>
    private let frame: Range<Int>
    private let specific: Range<Int>
    private let genericStrings: Int
    private let frameStrings: Int
    /// Each rule's address pattern, made once. One ICU can't read isn't here
    /// and its rule goes along: the script checks the address again itself,
    /// so this only ever saves work.
    private let patterns: [Int: NSRegularExpression]

    init?(_ data: Data) {
        guard let all = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = all["v"] as? Int, version <= Rulebook.format,
              let strings = all["s"] as? [Any],
              let rules = all["r"] as? [[Any]], !rules.isEmpty,
              let index = all["index"] as? [String: Any]
        else { return nil }
        func range(_ key: String) -> Range<Int>? {
            guard let ends = index[key] as? [Int], ends.count == 2,
                  0 <= ends[0], ends[0] <= ends[1], ends[1] <= rules.count else { return nil }
            return ends[0]..<ends[1]
        }
        guard let generic = range("genericRuleRange"), let frame = range("frameRuleRange"),
              let specific = range("specificRuleRange"),
              let genericStrings = index["genericStringEnd"] as? Int, let frameStrings = index["frameStringEnd"] as? Int
        else { return nil }
        self.version = version
        self.strings = strings
        self.rules = rules
        self.generic = generic
        self.frame = frame
        self.specific = specific
        self.genericStrings = min(max(genericStrings, 0), strings.count)
        self.frameStrings = min(max(frameStrings, 0), strings.count)
        var patterns: [Int: NSRegularExpression] = [:]
        for (i, rule) in rules.enumerated() {
            guard rule.count > 3, let pattern = rule[3] as? String, !pattern.isEmpty,
                  let made = try? NSRegularExpression(pattern: pattern) else { continue }
            patterns[i] = made
        }
        self.patterns = patterns
    }

    /// The rules for one frame, in the shape the script takes as `compact`.
    func rules(for url: String, mainFrame: Bool) -> [String: Any] {
        let whole = NSRange(url.startIndex..., in: url)
        func runs(_ i: Int) -> Bool {
            let rule = rules[i]
            // Where a rule runs: 1 frames only; 10, 12, 20 and 22 the top
            // page only (autoconsent's shouldRunRuleInContext).
            let context = rule.count > 4 ? rule[4] as? Int ?? 0 : 0
            if mainFrame, context == 1 { return false }
            if !mainFrame, [10, 12, 20, 22].contains(context) { return false }
            if let pattern = patterns[i], pattern.firstMatch(in: url, range: whole) == nil { return false }
            return true
        }
        if !mainFrame {
            return ["v": version, "s": Array(strings[..<frameStrings]), "r": frame.filter(runs).map { rules[$0] }]
        }
        let specific = specific.filter(runs).map { rules[$0] }
        guard !specific.isEmpty else {
            return ["v": version, "s": Array(strings[..<genericStrings]), "r": Array(rules[generic])]
        }
        return ["v": version, "s": strings, "r": Array(rules[generic]) + specific]
    }
}
