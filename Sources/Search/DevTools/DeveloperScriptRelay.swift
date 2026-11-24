import WebKit

/// A capture script in the inspected page's world that reports to its owner
/// through a message handler. WebKit allows one handler per name on a content
/// controller, so one relay per controller and name is shared by every
/// capture on it, each owner held weakly.
@MainActor
struct DeveloperScriptRelay {
    let handler: String
    private(set) var script: WKUserScript?
    private(set) weak var web: WKWebView?
    /// Subframes that reported, most recent last: the frames to restore when
    /// capture stops.
    private(set) var frames: [String: WKFrameInfo] = [:]
    private var frameOrder: [String] = []
    private static let frameLimit = 64
    private static var relays: [Key: Relay] = [:]

    nonisolated init(handler: String) { self.handler = handler }

    /// Puts `source` in every frame from the next navigation on, and in the
    /// current document now; reports go to `receive` while `owner` lives.
    mutating func start(_ source: String, key: UUID, owner: AnyObject, on web: WKWebView,
                        receive: @escaping (WKScriptMessage) -> Void) {
        let content = web.configuration.userContentController
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        self.script = script
        self.web = web
        relay(for: content).owners[key] = Owner(value: owner, receive: receive)
        content.addUserScript(script)
        ArmedRiders.add(script, to: content)
        // Existing subframes get it at their next navigation, since WKWebView
        // doesn't list their frames.
        web.evaluateJavaScript(source, in: nil, in: .page, completionHandler: nil)
    }

    private func relay(for content: WKUserContentController) -> Relay {
        let id = Key(content: ObjectIdentifier(content), handler: handler)
        if let relay = Self.relays[id], relay.content === content { return relay }
        let relay = Relay(content)
        Self.relays[id] = relay
        content.add(relay, contentWorld: .page, name: handler)
        return relay
    }

    /// Takes the script out of the tab, and stops the capture whose
    /// `Symbol.for(symbol)` global owns `key` in the frames it reached.
    /// False when nothing was started.
    @discardableResult
    mutating func stop(key: UUID, symbol: String) -> Bool {
        guard let script else { return false }
        self.script = nil
        ArmedRiders.remove(script)
        defer {
            forgetFrames()
            self.web = nil
        }
        guard let web else { return true }
        let content = web.configuration.userContentController
        let id = Key(content: ObjectIdentifier(content), handler: handler)
        if let relay = Self.relays[id], relay.content === content {
            relay.owners[key] = nil
            if relay.owners.values.allSatisfy({ $0.value == nil }) {
                Self.relays[id] = nil
                content.removeScriptMessageHandler(forName: handler, contentWorld: .page)
            }
        }
        content.developerRemove(script)
        let cleanup = """
            { const capture = globalThis[Symbol.for('\(symbol)')];
              if (capture?.owns?.('\(key.uuidString)')) capture.stop(); }
            """
        web.evaluateJavaScript(cleanup, in: nil, in: .page, completionHandler: nil)
        for frame in frames.values where !frame.isMainFrame {
            web.evaluateJavaScript(cleanup, in: frame, in: .page, completionHandler: nil)
        }
        return true
    }

    /// Keeps a reporting subframe, most recent last, up to the limit.
    mutating func remember(_ frame: String, _ info: WKFrameInfo) {
        if info.isMainFrame { return }
        if frames[frame] != nil { frameOrder.removeAll { $0 == frame } }
        frames[frame] = info
        frameOrder.append(frame)
        if frameOrder.count > Self.frameLimit {
            for id in frameOrder.prefix(frameOrder.count - Self.frameLimit) { frames[id] = nil }
            frameOrder.removeFirst(frameOrder.count - Self.frameLimit)
        }
    }

    mutating func forgetFrames() {
        frames.removeAll()
        frameOrder.removeAll()
    }

    private struct Key: Hashable {
        let content: ObjectIdentifier
        let handler: String
    }

    private struct Owner {
        weak var value: AnyObject?
        let receive: (WKScriptMessage) -> Void
    }

    private final class Relay: NSObject, WKScriptMessageHandler {
        weak var content: WKUserContentController?
        var owners: [UUID: Owner] = [:]
        init(_ content: WKUserContentController) { self.content = content }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                for owner in owners.values where owner.value != nil { owner.receive(message) }
            }
        }
    }
}
