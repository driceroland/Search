import XCTest
@testable import Search

/// News by email (OptIn.swift): what is remembered, when the card offers the
/// field, and that a press sends the email, the source and the build, and
/// nothing else. No window, no network: a settings suite of its own, and
/// requests answered by a stand-in for the site.
@MainActor
final class OptInTests: XCTestCase {
    private var store: UserDefaults!
    private let suite = "com.officecommun.search.optin-tests-\(getpid())"

    override func setUp() {
        super.setUp()
        store = UserDefaults(suiteName: suite)
        store.removePersistentDomain(forName: suite)
        Site.reset()
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: - flags

    func testOfferedUntilAnEmailIsGiven() {
        XCTAssertTrue(OptIn.offered(store), "nothing given: offered")
        XCTAssertFalse(OptIn.joined(store))
        XCTAssertFalse(OptIn.askedBeta(store))
    }

    func testClosingWithoutOneOffersItAgainNextVersion() {
        // A card shown and closed writes nothing: the next one offers again.
        XCTAssertTrue(OptIn.offered(store))
        XCTAssertTrue(OptIn.offered(store), "still offered on the next version's card")
        XCTAssertTrue(store.dictionaryRepresentation().keys.filter { $0.hasPrefix("optin.") }.isEmpty)
    }

    func testGivenHidesItOnLaterCards() {
        OptIn.remember(.news(iPhoneBeta: false), in: store)
        XCTAssertTrue(OptIn.joined(store))
        XCTAssertFalse(OptIn.askedBeta(store))
        XCTAssertFalse(OptIn.offered(store))
    }

    func testTickedBetaRemembersBoth() {
        OptIn.remember(.news(iPhoneBeta: true), in: store)
        XCTAssertTrue(OptIn.joined(store))
        XCTAssertTrue(OptIn.askedBeta(store))
    }

    func testBetaAloneLeavesTheCardOffering() {
        OptIn.remember(.iPhoneBeta, in: store)
        XCTAssertTrue(OptIn.askedBeta(store))
        XCTAssertFalse(OptIn.joined(store))
        XCTAssertTrue(OptIn.offered(store), "the iPhone beta from Settings isn't the updates list")
    }

    func testOnlyBooleansAreStored() {
        OptIn.remember(.news(iPhoneBeta: true), in: store)
        let kept = store.persistentDomain(forName: suite) ?? [:]
        XCTAssertEqual(Set(kept.keys), [OptIn.joinedKey, OptIn.betaKey])
        for value in kept.values { XCTAssertTrue(value is Bool || value is NSNumber, "\(value)") }
    }

    // MARK: - the request

    func testNewsBodyIsEmailSourceArchOnly() throws {
        let request = OptIn.request(email: "test+a@example.com", list: .news(iPhoneBeta: false), source: .whatsNew,
                                    base: URL(string: "https://searchbrowser.app/api/")!)
        XCTAssertEqual(request.url?.absoluteString, "https://searchbrowser.app/api/mac-list")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["email", "source", "arch"])
        XCTAssertEqual(body["email"] as? String, "test+a@example.com")
        XCTAssertEqual(body["source"] as? String, "app-whats-new")
        XCTAssertTrue(["apple", "intel"].contains(body["arch"] as? String ?? ""))
    }

    func testTickedBetaAddsOnlyTheTick() throws {
        let request = OptIn.request(email: "test+b@example.com", list: .news(iPhoneBeta: true), source: .welcome)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["email", "source", "arch", "ios_beta"])
        XCTAssertEqual(body["ios_beta"] as? Bool, true)
        XCTAssertEqual(body["source"] as? String, "app-welcome")
    }

    func testBetaAloneGoesToIOSBetaWithEmailAndSource() throws {
        let request = OptIn.request(email: "test+c@example.com", list: .iPhoneBeta, source: .settings,
                                    base: URL(string: "https://searchbrowser.app/api/")!)
        XCTAssertEqual(request.url?.absoluteString, "https://searchbrowser.app/api/ios-beta")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["email", "source"])
        XCTAssertEqual(body["source"] as? String, "app-settings")
    }

    func testHeadersCarryNoVersionOrLanguage() {
        let request = OptIn.request(email: "test+d@example.com", list: .news(iPhoneBeta: false), source: .settings)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "en")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(OptIn.session.configuration.httpCookieStorage)
        XCTAssertNil(OptIn.session.configuration.urlCache)
    }

    func testSourcesFitTheSitesRule() {
        for source in OptIn.Source.allCases {
            XCTAssertNotNil(source.rawValue.range(of: #"^[a-z0-9/#._-]{1,64}$"#, options: [.regularExpression, .caseInsensitive]))
        }
    }

    func testEmailIsCheckedBeforeSending() {
        XCTAssertEqual(OptIn.cleaned("  Test+E@Example.COM "), "test+e@example.com")
        XCTAssertNil(OptIn.cleaned("not an email"))
        XCTAssertNil(OptIn.cleaned("a@b"))
        XCTAssertNil(OptIn.cleaned(""))
    }

    // MARK: - sending, against a stand-in

    private func send(_ email: String, _ list: OptIn.List, status: Int) -> Result<Void, OptIn.Failure> {
        Site.status = status
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Site.self]
        let session = URLSession(configuration: config)
        let done = expectation(description: "answered")
        var outcome: Result<Void, OptIn.Failure>?
        OptIn.send(email: email, list: list, source: .whatsNew, base: URL(string: "https://optin.test/api/")!, session: session) {
            outcome = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return outcome ?? .failure(.unreachable)
    }

    private static func failure(_ outcome: Result<Void, OptIn.Failure>) -> OptIn.Failure? {
        if case .failure(let f) = outcome { return f } else { return nil }
    }

    func testOneRequestPerPressWithTheBodyOnly() throws {
        let outcome = send("test+f@example.com", .news(iPhoneBeta: true), status: 200)
        XCTAssertNoThrow(try outcome.get())
        XCTAssertEqual(Site.seen.count, 1, "one press, one request")
        let seen = try XCTUnwrap(Site.seen.first)
        XCTAssertEqual(seen.url, "https://optin.test/api/mac-list")
        XCTAssertEqual(Set(seen.body.keys), ["email", "source", "arch", "ios_beta"])
        XCTAssertNil(seen.headers["Cookie"])
    }

    func testFailuresAreNotRetried() {
        XCTAssertEqual(Self.failure(send("test+g@example.com", .news(iPhoneBeta: false), status: 500)), .unreachable)
        XCTAssertEqual(Site.seen.count, 1, "no retry")
        XCTAssertEqual(Self.failure(send("test+g@example.com", .news(iPhoneBeta: false), status: 400)), .notAnEmail)
        XCTAssertEqual(Self.failure(send("test+g@example.com", .news(iPhoneBeta: false), status: 429)), .tooMany)
        XCTAssertEqual(Site.seen.count, 3)
    }

    func testABadAddressSendsNothing() {
        XCTAssertEqual(Self.failure(send("nope", .news(iPhoneBeta: false), status: 200)), .notAnEmail)
        XCTAssertTrue(Site.seen.isEmpty)
    }

    func testFailureLeavesNothingRemembered() {
        _ = send("test+h@example.com", .news(iPhoneBeta: true), status: 503)
        XCTAssertTrue(OptIn.offered(store))
    }
}

/// The site, as far as these tests go: it notes what came and answers with
/// the status it is given.
private final class Site: URLProtocol {
    struct Seen { let url: String; let body: [String: Any]; let headers: [String: String] }
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var seen: [Seen] = []
    static func reset() { status = 200; seen = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        Site.seen.append(Seen(url: request.url?.absoluteString ?? "", body: body, headers: request.allHTTPHeaderFields ?? [:]))
        let response = HTTPURLResponse(url: request.url!, statusCode: Site.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
