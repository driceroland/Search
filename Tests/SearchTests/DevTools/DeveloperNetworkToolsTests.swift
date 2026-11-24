import AppKit
import Network
import WebKit
import XCTest
import os
@testable import Search

@MainActor
final class DeveloperNetworkToolsTests: XCTestCase {
    private func details(method: String = "GET", url: String, headers: [[String]], post: String? = nil) -> DeveloperRequestDetails {
        var raw: [String: Any] = ["url": url, "method": method, "requestHeaders": headers]
        if let post { raw["postData"] = post }
        return DeveloperRequestDetails(raw)
    }

    func testCopyAsCurlAndFetchMatchChromium() {
        let get = details(url: "https://example.test/api?q=1", headers: [
            ["Accept", "*/*"], ["Accept-Encoding", "gzip"], ["Cookie", "a=1; b=2"], ["User-Agent", "Perch"],
            ["Referer", "https://example.test/"], ["X-Note", "it's"],
        ])
        XCTAssertEqual(DeveloperRequestCopy.curl(get), """
            curl --url 'https://example.test/api?q=1' \\
              -H 'Accept: */*' \\
              -b 'a=1; b=2' \\
              -H 'User-Agent: Perch' \\
              -H 'Referer: https://example.test/' \\
              -H $'X-Note: it\\'s'
            """)
        XCTAssertEqual(DeveloperRequestCopy.fetch(get), """
            fetch("https://example.test/api?q=1", {
              "headers": {
                "accept": "*/*",
                "x-note": "it's"
              },
              "referrer": "https://example.test/",
              "body": null,
              "method": "GET",
              "mode": "cors",
              "credentials": "include"
            });
            """)
        XCTAssertEqual(DeveloperRequestCopy.fetch(get, node: true), """
            fetch("https://example.test/api?q=1", {
              "headers": {
                "accept": "*/*",
                "x-note": "it's",
                "cookie": "a=1; b=2",
                "Referer": "https://example.test/"
              },
              "body": null,
              "method": "GET"
            });
            """)

        let post = details(method: "POST", url: "https://example.test/form", headers: [
            ["Content-Type", "application/json"], ["Content-Length", "13"],
        ], post: #"{"a":"b\n!"}"#)
        XCTAssertEqual(DeveloperRequestCopy.curl(post), """
            curl --url 'https://example.test/form' \\
              -H 'Content-Type: application/json' \\
              --data-raw $'{"a":"b\\\\n\\u0021"}'
            """)
        XCTAssertTrue(DeveloperRequestCopy.fetch(post).contains(#""body": "{\"a\":\"b\\n!\"}","#))
        let put = details(method: "PUT", url: "https://example.test/x", headers: [])
        XCTAssertEqual(DeveloperRequestCopy.curl(put), "curl --url 'https://example.test/x' -X 'PUT'")
        XCTAssertEqual(DeveloperRequestCopy.curl(details(url: "blob:https://example.test/1", headers: [])),
                       "# Unsupported URL scheme")
        XCTAssertEqual(DeveloperRequestCopy.powerShell(get), """
            $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
            $session.UserAgent = "Perch"
            $session.Cookies.Add((New-Object System.Net.Cookie("a", "1", "/", "example.test")))
            $session.Cookies.Add((New-Object System.Net.Cookie("b", "2", "/", "example.test")))
            Invoke-WebRequest -UseBasicParsing -Uri "https://example.test/api?q=1" `
            -WebSession $session `
            -Headers @{
            "Accept"="*/*"
              "Accept-Encoding"="gzip"
              "Referer"="https://example.test/"
              "X-Note"="it's"
            }
            """)
        XCTAssertEqual(DeveloperRequestCopy.powerShell(put),
                       #"Invoke-WebRequest -UseBasicParsing -Uri "https://example.test/x" -Method "PUT""#)
    }

    func testServerTimingAndTimingPhasesAsChromeNamesThem() {
        let metrics = DeveloperNetworkTiming.serverTiming([("Server-Timing", #"db;dur=53.2;desc="Database", cache;desc=hit"#)])
        XCTAssertEqual(metrics.map(\.name), ["db", "cache"])
        XCTAssertEqual(metrics.first?.duration, 53.2)
        XCTAssertEqual(metrics.map(\.description), ["Database", "hit"])

        var request = DeveloperToolsSession.Request(id: "1", url: "https://example.test/", method: "GET",
                                                    type: "document", loader: nil, started: 100)
        request.ended = 100.5
        let phases = DeveloperNetworkTiming.phases(for: request, timing: [
            "startTime": 100, "fetchStart": 100.01, "domainLookupStart": 1, "domainLookupEnd": 5,
            "connectStart": 5, "connectEnd": 40, "secureConnectionStart": 20, "requestStart": 41,
            "responseStart": 200, "redirectStart": -1,
        ])
        XCTAssertEqual(phases.map(\.label), ["Queueing", "Stalled", "DNS lookup", "Initial connection", "SSL",
                                             "Request sent", "Waiting for server response", "Content download"])
        XCTAssertEqual(phases.first { $0.label == "DNS lookup" }.map { $0.end - $0.start } ?? 0, 4, accuracy: 0.001)
        XCTAssertEqual(phases.last?.end ?? 0, 500, accuracy: 0.001)
    }

    func testBlockingPatternsAsChromeWritesThem() {
        XCTAssertEqual(DeveloperNetworkTools.urlPattern(for: "https://cdn.example.test:8443/a/b.js?x=1"),
                       "*://cdn.example.test:8443/a/b.js?x=1")
        XCTAssertEqual(DeveloperNetworkTools.domainPattern(for: "https://cdn.example.test/a.js"), "*://cdn.example.test")
        XCTAssertEqual(DeveloperNetworkTools.escapeForURLPattern("a*(b):c"), #"a\*\(b\)\:c"#)
        XCTAssertTrue(DeveloperNetworkBlockingView.matches("*://cdn.example.test", "https://cdn.example.test/a.js"))
    }

    func testFilterKeysNegationAndInvert() {
        var image = DeveloperToolsSession.Request(id: "1", url: "https://img.example.test/a.png", method: "GET",
                                                  type: "Image", loader: nil, started: 1)
        image.status = 200
        image.mimeType = "image/png"
        image.bytes = 2_500
        image.ended = 2
        var api = DeveloperToolsSession.Request(id: "2", url: "https://api.example.test/v1/items", method: "POST",
                                                type: "Fetch", loader: nil, started: 1)
        api.status = 404
        api.mimeType = "application/json"
        api.bytes = 200
        api.cached = true
        var extra = DeveloperNetworkTools.Extra()
        extra.responseHeaders = ["x-trace"]
        let rows = [image, api]
        func names(_ query: String, invert: Bool = false) -> [String] {
            let filter = DeveloperNetworkFilter(query, invert: invert)
            return rows.filter { filter.matches($0, extra: $0.id == "2" ? extra : nil) }.map(\.id)
        }
        XCTAssertEqual(names("status-code:404"), ["2"])
        XCTAssertEqual(names("method:POST"), ["2"])
        XCTAssertEqual(names("-method:POST"), ["1"])
        XCTAssertEqual(names("domain:*.example.test"), ["1", "2"])
        XCTAssertEqual(names("domain:img.*"), ["1"])
        XCTAssertEqual(names("mime-type:image/png"), ["1"])
        XCTAssertEqual(names("larger-than:1k"), ["1"])
        XCTAssertEqual(names("larger-than:3k"), [])
        XCTAssertEqual(names("is:from-cache"), ["2"])
        XCTAssertEqual(names("has-response-header:X-Trace"), ["2"])
        XCTAssertEqual(names("/items$/"), ["2"])
        XCTAssertEqual(names("png"), ["1"])
        XCTAssertEqual(names("png", invert: true), ["2"])
        XCTAssertEqual(names("-png", invert: true), ["1"])
        XCTAssertEqual(names("api status-code:404"), ["2"])
        XCTAssertEqual(names("unknown:key"), [], "an unknown key is plain text")
        XCTAssertEqual(DeveloperNetworkColumn.sort(rows, by: .size, ascending: true, extras: [:]).map(\.id), ["2", "1"])
        XCTAssertEqual(DeveloperNetworkColumn.sort(rows, by: .name, ascending: false, extras: [:]).map(\.id), ["2", "1"])
        XCTAssertEqual(DeveloperNetworkColumn.value(.domain, image, nil), "img.example.test")
        XCTAssertEqual(DeveloperNetworkColumn.value(.path, api, nil), "/v1/items")
    }

    /// Narrow docks fold toolbar groups into » from the right; nothing wraps.
    func testToolbarFoldsIntoOverflowAsTheDockNarrows() {
        let label = DeveloperToolsSession.NetworkCondition.unrestricted.rawValue
        let all = DeveloperNetworkToolbar.Item.allCases
        XCTAssertEqual(DeveloperNetworkToolbar.shown(width: 1_200, conditionLabel: label), all)
        XCTAssertEqual(DeveloperNetworkToolbar.shown(width: 800, conditionLabel: label), all)
        let medium = DeveloperNetworkToolbar.shown(width: 400, conditionLabel: label)
        XCTAssertLessThan(medium.count, all.count, "400pt folds some groups")
        XCTAssertEqual(medium, Array(all.prefix(medium.count)), "groups fold from the right")
        XCTAssertTrue(DeveloperNetworkToolbar.shown(width: 160, conditionLabel: label).isEmpty)
        var last = all.count
        for width in stride(from: 1_200, through: 200, by: -20) {
            let count = DeveloperNetworkToolbar.shown(width: CGFloat(width), conditionLabel: label).count
            XCTAssertLessThanOrEqual(count, last, "narrower never shows more")
            last = count
        }
        XCTAssertTrue(DeveloperNetworkToolbar.chipsShareFilterRow(width: 1_200))
        XCTAssertFalse(DeveloperNetworkToolbar.chipsShareFilterRow(width: 800))
        XCTAssertGreaterThan(560, DeveloperNetworkToolbar.compactFilterWidth)
        XCTAssertLessThan(400, DeveloperNetworkToolbar.compactFilterWidth)
    }

    func testInitiatorFramesReadAsChromeLinksThem() {
        let raw: [String: Any] = ["url": "https://example.test/data", "initiator": [
            "type": "script", "stack": [
                ["functionName": "load", "url": "https://example.test/js/app.js?v=2", "lineNumber": 3, "columnNumber": 12],
                ["functionName": "", "url": "https://example.test/js/app.js?v=2", "lineNumber": 5],
            ],
        ]]
        let details = DeveloperRequestDetails(raw)
        XCTAssertEqual(details.frames.map(\.location), ["app.js:3", "app.js:5"])
        XCTAssertEqual(details.frames.first?.column, 12)
        XCTAssertEqual(details.stack, ["load @ https://example.test/js/app.js?v=2:3", "(anonymous) @ https://example.test/js/app.js?v=2:5"])
    }

    func testHARWrittenByPerchReadsBack() throws {
        var request = DeveloperToolsSession.Request(id: "7", url: "https://example.test/data?x=1", method: "POST",
                                                    type: "Fetch", loader: nil, started: 10)
        request.sent = 10.01
        request.received = 10.1
        request.ended = 10.2
        request.status = 201
        request.bytes = 321
        let shown = DeveloperRequestDetails([
            "url": request.url, "method": "POST", "requestHeaders": [["Content-Type", "text/plain"], ["Cookie", "s=1"]],
            "postData": "ping",
            "response": ["status": 201, "statusText": "Created", "mimeType": "application/json",
                         "headers": [["Content-Type", "application/json"], ["Set-Cookie", "t=2"]]],
            "body": #"{"ok":true}"#,
        ])
        let entry = DeveloperHAR.entry(request, details: shown, clock: 10.2)
        let data = try JSONSerialization.data(withJSONObject: ["log": ["version": "1.2", "entries": [entry]]])
        let read = try XCTUnwrap(DeveloperHAR.read(data).first)
        XCTAssertEqual(read.request.url, request.url)
        XCTAssertEqual(read.request.method, "POST")
        XCTAssertEqual(read.request.status, 201)
        XCTAssertEqual(read.request.bytes, 321)
        XCTAssertEqual(try XCTUnwrap(read.request.time), 200, accuracy: 1)
        XCTAssertEqual(read.details.bodyText, #"{"ok":true}"#)
        XCTAssertEqual(read.details.postData, "ping")
        XCTAssertTrue(read.details.responseHeaders.contains { $0.name == "Set-Cookie" })
        let clean = DeveloperHAR.sanitized(entry)
        let headers = ((clean["request"] as? [String: Any])?["headers"] as? [[String: Any]]) ?? []
        XCTAssertFalse(headers.contains { ($0["name"] as? String)?.lowercased() == "cookie" })
    }

    func testHARCarriesWebSocketAndEventSourceMessages() throws {
        typealias Frame = DeveloperNetworkTools.Frame
        let socket = DeveloperToolsSession.Request(id: "ws", url: "wss://example.test/live", method: "GET",
                                                   type: "WebSocket", loader: nil, started: 1)
        let events = DeveloperToolsSession.Request(id: "es", url: "https://example.test/feed", method: "GET",
                                                   type: "EventSource", loader: nil, started: 1)
        let details = DeveloperRequestDetails(["url": socket.url, "method": "GET"])
        var socketEntry = DeveloperHAR.entry(socket, details: details, clock: 2)
        let sent = DeveloperHAR.messages([
            Frame(id: 0, kind: .sent, opcode: 1, data: "hello", length: 5, time: 1_700_000_000.5),
            Frame(id: 1, kind: .received, opcode: 2, data: "AQI=", length: 2, time: 1_700_000_001),
            Frame(id: 2, kind: .error, opcode: nil, data: "closed", length: 6, time: nil),
        ], eventSource: false)
        XCTAssertEqual(sent.key, "_webSocketMessages")
        XCTAssertEqual(sent.value.map { $0["type"] as? String }, ["send", "receive"], "Errors aren't Chrome messages")
        socketEntry[sent.key] = sent.value
        var eventEntry = DeveloperHAR.entry(events, details: details, clock: 2)
        let received = DeveloperHAR.messages([
            Frame(id: 1, kind: .received, opcode: nil, data: "{\"n\":1}", length: 7, time: 1_700_000_002,
                  eventID: "42", eventType: "tick"),
        ], eventSource: true)
        XCTAssertEqual(received.key, "_eventSourceMessages")
        eventEntry[received.key] = received.value
        let data = try JSONSerialization.data(withJSONObject: ["log": ["version": "1.2", "entries": [socketEntry, eventEntry]]])
        let read = try DeveloperHAR.read(data)
        XCTAssertEqual(read.map(\.request.type), ["WebSocket", "EventSource"])
        let frames = read[0].frames
        XCTAssertEqual(frames.map(\.kind), [.sent, .received])
        XCTAssertEqual(frames.map(\.data), ["hello", "AQI="])
        XCTAssertEqual(frames.map(\.opcode), [1, 2])
        XCTAssertEqual(frames.first?.time, 1_700_000_000.5)
        let event = try XCTUnwrap(read[1].frames.first)
        XCTAssertEqual(event.eventType, "tick")
        XCTAssertEqual(event.eventID, "42")
        XCTAssertEqual(event.data, "{\"n\":1}")
        XCTAssertNil(event.opcode)
        XCTAssertTrue(read[1].request.isEventSource)
    }

    func testNetworkToolsAgainstARealPage() async throws {
        _ = NSApplication.shared
        let echo = try await EchoSocketServer.start()
        defer { echo.stop() }
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Network tools fixture</title><p>Network</p>
                """),
            "/sample": .init(type: "text/plain", body: "sample body needle"),
        ])
        let store = WKWebsiteDataStore.nonPersistent()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        page.load(URLRequest(url: server.url("/")))
        try await wait("page to load") { page.title == "Network tools fixture" }

        // The session holds its tab weakly.
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        let tools = session.networkTools
        tools.blockPatterns = []
        tools.blockingEnabled = true
        do {
            try await wait("inspector") { session.ready && session.root != nil }
            session.select(.network)
            // DOMContentLoaded and load of a recorded reload.
            page.reload()
            try await wait("request interception") { session.requestInterception }
            print("Network.setEmulatedConditions available:", tools.bandwidthThrottling)
            try await wait("load marks", poll: tools) { tools.load != nil && tools.domContentLoaded != nil }

            let fetched = try await fetch(in: page, "/sample?first")
            XCTAssertTrue(fetched)
            try await wait("sample request") {
                session.requests.contains { $0.url.contains("/sample") && $0.ended != nil && $0.status == 200 }
            }
            let sample = try XCTUnwrap(session.requests.first { $0.url.contains("/sample") })
            try await wait("column data", poll: tools) { tools.extras[sample.id]?.responseHeaders.contains("content-type") == true }

            // Copy as cURL from the request WebKit recorded.
            let shownDetails = await session.requestDetails(sample.id)
            let shown = try XCTUnwrap(shownDetails)
            XCTAssertTrue(DeveloperRequestCopy.curl(shown).hasPrefix("curl --url '\(server.url("/sample?first").absoluteString)'"))

            // Search finds the body.
            let hits = await tools.search("needle", in: session.requests, caseSensitive: false, regex: false)
            XCTAssertTrue(hits.contains { $0.request == sample.id && $0.place == "response" })

            // HAR export through WI.HARBuilder, then imported back.
            let harData = await tools.har(for: session.requests, sanitize: false)
            let har = try XCTUnwrap(harData)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: har) as? [String: Any])
            let entries = try XCTUnwrap((root["log"] as? [String: Any])?["entries"] as? [[String: Any]])
            let entry = try XCTUnwrap(entries.first { (($0["request"] as? [String: Any])?["url"] as? String)?.contains("/sample") == true })
            let content = (entry["response"] as? [String: Any])?["content"] as? [String: Any]
            XCTAssertEqual(content?["text"] as? String, "sample body needle")
            XCTAssertEqual(((root["log"] as? [String: Any])?["creator"] as? [String: Any])?["name"] as? String,
                           "WebKit Web Inspector")

            // Blocking a URL makes it fail; others still load.
            tools.blockPatterns = [.init(pattern: "*/sample?blocked*")]
            try await wait("blocking rule", poll: tools) { tools.blockingActive }
            let blocked = try await fetch(in: page, "/sample?blocked")
            XCTAssertFalse(blocked)
            let allowed = try await fetch(in: page, "/sample?allowed")
            XCTAssertTrue(allowed)
            try await wait("blocked row", poll: tools) {
                session.requests.contains { tools.extras[$0.id]?.blocked == true && $0.failure != nil }
            }
            tools.blockPatterns = []
            try await wait("blocking off", poll: tools) { !tools.blockingActive }
            let unblocked = try await fetch(in: page, "/sample?blocked")
            XCTAssertTrue(unblocked)

            // WebSocket messages, both ways.
            let reply = try await page.callAsyncJavaScript("""
                return await new Promise((resolve) => {
                    const socket = new WebSocket(address);
                    socket.onopen = () => socket.send("hello perch");
                    socket.onmessage = (event) => resolve(event.data);
                    socket.onerror = () => resolve("error");
                });
                """, arguments: ["address": "ws://127.0.0.1:\(echo.port)/"], in: nil, contentWorld: .page)
            XCTAssertEqual(reply as? String, "hello perch")
            try await wait("socket row") { session.requests.contains { $0.type == "WebSocket" } }
            let socket = try XCTUnwrap(session.requests.first { $0.type == "WebSocket" })
            var frames: [DeveloperNetworkTools.Frame] = []
            for _ in 0..<40 where frames.count < 2 {
                frames = await tools.frames(for: socket.id, after: 0).frames
                if frames.count < 2 { try await Task.sleep(for: .milliseconds(100)) }
            }
            XCTAssertEqual(frames.map(\.kind), [.sent, .received])
            XCTAssertEqual(frames.map(\.data), ["hello perch", "hello perch"])
            XCTAssertNotNil(frames.first?.time)
            XCTAssertTrue(DeveloperRequestTab.available(for: socket, details: nil).contains(.messages))

            // A HAR file replaces the list with its requests.
            try tools.importHAR(har)
            XCTAssertTrue(session.requests.allSatisfy { $0.id.hasPrefix("har-") })
            let imported = try XCTUnwrap(session.requests.first { $0.url.contains("/sample?first") })
            let importedDetails = await session.requestDetails(imported.id)
            XCTAssertEqual(importedDetails?.bodyText, "sample body needle")

            await session.disconnect().value
            withExtendedLifetime(tab) {}
        } catch {
            await session.disconnect().value
            throw error
        }
    }

    private func fetch(in view: WKWebView, _ path: String) async throws -> Bool {
        let response = try await view.callAsyncJavaScript("""
            try {
                return (await fetch(path, {cache: "no-store"})).ok;
            } catch {
                return false;
            }
            """, arguments: ["path": path], in: nil, contentWorld: .page)
        return response as? Bool ?? false
    }

    private func wait(_ action: String, poll tools: DeveloperNetworkTools? = nil, until condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if let tools { await tools.poll() }
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw NSError(domain: "DeveloperNetworkToolsTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(action)"])
    }
}

/// A loopback WebSocket server that sends every message back.
final class EchoSocketServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "search.echo-socket")
    private(set) var port: UInt16 = 0

    private init() throws {
        let parameters = NWParameters.tcp
        let socket = NWProtocolWebSocket.Options()
        socket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start() async throws -> EchoSocketServer {
        let server = try EchoSocketServer()
        let port: UInt16 = try await withCheckedThrowingContinuation { done in
            let finished = OSAllocatedUnfairLock(initialState: false)
            server.listener.stateUpdateHandler = { state in
                finished.withLock { resumed in
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        done.resume(returning: server.listener.port?.rawValue ?? 0)
                    case .failed(let error):
                        resumed = true
                        done.resume(throwing: error)
                    default: break
                    }
                }
            }
            server.listener.newConnectionHandler = { connection in
                connection.start(queue: server.queue)
                server.echo(connection)
            }
            server.listener.start(queue: server.queue)
        }
        server.port = port
        return server
    }

    private func echo(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            if let data, let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata, metadata.opcode == .text || metadata.opcode == .binary {
                let reply = NWProtocolWebSocket.Metadata(opcode: metadata.opcode)
                let context = NWConnection.ContentContext(identifier: "echo", metadata: [reply])
                connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
            }
            if error == nil { self?.echo(connection) }
        }
    }

    func stop() { listener.cancel() }
}
