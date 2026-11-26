import AppKit
import Foundation
import Network
import Security
import os

// Wi-Fi that wants a sign-in first: a café, a hotel, a campus gateway.
//
// macOS's own check (captive.apple.com) can't be relied on: some campus
// gateways let that one name through while holding everything else, so the
// Mac believes it is online. This one asks a name nobody whitelists
// (detectportal.firefox.com) over both https and http, and reads the answer
// the way such gateways behave:
//
//   • plain http on port 80 may be dropped without an answer (a timeout), so
//     a timeout on http says nothing by itself;
//   • https on port 443 may be answered by the gateway itself, with a
//     certificate of its own. A certificate that isn't the site's, on a name
//     that never changes, is the gateway talking: that is the sign.
//
// A page whose certificate fails (Dialogs.trust) asks `confirm()` before the
// person is told "can't prove who it is": behind a gateway that question is
// the wrong one, and the bar at the foot of the window is the right one.

@MainActor
final class CaptivePortal: NSObject, ObservableObject {
    static let shared = CaptivePortal()

    /// Where to sign in, while a sign-in is wanted and the bar has not been
    /// put away. Nil otherwise: that is what hides the bar.
    @Published private(set) var portalURL: URL?

    /// Behind a gateway right now, whether or not the bar is showing (it may
    /// have been put away with ✕). Cleared as soon as a probe gets through.
    private(set) var isBehindPortal = false

    /// The sign-in page to offer when the gateway doesn't say where it is
    /// (https interception gives no redirect). Set by `defaults write`, or
    /// learned from the last sign-in page that was opened from the bar.
    /// Falls back to this fork's campus gateway.
    static let urlKey = "network.captivePortal.url"
    static let fallbackURL = URL(string: "https://example.com/")!

    // MARK: Probe targets

    nonisolated private static let secureProbe = URL(string: "https://example.com/")!
    nonisolated private static let plainProbe = URL(string: "http://example.com/")!
    nonisolated private static let expectedBody = "example domain"

    private static let log = Logger(subsystem: "Search", category: "CaptivePortal")

    // MARK: State

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "CaptivePortal.path")
    private var heartbeat: Task<Void, Never>?
    private var running: Task<Bool, Never>?
    private var lastRun = Date.distantPast
    private var pathUp = true
    private var started = false
    /// Tabs opened from the bar: where one of them lands is the sign-in page
    /// worth remembering.
    private var openedFromBar: Set<UUID> = []

    private override init() { super.init() }

    private var enabled: Bool { Shared.prefs.detectsCaptivePortals }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor [weak self] in self?.pathChanged(up: up) }
        }
        monitor.start(queue: monitorQueue)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkNow() }
        }
        heartbeat = Task { [weak self] in
            // A short wait at the start lets the network come up with the app.
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                guard let self else { return }
                if !NSApp.isActive {
                    try? await Task.sleep(for: .seconds(10))
                    continue
                }
                _ = await self.run(force: true)
                // Quick while a bar is waiting to be answered, so it goes away
                // soon after signing in; slow otherwise, to catch the gateway
                // signing you out mid-session without costing anything.
                let wait: Duration = self.isBehindPortal ? .seconds(4) : .seconds(25)
                try? await Task.sleep(for: wait)
            }
        }
    }

    private func pathChanged(up: Bool) {
        pathUp = up
        if !up {
            // No network at all is not a sign-in; whatever was asked is moot.
            clear()
            return
        }
        // A new network (or the same one coming back) is when a gateway
        // appears. Let the interface settle, then look.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            await self?.run(force: true)
        }
    }

    /// Look again soon — a page failed to load, or one has just opened while
    /// the bar is up. Coalesced: one look at a time, none within 2 seconds of
    /// the last.
    func checkNow() {
        guard enabled else { return }
        Task { [weak self] in _ = await self?.run(force: false) }
    }

    /// For a page whose certificate has failed: is this Mac behind a gateway?
    /// Asks if it has not looked in the last few seconds. False when the
    /// feature is off, so the person gets the ordinary question.
    func confirm() async -> Bool {
        guard enabled, pathUp else { return false }
        if Date().timeIntervalSince(lastRun) < 2 { return isBehindPortal }
        return await run(force: false)
    }

    /// Could a gateway be what put this certificate there? Public names
    /// only: a router, a .local name or a bare hostname on this network
    /// really is its own, and the gateway's own name is where you sign in.
    func mayBeIntercepted(_ host: String) -> Bool {
        let host = host.lowercased()
        guard enabled, host.contains("."), !isPortalHost(host) else { return false }
        // Addresses, of any kind: not names a gateway stands in for.
        if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        for suffix in [".local", ".lan", ".home", ".internal", ".localdomain", ".home.arpa"]
        where host.hasSuffix(suffix) { return false }
        return true
    }

    /// Is this the gateway's own name — the one place a bad certificate must
    /// still get the ordinary question, since that is where the sign-in is?
    func isPortalHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return [portalURL, Self.savedURL, Self.fallbackURL]
            .contains { $0?.host?.lowercased() == host }
    }

    /// The failures a gateway makes: a held connection, a dropped one, a
    /// certificate that isn't the site's. Not "no such page".
    nonisolated static func looksLikeGateway(_ code: Int) -> Bool {
        tlsCodes.contains(code) || [
            NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
        ].contains(code)
    }

    // MARK: Actions

    func openPortal(in browser: Browser) {
        let url = portalURL ?? Self.savedURL ?? Self.fallbackURL
        let tab = browser.open(url, foreground: true)
        openedFromBar.insert(tab.id)
        // Checked again as the page is used; also learned if it proves to be
        // the sign-in (see learn).
        checkNow()
    }

    /// Put the bar away without leaving the gateway: not shown again until a
    /// probe has got through once and the gateway has come back.
    func dismiss() { portalURL = nil }

    /// Online, or no network at all: nothing to sign in to.
    func clear() {
        isBehindPortal = false
        if portalURL != nil { portalURL = nil }
    }

    /// A page committed in a tab. If the bar sent that tab, where it landed
    /// first is the sign-in page to offer next time.
    func learn(from url: URL?, in tabID: UUID) {
        guard openedFromBar.remove(tabID) != nil, let url, url.host != nil,
              url.scheme == "http" || url.scheme == "https" else { return }
        Store.settings.set(url.absoluteString, forKey: Self.urlKey)
    }

    private static var savedURL: URL? {
        Store.settings.string(forKey: urlKey).flatMap(URL.init(string:))
    }

    // MARK: Running a probe

    /// One probe at a time; everyone who asks while one is out gets its
    /// answer. Returns whether this Mac is behind a gateway.
    @discardableResult
    private func run(force: Bool) async -> Bool {
        guard enabled else { clear(); return false }
        guard pathUp else { return false }
        if let running { return await running.value }
        if !force, Date().timeIntervalSince(lastRun) < 2 { return isBehindPortal }

        let task = Task { [weak self] () -> Bool in
            let outcome = await CaptivePortal.probe()
            guard let self else { return false }
            return self.apply(outcome)
        }
        running = task
        let behind = await task.value
        running = nil
        lastRun = Date()
        return behind
    }

    private func apply(_ outcome: Outcome) -> Bool {
        switch outcome {
        case .online:
            Self.log.debug("probe: online")
            clear()
            return false
        case .unreachable:
            // Nothing answered either way: a dead network, not a gateway.
            // What was known stays as it is rather than flickering.
            Self.log.debug("probe: unreachable")
            return isBehindPortal
        case .portal(let found, let why):
            Self.log.debug("probe: portal (\(why, privacy: .public))")
            let wasBehind = isBehindPortal
            isBehindPortal = true
            // Where the gateway pointed, else what was learned or set, else
            // the built-in. Only brought back up when the gateway is new to
            // us: ✕ stays put until a probe has got through in between.
            if !wasBehind || portalURL != nil {
                portalURL = found ?? Self.savedURL ?? Self.fallbackURL
            }
            return true
        }
    }

    // MARK: The probe itself

    enum Outcome: Sendable {
        case online
        case portal(URL?, why: String)
        case unreachable
    }

    private enum Leg: Sendable {
        case clear                      // the real answer came back
        case redirected(URL?)           // sent somewhere else
        case wrongAnswer                // an answer, but not that file
        case intercepted                // a certificate that isn't the site's
        case silent                     // timeout, refused, no route
    }

    nonisolated private static func probe() async -> Outcome {
        async let secure = leg(secureProbe)
        async let plain = leg(plainProbe)
        let https = await secure
        switch https {
        case .clear:
            return .online
        case .intercepted:
            return .portal(nil, why: "https certificate isn't the site's")
        case .redirected(let url):
            return .portal(url, why: "https redirected")
        case .wrongAnswer:
            return .portal(nil, why: "https answered with something else")
        case .silent:
            break
        }
        // https said nothing. http may have: a redirect or another page is a
        // gateway; the real file is a network that only blocks 443 (not ours
        // to call a sign-in); a timeout says nothing at all.
        switch await plain {
        case .clear:
            return .online
        case .redirected(let url):
            return .portal(url, why: "http redirected")
        case .wrongAnswer:
            return .portal(nil, why: "http answered with something else")
        case .intercepted, .silent:
            return .unreachable
        }
    }

    nonisolated private static func leg(_ url: URL) async -> Leg {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let watcher = LegWatcher()
        var request = URLRequest(url: url)
        request.setValue("Search/captive-probe", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request, delegate: watcher)
            if let redirect = watcher.redirect { return .redirected(redirect) }
            guard let http = response as? HTTPURLResponse else { return .wrongAnswer }
            let body = String(decoding: data.prefix(2048), as: UTF8.self)
            if http.statusCode == 200, body.lowercased().contains(expectedBody) {
                return .clear
            }
            // A server error or a missing file from the probe's own host is that
            // host having a bad moment, not a gateway.
            return http.statusCode == 200 ? .wrongAnswer : .silent
        } catch {
            if let redirect = watcher.redirect { return .redirected(redirect) }
            let code = (error as NSError).code
            if watcher.untrusted || tlsCodes.contains(code) {
                return .intercepted
            }
            return .silent
        }
    }

    /// The ways URLSession says a certificate isn't right.
    nonisolated static let tlsCodes: Set<Int> = [
        NSURLErrorSecureConnectionFailed,
        NSURLErrorServerCertificateHasBadDate,
        NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasUnknownRoot,
        NSURLErrorServerCertificateNotYetValid,
        NSURLErrorClientCertificateRejected,
        NSURLErrorClientCertificateRequired,
    ]
}

/// Watches one probe request: stops at a redirect, and notes a certificate
/// that fails (the connection is then refused by the system's default
/// handling, as for any page).
private final class LegWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _redirect: URL?
    private var _untrusted = false

    var redirect: URL? { lock.withLock { _redirect } }
    var untrusted: Bool { lock.withLock { _untrusted } }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // A redirect to the same name (http to https, say) is the site's own
        // tidying: followed. To anywhere else is a gateway sending you to
        // sign in: noted, and not followed.
        let from = task.originalRequest?.url?.host?.lowercased()
        if let to = request.url, let host = to.host?.lowercased(), host == from {
            completionHandler(request)
            return
        }
        if let to = request.url { lock.withLock { _redirect = to } }
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if !SecTrustEvaluateWithError(trust, nil) {
            lock.withLock { _untrusted = true }
        }
        // Default handling still refuses it: nothing is ever sent to it.
        completionHandler(.performDefaultHandling, nil)
    }
}
