import Foundation

/// Settings › General › Suggestions from your search engine (idea 347): the
/// words your engine thinks you are typing, under the field's own rows.
/// Off unless turned on, because it means what you type leaves the Mac as
/// you type it. Never from a private tab, and never for something that
/// looks like an address, a file, an email or a key: those are sent nowhere,
/// whatever the switch says.
enum EngineSuggest {
    /// How long typing has to pause before a question goes out.
    static let pause: Duration = .milliseconds(120)
    /// An answer later than this is no use to someone typing.
    static let patience: TimeInterval = 0.8
    /// At most this many rows from the engine.
    static let most = 6
    /// Longer than this, it is a paragraph or a paste, not a search.
    static let longest = 80

    /// Where each engine answers, OpenSearch's JSON ["words", ["…", …]],
    /// each checked with a real request on 20 Oct 2026. A custom engine has
    /// none we could know, and so shows nothing.
    static func endpoint(for engine: Engine) -> String? {
        switch engine {
        case .google: return "https://suggestqueries.google.com/complete/search?client=firefox&q=%s"
        case .duckduckgo: return "https://duckduckgo.com/ac/?q=%s&type=list"
        case .bing: return "https://www.bing.com/osjson.aspx?query=%s"
        case .ecosia: return "https://ac.ecosia.org/autocomplete?q=%s&type=list"
        case .startpage: return "https://www.startpage.com/osuggestions?q=%s"
        case .kagi: return "https://kagi.com/api/autosuggest?q=%s"
        case .brave: return "https://search.brave.com/api/suggest?q=%s"
        case .qwant: return "https://api.qwant.com/api/suggest/?q=%s&client=opensearch"
        case .custom: return nil
        }
    }

    /// The question for these words, or nil when there is nowhere to ask.
    /// Only ever https — except, in a test run, a fake engine on this Mac
    /// (`suggest.testURL` in the test world's settings).
    static func url(for words: String, engine: Engine, test: String? = nil) -> URL? {
        let template = test ?? endpoint(for: engine)
        guard let template, let url = Engine.url(for: words, template: template),
              let scheme = url.scheme?.lowercased()
        else { return nil }
        if scheme == "https" { return url }
        if test != nil, scheme == "http", ["127.0.0.1", "localhost"].contains(url.host() ?? "") { return url }
        return nil
    }

    /// The fake engine a test run asks instead, if it set one. Never read
    /// outside a test run.
    static var testEndpoint: String? {
        guard Store.testing, let text = Store.settings.string(forKey: "suggest.testURL"), !text.isEmpty else { return nil }
        return text
    }

    /// Whether these words may leave the Mac at all. Only plain words do:
    /// nothing with a scheme, nothing shaped like a host, a path or an
    /// email, nothing long, and nothing that reads like a password or a key.
    static func sendable(_ typed: String) -> Bool {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= longest else { return false }
        guard !text.contains(where: \.isNewline) else { return false }
        // An address the field would go to: a scheme, a host, localhost, an IP.
        if Address.url(from: text) != nil { return false }
        let tokens = text.split(whereSeparator: \.isWhitespace)
        let first = tokens.first.map(String.init) ?? text
        // A scheme, of any kind: mailto:x, javascript:…, localhost:3000.
        if first.first?.isLetter == true, let colon = first.firstIndex(of: ":"),
           first.index(after: colon) < first.endIndex,
           first[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }) {
            return false
        }
        // A path on this Mac, or one of a project's files.
        if first.hasPrefix("/") || first.hasPrefix("~") || first.hasPrefix("./") || first.hasPrefix("../")
            || text.contains("\\") {
            return false
        }
        for token in tokens {
            // Host-like (a dot and no space within it) or a path (a slash).
            if tokens.count == 1, token.contains(".") || token.contains("/") { return false }
            // An email address, anywhere in it.
            if token.contains("@"), token.contains(".") { return false }
            if secretLike(token) { return false }
        }
        return true
    }

    /// A long run with no space that mixes letters and digits, or reads as
    /// a key's encoding: a password, a token, a card or account number.
    static func secretLike<S: StringProtocol>(_ token: S) -> Bool {
        let letters = token.contains(where: \.isLetter)
        let digits = token.contains(where: \.isNumber)
        if token.count >= 12, letters, digits { return true }
        // A long number: a card, a phone, an account.
        if token.count >= 9, digits, token.allSatisfy({ $0.isNumber || $0 == "-" }) { return true }
        // Long and unbroken, in the alphabet keys are written in.
        if token.count >= 24, token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=_-".contains($0)) }) {
            return true
        }
        return false
    }

    /// The words in an OpenSearch answer, ["what was asked", ["one", "two"]]:
    /// trimmed, each once, none the same as what was typed, at most `most`.
    static func parse(_ data: Data, asked: String) -> [String] {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [Any],
              top.count >= 2, let words = top[1] as? [Any]
        else { return [] }
        let typed = asked.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen: Set<String> = [typed]
        var out: [String] = []
        for case let word as String in words {
            let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= 200, !clean.contains(where: \.isNewline),
                  seen.insert(clean.lowercased()).inserted
            else { continue }
            out.append(clean)
            if out.count == most { break }
        }
        return out
    }

    /// One session for every question: nothing kept on disk, no cookies
    /// either way, no credentials, no cache, no referrer (a session's
    /// requests carry none), and a short timeout.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = patience
        configuration.timeoutIntervalForResource = patience
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: NoRedirects.shared, delegateQueue: nil)
    }()

    /// An engine that answers by sending us somewhere else isn't followed
    /// there: the words would go to a host nobody picked.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        static let shared = NoRedirects()
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            // Never a password: only the server's own certificate is judged.
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}

/// One question at a time: each new one waits out the pause and cancels
/// the one before, so an answer to "coff" never lands on "coffee".
@MainActor
final class EngineSuggester {
    private var task: Task<Void, Never>?
    /// Which question is the latest, so one that finished late doesn't
    /// forget the one after it.
    private var round = 0
    /// For a test run's `bench suggest`: questions sent, let go of, too slow.
    private(set) var asked = 0
    private(set) var cancelled = 0
    private(set) var tooSlow = 0

    func ask(_ url: URL, words: String, then answer: @escaping @MainActor ([String]) -> Void) {
        stop()
        round += 1
        let mine = round
        task = Task { [weak self] in
            defer { if let self, self.round == mine { self.task = nil } }
            do { try await Task.sleep(for: EngineSuggest.pause) } catch { return }
            self?.asked += 1
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: EngineSuggest.patience)
            request.httpShouldHandleCookies = false
            request.setValue("application/json, text/javascript;q=0.9", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await EngineSuggest.session.data(for: request)
                guard !Task.isCancelled, let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
                let words = EngineSuggest.parse(data, asked: words)
                guard !Task.isCancelled else { return }
                answer(words)
            } catch let error as URLError where error.code == .timedOut {
                self?.tooSlow += 1
            } catch {}
        }
    }

    /// Nothing is waiting any more: the field emptied, or went away, or what
    /// is in it isn't to be sent.
    func stop() {
        guard let task else { return }
        task.cancel()
        cancelled += 1
        self.task = nil
    }
}
