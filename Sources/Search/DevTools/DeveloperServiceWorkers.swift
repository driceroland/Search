import Foundation
import WebKit

/// What the Application panel's Service workers section can do to a
/// registration from outside it. Update and Unregister are the page's own
/// calls; a push message goes in through WebKit, as one from a push service.
@MainActor
enum DeveloperServiceWorkers {
    /// A push event with `text` as its data, delivered to the registration
    /// at `scope` as WebKit delivers one from a push service. False when
    /// this WebKit has no way in, or no worker took it.
    static func push(_ text: String, scope: URL, in web: WKWebView) async -> Bool {
        let store = web.configuration.websiteDataStore
        let selector = NSSelectorFromString("_processPushMessage:completionHandler:")
        guard store.responds(to: selector), let method = class_getMethodImplementation(type(of: store), selector) else {
            return false
        }
        typealias Call = @convention(c) (AnyObject, Selector, NSDictionary, @escaping @convention(block) (Bool) -> Void) -> Void
        let call = unsafeBitCast(method, to: Call.self)
        let message: NSDictionary = [
            "WebKitPushData": Data(text.utf8) as NSData,
            "WebKitPushRegistrationURL": scope as NSURL,
            "WebKitPushPartition": "",
            // Required when WebKit is built with declarative push: null
            // means an ordinary push event, not a notification payload.
            "WebKitNotificationPayload": NSNull(),
        ]
        return await withCheckedContinuation { continuation in
            call(store, selector, message) { processed in
                DispatchQueue.main.async { continuation.resume(returning: processed) }
            }
        }
    }
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
        syncSupported = raw["sync"] as? Bool == true
    }
}

extension DeveloperServiceWorkers {
    enum Action: String {
        case update, unregister, skipWaiting, sync
        /// Every registration of the page's origin, for Update on reload.
        case updateAll
    }

    private static let script = DevToolsResources.script("DeveloperServiceWorkers-script.js")

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
            "origin": DeveloperApplication.originText(origin),
            "action": action?.rawValue as Any? ?? NSNull(), "scope": scope as Any? ?? NSNull(), "tag": tag as Any? ?? NSNull(),
        ]
        let reply: Any?
        do {
            reply = try await web.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: Web.world)
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

    /// WebKit takes a push only for a site allowed to show notifications:
    /// one still at the prompt has its push subscriptions removed instead,
    /// so a test push is never sent there.
    static func pushAllowed(for url: URL?) -> Bool {
        guard let url, let origin = DeveloperApplication.origin(of: url) else { return false }
        return Shared.prefs.siteNotifications && SiteNotifications.choices[DeveloperApplication.originText(origin)] == true
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

    @Published var enabled = Store.settings.bool(forKey: DeveloperServiceWorkerReloads.key) {
        didSet { Store.settings.set(enabled, forKey: Self.key) }
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
