import Network
import Security
import SwiftUI
import WebKit

struct ProxySettingsValue: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case system, http, socks5
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return "Disabled / System"
            case .http: return "HTTP"
            case .socks5: return "SOCKS5"
            }
        }
    }

    var mode: Mode = .system
    var host = ""
    var port = ""
    var username = ""

    var validation: String? {
        guard mode != .system else { return nil }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              !host.contains("://"), !host.contains("/"), !host.contains("@") else {
            return "Enter a host name or IP address, without a URL or port."
        }
        guard let number = UInt16(port), number > 0 else {
            return "Enter a port from 1 to 65535."
        }
        return nil
    }

    func configurations(password: String) -> [ProxyConfiguration] {
        guard mode != .system, validation == nil, let number = UInt16(port) else { return [] }
        let endpoint = NWEndpoint.hostPort(
            host: .init(host.trimmingCharacters(in: .whitespacesAndNewlines)),
            port: .init(rawValue: number)!)
        var proxy = mode == .http ? ProxyConfiguration(httpCONNECTProxy: endpoint)
            : ProxyConfiguration(socksv5Proxy: endpoint)
        // A failed explicit proxy must not silently send traffic directly.
        proxy.allowFailover = false
        if !username.isEmpty { proxy.applyCredential(username: username, password: password) }
        return [proxy]
    }
}

/// Stores are weakly held: a closed private tab must not keep its cookies alive.
@MainActor
final class BrowserProxy: ObservableObject {
    static let shared = BrowserProxy()
    @Published private(set) var value: ProxySettingsValue
    private var password: String
    private let defaults: UserDefaults
    private let savePassword: (String) throws -> Void
    private let stores = NSHashTable<WKWebsiteDataStore>.weakObjects()
    private static let key = "network.proxy"

    init(defaults: UserDefaults = Store.settings, password: String? = nil,
         savePassword: @escaping (String) throws -> Void = { try ProxySecret.write($0) }) {
        self.defaults = defaults
        self.savePassword = savePassword
        value = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(ProxySettingsValue.self, from: $0) } ?? .init()
        self.password = password ?? ProxySecret.read()
    }

    func attach(_ store: WKWebsiteDataStore) {
        guard !stores.contains(store) else { return }
        stores.add(store)
        store.proxyConfigurations = value.configurations(password: password)
    }

    func save(_ proposed: ProxySettingsValue, password: String) throws {
        if let message = proposed.validation {
            throw NSError(domain: "SearchProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let data = try JSONEncoder().encode(proposed)
        // Save the secret first; a keychain failure leaves the active setup alone.
        try savePassword(password)
        defaults.set(data, forKey: Self.key)
        self.password = password
        value = proposed
        for store in stores.allObjects {
            store.proxyConfigurations = value.configurations(password: password)
        }
    }

    var savedPassword: String { password }
}

private enum ProxySecret {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Search.proxy" + (Store.world.map { ".\($0)" } ?? ""),
         kSecAttrAccount as String: "global"]
    }

    static func read() -> String {
        var query = query
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func write(_ password: String) throws {
        let status: OSStatus
        if password.isEmpty {
            let removed = SecItemDelete(query as CFDictionary)
            status = removed == errSecItemNotFound ? errSecSuccess : removed
        } else {
            let attributes = [kSecValueData as String: Data(password.utf8)]
            let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updated == errSecItemNotFound {
                var item = query
                item.merge(attributes) { _, new in new }
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
                status = SecItemAdd(item as CFDictionary, nil)
            } else { status = updated }
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not save the proxy password in Keychain (\(status))."])
        }
    }
}

struct ProxySettings: View {
    @ObservedObject private var proxy = BrowserProxy.shared
    @State private var draft = BrowserProxy.shared.value
    @State private var password = BrowserProxy.shared.savedPassword
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Line("Browser proxy", "Used by all spaces and private tabs") {
                Picker("Proxy", selection: $draft.mode) {
                    ForEach(ProxySettingsValue.Mode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            Rule()
            if draft.mode != .system {
                TextField("Host (e.g. 127.0.0.1)", text: $draft.host)
                TextField("Port (e.g. 7890)", text: $draft.port)
                TextField("Username (optional)", text: $draft.username)
                SecureField("Password (optional)", text: $password)
                Text("Passwords are saved in Keychain. HTTP uses CONNECT; the proxy must support tunneling.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            } else {
                Text("No Search proxy override. WebKit uses the Mac's system network settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            Text("Apply updates existing and new tabs without restarting. Reload pages to request them through the new proxy; transfers already in progress may finish on their current connection.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            if let validation = draft.validation {
                Text(validation).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            HStack {
                Pill("Apply", filled: true) {
                    do {
                        try proxy.save(draft, password: password)
                        message = "Proxy settings applied"
                    } catch { message = error.localizedDescription }
                }
                .disabled(draft.validation != nil)
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(Palette.muted) }
            }
        }
        .textFieldStyle(.roundedBorder)
    }
}
