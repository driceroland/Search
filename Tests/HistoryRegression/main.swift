import Foundation

private struct LegacyVisit: Codable {
    var url: String
    var key: String
    var title: String
    var count: Int
    var last: Date
}

@MainActor
private enum Checks {
    static var failures: [String] = []

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard !condition() else { return }
        failures.append(message)
        fputs("FAIL: \(message)\n", stderr)
    }
}

private func url(_ string: String) -> URL {
    guard let url = URL(string: string) else { fatalError("Invalid test URL: \(string)") }
    return url
}

private func sameRouteIgnoringFragment(_ leftURL: URL, _ rightURL: URL) -> Bool {
    guard let left = URLComponents(url: leftURL, resolvingAgainstBaseURL: false),
          let right = URLComponents(url: rightURL, resolvingAgainstBaseURL: false)
    else { return false }
    return left.scheme?.lowercased() == right.scheme?.lowercased()
        && left.host?.lowercased() == right.host?.lowercased()
        && left.port == right.port
        && left.percentEncodedPath == right.percentEncodedPath
        && left.percentEncodedQuery == right.percentEncodedQuery
}

@MainActor
private func traces(_ history: History, host: String) -> [History.Trace] {
    history.everything().filter { $0.url.host()?.lowercased() == host.lowercased() }
}

@MainActor
private func testRecordAndTakeKeepCanonicalIdentityComponents() {
    Store.use("identity")
    let history = History()
    let addresses = [
        "http://identity.example.test:8080/A?Q=One#first",
        "https://identity.example.test:8080/A?Q=One",
        "https://identity.example.test:9090/A?Q=One",
        "https://identity.example.test:8080/a?Q=One",
        "https://identity.example.test:8080/A?q=One",
        "https://identity.example.test:8080/A?Q=one"
    ]

    history.record(url(addresses[0]), title: "HTTP")
    for (index, address) in addresses.dropFirst().enumerated() {
        history.take(
            url(address),
            title: "Imported \(index)",
            count: index + 2,
            last: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
        )
    }
    // Fragments identify an in-page position, not a separate history entry.
    history.take(
        url("http://identity.example.test:8080/A?Q=One#later"),
        title: "",
        count: 8,
        last: Date(timeIntervalSince1970: 1_700_000_100)
    )

    let pages = traces(history, host: "identity.example.test").filter {
        ["/A", "/a"].contains($0.url.path())
    }
    Checks.expect(pages.count == 6, "record/take should keep scheme, port, path case, and query case distinct")
    Checks.expect(Set(pages.map(\.key)).count == 6, "each canonical page should have a distinct history identity")
    let original = pages.first { $0.url.scheme == "http" && $0.url.port == 8080 }
    Checks.expect(original?.count == 8, "a fragment-only repeat should update the original visit")
    Checks.expect(pages.allSatisfy { !$0.key.contains("#") }, "canonical history identities should omit fragments")

    Store.use("recorded-local-paths")
    let recorded = History()
    for address in [
        "http://localhost:3000/a",
        "http://localhost:4000/a",
        "http://localhost:3000/A",
        "http://localhost:4000/A"
    ] {
        recorded.record(url(address), title: address)
    }
    let localPages = traces(recorded, host: "localhost").filter { $0.url.path() != "/" }
    Checks.expect(localPages.count == 4, "record should preserve localhost port and /A versus /a identity")
    Checks.expect(Set(localPages.map(\.key)).count == 4, "recorded localhost variants should each have a unique identity")
}

@MainActor
private func testRetitleAndForgetUseIndependentIdentities() {
    Store.use("retitle-forget")
    let history = History()
    let insecure = url("http://titles.example.test:8080/A?Q=One")
    let secure = url("https://titles.example.test:8080/A?Q=One")
    history.record(insecure, title: "Insecure title")
    history.record(secure, title: "Secure title")
    history.retitle(insecure, "Retitled HTTP")

    var pages = traces(history, host: "titles.example.test").filter { $0.url.path() == "/A" }
    let httpTrace = pages.first { $0.url.scheme == "http" }
    let httpsTrace = pages.first { $0.url.scheme == "https" }
    Checks.expect(pages.count == 2, "different schemes should remain separately retitleable")
    Checks.expect(httpTrace?.title == "Retitled HTTP", "retitle should change only the matching scheme")
    Checks.expect(httpsTrace?.title == "Secure title", "retitle should leave the other scheme unchanged")

    if let httpTrace { history.forget(httpTrace.key) }
    pages = traces(history, host: "titles.example.test").filter { $0.url.path() == "/A" }
    Checks.expect(pages.count == 1 && pages.first?.url.scheme == "https", "forget should remove only the selected identity")
}

@MainActor
private func testLegacyLoadRebuildsIdentityFromStoredURL() {
    Store.use("legacy-load")
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let legacy = [
        LegacyVisit(url: "https://legacy.example.test:8080/A?Q=One#first", key: "stale-collision", title: "Upper", count: 2, last: now),
        LegacyVisit(url: "https://legacy.example.test:8080/a?Q=One", key: "stale-collision", title: "Lower", count: 3, last: now.addingTimeInterval(1)),
        LegacyVisit(url: "https://legacy.example.test:8080/A?Q=One#again", key: "old-third-key", title: "Duplicate fragment", count: 7, last: now.addingTimeInterval(2))
    ]
    do {
        try JSONEncoder().encode(legacy).write(to: Store.file("history.json"))
    } catch {
        fatalError("Could not seed legacy fixture: \(error)")
    }

    let history = History()
    let pages = traces(history, host: "legacy.example.test").filter { ["/A", "/a"].contains($0.url.path()) }
    let upper = pages.first { $0.url.path() == "/A" }
    let lower = pages.first { $0.url.path() == "/a" }
    Checks.expect(pages.count == 2, "legacy keys should be rebuilt so path case survives loading")
    Checks.expect(upper?.count == 9, "legacy records for the same fragment-free URL should merge their counts")
    Checks.expect(lower?.count == 3, "legacy path-case variant should retain its own count")
    Checks.expect(Set(pages.map(\.key)).count == pages.count && pages.allSatisfy { !$0.key.hasPrefix("stale-") && $0.key != "old-third-key" }, "loaded identities should come from stored URLs, not stale keys")
}

@MainActor
private func testRootCreditsKeepOriginAndDirectRootCountsOnce() {
    Store.use("root-origins")
    let history = History()
    for address in [
        "http://origin.example.test:8080/page",
        "https://origin.example.test:8080/page",
        "https://origin.example.test:9090/page"
    ] {
        history.record(url(address), title: "Page")
    }

    let roots = history.suggestions(for: "ORIGIN.EXAMPLE.TEST", limit: 50).filter {
        $0.url.host()?.lowercased() == "origin.example.test" && $0.url.path() == "/"
    }
    let origins = Set(roots.map { "\($0.url.scheme ?? ""):\($0.url.port ?? 0)" })
    Checks.expect(origins == ["http:8080", "https:8080", "https:9090"], "root credits should preserve the visited scheme and port")
    Checks.expect(traces(history, host: "origin.example.test").count == 3, "synthetic root credits should not add rows to visible history")

    Store.use("direct-root")
    let direct = History()
    direct.record(url("https://home.example.test/"), title: "Home")
    var home = traces(direct, host: "home.example.test").filter { $0.url.path() == "/" }
    Checks.expect(home.count == 1 && home.first?.count == 1, "recording a homepage should credit its root only once")
    direct.record(url("https://home.example.test/deep"), title: "Deep page")
    home = traces(direct, host: "home.example.test").filter { $0.url.path() == "/" }
    Checks.expect(home.count == 1 && home.first?.count == 2 && home.first?.title == "Home", "later deep-page credits should update the titled homepage once")

    Store.use("canonical-root")
    let canonical = History()
    canonical.record(url("HTTPS://Normalize.example.test"), title: "First form")
    canonical.record(url("https://normalize.example.test/"), title: "Slash form")
    let normalizedHome = traces(canonical, host: "normalize.example.test").filter { $0.url.path() == "/" }
    Checks.expect(
        normalizedHome.count == 1 && normalizedHome.first?.count == 2
            && normalizedHome.first?.key == "https://normalize.example.test/",
        "scheme and host case plus an empty/root slash should normalize to one homepage identity"
    )
}

@MainActor
private func testSuggestionIdsAndSafeCaseInsensitiveCompletion() {
    Store.use("suggestions")
    let history = History()
    history.record(url("https://suggest.example.test/A?Q=One"), title: "Upper page")
    history.record(url("https://suggest.example.test/a?Q=One"), title: "Lower page")
    history.record(url("https://suggest.example.test/A?q=One"), title: "Query case")

    let options = history.suggestions(for: "SUGGEST.EXAMPLE.TEST", limit: 50)
    Checks.expect(options.contains { $0.url.path() == "/A" }, "suggestion matching should ignore host letter case")
    Checks.expect(Set(options.map(\.id)).count == options.count, "suggestion ids should remain unique across case-sensitive URLs")

    let upper = options.first { $0.url.path() == "/A" && $0.url.query() == "Q=One" }
    if let upper {
        let safe = history.completion(for: "SUGGEST.EXAMPLE.TEST", among: [upper])
        Checks.expect(safe == "/A?Q=One", "completion should match the host case-insensitively")
        let unsafe = history.completion(for: "suggest.example.test/a?Q=", among: [upper])
        Checks.expect(unsafe == nil, "completion must not suggest a suffix that changes a case-sensitive path")
        let partialHostWithPath = history.completion(for: "suggest/A", among: [upper])
        Checks.expect(partialHostWithPath == nil, "completion must not append a host remainder after the user already typed a path")
    } else {
        Checks.expect(false, "upper-case path suggestion should be available for completion checks")
    }

    Store.use("scheme-suggestion-ids")
    let schemeHistory = History()
    schemeHistory.record(url("http://scheme-id.example.test:3000/a?Q=One"), title: "HTTP")
    schemeHistory.record(url("https://scheme-id.example.test:3000/a?Q=One"), title: "HTTPS")
    let schemeOptions = schemeHistory.suggestions(for: "scheme-id.example.test", limit: 50).filter {
        $0.url.host() == "scheme-id.example.test" && $0.url.path() == "/a" && $0.url.query() == "Q=One"
    }
    Checks.expect(Set(schemeOptions.map(\.url.scheme)).count == 2, "scheme-only URL variants should both remain suggestions")
    Checks.expect(Set(schemeOptions.map(\.id)).count == schemeOptions.count, "scheme-only URL variants should have unique suggestion ids")
    for candidate in schemeOptions where candidate.key.count > 2 {
        let typed = String(candidate.key.dropLast())
        guard let ending = schemeHistory.completion(for: typed, among: [candidate]) else {
            Checks.expect(false, "a proper prefix of a scheme-specific suggestion should complete")
            continue
        }
        guard let completed = Address.url(from: typed + ending) else {
            Checks.expect(false, "completed scheme-specific suggestion should parse as an address")
            continue
        }
        Checks.expect(
            sameRouteIgnoringFragment(completed, candidate.url),
            "completing a scheme-specific suggestion should resolve to its canonical origin"
        )
    }

    Store.use("known-suppression")
    let knownHistory = History()
    knownHistory.record(url("https://github.com/"), title: "GitHub home")
    let github = knownHistory.suggestions(for: "github", limit: 50)
    Checks.expect(!github.contains { if case .known = $0.kind { return true }; return false }, "a visited known site should not also appear as a known-site suggestion")
}

/// Lets the coalesced save reach the disk, then reads what it wrote.
@MainActor
private func savedFile() -> String {
    RunLoop.main.run(until: Date().addingTimeInterval(2.5))
    return (try? String(contentsOf: Store.file("history.json"), encoding: .utf8)) ?? ""
}

@MainActor
private func testCredentialsNeverReachTheFile() {
    Store.use("credentials")
    let history = History()
    history.record(url("https://user:secret@cred.example.test/page"), title: "Signed in")
    history.take(url("https://user:secret@cred.example.test/other"), title: "Taken", count: 2, last: Date())
    history.retitle(url("https://user:secret@cred.example.test/page"), "Retitled")
    let pages = traces(history, host: "cred.example.test")
    Checks.expect(pages.count == 2, "a page with a name and password in its address should still be kept")
    Checks.expect(pages.first { $0.url.path() == "/page" }?.title == "Retitled", "retitle should find a page recorded with credentials")
    Checks.expect(pages.allSatisfy { !$0.key.contains("secret") && !$0.url.absoluteString.contains("secret") && !$0.address.contains("secret") },
                  "history identities, URLs and addresses should never hold a password")
    Checks.expect(!savedFile().contains("secret"), "history.json should never hold a password")

    Store.use("legacy-credentials")
    let legacy = [LegacyVisit(url: "https://user:secret@oldcred.example.test/page", key: "oldcred.example.test/page", title: "Old", count: 4, last: Date())]
    do { try JSONEncoder().encode(legacy).write(to: Store.file("history.json")) } catch { fatalError("\(error)") }
    let loaded = History()
    Checks.expect(traces(loaded, host: "oldcred.example.test").first?.count == 4, "a legacy page kept with credentials should survive loading")
    loaded.record(url("https://elsewhere.example.test/"), title: "Save")
    Checks.expect(!savedFile().contains("secret"), "a password kept by an older version should leave history.json on the next save")
}

@MainActor
private func testLegacyCreditsMoveToTheOriginTheirPagesUsed() {
    Store.use("legacy-credits")
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let legacy = [
        // Pages on www, credited to the bare https host by the old rule.
        LegacyVisit(url: "https://site.example.test/", key: "site.example.test", title: "", count: 5, last: now),
        LegacyVisit(url: "https://www.site.example.test/a", key: "site.example.test/a", title: "A", count: 3, last: now),
        LegacyVisit(url: "https://www.site.example.test/b", key: "site.example.test/b", title: "B", count: 2, last: now),
        // A dev server: credited to https:// without its port.
        LegacyVisit(url: "https://localhost/", key: "localhost", title: "", count: 4, last: now),
        LegacyVisit(url: "http://localhost:3000/app", key: "localhost/app", title: "App", count: 4, last: now),
        // Pages on the bare host itself: the credit is already right.
        LegacyVisit(url: "https://bare.example.test/", key: "bare.example.test", title: "", count: 6, last: now),
        LegacyVisit(url: "https://bare.example.test/x", key: "bare.example.test/x", title: "X", count: 6, last: now),
        // A titled front door is a real visit, never moved.
        LegacyVisit(url: "https://titled.example.test/", key: "titled.example.test", title: "Titled", count: 2, last: now),
        LegacyVisit(url: "https://www.titled.example.test/x", key: "titled.example.test/x", title: "X", count: 2, last: now),
    ]
    do { try JSONEncoder().encode(legacy).write(to: Store.file("history.json")) } catch { fatalError("\(error)") }
    let history = History()

    let site = history.suggestions(for: "site.example", limit: 50).filter { $0.url.path() == "/" }
    Checks.expect(site.count == 1 && site.first?.url.host() == "www.site.example.test", "a legacy credit should move to the www its pages were on")
    history.record(url("https://www.site.example.test/c"), title: "C")
    let after = history.suggestions(for: "site.example", limit: 50).filter { $0.url.path() == "/" }
    Checks.expect(after.count == 1 && after.first.map { history.completion(for: "site.ex", among: [$0]) } == "ample.test",
                  "new visits should credit the same front door, which still completes without its www")

    let local = history.suggestions(for: "localhost", limit: 50).filter { $0.url.path() == "/" }
    Checks.expect(local.count == 1 && local.first?.url.absoluteString == "http://localhost:3000/", "a legacy credit should move to the scheme and port its pages used")
    let bare = history.suggestions(for: "bare.example", limit: 50).filter { $0.url.path() == "/" }
    Checks.expect(bare.count == 1 && bare.first?.url.host() == "bare.example.test", "a legacy credit on its pages' own origin should stay")
    let titled = history.suggestions(for: "titled.example", limit: 50).filter { $0.url.path() == "/" }
    Checks.expect(titled.count == 1 && titled.first?.url.host() == "titled.example.test", "a titled front door should never move")
}

@MainActor
private func testCompletionFinishesWWWSitesWithoutTheirWWW() {
    Store.use("www-completion")
    let history = History()
    history.record(url("https://www.apple-test.example/iPhone"), title: "iPhone")
    let options = history.suggestions(for: "apple-t", limit: 3)
    Checks.expect(history.completion(for: "apple-t", among: options) == "est.example", "a www site should complete from its name, as before")
    Checks.expect(history.completion(for: "www.apple-t", among: options) == "est.example", "typing the www should still complete")
    let page = options.filter { $0.url.path() == "/iPhone" }
    Checks.expect(history.completion(for: "apple-test.example/iP", among: page) == "hone", "a www page should complete without its www")
    Checks.expect(history.completion(for: "apple-test.example/ip", among: page) == nil, "completion without the www must still keep the path's case")
    history.record(url("http://www.plain-test.example/"), title: "Plain")
    let plain = history.suggestions(for: "plain-t", limit: 3)
    Checks.expect(history.completion(for: "plain-t", among: plain) == nil, "dropping the www must not turn an http page into https")
}

@main
private struct HistoryRegression {
    @MainActor
    static func main() {
        testRecordAndTakeKeepCanonicalIdentityComponents()
        testRetitleAndForgetUseIndependentIdentities()
        testLegacyLoadRebuildsIdentityFromStoredURL()
        testRootCreditsKeepOriginAndDirectRootCountsOnce()
        testSuggestionIdsAndSafeCaseInsensitiveCompletion()
        testCredentialsNeverReachTheFile()
        testLegacyCreditsMoveToTheOriginTheirPagesUsed()
        testCompletionFinishesWWWSitesWithoutTheirWWW()

        guard Checks.failures.isEmpty else {
            fputs("\(Checks.failures.count) History regression assertion(s) failed.\n", stderr)
            exit(1)
        }
        print("History URL identity regressions passed.")
    }
}
