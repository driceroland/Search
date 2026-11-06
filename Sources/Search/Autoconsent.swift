import Foundation
import OSLog
import WebKit

// Cookie banners, answered No.
//
// With Settings › Privacy › Refuse cookie banners on, a site's consent pop-up
// is answered the way you would answer it — reject all, or only what is
// needed — and closed, usually before it has been seen. The work is
// DuckDuckGo's autoconsent (Autoconsent/, MPL-2.0, as published; see
// Autoconsent/update.sh), the one DuckDuckGo's own Mac and iPhone browsers
// run in a WKWebView like this one. It knows the consent platforms most sites
// use — OneTrust, Cookiebot, Didomi, Sourcepoint, Usercentrics, Quantcast and
// a few hundred more, some site by site — by their own markup, and what to
// click, in what order, to say no.
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
// page world and answers whether it worked. That code is only ever a rule's,
// from the file shipped in the app: a page has no way to reach this world or
// its handler. Nothing is fetched and nothing leaves the Mac.

final class Autoconsent: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = Autoconsent()
    static let name = "searchConsent"
    @MainActor static let world = WKContentWorld.world(name: "Search Consent")

    /// Settings' switch. Off unless turned on.
    @MainActor static var on = false

    private static let log = Logger(subsystem: "com.officecommun.search", category: "Consent")

    /// For each page and frame: two lines of Search's, then DuckDuckGo's
    /// script as it comes. Nil in a build without Autoconsent/, which then
    /// simply goes without.
    @MainActor static let script: WKUserScript? = {
        guard let url = Bundle.main.url(forResource: "autoconsent", withExtension: "js", subdirectory: "Autoconsent"),
              let library = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return WKUserScript(source: glue + library, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }()

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

    /// The rules read ahead, off the main thread, so the first page doesn't
    /// wait for them.
    static func prepare() {
        DispatchQueue.global(qos: .utility).async { _ = Rulebook.shipped }
    }

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
                let main = message.frameInfo.isMainFrame
                DispatchQueue.global(qos: .userInitiated).async {
                    let rules = Rulebook.shipped?.rules(for: url, mainFrame: main)
                    DispatchQueue.main.async {
                        guard let rules else { return replyHandler(nil, nil) }
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
                // Each rule's code is one call, `(() => …)()`, answering true
                // or false; one that throws didn't work.
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

/// DuckDuckGo's rules as they ship (Autoconsent/rules.json, "compact"): the
/// strings every rule points into, the rules, and where each kind starts —
/// those for any site, those for a frame, those for one site. Read once; for
/// each frame, cut down to what can apply there, as autoconsent's own
/// filterCompactRules does, so an ad's frame isn't handed 900 sites' rules.
final class Rulebook: @unchecked Sendable {
    static let shipped: Rulebook? = Bundle.main
        .url(forResource: "rules", withExtension: "json", subdirectory: "Autoconsent")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap(Rulebook.init)

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
              let version = all["v"] as? Int,
              let strings = all["s"] as? [Any],
              let rules = all["r"] as? [[Any]],
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
        self.genericStrings = min(genericStrings, strings.count)
        self.frameStrings = min(frameStrings, strings.count)
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
