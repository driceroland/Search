import WebKit

/// One notification when Swift has actually retired an extension context.
/// This bridge only observes recovery; it cannot initiate it or call APIs.
@available(macOS 15.4, *)
@MainActor
final class ExtensionWorkerRecovery {
    static let shared = ExtensionWorkerRecovery()
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var handlers: [String: Handler] = [:]
    private var generations: [String: Int] = [:]
    private var waiting: [String: [String: (Int) -> Void]] = [:]

    func generation(for id: String) -> Int { generations[id, default: 0] }

    func attach(_ controller: WKUserContentController) {
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)
        for handler in handlers.values { handler.attach(controller) }
    }

    func register(_ id: String) {
        guard handlers[id] == nil else { return }
        let handler = Handler(id: id, owner: self)
        handlers[id] = handler
        for controller in controllers.allObjects { handler.attach(controller) }
    }

    func observe(_ id: String, generation: Int, token: String) async -> Int {
        await withCheckedContinuation { done in
            observe(id, generation: generation, token: token) { done.resume(returning: $0) }
        }
    }

    func observe(_ id: String, generation: Int, token: String, reply: @escaping (Int) -> Void) {
        let current = self.generation(for: id)
        guard !token.isEmpty, token.count <= 128, generation >= 0, generation <= current else { reply(generation); return }
        if generation < current { reply(current) }
        else {
            cancel(id, token: token)
            waiting[id, default: [:]][token] = reply
        }
    }

    func cancel(_ id: String, token: String) {
        waiting[id]?.removeValue(forKey: token)?(generation(for: id))
        if waiting[id]?.isEmpty == true { waiting[id] = nil }
    }

    func restarted(_ id: String) {
        let generation = generation(for: id) + 1
        generations[id] = generation
        // Remove first: a reply may arrange a subscription for the next one.
        let replies = waiting.removeValue(forKey: id) ?? [:]
        replies.values.forEach { $0(generation) }
    }

    @MainActor
    private final class Handler: NSObject, WKScriptMessageHandlerWithReply {
        let id: String
        unowned let owner: ExtensionWorkerRecovery
        let world: WKContentWorld

        init(id: String, owner: ExtensionWorkerRecovery) {
            self.id = id
            self.owner = owner
            // WebKit uses this shared named world for the extension's
            // isolated content scripts (WebExtensionContextCocoa.mm).
            // Keep it through unload so existing content scripts survive.
            // No handler is installed in a website's main world.
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
                  generation <= owner.generation(for: id) else {
                replyHandler(nil, "Invalid worker generation")
                return
            }
            owner.observe(id, generation: generation, token: token) { replyHandler($0, nil) }
        }
    }
}
