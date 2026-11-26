import Foundation
import JavaScriptCore
import Network
import WebKit

// chrome.proxy.settings, acted on.
//
// An extension that sets the browser's proxy (Tailchrome, a VPN's, a
// proxy switcher) used to have the value kept and read back as its own, and
// nothing else: every page went straight out. Tailchrome's worse than that —
// it waits for a request through its helper to be challenged with a 407 and
// answered by its own webRequest.onAuthRequired, and with no request ever
// reaching the helper it sat at "Preparing helper authentication" for good.
//
// WebKit takes a proxy per data store, and only an HTTP CONNECT or SOCKS5
// one with a fixed address: no PAC script, no rules per host. So when an
// extension is in control, every store and every session Search makes is
// pointed at a relay on this Mac (127.0.0.1, a port of the system's
// choosing), and the relay reads the extension's rules for each connection
// — its PAC script, or its fixed_servers and bypass list — and goes out
// directly, through an HTTP proxy with CONNECT, or through a SOCKS5 one, as
// they say. A proxy that asks for a sign-in (407) is answered by the
// extension's own onAuthRequired listeners, over a native port its worker
// opens (search.proxyauth), as Chrome asks them.
//
// The proxy set in Settings › Privacy wins over an extension's: someone who
// typed one in asked for it, and the extension is told the setting is
// "not_controllable", as Chrome tells it when a policy holds the proxy.
// Among extensions, the last installed of those that set one is in control,
// as in Chrome. This Mac's own names (localhost, 127.0.0.1) stay direct,
// as Chrome keeps them.
//
// The relay is a way into whatever the extension's proxy reaches, already
// signed in, and 127.0.0.1 is open to every app on this Mac. So WebKit signs
// in to it with a secret made at each launch, and anything else is turned
// away; a private tab's store has a secret of its own, so the relay knows
// which requests came from one. Private tabs go through an extension's
// proxy only when that extension is let into them, as in Chrome. While the
// relay isn't listening (at launch, or if it can't), stores are pointed at
// a port that refuses: a VPN's rules are never gone around.

/// One way out for a connection, as a PAC result or fixed_servers names it.
enum ProxyRoute: Equatable {
    case direct
    case http(String, UInt16)
    case socks5(String, UInt16)

    /// A PAC script's answer: "PROXY a:1; SOCKS5 b:2; DIRECT". Entries
    /// Search can't follow (HTTPS, QUIC, SOCKS4 proxies) are left out, so the
    /// next one is tried as Chrome tries the next when one fails. An answer
    /// with nothing usable in it is no way out at all, not direct: a script
    /// that only names a proxy meant everything to go through one.
    static func parse(pac answer: String) -> [ProxyRoute] {
        answer.split(separator: ";").compactMap { item -> ProxyRoute? in
            let words = item.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let kind = words.first?.uppercased() else { return nil }
            if kind == "DIRECT" { return .direct }
            guard words.count >= 2, let (host, port) = hostPort(words[1], defaultPort: kind.hasPrefix("SOCKS") ? 1080 : 80)
            else { return nil }
            switch kind {
            case "PROXY", "HTTP": return .http(host, port)
            case "SOCKS", "SOCKS5": return .socks5(host, port)
            default: return nil
            }
        }
    }

    /// "host:port", "[::1]:8080" or a bare host.
    static func hostPort(_ text: String, defaultPort: UInt16) -> (String, UInt16)? {
        var host = text, port = defaultPort
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return nil }
            let rest = host[host.index(after: close)...]
            if rest.hasPrefix(":") { guard let p = UInt16(rest.dropFirst()), p > 0 else { return nil }; port = p }
            else if !rest.isEmpty { return nil }
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if let colon = host.lastIndex(of: ":"), host.firstIndex(of: ":") == colon {
            guard let p = UInt16(host[host.index(after: colon)...]), p > 0 else { return nil }
            port = p
            host = String(host[..<colon])
        }
        guard !host.isEmpty else { return nil }
        return (host, port)
    }

    /// "host", "host:8080" or "[::1]:8080": the port left out when it is
    /// the one the scheme implies.
    static func authority(_ host: String, _ port: UInt16, implied: UInt16? = nil) -> String {
        (host.contains(":") ? "[\(host)]" : host) + (port == implied ? "" : ":\(port)")
    }
}

/// What an extension set with chrome.proxy.settings.set, read once when it
/// is set. Nil for "system" (Search's own settings apply) and for a value
/// that can't be followed.
struct ExtensionProxyRules: @unchecked Sendable {
    enum Kind {
        case direct
        case fixed(single: ProxyRoute?, http: ProxyRoute?, https: ProxyRoute?, fallback: ProxyRoute?, bypass: [String])
        case pac(PACScript)
    }

    let kind: Kind
    /// A PAC script that fails stops everything, rather than going direct.
    let mandatory: Bool

    /// Why a value is refused, for chrome.runtime.lastError.
    struct Refused: Error, LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    /// Throws for a value Search can't act on, so the extension hears so at
    /// once instead of believing it is in control; nil for "system".
    static func read(_ value: Any?) throws -> ExtensionProxyRules? {
        guard let value = value as? [String: Any] else { return nil }
        switch value["mode"] as? String ?? "" {
        case "system", "auto_detect":
            return nil
        case "direct":
            return ExtensionProxyRules(kind: .direct, mandatory: false)
        case "fixed_servers":
            let rules = value["rules"] as? [String: Any] ?? [:]
            func server(_ key: String) -> ProxyRoute? {
                guard let entry = rules[key] as? [String: Any], let host = entry["host"] as? String, !host.isEmpty else { return nil }
                let scheme = (entry["scheme"] as? String ?? "http").lowercased()
                let port = (entry["port"] as? NSNumber)?.intValue
                switch scheme {
                case "http": return .http(host, UInt16(clamping: port ?? 80))
                case "socks5": return .socks5(host, UInt16(clamping: port ?? 1080))
                default: return nil
                }
            }
            let named = ["singleProxy", "proxyForHttp", "proxyForHttps", "fallbackProxy"].filter { rules[$0] != nil }
            let single = server("singleProxy"), http = server("proxyForHttp"), https = server("proxyForHttps"), fallback = server("fallbackProxy")
            if named.isEmpty || [single, http, https, fallback].allSatisfy({ $0 == nil }) {
                throw Refused(why: "Search can use an HTTP or SOCKS5 proxy, and none was given.")
            }
            let bypass = (rules["bypassList"] as? [Any] ?? []).compactMap { $0 as? String }
            return ExtensionProxyRules(kind: .fixed(single: single, http: http, https: https, fallback: fallback, bypass: bypass), mandatory: false)
        case "pac_script":
            let pac = value["pacScript"] as? [String: Any] ?? [:]
            var data = pac["data"] as? String
            if data == nil, let address = pac["url"] as? String, address.hasPrefix("data:"),
               let url = URL(string: address), let bytes = try? Data(contentsOf: url) {
                data = String(data: bytes, encoding: .utf8)
            }
            guard let script = data, !script.isEmpty else {
                throw Refused(why: "Search runs a PAC script given as pacScript.data; one at a web address isn't fetched.")
            }
            return ExtensionProxyRules(kind: .pac(PACScript(script)), mandatory: pac["mandatory"] as? Bool ?? false)
        default:
            throw Refused(why: "Unknown proxy mode.")
        }
    }

    /// The ways out for one connection, in the order to try them. `url` is
    /// what Chrome hands a PAC script: for https, the scheme and host alone.
    func routes(url: String, host: String) async -> [ProxyRoute] {
        switch kind {
        case .direct:
            return [.direct]
        case .fixed(let single, let http, let https, let fallback, let bypass):
            if Self.bypassed(host, by: bypass) { return [.direct] }
            let secure = url.lowercased().hasPrefix("https:")
            let chosen = single ?? (secure ? https : http) ?? fallback
            return [chosen ?? .direct]
        case .pac(let script):
            guard let answer = await script.find(url: url, host: host) else {
                return mandatory ? [] : [.direct]
            }
            return ProxyRoute.parse(pac: answer)
        }
    }

    /// A fixed_servers bypass list: "<local>" for plain names, a CIDR block,
    /// or a host with * wildcards ("*.example.com", "example.com"); a scheme
    /// or port on an entry is ignored rather than making it match nothing.
    static func bypassed(_ rawHost: String, by list: [String]) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        for raw in list {
            var entry = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if entry == "<local>" { if !host.contains(".") && !host.contains(":") { return true }; continue }
            if entry == "<-loopback>" { continue }
            if let scheme = entry.range(of: "://") { entry = String(entry[scheme.upperBound...]) }
            if entry.contains("/"), let block = CIDR(entry) { if block.contains(host) { return true }; continue }
            if let colon = entry.lastIndex(of: ":"), entry.firstIndex(of: ":") == colon { entry = String(entry[..<colon]) }
            entry = entry.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if entry.hasPrefix(".") { entry = "*" + entry }
            if PACScript.glob(entry, host) { return true }
            // "*.example.com" leaves out example.com itself in a glob; Chrome
            // counts the domain too.
            if entry.hasPrefix("*."), host == String(entry.dropFirst(2)) { return true }
        }
        return false
    }

    /// An address block, v4 or v6.
    struct CIDR {
        let bytes: [UInt8]
        let bits: Int

        init?(_ text: String) {
            let parts = text.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let bits = Int(parts[1]), let bytes = CIDR.address(parts[0]) else { return nil }
            guard bits >= 0, bits <= bytes.count * 8 else { return nil }
            self.bytes = bytes
            self.bits = bits
        }

        static func address(_ text: String) -> [UInt8]? {
            let bare = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            var v4 = in_addr()
            if inet_pton(AF_INET, bare, &v4) == 1 { return withUnsafeBytes(of: v4) { Array($0) } }
            var v6 = in6_addr()
            if inet_pton(AF_INET6, bare, &v6) == 1 { return withUnsafeBytes(of: v6) { Array($0) } }
            return nil
        }

        func contains(_ host: String) -> Bool {
            guard let other = CIDR.address(host), other.count == bytes.count else { return false }
            var left = bits
            for (a, b) in zip(bytes, other) where left > 0 {
                let mask: UInt8 = left >= 8 ? 0xff : ~(0xff >> UInt8(left))
                if a & mask != b & mask { return false }
                left -= 8
            }
            return true
        }
    }
}

/// A PAC script, run in a JavaScriptCore context of its own on a queue of
/// its own, with the helpers every PAC script expects. A context is not
/// shared between threads, and a script can be slow (dnsResolve), so the
/// relay waits for it without holding anything else up.
final class PACScript: @unchecked Sendable {
    private let queue = DispatchQueue(label: "search.pac")
    private var context: JSContext?
    private var function: JSValue?
    private let source: String
    /// How dnsResolve looks a name up; a test puts a slow one in.
    var lookUp: @Sendable (String) -> String? = { PACScript.resolve($0) }
    /// When the answer being worked out is due. JavaScriptCore's limit stops
    /// the script, not a lookup it is waiting on, so dnsResolve gives up at
    /// this time too: a name that never resolves, asked again and again,
    /// would otherwise hold the queue as long as a loop.
    private var deadline = DispatchTime.now()

    init(_ source: String) {
        self.source = source
    }

    /// FindProxyForURL's answer, or nil when the script fails or answers
    /// something that isn't a string.
    func find(url: String, host: String) async -> String? {
        await withCheckedContinuation { done in
            queue.async {
                done.resume(returning: self.run(url: url, host: host))
            }
        }
    }

    /// For tests: the same, without the hop.
    func findNow(url: String, host: String) -> String? {
        queue.sync { run(url: url, host: host) }
    }

    private func run(url: String, host: String) -> String? {
        deadline = .now() + Self.limit
        if context == nil { load() }
        guard let context, let function, !function.isUndefined else { return nil }
        context.exception = nil
        let answer = function.call(withArguments: [url, host])
        guard context.exception == nil, let answer, answer.isString else { return nil }
        return answer.toString()
    }

    /// The longest a script may run for one answer, in seconds. One that
    /// loops would otherwise hold the queue, and with it every connection
    /// waiting on an answer, until the extension is turned off.
    static let limit = 2.0

    /// JavaScriptCore's own time limit for a group of contexts: exported,
    /// though not in its public headers. A script that runs past it is
    /// stopped as if it had thrown. Without it, a looping script still holds
    /// only the PAC queue, never the main thread.
    private typealias SetLimit = @convention(c) (OpaquePointer?, Double, OpaquePointer?, UnsafeMutableRawPointer?) -> Void
    private static let setLimit: SetLimit? = {
        let core = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_NOW)
        return dlsym(core, "JSContextGroupSetExecutionTimeLimit").map { unsafeBitCast($0, to: SetLimit.self) }
    }()

    private func load() {
        guard let made = JSContext() else { return }
        made.name = "PAC"
        Self.setLimit?(JSContextGetGroup(made.jsGlobalContextRef), Self.limit, nil, nil)
        let resolve: @convention(block) (String) -> Any = { [weak self] host in (self?.resolveInTime(host)).map { $0 as Any } ?? NSNull() }
        made.setObject(resolve, forKeyedSubscript: "dnsResolve" as NSString)
        let mine: @convention(block) () -> String = { PACScript.myAddress() }
        made.setObject(mine, forKeyedSubscript: "myIpAddress" as NSString)
        made.evaluateScript(Self.helpers)
        made.exception = nil
        made.evaluateScript(source)
        if made.exception != nil { context = made; function = nil; return }
        context = made
        function = made.objectForKeyedSubscript("FindProxyForURL")
    }

    /// The first IPv4 address a name has, as PAC's dnsResolve answers.
    /// A lookup that waits no longer than the answer's deadline. One still
    /// going then is left to finish on its own.
    private func resolveInTime(_ host: String) -> String? {
        let due = deadline
        guard DispatchTime.now() < due else { return nil }
        final class Found: @unchecked Sendable { var address: String? }
        let found = Found(), done = DispatchSemaphore(value: 0), lookUp = lookUp
        DispatchQueue.global().async {
            found.address = lookUp(host)
            done.signal()
        }
        return done.wait(timeout: due) == .success ? found.address : nil
    }

    static func resolve(_ host: String) -> String? {
        if ExtensionProxyRules.CIDR.address(host)?.count == 4 { return host }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &found) == 0, let first = found else { return nil }
        defer { freeaddrinfo(found) }
        return first.pointee.ai_addr.flatMap(text)
    }

    /// An IPv4 socket address, written out.
    private static func text(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer -> String? in
            var addr = pointer.pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buffer)
        }
    }

    /// This Mac's first IPv4 address off loopback, as myIpAddress answers.
    static func myAddress() -> String {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return "127.0.0.1" }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0, item.pointee.ifa_flags & UInt32(IFF_UP) != 0
            else { continue }
            if let found = text(address) { return found }
        }
        return "127.0.0.1"
    }

    /// Shell-style * and ? against a whole string, as shExpMatch reads them.
    static func glob(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] { pi += 1; ti += 1 }
            else if pi < p.count, p[pi] == "*" { star = pi; mark = ti; pi += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; ti = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// The functions a PAC script may call, as Netscape defined them and
    /// Chrome provides them. Dates and times are the Mac's local ones.
    static let helpers = #"""
    function isPlainHostName(host) { return host.indexOf(".") < 0 && host.indexOf(":") < 0; }
    function dnsDomainIs(host, domain) {
      host = String(host).toLowerCase(); domain = String(domain).toLowerCase();
      return host.length >= domain.length && host.substring(host.length - domain.length) === domain;
    }
    function localHostOrDomainIs(host, hostdom) {
      return host === hostdom || hostdom.lastIndexOf(host + ".", 0) === 0;
    }
    function isResolvable(host) { return dnsResolve(host) !== null; }
    function convert_addr(ipchars) {
      var bytes = ipchars.split(".");
      return ((bytes[0] & 0xff) << 24) | ((bytes[1] & 0xff) << 16) | ((bytes[2] & 0xff) << 8) | (bytes[3] & 0xff);
    }
    function isInNet(ipaddr, pattern, maskstr) {
      if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(ipaddr)) { ipaddr = dnsResolve(ipaddr); if (ipaddr === null) return false; }
      var host = convert_addr(ipaddr), pat = convert_addr(pattern), mask = convert_addr(maskstr);
      return (host & mask) === (pat & mask);
    }
    function dnsDomainLevels(host) { return host.split(".").length - 1; }
    function shExpMatch(url, pattern) {
      pattern = String(pattern).replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".");
      return new RegExp("^" + pattern + "$").test(url);
    }
    var __days = { SUN: 0, MON: 1, TUE: 2, WED: 3, THU: 4, FRI: 5, SAT: 6 };
    var __months = { JAN: 0, FEB: 1, MAR: 2, APR: 3, MAY: 4, JUN: 5, JUL: 6, AUG: 7, SEP: 8, OCT: 9, NOV: 10, DEC: 11 };
    function __gmt(args) { return args.length && args[args.length - 1] === "GMT"; }
    function weekdayRange() {
      var a = Array.prototype.slice.call(arguments), gmt = __gmt(a); if (gmt) a.pop();
      var now = new Date(), d = gmt ? now.getUTCDay() : now.getDay();
      var w1 = __days[a[0]], w2 = a.length > 1 ? __days[a[1]] : w1;
      if (w1 === undefined || w2 === undefined) return false;
      return w1 <= w2 ? d >= w1 && d <= w2 : d >= w1 || d <= w2;
    }
    function dateRange() {
      var a = Array.prototype.slice.call(arguments), gmt = __gmt(a); if (gmt) a.pop();
      var now = new Date();
      var day = gmt ? now.getUTCDate() : now.getDate(), month = gmt ? now.getUTCMonth() : now.getMonth(),
          year = gmt ? now.getUTCFullYear() : now.getFullYear();
      function value(x) {
        if (typeof x === "string" && __months[x] !== undefined) return { m: __months[x] };
        var n = Number(x); return n > 31 ? { y: n } : { d: n };
      }
      var parts = a.map(value);
      function key(p, ref) { return [p.y !== undefined ? p.y : ref.y, p.m !== undefined ? p.m : ref.m, p.d !== undefined ? p.d : ref.d]; }
      function cmp(x, y) { for (var i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] < y[i] ? -1 : 1; return 0; }
      if (parts.length === 1) {
        var p = parts[0];
        return (p.y === undefined || p.y === year) && (p.m === undefined || p.m === month) && (p.d === undefined || p.d === day);
      }
      var half = Math.floor(parts.length / 2), from = {}, to = {};
      for (var i = 0; i < half; i++) for (var k in parts[i]) from[k] = parts[i][k];
      for (var j = half; j < parts.length; j++) for (var l in parts[j]) to[l] = parts[j][l];
      var lo = key(from, { y: year, m: from.d !== undefined && from.m === undefined ? month : 0, d: 1 });
      var hi = key(to, { y: year, m: to.d !== undefined && to.m === undefined ? month : 11, d: 31 });
      var now3 = [year, month, day];
      return cmp(lo, hi) <= 0 ? cmp(now3, lo) >= 0 && cmp(now3, hi) <= 0 : cmp(now3, lo) >= 0 || cmp(now3, hi) <= 0;
    }
    function timeRange() {
      var a = Array.prototype.slice.call(arguments), gmt = __gmt(a); if (gmt) a.pop();
      var now = new Date(), h = gmt ? now.getUTCHours() : now.getHours(), m = gmt ? now.getUTCMinutes() : now.getMinutes(),
          s = gmt ? now.getUTCSeconds() : now.getSeconds(), t = h * 3600 + m * 60 + s;
      if (a.length === 1) return h === Number(a[0]);
      var lo, hi;
      if (a.length === 2) { lo = a[0] * 3600; hi = a[1] * 3600 + 3599; }
      else if (a.length === 4) { lo = a[0] * 3600 + a[1] * 60; hi = a[2] * 3600 + a[3] * 60 + 59; }
      else if (a.length === 6) { lo = a[0] * 3600 + a[1] * 60 + Number(a[2]); hi = a[3] * 3600 + a[4] * 60 + Number(a[5]); }
      else return false;
      return lo <= hi ? t >= lo && t <= hi : t >= lo || t <= hi;
    }
    function alert(message) {}
    """#
}

// MARK: - the relay

/// A proxy's sign-in, as onAuthRequired answers one.
struct ProxyCredentials: Equatable, Sendable {
    let username: String
    let password: String

    var header: String {
        "Proxy-Authorization: Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }
}

/// What the relay asks when a proxy wants a sign-in.
struct ProxyChallenge: Sendable {
    let url: String
    let method: String
    let proxyHost: String
    let proxyPort: UInt16
    let realm: String
    let scheme: String
    /// From a private tab: only extensions let into them may hear of it.
    var inPrivate = false
}

/// The proxy every store and session is pointed at while an extension holds
/// the proxy. It speaks just enough HTTP to read where a connection is for
/// — CONNECT host:port, or a plain request with its full address — then
/// asks the rules and joins the two ends.
final class ExtensionProxyRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "search.proxy-relay")
    private let lock = NSLock()
    private var listener: NWListener?
    private var current: ExtensionProxyRules?
    private var credentials: [String: ProxyCredentials] = [:]
    private var live: [ObjectIdentifier: NWConnection] = [:]
    /// Asked when a proxy answers 407; nil means no sign-in.
    let authenticate: @Sendable (ProxyChallenge) async -> ProxyCredentials?
    /// What WebKit signs in to the relay with (see the top of this file):
    /// one secret for ordinary tabs, one for private tabs.
    static let username = "search"
    let secret = UUID().uuidString
    let privateSecret = UUID().uuidString

    init(authenticate: @escaping @Sendable (ProxyChallenge) async -> ProxyCredentials?) {
        self.authenticate = authenticate
    }

    /// Sign-ins are kept across a change of rules: they are kept by proxy,
    /// and one a proxy turns down is forgotten and asked for again.
    /// Tailchrome sets its rules again each time its state changes, and
    /// its helper would otherwise be signed in to over and over.
    var rules: ExtensionProxyRules? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    /// When another extension takes over the proxy: what the last one
    /// signed in to isn't the new one's to use.
    func forgetSignIns() {
        lock.withLock { credentials = [:] }
    }

    /// Which of Search's own sign-ins a request carries: false for an
    /// ordinary tab's, true for a private tab's, nil for neither.
    func signedIn(_ head: Data) -> Bool? {
        let text = String(decoding: head, as: UTF8.self)
        for line in text.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("proxy-authorization:") {
            let given = "Proxy-Authorization: " + line.dropFirst("proxy-authorization:".count).trimmingCharacters(in: .whitespaces)
            if Self.same(given, ProxyCredentials(username: Self.username, password: secret).header) { return false }
            if Self.same(given, ProxyCredentials(username: Self.username, password: privateSecret).header) { return true }
        }
        return nil
    }

    /// Compared byte for byte without stopping at the first difference, so
    /// how long a wrong guess takes says nothing about the secret.
    static func same(_ a: String, _ b: String) -> Bool {
        let (x, y) = (Array(a.utf8), Array(b.utf8))
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Starts listening on 127.0.0.1 and says the port once it is known.
    func start(ready: @escaping @Sendable (UInt16?) -> Void) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { ready(nil); return }
        self.listener = listener
        let told = Once()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: told.run { ready(listener.port?.rawValue) }
            case .failed, .cancelled: told.run { ready(nil) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let open = lock.withLock { () -> [NWConnection] in
            defer { live = [:] }
            return Array(live.values)
        }
        open.forEach { $0.cancel() }
    }

    private func hold(_ connection: NWConnection) {
        lock.withLock { live[ObjectIdentifier(connection)] = connection }
    }

    private func drop(_ connection: NWConnection) {
        lock.withLock { live[ObjectIdentifier(connection)] = nil }
        connection.cancel()
    }

    /// Answers the client with a status of the relay's own and lets it go.
    private func refuse(_ client: NWConnection, _ status: String, also: String = "") async {
        try? await client.sendAll(Data("HTTP/1.1 \(status)\r\n\(also)Connection: close\r\nContent-Length: 0\r\n\r\n".utf8))
        drop(client)
    }

    private func accept(_ client: NWConnection) {
        hold(client)
        client.start(queue: queue)
        Task { await self.serve(client) }
    }

    /// One request's head, read.
    struct Head {
        let method: String
        let host: String
        let port: UInt16
        /// What the PAC script is given.
        let url: String
        /// For a plain request: the head to send on, in origin form, without
        /// the Proxy- headers that were for this relay.
        let forward: Data?
        /// Signed in with a private tab's secret.
        var inPrivate = false

        static func read(_ data: Data) -> Head? {
            guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
            var lines = text.components(separatedBy: "\r\n")
            let request = lines.first?.split(separator: " ").map(String.init) ?? []
            guard request.count == 3 else { return nil }
            let method = request[0].uppercased(), target = request[1]
            if method == "CONNECT" {
                guard let (host, port) = ProxyRoute.hostPort(target, defaultPort: 443) else { return nil }
                let implied: UInt16 = port == 80 ? 80 : 443
                let url = (port == 80 ? "http://" : "https://") + ProxyRoute.authority(host, port, implied: implied) + "/"
                return Head(method: method, host: host, port: port, url: url, forward: nil)
            }
            guard let address = URLComponents(string: target), address.scheme?.lowercased() == "http",
                  let host = address.host, !host.isEmpty else { return nil }
            let port = UInt16(clamping: address.port ?? 80)
            var path = address.percentEncodedPath.isEmpty ? "/" : address.percentEncodedPath
            if let query = address.percentEncodedQuery { path += "?" + query }
            lines[0] = "\(request[0]) \(path) \(request[2])"
            lines = lines.filter { !$0.lowercased().hasPrefix("proxy-") }
            let url = "http://" + ProxyRoute.authority(host, port, implied: 80) + path
            return Head(method: method, host: host, port: port, url: url,
                        forward: lines.joined(separator: "\r\n").data(using: .isoLatin1))
        }
    }

    private func serve(_ client: NWConnection) async {
        // A client that opens a connection and says nothing is let go.
        let said = Once()
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in said.run { self?.drop(client) } }
        let read = try? await client.readHead()
        said.run {}
        guard let (headData, rest) = read, var head = Head.read(headData) else {
            await refuse(client, "400 Bad Request")
            return
        }
        guard let inPrivate = signedIn(headData) else {
            await refuse(client, "407 Proxy Authentication Required", also: "Proxy-Authenticate: Basic realm=\"Search\"\r\n")
            return
        }
        head.inPrivate = inPrivate
        let routes = await rules?.routes(url: head.url, host: head.host) ?? [.direct]
        // A plain http:// address goes to an HTTP proxy as Chrome sends it:
        // the request itself, its full address on the first line, not a
        // tunnel. Some proxies only take port 443 through a tunnel, and
        // Tailchrome's helper answers its sign-in probe
        // (http://tailchrome-proxy-auth.invalid/) only when asked that way.
        let plain = head.forward != nil || head.port == 80
        var upstream: NWConnection?
        var refusal = "502 Bad Gateway"
        for route in routes {
            do {
                if plain, case .http(let host, let port) = route {
                    try await relayPlain(client, head: head, rest: rest, proxy: host, port: port)
                    return
                }
                upstream = try await open(route, to: head)
                break
            } catch let error as Refusal {
                refusal = error.status
            } catch {
                continue
            }
        }
        guard let upstream else {
            await refuse(client, refusal)
            return
        }
        hold(upstream)
        do {
            if let forward = head.forward {
                try await upstream.sendAll(forward + rest)
            } else {
                try await client.sendAll(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
                if !rest.isEmpty { try await upstream.sendAll(rest) }
            }
        } catch {
            drop(client); drop(upstream)
            return
        }
        join(client, upstream)
    }

    /// One plain HTTP request through an HTTP proxy, in absolute form. A
    /// tunnel to port 80 (WebKit asks for every page with CONNECT) is
    /// answered here, and the request read from inside it. The request goes
    /// with "Connection: close", so the next one on the same connection —
    /// which would come in origin form — comes on a new connection instead.
    /// Throws, so the next route is tried, only while nothing has been said
    /// to the client yet.
    private func relayPlain(_ client: NWConnection, head: Head, rest: Data, proxy host: String, port: UInt16) async throws {
        let key = "\(host):\(port)"
        let endpoint = NWEndpoint.hostPort(host: .init(host), port: .init(rawValue: port) ?? 80)
        var connection = NWConnection(to: endpoint, using: .tcp)
        do { try await connection.ready(on: queue) } catch { connection.cancel(); throw error }
        var request: Data, body: Data
        if let forward = head.forward {
            (request, body) = (forward, rest)
        } else {
            do {
                try await client.sendAll(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
                (request, body) = rest.range(of: Data("\r\n\r\n".utf8)) != nil
                    ? Self.split(rest) : try await client.readHead(after: rest)
            } catch {
                connection.cancel(); drop(client)
                return
            }
        }
        var asked = 0
        while true {
            guard let sent = Self.absolute(request, host: head.host, port: head.port, credentials: credential(key)) else {
                connection.cancel()
                await refuse(client, "400 Bad Request")
                return
            }
            do {
                try await connection.sendAll(sent + body)
                let (answer, after) = try await connection.readHead()
                // Asked again only for a request whose body is all here: one
                // still arriving can't be sent twice.
                if Self.status(answer) == 407, Self.whole(request, body),
                   await signIn(after: answer, to: host, port, for: head, method: Self.method(request), asked: &asked) {
                    connection.cancel()
                    connection = NWConnection(to: endpoint, using: .tcp)
                    try await connection.ready(on: queue)
                    continue
                }
                // Nobody signed in, or it wasn't a 407: the proxy's answer
                // is the answer.
                try await client.sendAll(answer + after)
            } catch {
                connection.cancel(); drop(client)
                return
            }
            hold(connection)
            join(client, connection)
            return
        }
    }

    /// A head and what came after its blank line.
    static func split(_ data: Data) -> (Data, Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return (data, Data()) }
        return (data.subdata(in: data.startIndex..<end.upperBound), data.subdata(in: end.upperBound..<data.endIndex))
    }

    static func method(_ request: Data) -> String {
        String(data: request.prefix(16), encoding: .isoLatin1)?.split(separator: " ").first.map(String.init) ?? "GET"
    }

    /// Whether a request's body has all arrived: none, or Content-Length of
    /// it here. A chunked one is never whole in advance.
    static func whole(_ request: Data, _ body: Data) -> Bool {
        let text = String(data: request, encoding: .isoLatin1)?.lowercased() ?? ""
        if text.contains("transfer-encoding:") { return false }
        for line in text.components(separatedBy: "\r\n") where line.hasPrefix("content-length:") {
            return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0 <= body.count
        }
        return true
    }

    /// An origin-form request head made absolute for a proxy: its full
    /// address on the first line, the sign-in if there is one, and
    /// "Connection: close" unless it asks for an upgrade (a WebSocket).
    static func absolute(_ request: Data, host: String, port: UInt16, credentials: ProxyCredentials?) -> Data? {
        guard let text = String(data: request, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        while lines.last == "" { lines.removeLast() }
        let first = lines.first?.split(separator: " ").map(String.init) ?? []
        guard first.count == 3, first[1].hasPrefix("/") || first[1].hasPrefix("http://") else { return nil }
        let target = first[1].hasPrefix("/") ? "http://" + ProxyRoute.authority(host, port, implied: 80) + first[1] : first[1]
        let upgrade = lines.contains { $0.lowercased().hasPrefix("upgrade:") }
        var out = ["\(first[0]) \(target) \(first[2])"]
        for line in lines.dropFirst() {
            let name = line.lowercased()
            if name.hasPrefix("proxy-") { continue }
            if !upgrade, name.hasPrefix("connection:") || name.hasPrefix("keep-alive:") { continue }
            out.append(line)
        }
        if !upgrade { out.append("Connection: close") }
        if let credentials { out.append(credentials.header) }
        return (out.joined(separator: "\r\n") + "\r\n\r\n").data(using: .isoLatin1)
    }

    private func credential(_ key: String) -> ProxyCredentials? {
        lock.withLock { credentials[key] }
    }

    private func keep(_ given: ProxyCredentials?, for key: String) {
        lock.withLock { credentials[key] = given }
    }

    /// After a proxy's 407: the sign-in it turned down is forgotten, and the
    /// listeners asked for one, twice per request at most, as Chrome stops
    /// asking after the same request fails again. True when one was given.
    private func signIn(after answer: Data, to host: String, _ port: UInt16, for head: Head, method: String,
                        asked: inout Int) async -> Bool {
        let key = "\(host):\(port)"
        keep(nil, for: key)
        guard asked < 2 else { return false }
        let (scheme, realm) = Self.challenge(answer)
        let challenge = ProxyChallenge(url: head.url, method: method, proxyHost: host, proxyPort: port, realm: realm,
                                       scheme: scheme, inPrivate: head.inPrivate)
        guard let given = await authenticate(challenge) else { return false }
        asked += 1
        keep(given, for: key)
        return true
    }

    /// A proxy's answer the client should see instead of a 502: a sign-in
    /// nobody could give is a 407.
    struct Refusal: Error { let status: String }

    private func open(_ route: ProxyRoute, to head: Head) async throws -> NWConnection {
        switch route {
        case .direct:
            let connection = NWConnection(to: .hostPort(host: .init(head.host), port: .init(rawValue: head.port) ?? 443), using: .tcp)
            try await connection.ready(on: queue)
            return connection
        case .socks5(let host, let port):
            let connection = NWConnection(to: .hostPort(host: .init(host), port: .init(rawValue: port) ?? 1080), using: .tcp)
            do {
                try await connection.ready(on: queue)
                try await Self.socks5(connection, to: head.host, port: head.port)
                return connection
            } catch {
                connection.cancel()
                throw error
            }
        case .http(let host, let port):
            let key = "\(host):\(port)"
            var asked = 0
            let target = ProxyRoute.authority(head.host, head.port)
            while true {
                let connection = NWConnection(to: .hostPort(host: .init(host), port: .init(rawValue: port) ?? 80), using: .tcp)
                do {
                    try await connection.ready(on: queue)
                    let authorization = credential(key).map { $0.header + "\r\n" } ?? ""
                    try await connection.sendAll(Data("CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\(authorization)\r\n".utf8))
                    let (answer, _) = try await connection.readHead()
                    let status = Self.status(answer)
                    if (200..<300).contains(status) { return connection }
                    connection.cancel()
                    guard status == 407 else { throw Refusal(status: "502 Bad Gateway") }
                    guard await signIn(after: answer, to: host, port, for: head, method: "GET", asked: &asked) else {
                        throw Refusal(status: "407 Proxy Authentication Required")
                    }
                } catch {
                    connection.cancel()
                    throw error
                }
            }
        }
    }

    static func status(_ head: Data) -> Int {
        let line = String(data: head.prefix(64), encoding: .isoLatin1)?.split(separator: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
    }

    /// The scheme and realm of a Proxy-Authenticate header.
    static func challenge(_ head: Data) -> (String, String) {
        let text = String(data: head, encoding: .isoLatin1) ?? ""
        for line in text.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("proxy-authenticate:") {
            let value = line.dropFirst("proxy-authenticate:".count).trimmingCharacters(in: .whitespaces)
            let scheme = String(value.prefix(while: { $0 != " " })).lowercased()
            var realm = ""
            if let found = value.range(of: #"realm="([^"]*)""#, options: [.regularExpression, .caseInsensitive]) {
                realm = String(value[found].dropFirst(7).dropLast())
            }
            return (scheme.isEmpty ? "basic" : scheme, realm)
        }
        return ("basic", "")
    }

    /// RFC 1928, no sign-in, the name sent as it is so the proxy resolves it.
    static func socks5(_ connection: NWConnection, to host: String, port: UInt16) async throws {
        try await connection.sendAll(Data([5, 1, 0]))
        let greeting = try await connection.readExactly(2)
        guard greeting == Data([5, 0]) else { throw Refusal(status: "502 Bad Gateway") }
        var request = Data([5, 1, 0])
        if let address = ExtensionProxyRules.CIDR.address(host) {
            request.append(address.count == 4 ? 1 : 4)
            request.append(contentsOf: address)
        } else {
            let name = Array(host.utf8)
            guard name.count < 256 else { throw Refusal(status: "502 Bad Gateway") }
            request.append(3)
            request.append(UInt8(name.count))
            request.append(contentsOf: name)
        }
        request.append(UInt8(port >> 8))
        request.append(UInt8(port & 0xff))
        try await connection.sendAll(request)
        let reply = try await connection.readExactly(4)
        guard reply[reply.startIndex] == 5, reply[reply.startIndex + 1] == 0 else { throw Refusal(status: "502 Bad Gateway") }
        switch reply[reply.startIndex + 3] {
        case 1: _ = try await connection.readExactly(4 + 2)
        case 4: _ = try await connection.readExactly(16 + 2)
        case 3:
            let length = try await connection.readExactly(1)
            _ = try await connection.readExactly(Int(length[length.startIndex]) + 2)
        default: throw Refusal(status: "502 Bad Gateway")
        }
    }

    /// Both ways at once until both ends are done; an end that closes is
    /// passed on as a close, so a request that ends with its sender's half
    /// still gets its answer.
    private func join(_ a: NWConnection, _ b: NWConnection) {
        let finished = Finished(count: 2) { [weak self] in self?.drop(a); self?.drop(b) }
        pump(from: a, to: b, done: finished)
        pump(from: b, to: a, done: finished)
    }

    private final class Finished: @unchecked Sendable {
        private let lock = NSLock()
        private var left: Int
        private let then: () -> Void
        init(count: Int, then: @escaping () -> Void) { left = count; self.then = then }
        func one() { if lock.withLock({ left -= 1; return left == 0 }) { then() } }
        func all() { if lock.withLock({ defer { left = 0 }; return left > 0 }) { then() } }
    }

    private func pump(from source: NWConnection, to sink: NWConnection, done: Finished) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            if let data, !data.isEmpty {
                sink.send(content: data, completion: .contentProcessed { sent in
                    if sent != nil { done.all(); return }
                    if complete { sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent); done.one(); return }
                    self?.pump(from: source, to: sink, done: done)
                })
                return
            }
            if error != nil { done.all(); return }
            if complete {
                sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                done.one()
                return
            }
            self?.pump(from: source, to: sink, done: done)
        }
    }
}

// MARK: - NWConnection, awaited

extension NWConnection {
    struct Closed: Error {}

    /// Starts the connection and waits until it can be used, or 15 s.
    func ready(on queue: DispatchQueue) async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { done.resume() }
                case .failed(let error): once.run { done.resume(throwing: error) }
                case .waiting(let error): once.run { done.resume(throwing: error) }
                case .cancelled: once.run { done.resume(throwing: Closed()) }
                default: break
                }
            }
            start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                once.run { done.resume(throwing: Closed()) }
                self?.stateUpdateHandler = nil
            }
        }
    }

    func sendAll(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            })
        }
    }

    func receiveSome() async throws -> Data? {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Data?, Error>) in
            receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let data, !data.isEmpty { done.resume(returning: data); return }
                if let error { done.resume(throwing: error); return }
                done.resume(returning: complete ? nil : Data())
            }
        }
    }

    func readExactly(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { (done: CheckedContinuation<Data, Error>) in
            receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count { done.resume(returning: data); return }
                done.resume(throwing: error ?? Closed())
            }
        }
    }

    /// An HTTP head up to its blank line, and whatever came after it in the
    /// same read. 64 KB at most: anything longer is no proxy request.
    func readHead(after start: Data = Data()) async throws -> (Data, Data) {
        var buffer = start
        let end = Data("\r\n\r\n".utf8)
        while buffer.count < 64 * 1024 {
            guard let more = try await receiveSome() else { throw Closed() }
            buffer.append(more)
            if let found = buffer.range(of: end) {
                return (buffer.subdata(in: buffer.startIndex..<found.upperBound), buffer.subdata(in: found.upperBound..<buffer.endIndex))
            }
        }
        throw Closed()
    }
}

/// Runs its work once, whichever of several callbacks comes first.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ work: () -> Void) {
        if lock.withLock({ defer { done = true }; return !done }) { work() }
    }
}

// MARK: - sign-ins, asked of the extension

/// The port an extension's worker opens while it has a blocking
/// webRequest.onAuthRequired listener, and the questions asked on it.
@available(macOS 15.4, *)
@MainActor
enum ExtensionProxyAuth {
    static let name = ExtensionShims.application + ".proxyauth"

    private final class Ear {
        let extensionID: String
        let port: WKWebExtension.MessagePort
        weak var context: WKWebExtensionContext?
        var listening = false
        var worker = false
        init(extensionID: String, port: WKWebExtension.MessagePort, context: WKWebExtensionContext) {
            self.extensionID = extensionID
            self.port = port
            self.context = context
        }
    }

    private static var ears: [ObjectIdentifier: Ear] = [:]
    /// Questions waiting, each with the port it was asked on: an answer is
    /// taken only from there, so one extension can't answer, or cancel, a
    /// question put to another. Their names are random for the same reason.
    private static var pending: [String: (ear: ObjectIdentifier, done: CheckedContinuation<ProxyCredentials?, Never>)] = [:]

    /// Starts an extension's worker that isn't running, so it can be asked.
    static var wake: (String) -> Void = { _ in }

    /// A blocking onAuthRequired is for an extension that asked for it, as
    /// in Chrome's MV3: webRequestAuthProvider, or MV2's webRequestBlocking.
    static func connect(_ port: WKWebExtension.MessagePort, from context: WKWebExtensionContext) throws {
        let id = context.uniqueIdentifier
        let allowed = ExtensionShims.allowed(id, context: context)
        guard allowed.contains("webRequestAuthProvider") || allowed.contains("webRequestBlocking") else {
            throw ExtensionShims.Unsupported(what: "The extension never asked for \u{201C}webRequestAuthProvider\u{201D}")
        }
        for (key, ear) in ears where ear.port.isDisconnected { ears[key] = nil }
        let ear = Ear(extensionID: id, port: port, context: context)
        let key = ObjectIdentifier(ear)
        ears[key] = ear
        port.messageHandler = { message, _ in
            MainActor.assumeIsolated {
                guard let message = message as? [String: Any] else { return }
                if message["listen"] as? Bool == true {
                    ear.listening = true
                    ear.worker = message["worker"] as? Bool == true
                    if !port.isDisconnected { port.sendMessage(["listening": true], completionHandler: nil) }
                    return
                }
                guard let answer = message["answer"] as? String, pending[answer]?.ear == key,
                      let waiting = pending.removeValue(forKey: answer)?.done else { return }
                if message["cancel"] as? Bool == true { waiting.resume(returning: nil); return }
                let given = message["authCredentials"] as? [String: Any]
                if let user = given?["username"] as? String, let password = given?["password"] as? String {
                    waiting.resume(returning: ProxyCredentials(username: user, password: password))
                } else {
                    waiting.resume(returning: nil)
                }
            }
        }
        port.disconnectHandler = { _ in
            MainActor.assumeIsolated { _ = ears.removeValue(forKey: key) }
        }
        port.sendMessage(["ready": true], completionHandler: nil)
    }

    static func workerGone(of extensionID: String) {
        for (key, ear) in ears where ear.extensionID == extensionID && ear.worker {
            ears[key] = nil
            if !ear.port.isDisconnected { ear.port.disconnect() }
        }
    }

    private static func listening(_ extensionID: String) -> [Ear] {
        ears.values.filter { $0.extensionID == extensionID && $0.listening && !$0.port.isDisconnected }
    }

    /// Asks the extension in control first, then any other that listens, as
    /// Chrome asks every extension with a listener; the first sign-in given
    /// is the one used. An extension whose worker isn't running is woken and
    /// given a few seconds to start listening.
    static func ask(_ challenge: ProxyChallenge, controller: String?) async -> ProxyCredentials? {
        var order = [String]()
        if let controller { order.append(controller) }
        for ear in ears.values where ear.listening && !order.contains(ear.extensionID) && mayHear(ear, of: challenge) {
            order.append(ear.extensionID)
        }
        for id in order {
            if listening(id).isEmpty, id == controller {
                wake(id)
                for _ in 0..<30 where listening(id).isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            }
            for ear in listening(id) {
                if let given = await ask(ear, challenge) { return given }
            }
        }
        return nil
    }

    /// Another extension hears of a request only as Chrome would tell it:
    /// with access to its address, and let into private tabs if it is from
    /// one. The one in control is always asked; its rules saw it already.
    private static func mayHear(_ ear: Ear, of challenge: ProxyChallenge) -> Bool {
        guard let context = ear.context, let url = URL(string: challenge.url), context.hasAccess(to: url) else { return false }
        return !challenge.inPrivate || Extensions.mayGoPrivate(context)
    }

    private static func ask(_ ear: Ear, _ challenge: ProxyChallenge) async -> ProxyCredentials? {
        let question = UUID().uuidString
        let details: [String: Any] = [
            "requestId": question, "url": challenge.url, "method": challenge.method,
            "frameId": -1, "parentFrameId": -1, "tabId": -1, "type": "other",
            "timeStamp": Date().timeIntervalSince1970 * 1000,
            "statusCode": 407, "statusLine": "HTTP/1.1 407 Proxy Authentication Required",
            "isProxy": true, "scheme": challenge.scheme, "realm": challenge.realm,
            "challenger": ["host": challenge.proxyHost, "port": Int(challenge.proxyPort)],
        ]
        return await withCheckedContinuation { done in
            pending[question] = (ObjectIdentifier(ear), done)
            ear.port.sendMessage(["ask": question, "details": details]) { error in
                guard error != nil else { return }
                MainActor.assumeIsolated { pending.removeValue(forKey: question)?.done.resume(returning: nil) }
            }
            // A listener that never calls back is no answer.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                pending.removeValue(forKey: question)?.done.resume(returning: nil)
            }
        }
    }
}
