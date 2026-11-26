import AppKit
import XCTest
import WebKit
@testable import Search

/// A site that couldn't be found is tried again by itself, as Chrome does
/// (idea 1284): after 1, 3 and 8 seconds while its tab is in sight, never
/// for a form or a POST, never for an address that was only a guess at
/// what was typed, and no more once you go elsewhere.
@MainActor
final class DNSRetryTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private let site = URL(string: "https://slackmojis.com/")!

    // MARK: the policy

    func testBacksOffOneThreeEightThenStops() {
        XCTAssertEqual(DNSRetryPolicy.delays, [1, 3, 8])
        XCTAssertEqual(DNSRetryPolicy.delay(after: 0), 1)
        XCTAssertEqual(DNSRetryPolicy.delay(after: 1), 3)
        XCTAssertEqual(DNSRetryPolicy.delay(after: 2), 8)
        XCTAssertNil(DNSRetryPolicy.delay(after: 3))
        XCTAssertNil(DNSRetryPolicy.delay(after: 10))
    }

    func testOnlyLookupFailuresCount() {
        XCTAssertTrue(DNSRetryPolicy.isLookupFailure(NSURLErrorCannotFindHost))
        XCTAssertTrue(DNSRetryPolicy.isLookupFailure(NSURLErrorDNSLookupFailed))
        XCTAssertFalse(DNSRetryPolicy.isLookupFailure(NSURLErrorTimedOut))
        XCTAssertFalse(DNSRetryPolicy.isLookupFailure(NSURLErrorCannotConnectToHost))
        XCTAssertFalse(DNSRetryPolicy.isLookupFailure(NSURLErrorCancelled))
    }

    func testAPlainGetOfAWebAddressIsRetried() {
        XCTAssertTrue(DNSRetryPolicy.mayRetry(site, method: "GET", form: false, guessed: false, known: false))
        XCTAssertTrue(DNSRetryPolicy.mayRetry(site, method: nil, form: false, guessed: false, known: false))
        XCTAssertTrue(DNSRetryPolicy.mayRetry(URL(string: "http://a.b.example.org/x?y")!, method: "get", form: false, guessed: false, known: false))
    }

    func testPostAndFormsAreNeverRetried() {
        XCTAssertFalse(DNSRetryPolicy.mayRetry(site, method: "POST", form: false, guessed: false, known: true))
        XCTAssertFalse(DNSRetryPolicy.mayRetry(site, method: "PUT", form: false, guessed: false, known: true))
        // A GET form sent, or sent again, is still a form.
        XCTAssertFalse(DNSRetryPolicy.mayRetry(site, method: "GET", form: true, guessed: false, known: true))
    }

    func testTyposAndNamesWithNoDotAreNotRetried() {
        // No dot: never a site the field takes, a machine's name on some network.
        XCTAssertFalse(DNSRetryPolicy.mayRetry(URL(string: "http://intranet/")!, method: "GET", form: false, guessed: false, known: true))
        XCTAssertFalse(DNSRetryPolicy.mayRetry(URL(string: "http://intranet./")!, method: "GET", form: false, guessed: false, known: true))
        // Typed with no scheme to a site never visited: a typo, most likely.
        XCTAssertFalse(DNSRetryPolicy.mayRetry(URL(string: "https://gogle.cmo/")!, method: "GET", form: false, guessed: true, known: false))
        // The same guess at a site you've been to is worth another go.
        XCTAssertTrue(DNSRetryPolicy.mayRetry(site, method: "GET", form: false, guessed: true, known: true))
        // Not the web.
        XCTAssertFalse(DNSRetryPolicy.mayRetry(URL(string: "ftp://files.example.com/")!, method: "GET", form: false, guessed: false, known: true))
    }

    func testWordingNoLongerSaysTheSiteDoesNotExist() {
        XCTAssertEqual(DNSRetryPolicy.trying, "Couldn't find this site. Trying again…")
        XCTAssertTrue(DNSRetryPolicy.gaveUp.hasPrefix("Couldn't find this site.\n"))
        XCTAssertTrue(DNSRetryPolicy.gaveUp.contains("Check the address or your connection."))
        XCTAssertFalse(DNSRetryPolicy.gaveUp.contains("No site"))
    }

    // MARK: a tab's tries

    private func tab(inSight: Bool = true) -> (Tab, DNSRetry, Counter) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: true, configuration: configuration)
        let retry = tab.dnsRetry
        let counter = Counter()
        retry.sight = { _ in counter.inSight }
        counter.inSight = inSight
        retry.load = { _ in counter.loads += 1 }
        return (tab, retry, counter)
    }

    final class Counter { var loads = 0; var inSight = true }

    /// What Browser.fail does with a lookup failure.
    private func fail(_ tab: Tab, _ url: URL, known: Bool = false) {
        tab.failed(at: url)
        tab.failure = tab.dnsRetry.failed(url) { _ in known }
    }

    func testTriesThreeTimesWithBackoffThenGivesUp() {
        let (tab, retry, counter) = tab()
        retry.going(to: site, method: "GET", form: false)
        fail(tab, site)
        XCTAssertEqual(tab.failure, DNSRetryPolicy.trying)
        XCTAssertEqual(retry.nextWait, 1)
        XCTAssertTrue(retry.pending)
        for (n, wait) in [(1, 3.0), (2, 8.0)] {
            retry.fire()
            XCTAssertEqual(counter.loads, n)
            retry.going(to: site, method: "GET", form: false)   // the try itself
            fail(tab, site)
            XCTAssertEqual(tab.failure, DNSRetryPolicy.trying)
            XCTAssertEqual(retry.nextWait, wait)
        }
        retry.fire()
        XCTAssertEqual(counter.loads, 3)
        fail(tab, site)
        XCTAssertEqual(tab.failure, DNSRetryPolicy.gaveUp)
        XCTAssertNil(retry.nextWait)
        XCTAssertFalse(retry.pending)
        XCTAssertEqual(retry.done, 3)
    }

    func testAPageThatArrivesEndsTheTries() {
        let (tab, retry, counter) = tab()
        fail(tab, site)
        XCTAssertTrue(retry.pending)
        tab.failure = nil   // the page came (Browser's didCommit)
        XCTAssertFalse(retry.pending)
        retry.fire()
        XCTAssertEqual(counter.loads, 0)
    }

    func testGoingElsewhereEndsTheTries() {
        let (tab, retry, counter) = tab()
        fail(tab, site)
        retry.going(to: URL(string: "https://example.com/")!, method: "GET", form: false)
        XCTAssertFalse(retry.pending)
        retry.fire()
        XCTAssertEqual(counter.loads, 0)
    }

    func testAPostIsNotTried() {
        let (tab, retry, counter) = tab()
        retry.going(to: site, method: "POST", form: true)
        fail(tab, site)
        XCTAssertEqual(tab.failure, DNSRetryPolicy.gaveUp)
        XCTAssertFalse(retry.pending)
        retry.fire()
        XCTAssertEqual(counter.loads, 0)
    }

    func testATypedGuessIsTriedOnlyForASiteYouKnow() {
        let typo = URL(string: "https://gogle.cmo/")!
        let (tab, retry, _) = tab()
        retry.typedGuess(typo)
        retry.going(to: typo, method: "GET", form: false)
        fail(tab, typo, known: false)
        XCTAssertEqual(tab.failure, DNSRetryPolicy.gaveUp)

        let (known, knownRetry, _) = self.tab()
        knownRetry.typedGuess(site)
        knownRetry.going(to: site, method: "GET", form: false)
        fail(known, site, known: true)
        XCTAssertEqual(known.failure, DNSRetryPolicy.trying)
    }

    func testABackgroundTabWaitsToBeLookedAt() {
        let (tab, retry, counter) = tab(inSight: false)
        fail(tab, site)
        XCTAssertEqual(tab.failure, DNSRetryPolicy.trying)
        XCTAssertTrue(retry.waitingForSight)
        retry.fire()   // the time came, nobody looking
        XCTAssertEqual(counter.loads, 0)
        XCTAssertTrue(retry.waitingForSight)
        counter.inSight = true
        retry.fire()   // looked at (DNSRetry.shown)
        XCTAssertEqual(counter.loads, 1)
        XCTAssertFalse(retry.waitingForSight)
    }

    func testANetworkChangeTriesAtOnce() {
        let (tab, retry, counter) = tab()
        fail(tab, site)
        XCTAssertEqual(counter.loads, 0)
        DNSRetry.networkChanged()
        XCTAssertEqual(counter.loads, 1)
        XCTAssertFalse(retry.pending)
    }

    func testTheTimerFiresByItself() {
        let (tab, _, counter) = tab()
        fail(tab, site)
        let tried = expectation(description: "tried after a second")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            XCTAssertEqual(counter.loads, 1)
            tried.fulfill()
        }
        wait(for: [tried], timeout: 3)
    }
}
