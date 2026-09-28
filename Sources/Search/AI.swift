import Foundation
import Security

// The AI add-on: a summary of the page you're on, and questions about it,
// answered where you choose — a model on this Mac, an app on this Mac that
// runs one (Ollama, LM Studio), or a provider you have an account or a key
// with. Off until you turn it on in Settings › AI; nothing is detected,
// downloaded or sent before that, and nothing afterwards until you ask.
//
// This file: where it runs, and the keys. The requests are AIClient's, the
// page's text AIPage's.

/// Where the answers come from.
enum AIProvider: String, CaseIterable, Identifiable {
    /// The model downloaded to this Mac, run by Search's own engine (AIEngine).
    case thisMac
    case anthropic, openAI, gemini, openRouter
    /// Ollama, on this Mac.
    case ollama
    /// LM Studio, on this Mac.
    case lmStudio

    var id: String { rawValue }

    var name: String {
        switch self {
        case .thisMac: return "On this Mac"
        case .anthropic: return "Anthropic"
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .openRouter: return "OpenRouter"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        }
    }

    /// Runs on this Mac: nothing leaves it, and no key is needed.
    var isLocal: Bool { self == .thisMac || self == .ollama || self == .lmStudio }

    /// The one address requests go to. A key is kept for this host and is
    /// never sent to any other (see AIClient.request).
    var base: URL {
        if Store.testing, let mock = AIProvider.mock { return mock.appendingPathComponent(rawValue + "/") }
        switch self {
        // Never asked over the network: the engine is a program of its own.
        case .thisMac: return URL(string: "http://127.0.0.1:1/")!
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/")!
        case .openAI: return URL(string: "https://api.openai.com/v1/")!
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/")!
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1/")!
        case .ollama: return URL(string: "http://127.0.0.1:11434/v1/")!
        case .lmStudio: return URL(string: "http://127.0.0.1:1234/v1/")!
        }
    }

    var host: String { self == .thisMac ? "this Mac" : base.host() ?? "" }

    /// A test run's stand-in for every provider: a server on this Mac that
    /// answers the way they do (bench ai-mock). Never outside a test run,
    /// and only ever on the loopback address.
    nonisolated(unsafe) static var mock: URL?

    /// Cheap and quick, for a summary; each can be changed in Settings.
    /// The local apps have no default: the list comes from the app.
    var defaultModel: String {
        switch self {
        case .thisMac: return AIEngine.model.name
        case .anthropic: return "claude-haiku-4-5"
        case .openAI: return "gpt-5.4-mini"
        case .gemini: return "gemini-3.8-flash"
        case .openRouter: return "google/gemini-3.8-flash"
        case .ollama, .lmStudio: return ""
        }
    }

    /// How requests are written.
    enum Wire { case openAI, anthropic, gemini }

    var wire: Wire {
        switch self {
        case .anthropic: return .anthropic
        case .gemini: return .gemini
        default: return .openAI
        }
    }
}

/// The keys, in the keychain and nowhere else.
///
/// The data protection keychain, under Search's own access group: only apps
/// signed as Search, with its provisioning profile, can read or write them.
/// This Mac only, readable while it is unlocked, never synced, and each kept
/// for its provider's host (account "provider@host"). A copy of Search built
/// without that profile — from source, or for testing — has no access group,
/// and keeps no key at all rather than one somewhere weaker. Test runs keep
/// theirs in memory, for the run.
///
/// A key is read the moment a request needs it and let go with the request:
/// never in the settings file, a published value, a log line or an error.
@MainActor
enum AIKeys {
    enum Saved { case kept, unavailable, failed }

    private static let service = "com.officecommun.search.ai"
    /// A test run's, by account, gone when it quits.
    private static var rehearsal: [String: String] = [:]

    private static func account(_ provider: AIProvider) -> String { "\(provider.rawValue)@\(provider.host)" }

    private static func query(_ provider: AIProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account(provider)]
    }

    /// Whether a key can be kept at all by this copy of Search.
    static var available: Bool {
        if Store.testing { return true }
        var asked = query(.anthropic)
        asked[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(asked as CFDictionary, nil) != errSecMissingEntitlement
    }

    static func save(_ key: String, for provider: AIProvider) -> Saved {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !provider.isLocal else { return .failed }
        if Store.testing {
            rehearsal[account(provider)] = key
            return .kept
        }
        SecItemDelete(query(provider) as CFDictionary)
        var item = query(provider)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        item[kSecAttrLabel as String] = "Search — \(provider.name) key"
        // The last four, to tell keys apart in Settings without reading one.
        item[kSecAttrComment as String] = String(key.suffix(4))
        switch SecItemAdd(item as CFDictionary, nil) {
        case errSecSuccess: return .kept
        case errSecMissingEntitlement: return .unavailable
        default: return .failed
        }
    }

    /// The key, for the request about to go out. Nil when there is none.
    static func key(for provider: AIProvider) -> String? {
        if Store.testing { return rehearsal[account(provider)] }
        var asked = query(provider)
        asked[kSecReturnData as String] = true
        asked[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(asked as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// "••••1a2b" for one that is kept, without reading the key itself.
    static func hint(for provider: AIProvider) -> String? {
        if Store.testing { return rehearsal[account(provider)].map { "••••" + $0.suffix(4) } }
        var asked = query(provider)
        asked[kSecReturnAttributes as String] = true
        var found: CFTypeRef?
        guard SecItemCopyMatching(asked as CFDictionary, &found) == errSecSuccess,
              let attributes = found as? [String: Any]
        else { return nil }
        return "••••" + (attributes[kSecAttrComment as String] as? String ?? "")
    }

    static func forget(_ provider: AIProvider) {
        if Store.testing { rehearsal[account(provider)] = nil; return }
        SecItemDelete(query(provider) as CFDictionary)
    }

    static func forgetAll() {
        AIProvider.allCases.forEach(forget)
    }
}
