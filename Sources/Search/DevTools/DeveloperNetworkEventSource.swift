import WebKit

/// EventSource records emitted by the inspected page. The WebKit Network
/// domain reports the HTTP requests, but has no event for the messages.
@MainActor
final class DeveloperNetworkEventSource {
    private struct Connection {
        let url: String
        let documentURL: String?
        let startedAfter: Double
        let opened: Double
        let stream: String?
        var requestID: String?
        var frames: [DeveloperNetworkTools.Frame] = []
        var count = 0
        var dropped = 0
    }

    /// A source as the page created it, before it opens. Its request is
    /// reserved from then on, so a later source on the same URL that opens
    /// first can't take it.
    private struct Stream {
        let url: String
        let documentURL: String?
        let created: Double
        var requestID: String?
    }

    private static let handler = "perchNetworkEventSource"
    private static let connectionLimit = 32
    private static let messageLimit = 512
    private static let frameLimit = 64
    /// One message handler per content controller, shared by the sessions on
    /// it: adding a second handler with the same name raises.
    private static var relays: [ObjectIdentifier: Relay] = [:]
    private let sessionID = UUID()
    private weak var web: WKWebView?
    private var script: WKUserScript?
    private var frames: [String: WKFrameInfo] = [:]
    private var frameOrder: [String] = []
    private var mainDocument: String?
    private var connections: [String: Connection] = [:]
    private var order: [String] = []
    private var streams: [String: Stream] = [:]
    private var streamOrder: [String] = []

    func start(on web: WKWebView) {
        guard script == nil else { return }
        self.web = web
        let content = web.configuration.userContentController
        let source = DeveloperNetworkBridgeScript.eventSource(session: sessionID)
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        self.script = script
        Self.relay(for: content).owners[sessionID] = Owner(value: self)
        content.addUserScript(script)
        ArmedRiders.add(script, to: content)
        // The current document gets the capture now. Existing subframes get it
        // at their next navigation, since WKWebView doesn't list their frames.
        web.evaluateJavaScript(source, in: nil, in: .page, completionHandler: nil)
    }

    private static func relay(for content: WKUserContentController) -> Relay {
        let id = ObjectIdentifier(content)
        if let relay = relays[id], relay.content === content { return relay }
        let relay = Relay(content)
        relays[id] = relay
        content.add(relay, contentWorld: .page, name: handler)
        return relay
    }

    func stop() {
        guard let script else { return }
        self.script = nil
        ArmedRiders.remove(script)
        defer {
            frames.removeAll()
            frameOrder.removeAll()
            mainDocument = nil
            clear()
            self.web = nil
        }
        guard let web else { return }
        let content = web.configuration.userContentController
        let id = ObjectIdentifier(content)
        if let relay = Self.relays[id], relay.content === content {
            relay.owners[sessionID] = nil
            if relay.owners.values.allSatisfy({ $0.value == nil }) {
                Self.relays[id] = nil
                content.removeScriptMessageHandler(forName: Self.handler, contentWorld: .page)
            }
        }
        if content.userScripts.contains(where: { $0 === script }) {
            let kept = content.userScripts.filter { $0 !== script }
            content.removeAllUserScripts()
            kept.forEach(content.addUserScript)
        }
        let cleanup = """
            { const capture = globalThis[Symbol.for('perch.eventSourceCapture')];
              if (capture?.owns?.('\(sessionID.uuidString)')) capture.stop(); }
            """
        web.evaluateJavaScript(cleanup, in: nil, in: .page, completionHandler: nil)
        for frame in frames.values where !frame.isMainFrame {
            web.evaluateJavaScript(cleanup, in: frame, in: .page, completionHandler: nil)
        }
    }

    func clear() {
        connections.removeAll()
        order.removeAll()
        streams.removeAll()
        streamOrder.removeAll()
    }

    /// Messages the page received that weren't recorded, in a burst too
    /// large to send.
    func dropped(for requestID: String) -> Int {
        connections.values.first { $0.requestID == requestID }?.dropped ?? 0
    }

    /// The frames to restore when capture stops. The page's own is always
    /// reached; subframes are kept by document, most recent last, and a new
    /// page document takes the old one's subframes with it.
    private func remember(_ frame: String, _ info: WKFrameInfo) {
        if info.isMainFrame {
            if mainDocument != frame {
                mainDocument = frame
                frames.removeAll()
                frameOrder.removeAll()
            }
            return
        }
        if frames[frame] != nil { frameOrder.removeAll { $0 == frame } }
        frames[frame] = info
        frameOrder.append(frame)
        if frameOrder.count > Self.frameLimit {
            for id in frameOrder.prefix(frameOrder.count - Self.frameLimit) { frames[id] = nil }
            frameOrder.removeFirst(frameOrder.count - Self.frameLimit)
        }
    }

    private func receive(_ message: WKScriptMessage) {
        guard script != nil, let web, message.webView === web,
              let body = message.body as? [String: Any], body["session"] as? String == sessionID.uuidString,
              let frame = body["frame"] as? String, frame.count <= 80,
              let list = body["messages"] as? [[String: Any]] else { return }
        remember(frame, message.frameInfo)
        let document = message.frameInfo.request.url.flatMap { Self.address($0.absoluteString, omitQuery: true) }
        for item in (body["streams"] as? [[String: Any]] ?? []).prefix(128) {
            guard let id = item["stream"] as? String, id.count <= 100, id.hasPrefix(frame + "-"), streams[id] == nil,
                  let rawURL = item["url"] as? String, rawURL.count <= 8_192,
                  let url = Self.address(rawURL),
                  let created = item["after"] as? Double, created.isFinite else { continue }
            streams[id] = Stream(url: url, documentURL: document, created: created)
            streamOrder.append(id)
        }
        for item in list.prefix(128) {
            guard let key = item["connection"] as? String, key.count <= 100, key.hasPrefix(frame + "-"),
                  let rawURL = item["url"] as? String, rawURL.count <= 8_192,
                  let url = Self.address(rawURL),
                  let start = item["after"] as? Double, start.isFinite,
                  let opened = item["opened"] as? Double, opened.isFinite, opened >= start,
                  let time = item["time"] as? Double, time.isFinite, time >= opened,
                  let type = item["type"] as? String, let payload = item["data"] as? String else { continue }
            if connections[key] == nil {
                let stream = (item["stream"] as? String).flatMap { $0.count <= 100 && key.hasPrefix($0 + "-") ? $0 : nil }
                connections[key] = Connection(url: url, documentURL: document, startedAfter: start, opened: opened,
                                              stream: stream)
                order.append(key)
            }
            guard var connection = connections[key] else { continue }
            let data = String(payload.prefix(8_192))
            connection.count += 1
            connection.frames.append(.init(id: connection.count, kind: .received, opcode: nil,
                                           data: data, length: data.utf8.count, time: time,
                                           eventID: (item["eventId"] as? String).map { String($0.prefix(512)) },
                                           eventType: String(type.prefix(256))))
            connections[key] = connection
        }
        for (key, value) in (body["dropped"] as? [String: Any] ?? [:]).prefix(128) {
            guard key.hasPrefix(frame + "-"), let count = value as? Int, count > 0 else { continue }
            connections[key]?.dropped += min(count, 1_000_000)
        }
        trim()
    }

    private func trim() {
        if order.count > Self.connectionLimit {
            let excess = order.count - Self.connectionLimit
            for id in order.prefix(excess) { connections[id] = nil }
            order.removeFirst(excess)
        }
        if streamOrder.count > Self.connectionLimit {
            let excess = streamOrder.count - Self.connectionLimit
            for id in streamOrder.prefix(excess) { streams[id] = nil }
            streamOrder.removeFirst(excess)
        }
        var excess = connections.values.reduce(0) { $0 + $1.frames.count } - Self.messageLimit
        for id in order where excess > 0 {
            guard let count = connections[id]?.frames.count, count > 0 else { continue }
            let removed = min(count, excess)
            connections[id]?.frames.removeFirst(removed)
            excess -= removed
        }
    }

    func messages(for requestID: String, after count: Int, requests: [DeveloperToolsSession.Request])
        -> (count: Int, frames: [DeveloperNetworkTools.Frame]) {
        // Bridge request wall time and the constructor/open interval are in
        // the same clock. Match one HTTP request per connection, including
        // reconnects, and keep that match as further messages arrive. Sources
        // are matched in the order the page created them, each to the
        // earliest request left for its URL.
        let requests = requests.filter(\.isEventSource)
            .sorted { ($0.wallStarted ?? 0) < ($1.wallStarted ?? 0) }
        for key in order {
            guard let connection = connections[key], connection.requestID == nil, let stream = connection.stream,
                  key == stream + "-1", let reserved = streams[stream]?.requestID else { continue }
            connections[key]?.requestID = reserved
        }
        var claimed = Set(connections.values.compactMap(\.requestID)).union(streams.values.compactMap(\.requestID))
        struct Waiting {
            let connection: String?
            let stream: String?
            let url: String
            let documentURL: String?
            let from: Double
            let until: Double
        }
        var waiting = order.compactMap { key -> Waiting? in
            guard let connection = connections[key], connection.requestID == nil else { return nil }
            return Waiting(connection: key, stream: nil, url: connection.url, documentURL: connection.documentURL,
                           from: connection.startedAfter, until: connection.opened)
        }
        // Not opened yet: its request is sent from the constructor.
        waiting += streamOrder.compactMap { id -> Waiting? in
            guard let stream = streams[id], stream.requestID == nil, connections[id + "-1"] == nil else { return nil }
            return Waiting(connection: nil, stream: id, url: stream.url, documentURL: stream.documentURL,
                           from: stream.created, until: stream.created + 0.5)
        }
        waiting.sort { $0.from < $1.from }
        for item in waiting {
            let match = requests.first { request in
                guard !claimed.contains(request.id), let time = request.wallStarted,
                      item.from - 0.05 <= time, time <= item.until + 0.05,
                      Self.address(request.originalURL ?? request.url) == item.url else { return false }
                guard let page = request.documentURL.flatMap({ Self.address($0, omitQuery: true) }),
                      let frame = item.documentURL else { return true }
                return page == frame
            }
            guard let match else { continue }
            claimed.insert(match.id)
            if let key = item.connection { connections[key]?.requestID = match.id }
            if let id = item.stream { streams[id]?.requestID = match.id }
        }
        guard let connection = connections.values.first(where: { $0.requestID == requestID }) else { return (count, []) }
        return (connection.count, connection.frames.filter { $0.id > count })
    }

    private static func address(_ url: String, omitQuery: Bool = false) -> String? {
        guard var address = URLComponents(string: url), let scheme = address.scheme,
              scheme == "http" || scheme == "https" else { return nil }
        address.user = nil
        address.password = nil
        address.fragment = nil
        if omitQuery { address.query = nil }
        return address.string
    }

    private struct Owner {
        weak var value: DeveloperNetworkEventSource?
    }

    private final class Relay: NSObject, WKScriptMessageHandler {
        weak var content: WKUserContentController?
        var owners: [UUID: Owner] = [:]
        init(_ content: WKUserContentController) { self.content = content }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                for owner in owners.values { owner.value?.receive(message) }
            }
        }
    }
}
