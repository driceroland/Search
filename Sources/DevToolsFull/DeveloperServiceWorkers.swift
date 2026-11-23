import Foundation
import WebKit

/// What the Application panel's Service workers section can do to a
/// registration from outside it. Update and Unregister are the page's own
/// calls.
@MainActor
enum DeveloperServiceWorkers {
}

/// One registration as the Service workers section lists it.
struct DeveloperWorkerRegistration: Identifiable, Equatable {
    struct Worker: Equatable {
        let role: String
        let state: String
        let scriptURL: String
    }

    let scope: String
    let workers: [Worker]
    let controlsPage: Bool
    let updateViaCache: String
    let subscribed: Bool
    let syncSupported: Bool
    var id: String { scope }

    var active: Worker? { workers.first { $0.role == "active" } }
    var waiting: Worker? { workers.first { $0.role == "waiting" } }
    var installing: Worker? { workers.first { $0.role == "installing" } }

    init?(_ raw: [String: Any]) {
        guard let scope = raw["scope"] as? String else { return nil }
        self.scope = scope
        workers = (raw["workers"] as? [[String: Any]] ?? []).compactMap { item in
            guard let role = item["role"] as? String, let state = item["state"] as? String,
                  let script = item["scriptURL"] as? String else { return nil }
            return Worker(role: role, state: state, scriptURL: script)
        }
        controlsPage = raw["controlsPage"] as? Bool == true
        updateViaCache = raw["updateViaCache"] as? String ?? "imports"
        subscribed = raw["subscribed"] as? Bool == true
        syncSupported = raw["sync"] as? Bool == true
    }
}

extension DeveloperServiceWorkers {
    enum Action: String {
        case update, unregister, skipWaiting, sync
        /// Every registration of the page's origin, for Update on reload.
        case updateAll
    }

    private static let script = DevToolsScripts.serviceWorkersScript

    struct Listing {
        var registrations: [DeveloperWorkerRegistration] = []
        var note: String?
    }

    enum Problem: LocalizedError {
        case pageChanged, failed(String)
        var errorDescription: String? {
            switch self {
            case .pageChanged: "Wait for the current website to finish loading, then refresh."
            case .failed(let text): text
            }
        }
    }

    private static func run(_ web: WKWebView, action: Action?, scope: String? = nil, tag: String? = nil) async throws -> [String: Any] {
        guard let url = web.url, let origin = DeveloperApplication.origin(of: url) else { throw Problem.pageChanged }
        let arguments: [String: Any] = [
            "origin": origin.absoluteString.hasSuffix("/") ? String(origin.absoluteString.dropLast()) : origin.absoluteString,
            "action": action?.rawValue as Any? ?? NSNull(), "scope": scope as Any? ?? NSNull(), "tag": tag as Any? ?? NSNull(),
        ]
        let reply: Any?
        do {
            reply = try await web.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: DevHost.world)
        } catch {
            throw Problem.failed(error.localizedDescription)
        }
        guard let result = reply as? [String: Any] else { throw Problem.failed("The page could not answer.") }
        if result["changed"] as? Bool == true { throw Problem.pageChanged }
        if let issue = result["issue"] as? String { throw Problem.failed(issue) }
        return result
    }

    static func list(in web: WKWebView) async throws -> Listing {
        let result = try await run(web, action: nil)
        return Listing(registrations: (result["rows"] as? [[String: Any]] ?? []).compactMap(DeveloperWorkerRegistration.init),
                       note: result["note"] as? String)
    }

    static func perform(_ action: Action, scope: String, tag: String? = nil, in web: WKWebView) async throws {
        _ = try await run(web, action: action, scope: scope, tag: tag)
    }

    static func updateAll(in web: WKWebView) async throws {
        _ = try await run(web, action: .updateAll)
    }

}

/// Service workers › "Update on reload", kept as Chrome keeps it
/// (`service-worker-update-on-reload`), across DevTools sessions. Chrome
/// updates the worker before the page loads, so the new one controls the
/// reload; WebKit gives no hook before a navigation, so once each load of
/// the inspected page finishes its registrations check for a new script and
/// a new worker is asked to take over, which the next load then uses.
@MainActor
final class DeveloperServiceWorkerReloads: ObservableObject {
    static let shared = DeveloperServiceWorkerReloads()
    private static let key = "developerTools.serviceWorkers.updateOnReload"

    @Published var enabled = DevDefaults.store.bool(forKey: DeveloperServiceWorkerReloads.key) {
        didSet { DevDefaults.store.set(enabled, forKey: Self.key) }
    }

    private weak var web: WKWebView?
    private var observation: NSKeyValueObservation?

    /// Follows the loads of the page DevTools inspects.
    func watch(_ web: WKWebView?) {
        guard web !== self.web || observation == nil else { return }
        observation = nil
        self.web = web
        guard let web else { return }
        observation = web.observe(\.isLoading, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }
            MainActor.assumeIsolated { self?.loaded() }
        }
    }

    private func loaded() {
        guard enabled, let web, DeveloperTools.shared.session?.web === web else { return }
        Task { try? await DeveloperServiceWorkers.updateAll(in: web) }
    }
}
