import AppKit
import Network
import WebKit

// A site whose name couldn't be looked up is, as often as not, a site that
// is there: the Mac's resolver had a bad moment, the Wi-Fi was changing, a
// VPN was coming up. Chrome loads the page again by itself when that
// happens; Search said "No site at that address." and waited (idea 1284).
//
// So a page that failed only on its lookup is asked for again, a little
// later each time (1 s, 3 s, 8 s), while its tab is in sight, and at once
// when the Mac's network changes or comes back. A tab out of sight waits
// until it is looked at. It stops at the first page that arrives, once the
// tries are used up, or as you go somewhere else. Nothing that would send
// something again is retried — a form, a POST — nor an address that was
// only ever a guess at what you typed (see DNSRetryPolicy.mayRetry).

/// What decides, with nothing of a tab or WebKit in it, for the tests.
enum DNSRetryPolicy {
    /// The waits before each try, the first after one second.
    static let delays: [TimeInterval] = [1, 3, 8]

    /// What the page says while it is trying again, and once it has stopped.
    /// The second line is a hint, drawn smaller (see Trouble).
    static let trying = "Couldn't find this site. Trying again…"
    static let gaveUp = "Couldn't find this site.\nCheck the address or your connection."

    /// The site's name couldn't be looked up: WebKit's -1003 and -1006.
    static func isLookupFailure(_ code: Int) -> Bool {
        code == NSURLErrorCannotFindHost || code == NSURLErrorDNSLookupFailed
    }

    /// The wait before the next try, when `done` have been made; nil once
    /// they are used up.
    static func delay(after done: Int) -> TimeInterval? {
        delays.indices.contains(done) ? delays[done] : nil
    }

    /// Whether a page that failed on its lookup may be asked for again by
    /// itself. Only a plain GET of a web address, never a form sent or sent
    /// again, whatever its method: asking again would send it again. Not a
    /// name with no dot in it, which the field never takes for a site
    /// (Address.looksLikeHost) and only reaches as a link to a machine on
    /// some network. And not an address typed without a scheme that you
    /// didn't pick from the list or have finished for you (`guessed`), to a
    /// site you have never been to (`known`): "gogle.cmo" is a typo, not a
    /// site that is down.
    static func mayRetry(_ url: URL, method: String?, form: Bool, guessed: Bool, known: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host()?.lowercased(),
              host.split(separator: ".", omittingEmptySubsequences: false).filter({ !$0.isEmpty }).count >= 2
        else { return false }
        let method = (method ?? "GET").uppercased()
        guard method == "GET" || method == "HEAD", !form else { return false }
        return !guessed || known
    }
}

/// A tab's tries at a page that failed on its lookup. One per tab, made
/// when first needed.
@MainActor
final class DNSRetry {
    private weak var tab: Tab?
    /// The page being tried, and how many tries it has had (still read
    /// after the tries end, for the bench).
    private(set) var url: URL?
    private(set) var done = 0
    /// Whether this page may be tried at all, judged when it first failed.
    private var eligible = false
    /// The try waiting for its time to come.
    private var timer: DispatchWorkItem?
    /// Out of sight when its time came: it goes as the tab is looked at.
    private(set) var waitingForSight = false
    /// The last page the tab's own frame was let go to, and how.
    private var asked: (url: URL, method: String?, form: Bool)?
    /// An address typed without a scheme, sent as the field guessed it.
    private var guessed: URL?

    /// Every tab's, for a network change and a view coming into sight.
    private static let all = NSHashTable<DNSRetry>.weakObjects()

    init(tab: Tab) { self.tab = tab }

    /// Whether the try in hand is still under way: waiting for its time or
    /// for the tab to be looked at.
    var pending: Bool { timer != nil || waitingForSight }

    // MARK: what the browser tells it

    /// A page the tab's frame is going to (Browser's policy answer). Going
    /// anywhere but the page being tried ends the tries.
    func going(to url: URL, method: String?, form: Bool) {
        asked = (url, method, form)
        if let guessed, guessed.host()?.lowercased() != url.host()?.lowercased() { self.guessed = nil }
        if let tried = self.url, !Self.same(tried, url) { stop() }
    }

    /// The field sent the tab to an address it made from what was typed.
    func typedGuess(_ url: URL) { guessed = url }

    /// The page at `url` failed on its lookup. What the page should say.
    func failed(_ url: URL, known: (String) -> Bool) -> String {
        if let tried = self.url, Self.same(tried, url) {
            // The same page again: a try that didn't work, or Try again.
        } else {
            stop()
            self.url = url
            done = 0
            let ask = asked.flatMap { Self.same($0.url, url) ? $0 : nil }
            let guess = guessed.map { $0.host()?.lowercased() == url.host()?.lowercased() } ?? false
            eligible = DNSRetryPolicy.mayRetry(url, method: ask?.method, form: ask?.form ?? false,
                                               guessed: guess, known: guess ? known(url.host()?.lowercased() ?? "") : true)
        }
        cancelTimer()
        nextWait = eligible ? DNSRetryPolicy.delay(after: done) : nil
        guard let wait = nextWait else {
            waitingForSight = false
            Self.all.remove(self)
            return DNSRetryPolicy.gaveUp
        }
        Self.all.add(self)
        DNSRetry.watchNetwork()
        if inSight {
            let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.fire() } }
            timer = item
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
        } else {
            waitingForSight = true
        }
        return DNSRetryPolicy.trying
    }

    /// Nothing more to try: a page came, or the tab went elsewhere.
    func stop() {
        cancelTimer()
        waitingForSight = false
        nextWait = nil
        url = nil
        eligible = false
        Self.all.remove(self)
    }

    // MARK: trying

    /// Whether the tab's page is in a window that shows (LoadTurns), and
    /// how a try is made; the tests put their own in.
    var sight: (Tab) -> Bool = { tab in tab.built.map(LoadTurns.inSight) ?? false }
    var load: (Tab) -> Void = { $0.reload() }
    /// The wait the last failure was given before its next try, nil when
    /// none is to come.
    private(set) var nextWait: TimeInterval?

    private var inSight: Bool { tab.map(sight) ?? false }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    /// The time has come, the tab was looked at, or the network changed.
    func fire() {
        // Only a try that was waiting: not one given up, nor one made.
        guard pending else { return }
        cancelTimer()
        guard let tab, let url, tab.failure != nil, let at = tab.failedAt, Self.same(at, url) else {
            stop()
            return
        }
        guard inSight else {
            waitingForSight = true
            return
        }
        waitingForSight = false
        done += 1
        load(tab)
    }

    /// The view came into sight: a try waiting for that goes now.
    static func shown(_ view: PageView) {
        for retry in all.allObjects where retry.waitingForSight && retry.tab?.built === view {
            retry.fire()
        }
    }

    /// The Mac's network changed or came back: every try waiting for its
    /// time, in sight, goes now.
    static func networkChanged() {
        for retry in all.allObjects where retry.timer != nil && retry.inSight {
            retry.fire()
        }
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        a.absoluteString == b.absoluteString
    }

    // MARK: the network

    private static var monitor: NWPathMonitor?
    private static var lastPath: String?

    /// Started with the first page to try, and left running: one monitor.
    private static func watchNetwork() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { path in
            let shape = "\(path.status == .satisfied)|" + path.availableInterfaces.map(\.name).joined(separator: ",")
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // The first answer is how things are, not a change.
                    defer { lastPath = shape }
                    guard let last = lastPath, last != shape, satisfied else { return }
                    networkChanged()
                }
            }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    // MARK: tests

    /// Test runs only: hosts whose next loads fail on their lookup, as if
    /// the Mac's resolver had failed, and how many of them.
    static var testFailures: [String: Int] = [:]

    /// Whether a load of `url` should fail as if its lookup had (test runs).
    static func failsForTest(_ url: URL) -> Bool {
        guard Store.testing, let host = url.host()?.lowercased(), let left = testFailures[host], left > 0 else { return false }
        testFailures[host] = left - 1
        return true
    }
}
