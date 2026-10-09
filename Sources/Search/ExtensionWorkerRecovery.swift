import WebKit

/// Passive port subscriptions, scoped to the native background they belong to.
/// Neither this bridge nor its messages can initiate recovery or call APIs.
@available(macOS 15.4, *)
@MainActor
final class ExtensionWorkerRecovery {
    static let shared = ExtensionWorkerRecovery()
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var handlers: [String: Handler] = [:]
    private var contexts: [String: WeakContext] = [:]
    private var backgrounds: [String: Background] = [:]
    private var generations: [String: Int] = [:]
    private struct Observation {
        var lifetime: UUID?
        let reply: (Int?) -> Void
    }
    private var waiting: [String: [String: Observation]] = [:]

    private final class WeakContext {
        weak var value: WKWebExtensionContext?
        init(_ value: WKWebExtensionContext) { self.value = value }
    }
    private final class Background {
        weak var view: WKWebView?
        let lifetime = UUID()
        init(_ view: WKWebView) { self.view = view }
    }

    /// Written into newly installed shims. Worker-only wake does not advance
    /// it: a new page must not mistake earlier idle wakes for its own restart.
    func generation(for id: String) -> Int { generations[id, default: 0] }

    func attach(_ controller: WKUserContentController) {
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)
        for handler in handlers.values { handler.attach(controller) }
    }

    /// Registration precedes controller.load because its first background
    /// callback can be synchronous. The caller rolls back if loading fails.
    func register(_ context: WKWebExtensionContext) -> @MainActor () -> Void {
        let id = context.uniqueIdentifier
        let previous = contexts[id], previousBackground = backgrounds[id]
        contexts[id] = WeakContext(context)
        if handlers[id] == nil {
            let handler = Handler(id: id, owner: self)
            handlers[id] = handler
            for controller in controllers.allObjects { handler.attach(controller) }
        }
        return { [weak self, weak context] in
            guard let self, let context, self.contexts[id]?.value === context else { return }
            self.contexts[id] = previous
            self.backgrounds[id] = previousBackground
        }
    }

    private func lifetime(for id: String) -> UUID? {
        guard let context = contexts[id]?.value, context.isLoaded else { return nil }
        // Public loadBackgroundContent returns only an error, not whether
        // it replaced anything. WebKit's read-only view identity distinguishes
        // a running background from a connect that is about to wake a new one.
        let selector = NSSelectorFromString("_backgroundWebView")
        guard context.responds(to: selector),
              let view = context.perform(selector)?.takeUnretainedValue() as? WKWebView else { return nil }
        created(view, in: context)
        return backgrounds[id]?.lifetime
    }

    func observe(_ id: String, generation: Int, token: String) async -> Int? {
        await withCheckedContinuation { done in
            observe(id, generation: generation, token: token, lifetime: lifetime(for: id)) { done.resume(returning: $0) }
        }
    }

    func observe(_ id: String, generation: Int, token: String, lifetime: UUID?, reply: @escaping (Int?) -> Void) {
        let current = self.generation(for: id)
        guard !token.isEmpty, token.count <= 128, generation >= 0, generation <= current else { reply(nil); return }
        if generation < current { reply(current) }
        else {
            cancel(id, token: token)
            waiting[id, default: [:]][token] = Observation(lifetime: lifetime, reply: reply)
        }
    }

    func cancel(_ id: String, token: String) {
        waiting[id]?.removeValue(forKey: token)?.reply(nil)
        if waiting[id]?.isEmpty == true { waiting[id] = nil }
    }

    func restarted(_ id: String) {
        let generation = generation(for: id) + 1
        generations[id] = generation
        backgrounds[id] = nil
        let replies = waiting.removeValue(forKey: id) ?? [:]
        replies.values.forEach { $0.reply(generation) }
    }

    func created(_ view: WKWebView, in context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        guard contexts[id]?.value === context, context.isLoaded,
              backgrounds[id]?.view !== view else { return }
        let background = Background(view)
        backgrounds[id] = background
        createdWorker(id, lifetime: background.lifetime)
    }

    func createdWorker(_ id: String, lifetime: UUID) {
        var replies: [(Int?) -> Void] = []
        for (token, var observation) in waiting[id] ?? [:] {
            if observation.lifetime == nil {
                // The caller connected while no background existed. It is
                // waiting for this one; it did not belong to the retired one.
                observation.lifetime = lifetime
                waiting[id]?[token] = observation
            } else if observation.lifetime != lifetime {
                waiting[id]?.removeValue(forKey: token)
                replies.append(observation.reply)
            }
        }
        // Remove old observers before callbacks can register fresh ports.
        replies.forEach { $0(generation(for: id)) }
    }

    @MainActor
    private final class Handler: NSObject, WKScriptMessageHandlerWithReply {
        let id: String
        unowned let owner: ExtensionWorkerRecovery
        let world: WKContentWorld

        init(id: String, owner: ExtensionWorkerRecovery) {
            self.id = id
            self.owner = owner
            // WebKit uses this shared named world for isolated scripts.
            // Retained through unload; no website main-world handler is added.
            world = .world(name: "WebExtension-" + id)
            super.init()
        }

        func attach(_ controller: WKUserContentController) {
            controller.addScriptMessageHandler(self, contentWorld: world, name: "searchWorkerRecovery")
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
            guard let request = message.body as? [String: Any], let token = request["token"] as? String,
                  !token.isEmpty, token.count <= 128 else { replyHandler(nil, "Invalid observer"); return }
            if request["cancel"] as? Bool == true {
                owner.cancel(id, token: token)
                replyHandler(nil, nil)
                return
            }
            guard let generation = request["generation"] as? Int, generation >= 0,
                  generation <= owner.generation(for: id) else { replyHandler(nil, "Invalid worker generation"); return }
            owner.observe(id, generation: generation, token: token, lifetime: owner.lifetime(for: id)) { replyHandler($0, nil) }
        }
    }
}
