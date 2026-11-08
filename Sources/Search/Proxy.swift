import Network
import Security
import SwiftUI
import WebKit

// Settings › Network › Proxy, off unless turned on: an HTTP CONNECT or SOCKS5
// proxy that everything Search fetches goes through, pages and the browser's
// own requests alike. A proxy that only covered pages would be worse than
// none, since the address of every site you open would still be read by
// whoever you were avoiding, through a favicon or a search suggestion.
//
// So the configuration is kept in one place and stamped on both halves: each
// WKWebsiteDataStore as it is made (pages), and every URLSession Search makes
// itself (favicons, Copy Image, suggestions, extensions, the Web Store, the
// AI add-on, the updater). Local addresses are left direct, or a proxy would
// cut you off from your own machine and your own network.
//
// The password is the one secret here. It lives in the data-protection
// keychain under Search's own item, as AIKeys does, is read only when a proxy
// with a username is set, and is deleted when the proxy is turned off.

struct ProxySettingsValue: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case system, http, socks5
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return "Off, or the Mac's own"
            case .http: return "HTTP"
            case .socks5: return "SOCKS5"
            }
        }
    }

    var mode: Mode = .system
    var host = ""
    var port = ""
    var username = ""

    /// Kept direct whatever the proxy says: your own machine and your own
    /// network. A proxy that swallowed these would leave a local server, a
    /// router's page or a Bonjour name unreachable while it was on, which
    /// looks like the browser being broken rather than the proxy working.
    static let direct = ["localhost", "127.0.0.1", "::1", "local"]

    /// The host as typed, in the form NWEndpoint wants. An IPv6 address is
    /// written in brackets in an address bar but bare here, and a port
    /// smuggled into this field ("localhost:8080") used to pass every check
    /// and then resolve to nothing at all, so a colon is refused unless what
    /// it is part of really is an IPv6 address.
    var bare: String? {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }),
              !text.contains("://"), !text.contains("/"), !text.contains("@")
        else { return nil }
        if text.contains(":"), IPv6Address(text) == nil { return nil }
        return text
    }

    /// What Settings says under the fields, or nil when it is ready to save.
    var validation: String? {
        guard mode != .system else { return nil }
        guard bare != nil else {
            return "Enter a host name or IP address on its own, without a scheme, a port or a path."
        }
        guard let number = UInt16(port), number > 0 else { return "Enter a port from 1 to 65535." }
        return nil
    }

    /// Nil when nothing should be proxied, which is also what a half-filled
    /// setting gives: a proxy is either whole and used, or absent.
    func configuration(password: String) -> ProxyConfiguration? {
        guard mode != .system, validation == nil,
              let host = bare, let number = UInt16(port), let port = NWEndpoint.Port(rawValue: number)
        else { return nil }
        let endpoint = NWEndpoint.hostPort(host: .init(host), port: port)
        var proxy = mode == .http
            ? ProxyConfiguration(httpCONNECTProxy: endpoint)
            : ProxyConfiguration(socksv5Proxy: endpoint)
        // A proxy that cannot be reached must fail, not quietly send the
        // request straight out: whoever turned it on did so to be sure.
        proxy.allowFailover = false
        proxy.excludedDomains = Self.direct
        if !username.isEmpty { proxy.applyCredential(username: username, password: password) }
        return proxy
    }

    /// Whether a host is one of the local names kept direct. The excluded
    /// domains above are given to the network stack as well; this is what
    /// Search's own requests are judged by, so a local address stays reachable
    /// even where the stack's own list does not reach.
    static func isDirect(_ host: String?) -> Bool {
        guard var host = host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return direct.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// The proxy password, in the data-protection keychain under Search's own
/// item, as `AIKeys.query` does: never in the settings file, a published
/// value, a log line or an error. A test run keeps it in memory and leaves
/// the real keychain alone.
enum ProxySecret {
    private static let service = "com.officecommun.search.proxy"
    private static let account = "global"
    /// A test run's, gone when it quits, as AIKeys keeps its own.
    nonisolated(unsafe) private static var rehearsal: String?

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Read only when a proxy with a username is set, so a browser with no
    /// proxy never touches the keychain at launch.
    static func read() -> String {
        if Store.testing { return rehearsal ?? "" }
        var asked = query
        asked[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(asked as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    static func write(_ password: String) throws {
        guard !password.isEmpty else { forget(); return }
        if Store.testing { rehearsal = password; return }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        item[kSecAttrLabel as String] = "Search — proxy password"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: status == errSecMissingEntitlement
                    ? "This copy of Search can't keep a password in the keychain."
                    : "The proxy password couldn't be kept in the keychain (\(status)).",
            ])
        }
    }

    /// Gone when the proxy is turned off, so nothing is left behind for a
    /// setting that is no longer there.
    static func forget() {
        rehearsal = nil
        guard !Store.testing else { return }
        SecItemDelete(query as CFDictionary)
    }
}

/// What the proxy is, for the requests Search makes itself. Read from any
/// thread, so a favicon fetched off the main actor can be stamped without
/// hopping: the value is small, copied under a lock, and changes only when
/// Settings saves.
enum ProxyNetwork {
    nonisolated(unsafe) private static var current: ProxyConfiguration?
    private static let lock = NSLock()

    static var configuration: ProxyConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    fileprivate static func keep(_ proxy: ProxyConfiguration?) {
        lock.lock()
        current = proxy
        lock.unlock()
    }

    /// Stamped on a configuration before its session is made. WebKit's own
    /// requests go through the stores instead (see BrowserProxy.attach).
    /// A test's stand-in for the network. `URLSession.shared` consulted every
    /// class given to `URLProtocol.registerClass`; a session made from a
    /// configuration consults only the classes that configuration names, so
    /// a test that stands in for what Search fetches itself says so here
    /// (as AI.mock and AIEngine.testEngine do for theirs).
    nonisolated(unsafe) static var testProtocols: [AnyClass] = []

    static func stamp(_ configuration: URLSessionConfiguration) {
        configuration.proxyConfigurations = [Self.configuration].compactMap { $0 }
        if !testProtocols.isEmpty {
            configuration.protocolClasses = testProtocols + (configuration.protocolClasses ?? [])
        }
    }

    /// A session Search keeps for one purpose, by name. A URLSession holds
    /// the configuration it was born with, so one made once and kept as a
    /// `static let` would go on fetching directly for the rest of the run
    /// after a proxy was turned on. These are made again, once, the first
    /// time they are asked for after the proxy changed.
    nonisolated(unsafe) private static var kept: [String: (mark: String, session: URLSession)] = [:]

    static func kept(_ purpose: String, make: () -> URLSession) -> URLSession {
        lock.lock()
        let proxy = current
        // The mark covers the stand-ins as well as the proxy: a session kept
        // from before a test set one would be handed back without it, and the
        // test would watch a session that never asks it anything.
        let mark = (proxy?.debugDescription ?? "")
            + "\u{1}" + testProtocols.map { String(describing: $0) }.joined(separator: ",")
        if let had = kept[purpose], had.mark == mark {
            lock.unlock()
            return had.session
        }
        lock.unlock()
        // Made outside the lock, so the call site may call stamp while it
        // builds its own session.
        let session = make()
        lock.lock()
        let older = kept[purpose]?.session
        kept[purpose] = (mark, session)
        lock.unlock()
        older?.finishTasksAndInvalidate()
        return session
    }

    /// For the places that reached for `URLSession.shared`, which takes no
    /// configuration at all and so could never be proxied. One session, made
    /// again when the proxy changes.
    static var session: URLSession {
        kept("shared") {
            let configuration = URLSessionConfiguration.default
            stamp(configuration)
            return URLSession(configuration: configuration)
        }
    }

}

/// Settings' side of it, and what the stores are given.
@MainActor
final class BrowserProxy: ObservableObject {
    static let shared = BrowserProxy()

    @Published private(set) var value: ProxySettingsValue
    private var password: String
    private let defaults: UserDefaults
    private let keep: (String) throws -> Void
    private let forget: () -> Void
    /// Every store the proxy has been put on, weakly: a private tab's store
    /// is nobody else's and must not be kept alive past the tab, and a
    /// space's store is held by Spaces. Spaces.everyStore is not enough on
    /// its own, since a private tab's is left out of it on purpose.
    private let stores = NSHashTable<WKWebsiteDataStore>.weakObjects()
    private static let key = "network.proxy"

    init(defaults: UserDefaults = Store.settings,
         password: String? = nil,
         keep: @escaping (String) throws -> Void = { try ProxySecret.write($0) },
         forget: @escaping () -> Void = { ProxySecret.forget() }) {
        self.defaults = defaults
        self.keep = keep
        self.forget = forget
        let value = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(ProxySettingsValue.self, from: $0) } ?? .init()
        self.value = value
        // The keychain is asked only for a proxy that names a user.
        self.password = password ?? (value.mode != .system && !value.username.isEmpty ? ProxySecret.read() : "")
        ProxyNetwork.keep(value.configuration(password: self.password))
    }

    /// Called where a store is made, not where one is read: `Store.websites`
    /// hands out WebKit's default store on every read, and attaching there
    /// meant hopping to the main actor inside a getter that is read off it.
    func attach(_ store: WKWebsiteDataStore) {
        guard !stores.contains(store) else { return }
        stores.add(store)
        store.proxyConfigurations = [value.configuration(password: password)].compactMap { $0 }
    }

    func save(_ proposed: ProxySettingsValue, password: String) throws {
        if let message = proposed.validation {
            throw NSError(domain: "SearchProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let secret = proposed.mode == .system || proposed.username.isEmpty ? "" : password
        // The secret first: a keychain that refuses leaves the proxy as it
        // was rather than running with a password it cannot keep.
        if proposed.mode == .system { forget() } else { try keep(secret) }
        defaults.set(try JSONEncoder().encode(proposed), forKey: Self.key)
        self.password = secret
        value = proposed
        let proxy = proposed.configuration(password: secret)
        ProxyNetwork.keep(proxy)
        let configurations = [proxy].compactMap { $0 }
        for store in stores.allObjects { store.proxyConfigurations = configurations }
    }

    var savedPassword: String { password }
}

/// Settings › Privacy › Proxy. Built on the pane in #510 (@standby2025),
/// with the review's two lines added: what actually goes through it, and
/// that a password reaches a proxy in the clear.
struct ProxySettings: View {
    @ObservedObject private var proxy = BrowserProxy.shared
    @State private var draft = BrowserProxy.shared.value
    @State private var password = BrowserProxy.shared.savedPassword
    @State private var message: String?

    private var note: String {
        """
        Everything Search fetches goes through it: pages, favicons, search \
        suggestions, copied pictures, extensions and the Web Store, the AI \
        add-on and Search's own updates. Your own machine and your own \
        network stay direct, so a local server or a router's page still \
        opens. A proxy that can't be reached fails rather than going direct.
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Line("Send everything through a proxy", draft.mode == .system ? "Off: Search follows the Mac's own network settings." : note) {
                Picker("Proxy", selection: $draft.mode) {
                    ForEach(ProxySettingsValue.Mode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 180)
            }
            if draft.mode != .system {
                Rule()
                TextField("Host, such as 127.0.0.1", text: $draft.host)
                TextField("Port, such as 7890", text: $draft.port)
                TextField("User name, if the proxy asks for one", text: $draft.username)
                SecureField("Password, if the proxy asks for one", text: $password)
                small(draft.mode == .http
                    ? "HTTP proxies are reached with CONNECT, so the proxy has to allow tunnelling."
                    : "SOCKS5, as an SSH tunnel or a local client offers.")
                if !draft.username.isEmpty {
                    small("The user name and password are sent to the proxy as they are, which anyone between this Mac and the proxy can read. For a proxy that isn't on this Mac or your own network, prefer one that needs no password. The password itself is kept in the keychain, and removed when the proxy is turned off.")
                }
            }
            if let validation = draft.validation { small(validation) }
            HStack(spacing: 10) {
                Pill("Apply", filled: true) {
                    do {
                        try proxy.save(draft, password: password)
                        message = draft.mode == .system ? "Proxy turned off." : "Proxy applied. Reload a page to fetch it through the proxy."
                    } catch {
                        message = error.localizedDescription
                    }
                }
                .disabled(draft.validation != nil)
                if let message { small(message) }
            }
        }
        .textFieldStyle(.roundedBorder)
        .onChange(of: proxy.value) { _, saved in
            draft = saved
            password = proxy.savedPassword
        }
    }

    private func small(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
