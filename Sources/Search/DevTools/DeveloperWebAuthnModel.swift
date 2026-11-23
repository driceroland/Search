import AppKit
import UniformTypeIdentifiers
import WebKit

/// The WebAuthn tool's state for one DevTools session: whether the virtual
/// authenticator environment is on, its authenticators and their
/// credentials. While it's on, DeveloperWebAuthn-hooks.js is in the tab
/// (kept through navigations) and its requests come to `answer`.
@MainActor
final class DeveloperWebAuthnModel: ObservableObject {
    @Published private(set) var enabled = false
    @Published var authenticators: [DeveloperVirtualAuthenticator] = []
    @Published var active: UUID?
    @Published private(set) var problem: String?
    /// The last requests answered, newest last, for the tool's log.
    @Published private(set) var log: [String] = []

    static let handlerName = "perchWebAuthn"
    static let hooksScript = DevToolsResources.script("DeveloperWebAuthn-hooks.js")

    private weak var session: DeveloperToolsSession?
    private weak var observedWeb: WKWebView?
    private var script: WKUserScript?
    private var relay: Relay?
    private var loading: NSKeyValueObservation?
    private var counter = 0

    private static var models: [ObjectIdentifier: (session: WeakSession, model: DeveloperWebAuthnModel)] = [:]
    struct WeakSession { weak var value: DeveloperToolsSession? }

    static func model(for session: DeveloperToolsSession) -> DeveloperWebAuthnModel {
        for (key, entry) in models where entry.session.value == nil {
            entry.model.disable()
            models[key] = nil
        }
        let key = ObjectIdentifier(session)
        if let found = models[key], found.session.value === session { return found.model }
        let model = DeveloperWebAuthnModel(session: session)
        models[key] = (WeakSession(value: session), model)
        return model
    }

    private init(session: DeveloperToolsSession) { self.session = session }

    // MARK: The environment

    func setEnabled(_ on: Bool) { on ? enable() : disable() }

    private func enable() {
        guard let web = session?.web else {
            problem = "The inspected page isn’t available."
            return
        }
        problem = nil
        let controller = web.configuration.userContentController
        let relay = Relay { [weak self] body, frame, reply in self?.answer(body, frame: frame, reply: reply) }
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
        controller.addScriptMessageHandler(relay, contentWorld: .page, name: Self.handlerName)
        let script = WKUserScript(source: Self.hooksScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        controller.addUserScript(script)
        ArmedRiders.add(script, to: controller)
        loading = web.observe(\.isLoading, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated {
                guard let self, let script = self.script, web.isLoading else { return }
                let controller = web.configuration.userContentController
                if !controller.userScripts.contains(where: { $0 === script }) { controller.addUserScript(script) }
            }
        }
        self.script = script
        self.relay = relay
        observedWeb = web
        enabled = true
        // The page already up gets the hooks now.
        web.evaluateJavaScript(Self.hooksScript, in: nil, in: .page, completionHandler: nil)
    }

    private func disable() {
        loading?.invalidate()
        loading = nil
        if let web = observedWeb {
            let controller = web.configuration.userContentController
            controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
            if let script {
                ArmedRiders.remove(script)
                if controller.userScripts.contains(where: { $0 === script }) {
                    let others = controller.userScripts.filter { $0 !== script }
                    controller.removeAllUserScripts()
                    others.forEach(controller.addUserScript)
                }
            }
        }
        script = nil
        relay = nil
        observedWeb = nil
        enabled = false
    }

    // MARK: Authenticators

    func addAuthenticator(_ template: DeveloperVirtualAuthenticator) {
        counter += 1
        var authenticator = template
        authenticator.name = "Authenticator \(counter)"
        if authenticator.protocolKind == .u2f { authenticator.residentKeys = false; authenticator.userVerification = false }
        authenticators.append(authenticator)
        active = authenticator.id
    }

    func removeAuthenticator(_ id: UUID) {
        authenticators.removeAll { $0.id == id }
        if active == id { active = authenticators.first?.id }
    }

    func removeCredential(_ credential: Data, from authenticator: UUID) {
        guard let index = authenticators.firstIndex(where: { $0.id == authenticator }) else { return }
        authenticators[index].credentials.removeAll { $0.id == credential }
    }

    /// Chrome's Export: the credential's private key as a PEM file.
    func export(_ credential: DeveloperWebAuthnCredential) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Credential.pem"
        panel.allowedContentTypes = [UTType(filenameExtension: "pem") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(credential.pem.utf8).write(to: url) } catch { problem = error.localizedDescription }
    }

    // MARK: Requests

    private func answer(_ body: Any, frame: WKFrameInfo, reply: @escaping (Any?, String?) -> Void) {
        let message = body as? [String: Any] ?? [:]
        let kind = message["kind"] as? String ?? ""
        let origin = frame.securityOrigin
        let host = origin.host
        var text = "\(origin.protocol)://\(host)"
        if origin.port != 0 { text += ":\(origin.port)" }
        guard enabled, frame.webView === observedWeb else {
            return reply(["error": "NotAllowedError", "message": "The virtual authenticator environment is off."], nil)
        }
        if kind == "platform" {
            let available = authenticators.first { $0.id == active }.map { $0.transport == .internal && $0.supportsUserVerification } ?? false
            return reply(["available": available], nil)
        }
        guard let index = authenticators.firstIndex(where: { $0.id == active }) else {
            note("\(kind) for \(host): no active authenticator")
            return reply(["error": "NotAllowedError", "message": "No virtual authenticator is active."], nil)
        }
        let request = message["request"] as? [String: Any] ?? [:]
        do {
            let result = kind == "create"
                ? try DeveloperWebAuthn.create(request, origin: text, host: host, authenticator: &authenticators[index])
                : try DeveloperWebAuthn.get(request, origin: text, host: host, authenticator: &authenticators[index])
            note("\(kind == "create" ? "Registered" : "Signed in") on \(host) with \(authenticators[index].name)")
            reply(result, nil)
        } catch let failure as DeveloperWebAuthn.Failure {
            note("\(kind) on \(host): \(failure.name): \(failure.message)")
            reply(["error": failure.name, "message": failure.message], nil)
        } catch {
            reply(["error": "UnknownError", "message": error.localizedDescription], nil)
        }
    }

    private func note(_ line: String) {
        log.append(line)
        if log.count > 50 { log.removeFirst(log.count - 50) }
    }

    private final class Relay: NSObject, WKScriptMessageHandlerWithReply {
        let receive: @MainActor (Any, WKFrameInfo, @escaping (Any?, String?) -> Void) -> Void
        init(_ receive: @escaping @MainActor (Any, WKFrameInfo, @escaping (Any?, String?) -> Void) -> Void) {
            self.receive = receive
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
            MainActor.assumeIsolated { receive(message.body, message.frameInfo, replyHandler) }
        }
    }
}
