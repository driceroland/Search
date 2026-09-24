import Foundation
import WebKit

// WebSockets for an extension's worker, opened by the browser.
//
// WebKit runs an extension's service worker on the main thread of the
// process it lives in. A WebSocket made from a worker sets its connection up
// on the main thread and waits for that to finish — so there it waits on
// itself, and the worker never runs again: every message to it goes
// unanswered until the browser quits. 1Password's worker does this as soon
// as it signs in (its notifier).
//
// So the shim gives a worker a WebSocket of its own (see ExtensionShims):
// each one a native port to "search.websocket", and here a
// URLSessionWebSocketTask on the other end. The connection is made as the
// worker's would have been — its URL and subprotocols, the extension's
// origin, its user agent, the cookies the extension's store holds for that
// address — and every frame is carried across as it comes.
//
// Over the port, to here: {op: "open", url, protocols, userAgent},
// {op: "send", text} or {op: "send", binary: base64}, {op: "close", code, reason}.
// Back: {ev: "ready"} once listening, {ev: "opening"} once the open is heard,
// {ev: "open", protocol}, {ev: "message", text} or {ev: "message", binary},
// {ev: "close", code, reason, clean}.

@available(macOS 15.4, *)
final class ExtensionSocket: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    static let application = "search.websocket"

    /// The open ones, held until they close.
    @MainActor private static var live: [ObjectIdentifier: ExtensionSocket] = [:]

    private let port: WKWebExtension.MessagePort
    private let origin: String
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var started = false
    private var opened = false
    private var ended = false
    /// The close the worker asked for, reported as the close if the server
    /// doesn't answer it with one of its own.
    private var closing: (code: Int, reason: String)?

    private init(port: WKWebExtension.MessagePort, origin: String) {
        self.port = port
        self.origin = origin
    }

    @MainActor
    static func connect(_ port: WKWebExtension.MessagePort, for context: WKWebExtensionContext) {
        var origin = context.baseURL.absoluteString
        if origin.hasSuffix("/") { origin.removeLast() }
        let socket = ExtensionSocket(port: port, origin: origin)
        live[ObjectIdentifier(socket)] = socket
        port.messageHandler = { message, _ in
            DispatchQueue.main.async { socket.take(message) }
        }
        port.disconnectHandler = { _ in
            DispatchQueue.main.async { socket.end(code: nil, reason: nil, clean: false, tell: false) }
        }
        // What the worker posts before this handler is set is lost, and it
        // posts at once: so it asks again until told it was heard.
        DispatchQueue.main.async { socket.tell(["ev": "ready"]) }
    }

    // MARK: - from the worker

    @MainActor
    private func take(_ message: Any?) {
        guard !ended, let message = message as? [String: Any], let op = message["op"] as? String else { return }
        switch op {
        case "open":
            guard !started else { return }
            started = true
            tell(["ev": "opening"])
            guard let text = message["url"] as? String, let url = URL(string: text),
                  ["ws", "wss"].contains(url.scheme?.lowercased() ?? "")
            else { end(code: 1006, reason: "", clean: false, tell: true); return }
            let protocols = message["protocols"] as? [String] ?? []
            let agent = message["userAgent"] as? String
            Task { @MainActor in await self.open(url, protocols: protocols, userAgent: agent) }
        case "send":
            guard let task, opened else { return }
            let frame: URLSessionWebSocketTask.Message
            if let text = message["text"] as? String {
                frame = .string(text)
            } else if let base64 = message["binary"] as? String, let data = Data(base64Encoded: base64) {
                frame = .data(data)
            } else { return }
            task.send(frame) { [weak self] error in
                guard error != nil else { return }
                DispatchQueue.main.async { self?.end(code: 1006, reason: "", clean: false, tell: true) }
            }
        case "close":
            let code = (message["code"] as? NSNumber)?.intValue ?? 1000
            let reason = message["reason"] as? String ?? ""
            guard let task else { end(code: 1006, reason: "", clean: false, tell: true); return }
            if !opened { task.cancel(); end(code: 1006, reason: "", clean: false, tell: true); return }
            // The worker's close is answered by the server's; didCloseWith
            // reports it.
            closing = (code, reason)
            let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
            task.cancel(with: closeCode, reason: reason.data(using: .utf8))
        default:
            return
        }
    }

    @MainActor
    private func open(_ url: URL, protocols: [String], userAgent: String?) async {
        var request = URLRequest(url: url)
        request.setValue(origin, forHTTPHeaderField: "Origin")
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if !protocols.isEmpty { request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol") }
        let cookies = await Store.websites.httpCookieStore.allCookies().filter { Self.matches($0, url) }
        if !cookies.isEmpty, let header = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] {
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }
        guard !ended else { return }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        let task = session.webSocketTask(with: request)
        // A browser's socket takes messages of any size; URLSession's stops
        // at one megabyte unless told otherwise.
        task.maximumMessageSize = 64 << 20
        self.session = session
        self.task = task
        task.resume()
    }

    /// Whether the extension's store would send this cookie to this address.
    private static func matches(_ cookie: HTTPCookie, _ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if let expires = cookie.expiresDate, expires < Date() { return false }
        if cookie.isSecure && url.scheme?.lowercased() != "wss" { return false }
        let domain = cookie.domain.lowercased()
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard host == bare || host.hasSuffix("." + bare) else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        return path.hasPrefix(cookie.path)
    }

    // MARK: - from the server

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.ended else { return }
                switch result {
                case .success(.string(let text)):
                    self.tell(["ev": "message", "text": text])
                    self.receive()
                case .success(.data(let data)):
                    self.tell(["ev": "message", "binary": data.base64EncodedString()])
                    self.receive()
                case .success:
                    self.receive()
                case .failure:
                    // A close from either side ends the loop too; that one
                    // is reported by didCloseWith, with its code.
                    break
                }
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        MainActor.assumeIsolated {
            guard !ended else { return }
            opened = true
            tell(["ev": "open", "protocol": `protocol` ?? ""])
            receive()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        MainActor.assumeIsolated {
            let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            end(code: closeCode.rawValue, reason: text, clean: true, tell: true)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            if let closing {
                end(code: closing.code, reason: closing.reason, clean: true, tell: true)
                return
            }
            // Refused, unreachable, or dropped without a close frame.
            end(code: 1006, reason: "", clean: false, tell: true)
        }
    }

    // MARK: -

    @MainActor
    private func tell(_ message: [String: Any]) {
        guard !port.isDisconnected else { return }
        port.sendMessage(message, completionHandler: nil)
    }

    @MainActor
    private func end(code: Int?, reason: String?, clean: Bool, tell told: Bool) {
        guard !ended else { return }
        ended = true
        if told, let code { tell(["ev": "close", "code": code, "reason": reason ?? "", "clean": clean]) }
        task?.cancel()
        session?.invalidateAndCancel()
        port.messageHandler = nil
        port.disconnectHandler = nil
        if !port.isDisconnected { port.disconnect() }
        Self.live[ObjectIdentifier(self)] = nil
    }
}
