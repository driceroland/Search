import Foundation

/// The Network panel's Copy submenu, written the way Chromium's
/// NetworkLogView generates each format.
enum DeveloperRequestCopy {
    static func validURL(_ url: String) -> String? {
        guard let scheme = URL(string: url)?.scheme?.lowercased(),
              ["http", "https", "ws", "wss", "data", "file", "about", "javascript"].contains(scheme) else { return nil }
        return url
    }

    // MARK: cURL (bash)

    static func curl(_ request: DeveloperRequestDetails) -> String {
        guard let url = validURL(request.url) else { return "# Unsupported URL scheme" }
        var ignored: Set<String> = ["accept-encoding", "host", "method", "path", "scheme", "version", "authority", "protocol"]
        var command = ["--url " + escapePosix(url).replacingOccurrences(of: #"[\[{}\]]"#, with: #"\\$0"#,
                                                                         options: .regularExpression)]
        var inferredMethod = "GET"
        var data: [String] = []
        if let body = request.postData {
            data.append("--data-raw " + escapePosix(body))
            ignored.insert("content-length")
            inferredMethod = "POST"
        }
        if request.method != inferredMethod { command.append("-X " + escapePosix(request.method)) }
        for header in request.requestHeaders {
            let name = header.name.hasPrefix(":") ? String(header.name.dropFirst()) : header.name
            if ignored.contains(name.lowercased()) { continue }
            let value = header.value
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                command.append("-H " + escapePosix(name + ";"))
            } else if name.lowercased() == "cookie" && value.contains("=") {
                command.append("-b " + escapePosix(value))
            } else {
                command.append("-H " + escapePosix(name + ": " + value))
            }
        }
        command += data
        return "curl " + command.joined(separator: command.count >= 3 ? " \\\n  " : " ")
    }

    /// Single quotes, or ANSI-C quoting when the text needs escapes.
    static func escapePosix(_ text: String) -> String {
        func special(_ scalar: Unicode.Scalar) -> Bool {
            scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value) || scalar == "!"
        }
        guard text.unicodeScalars.contains(where: { special($0) || $0 == "'" }) else { return "'" + text + "'" }
        var result = "$'"
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "'": result += "\\'"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            default:
                if special(scalar) {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "'"
    }

    // MARK: PowerShell

    static func escapePowerShell(_ text: String) -> String {
        var result = "\""
        for unit in text.utf16 {
            let character = Character(Unicode.Scalar(unit) ?? " ")
            if unit < 0x20 || unit > 0x7E {
                result += "$([char]\(unit))"
            } else {
                if "`$\"".contains(character) { result += "`" }
                result.append(character)
            }
        }
        return result + "\""
    }

    static func powerShell(_ request: DeveloperRequestDetails) -> String {
        guard let url = validURL(request.url) else { return "# Unsupported URL scheme" }
        let ignored: Set<String> = ["host", "connection", "proxy-connection", "content-length", "expect", "range",
                                    "content-type", "user-agent", "cookie"]
        var command = ["-Uri " + escapePowerShell(url)]
        if request.method != "GET" { command.append("-Method " + escapePowerShell(request.method)) }
        var session: [String] = []
        if let agent = request.requestHeaders.first(where: { $0.name.lowercased() == "user-agent" }) {
            session.append("$session.UserAgent = " + escapePowerShell(agent.value))
        }
        let domain = URLComponents(string: request.url)?.host ?? ""
        for cookie in request.requestCookies {
            session.append("$session.Cookies.Add((New-Object System.Net.Cookie(\(escapePowerShell(cookie.name)), "
                           + "\(escapePowerShell(cookie.value)), \"/\", \(escapePowerShell(domain)))))")
        }
        if !session.isEmpty { command.append("-WebSession $session") }
        let headers = request.requestHeaders.compactMap { header -> String? in
            let name = header.name.hasPrefix(":") ? String(header.name.dropFirst()) : header.name
            return ignored.contains(name.lowercased()) ? nil : escapePowerShell(name) + "=" + escapePowerShell(header.value)
        }
        if !headers.isEmpty { command.append("-Headers @{\n" + headers.joined(separator: "\n  ") + "\n}") }
        if let type = request.requestContentType { command.append("-ContentType " + escapePowerShell(type)) }
        if let body = request.postData {
            let escaped = escapePowerShell(body)
            command.append(body.utf16.contains { $0 < 0x20 || $0 > 0x7E }
                           ? "-Body ([System.Text.Encoding]::UTF8.GetBytes(" + escaped + "))" : "-Body " + escaped)
        }
        let prelude = session.isEmpty ? "" : "$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession\n"
            + session.joined(separator: "\n") + "\n"
        return prelude + "Invoke-WebRequest -UseBasicParsing " + command.joined(separator: command.count >= 3 ? " `\n" : " ")
    }

    // MARK: fetch

    private static let internalHeaders: Set<String> = ["method", "path", "scheme", "version"]
    private static let forbidden: [String] = [
        "accept-charset", "accept-encoding", "access-control-request-headers", "access-control-request-method",
        "connection", "content-length", "cookie", "cookie2", "date", "dnt", "expect", "host", "keep-alive",
        "origin", "referer", "set-cookie", "te", "trailer", "transfer-encoding", "upgrade", "via",
    ]

    /// The fetch spec's forbidden request headers, as Chromium lists them.
    static func isForbiddenHeader(_ name: String, value: String) -> Bool {
        let name = name.lowercased()
        if name.hasPrefix("sec-") || name.hasPrefix("proxy-") || forbidden.contains(name) { return true }
        if ["x-http-method", "x-http-method-override", "x-method-override"].contains(name) {
            return value.split(separator: ",").contains {
                ["CONNECT", "TRACE", "TRACK"].contains($0.trimmingCharacters(in: .whitespaces).uppercased())
            }
        }
        return false
    }

    static func fetch(_ request: DeveloperRequestDetails, node: Bool = false) -> String {
        guard let url = validURL(request.url) else { return "// Unsupported URL scheme" }
        // As a Headers object holds them: lower-case names, sorted, with
        // repeated names joined.
        var headers: [String: String] = [:]
        for header in request.requestHeaders {
            let name = header.name.lowercased()
            if internalHeaders.contains(name) || header.name.contains(":") { continue }
            if name == "user-agent" || isForbiddenHeader(header.name, value: header.value) { continue }
            headers[name] = headers[name].map { $0 + ", " + header.value } ?? header.value
        }
        var headerList: [(String, String)] = headers.keys.sorted().map { ($0, headers[$0]!) }
        let hasCredentials = request.requestHeaders.contains {
            ["cookie", "authorization"].contains($0.name.lowercased())
        }
        let referrer = request.requestHeaders.first { $0.name.lowercased() == "referer" }?.value
        var fields: [(String, DeveloperJSON)] = []
        if node {
            var extra: [(String, String)] = []
            if let cookie = request.requestHeaders.first(where: { $0.name.lowercased() == "cookie" }) {
                extra.append(("cookie", cookie.value))
            }
            if let referrer { extra.append(("Referer", referrer)) }
            for (name, value) in extra {
                if let index = headerList.firstIndex(where: { $0.0 == name }) { headerList[index].1 = value }
                else { headerList.append((name, value)) }
            }
        }
        if !headerList.isEmpty { fields.append(("headers", .object(headerList.map { ($0.0, .string($0.1)) }))) }
        if !node, let referrer { fields.append(("referrer", .string(referrer))) }
        fields.append(("body", request.postData.map(DeveloperJSON.string) ?? .null))
        fields.append(("method", .string(request.method)))
        if !node {
            fields += [("mode", .string("cors")), ("credentials", .string(hasCredentials ? "include" : "omit"))]
        }
        return "fetch(\(DeveloperJSON.quote(url)), \(DeveloperJSON.object(fields).json(indent: 0)));"
    }

    /// The options Replay XHR hands to the page's fetch.
    static func replayOptions(_ request: DeveloperRequestDetails) -> [String: Any] {
        var headers: [String: String] = [:]
        for header in request.requestHeaders where !header.name.contains(":")
            && header.name.lowercased() != "user-agent" && !isForbiddenHeader(header.name, value: header.value) {
            headers[header.name] = header.value
        }
        var options: [String: Any] = ["method": request.method, "headers": headers, "credentials": "include",
                                      "cache": "no-store"]
        if let body = request.postData, !["GET", "HEAD"].contains(request.method.uppercased()) { options["body"] = body }
        return options
    }

    // MARK: Headers

    static func requestHeaders(_ request: DeveloperRequestDetails) -> String {
        let path = URLComponents(string: request.url).map { ($0.percentEncodedPath.isEmpty ? "/" : $0.percentEncodedPath)
            + ($0.percentEncodedQuery.map { "?" + $0 } ?? "") } ?? request.url
        return ([request.method + " " + path + " HTTP/1.1"] + request.requestHeaders.map { $0.name + ": " + $0.value })
            .joined(separator: "\r\n") + "\r\n"
    }

    static func responseHeaders(_ request: DeveloperRequestDetails) -> String {
        let status = "HTTP/1.1 \(request.status ?? 0)" + (request.statusText.map { $0.isEmpty ? "" : " " + $0 } ?? "")
        return ([status] + request.responseHeaders.map { $0.name + ": " + $0.value }).joined(separator: "\r\n") + "\r\n"
    }
}

/// Enough of JSON.stringify(value, null, 2) to write fetch options in
/// the order Chromium does.
indirect enum DeveloperJSON {
    case string(String), null, object([(String, DeveloperJSON)])

    func json(indent: Int) -> String {
        switch self {
        case .string(let text): return Self.quote(text)
        case .null: return "null"
        case .object(let fields):
            if fields.isEmpty { return "{}" }
            let inner = String(repeating: " ", count: indent + 2)
            let body = fields.map { inner + Self.quote($0.0) + ": " + $0.1.json(indent: indent + 2) }
            return "{\n" + body.joined(separator: ",\n") + "\n" + String(repeating: " ", count: indent) + "}"
        }
    }

    static func quote(_ text: String) -> String {
        var result = "\""
        for unit in text.unicodeScalars {
            switch unit {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if unit.value < 0x20 { result += String(format: "\\u%04x", unit.value) }
                else { result.unicodeScalars.append(unit) }
            }
        }
        return result + "\""
    }
}

/// HAR 1.2 entries Search writes itself (for requests WebKit's frontend no
/// longer holds) and reads back on import.
enum DeveloperHAR {
    struct Imported {
        let request: DeveloperToolsSession.Request
        let details: DeveloperRequestDetails
        let extra: DeveloperNetworkTools.Extra
        var frames: [DeveloperNetworkTools.Frame] = []
    }

    /// Without fractions of a second, for the HAR files that leave them out.
    private static let plainDates = ISO8601DateFormatter()

    /// ISO dates with milliseconds, as HAR and Chrome's cookie table write them.
    static let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func entry(_ request: DeveloperToolsSession.Request, details: DeveloperRequestDetails,
                      clock: Double) -> [String: Any] {
        let started = Date().addingTimeInterval(-(clock - (request.started ?? clock)))
        func pairs(_ list: [DeveloperRequestDetails.Header]) -> [[String: String]] {
            list.map { ["name": $0.name, "value": $0.value] }
        }
        var content: [String: Any] = ["size": details.bodyData?.count ?? 0, "mimeType": details.mimeType ?? "x-unknown"]
        if let body = details.body {
            content["text"] = body
            if details.base64Encoded { content["encoding"] = "base64" }
        }
        var requestEntry: [String: Any] = [
            "method": details.method, "url": details.url, "httpVersion": details.networkProtocol ?? "",
            "cookies": details.requestCookies.map { ["name": $0.name, "value": $0.value] },
            "headers": pairs(details.requestHeaders), "queryString": pairs(details.queryParameters),
            "headersSize": -1, "bodySize": details.postData?.utf8.count ?? 0,
        ]
        if let post = details.postData {
            requestEntry["postData"] = ["mimeType": details.requestContentType ?? "", "text": post]
        }
        var response: [String: Any] = [
            "status": details.status ?? 0, "statusText": details.statusText ?? "",
            "httpVersion": details.networkProtocol ?? "", "cookies": [] as [Any],
            "headers": pairs(details.responseHeaders), "content": content,
            "redirectURL": details.responseHeaders.first { $0.name.lowercased() == "location" }?.value ?? "",
            "headersSize": -1, "bodySize": -1,
        ]
        if let bytes = request.bytes { response["_transferSize"] = bytes }
        if let failure = request.failure { response["_error"] = failure }
        let segments = DeveloperNetworkTiming.segments(for: request)
        func phase(_ phase: DeveloperNetworkTiming.Phase) -> Double {
            segments.first { $0.phase == phase }?.milliseconds ?? 0
        }
        var entry: [String: Any] = [
            "startedDateTime": dates.string(from: started), "time": request.time ?? 0,
            "request": requestEntry, "response": response, "cache": [:] as [String: Any],
            "timings": ["blocked": phase(.beforeSend), "dns": -1, "ssl": -1, "connect": -1, "send": 0,
                        "wait": phase(.waiting), "receive": phase(.receiving)],
            "_resourceType": request.type.lowercased(),
        ]
        if let address = details.remoteAddress { entry["serverIPAddress"] = address }
        return entry
    }

    /// A WebSocket's or EventSource's messages as Chrome writes them on the
    /// entry: `_webSocketMessages` or `_eventSourceMessages`.
    static func messages(_ frames: [DeveloperNetworkTools.Frame], eventSource: Bool)
        -> (key: String, value: [[String: Any]]) {
        if eventSource {
            return ("_eventSourceMessages", frames.map { frame -> [String: Any] in
                ["time": frame.time ?? 0, "eventName": frame.eventType ?? "message", "eventId": frame.eventID ?? "",
                 "data": frame.data]
            })
        }
        return ("_webSocketMessages", frames.filter { $0.kind != .error }.map { frame -> [String: Any] in
            ["type": frame.kind == .sent ? "send" : "receive", "time": frame.time ?? 0, "opcode": frame.opcode ?? 1,
             "data": frame.data]
        })
    }

    /// The messages an entry carries, read back for the Messages tab.
    static func frames(_ entry: [String: Any]) -> [DeveloperNetworkTools.Frame] {
        let socket = entry["_webSocketMessages"] as? [[String: Any]]
        let list = socket ?? entry["_eventSourceMessages"] as? [[String: Any]] ?? []
        return list.enumerated().map { index, item in
            let data = item["data"] as? String ?? ""
            let source = socket == nil
            return DeveloperNetworkTools.Frame(
                id: index + 1, kind: item["type"] as? String == "send" ? .sent : .received,
                opcode: source ? nil : item["opcode"] as? Int ?? 1, data: data, length: data.utf8.count,
                time: item["time"] as? Double, eventID: source ? item["eventId"] as? String : nil,
                eventType: source ? item["eventName"] as? String : nil)
        }
    }

    /// Chrome's "sanitized" HAR: no cookies or authorization.
    static func sanitized(_ entry: [String: Any]) -> [String: Any] {
        let sensitive: Set<String> = ["cookie", "set-cookie", "authorization"]
        var entry = entry
        for side in ["request", "response"] {
            guard var part = entry[side] as? [String: Any] else { continue }
            if let headers = part["headers"] as? [[String: Any]] {
                part["headers"] = headers.filter { !sensitive.contains(($0["name"] as? String ?? "").lowercased()) }
            }
            part["cookies"] = [] as [Any]
            entry[side] = part
        }
        return entry
    }

    static func read(_ data: Data) throws -> [Imported] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let log = root["log"] as? [String: Any], let entries = log["entries"] as? [[String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let batch = UUID().uuidString.prefix(8)
        return entries.enumerated().compactMap { index, entry in
            guard let request = entry["request"] as? [String: Any], let url = request["url"] as? String else { return nil }
            let response = entry["response"] as? [String: Any] ?? [:]
            let content = response["content"] as? [String: Any] ?? [:]
            func pairs(_ value: Any?) -> [[String]] {
                (value as? [[String: Any]] ?? []).compactMap { item in
                    guard let name = item["name"] as? String, let value = item["value"] as? String else { return nil }
                    return [name, value]
                }
            }
            func number(_ value: Any?) -> Double? {
                guard let value = value as? Double, value >= 0 else { return nil }
                return value
            }
            let started = (entry["startedDateTime"] as? String).flatMap { dates.date(from: $0)
                ?? plainDates.date(from: $0) }?.timeIntervalSince1970 ?? 0
            let mime = content["mimeType"] as? String ?? ""
            let method = request["method"] as? String ?? "GET"
            let type = (entry["_resourceType"] as? String).map(Self.webKitType) ?? Self.type(forMIME: mime)
            var row = DeveloperToolsSession.Request(id: "har-\(batch)-\(index)", url: url, method: method,
                                                    type: type, loader: nil, started: started)
            let timings = entry["timings"] as? [String: Any] ?? [:]
            let before = ["blocked", "dns", "connect", "send"].compactMap { number(timings[$0]) }.reduce(0, +)
            if let wait = number(timings["wait"]) {
                row.sent = started + before / 1_000
                row.received = started + (before + wait) / 1_000
            }
            row.ended = started + (number(entry["time"]) ?? 0) / 1_000
            let status = response["status"] as? Int ?? 0
            row.status = status > 0 ? status : nil
            row.statusText = response["statusText"] as? String
            row.mimeType = mime.isEmpty ? nil : mime.components(separatedBy: ";").first
            let transfer = (response["_transferSize"] as? Int)
                ?? (response["bodySize"] as? Int).map { $0 + max(0, response["headersSize"] as? Int ?? 0) }
            row.bytes = transfer.flatMap { $0 >= 0 ? $0 : nil }
            row.failure = (response["_error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if status == 0 && row.failure == nil { row.failure = "Failed" }
            row.cached = ((entry["_fetchType"] as? String) ?? "").localizedCaseInsensitiveContains("cache")
            let protocolName = response["httpVersion"] as? String
            var address = entry["serverIPAddress"] as? String
            if let address0 = address, let port = entry["_serverPort"] as? Int { address = address0 + ":\(port)" }
            var raw: [String: Any] = [
                "url": url, "method": method, "requestHeaders": pairs(request["headers"]),
                "response": ["status": status, "statusText": row.statusText ?? "", "mimeType": mime,
                             "headers": pairs(response["headers"])],
                "metrics": ["protocol": protocolName as Any, "remoteAddress": address as Any],
            ]
            if let post = (request["postData"] as? [String: Any])?["text"] as? String { raw["postData"] = post }
            if let text = content["text"] as? String {
                raw["body"] = text
                raw["base64Encoded"] = (content["encoding"] as? String) == "base64"
            }
            if let failure = row.failure { raw["failure"] = failure }
            let details = DeveloperRequestDetails(raw)
            var extra = DeveloperNetworkTools.Extra()
            extra.networkProtocol = protocolName
            extra.remoteAddress = address
            extra.priority = entry["_priority"] as? String
            extra.resourceSize = content["size"] as? Int
            extra.requestHeaders = details.requestHeaders.map { $0.name.lowercased() }
            extra.responseHeaders = details.responseHeaders.map { $0.name.lowercased() }
            extra.cookies = details.requestCookies.map(\.name)
            extra.setCookies = details.responseCookies.map(\.name)
            return Imported(request: row, details: details, extra: extra, frames: Self.frames(entry))
        }
    }

    private static func webKitType(_ type: String) -> String {
        switch type.lowercased() {
        case "xhr": "XHR"
        case "fetch": "Fetch"
        case "websocket": "WebSocket"
        case "eventsource": "EventSource"
        case "stylesheet": "StyleSheet"
        default: type.prefix(1).uppercased() + type.dropFirst()
        }
    }

    private static func type(forMIME mime: String) -> String {
        let mime = mime.lowercased()
        if mime.contains("html") { return "Document" }
        if mime.contains("css") { return "StyleSheet" }
        if mime.contains("javascript") || mime.contains("ecmascript") { return "Script" }
        if mime.hasPrefix("image/") { return "Image" }
        if mime.hasPrefix("font/") || mime.contains("woff") { return "Font" }
        if mime.hasPrefix("audio/") || mime.hasPrefix("video/") { return "Media" }
        if mime.contains("json") || mime.contains("xml") { return "Fetch" }
        return "Other"
    }
}
