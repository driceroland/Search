import AppKit
import SwiftUI
import WebKit

/// One request as DevTools' detail tabs show it, read from WebKit's
/// inspector when the request is chosen (DeveloperToolsSession.requestDetails).
struct DeveloperRequestDetails: Equatable {
    typealias Header = (name: String, value: String)

    var url: String
    var method: String
    var requestHeaders: [Header]
    var responseHeaders: [Header]
    var postData: String?
    /// The policy the request was sent under (WebKit's Network.Request.referrerPolicy).
    var referrerPolicy: String?
    var status: Int?
    var statusText: String?
    var mimeType: String?
    var source: String?
    var remoteAddress: String?
    var networkProtocol: String?
    var initiatorType: String?
    var initiatorURL: String?
    var initiatorLine: Int?
    /// The script frames that started the request, innermost first.
    var frames: [StackFrame]
    /// The frames as "Copy stack trace" writes them.
    var stack: [String] { frames.map(\.text) }
    var body: String?
    var base64Encoded: Bool
    var bodyError: String?
    var failure: String?

    init(_ raw: [String: Any]) {
        func headers(_ value: Any?) -> [Header] {
            (value as? [[Any]] ?? []).compactMap { pair in
                guard pair.count == 2, let name = pair[0] as? String, let value = pair[1] as? String else { return nil }
                return (name, value)
            }
        }
        let response = raw["response"] as? [String: Any]
        let metrics = raw["metrics"] as? [String: Any]
        let initiator = raw["initiator"] as? [String: Any]
        url = raw["url"] as? String ?? ""
        method = raw["method"] as? String ?? "GET"
        // The headers the engine finally sent, when it reports them, over
        // what the page asked for.
        let sent = headers(response?["requestHeaders"])
        requestHeaders = sent.isEmpty ? headers(raw["requestHeaders"]) : sent
        responseHeaders = headers(response?["headers"])
        postData = raw["postData"] as? String
        referrerPolicy = raw["referrerPolicy"] as? String
        status = response?["status"] as? Int
        statusText = response?["statusText"] as? String
        mimeType = response?["mimeType"] as? String
        source = response?["source"] as? String
        remoteAddress = metrics?["remoteAddress"] as? String
        networkProtocol = metrics?["protocol"] as? String
        initiatorType = initiator?["type"] as? String
        initiatorURL = initiator?["url"] as? String
        initiatorLine = initiator?["lineNumber"] as? Int
        // WebKit puts the built-in that sent it on top (`fetch @ [native
        // code]`); Chrome's Initiator starts at the page's own script.
        frames = (initiator?["stack"] as? [[String: Any]] ?? []).map(StackFrame.init).filter { !$0.isNative }
        body = raw["body"] as? String
        base64Encoded = raw["base64Encoded"] as? Bool == true
        bodyError = raw["bodyError"] as? String
        failure = raw["failure"] as? String
    }

    /// One call frame of a request's initiator. WebKit numbers its lines
    /// and columns from 1, as Chrome's links show them.
    struct StackFrame: Equatable {
        let function: String
        let url: String
        let line: Int?
        let column: Int?

        /// A frame inside the browser (fetch, setTimeout), with no source.
        var isNative: Bool { url.isEmpty || url == "[native code]" }

        /// file:line, as the link reads.
        var location: String {
            let name = URL(string: url).map { $0.lastPathComponent.isEmpty ? ($0.host() ?? url) : $0.lastPathComponent } ?? url
            return name + (line.map { ":\($0)" } ?? "")
        }

        var text: String { url.isEmpty ? function : "\(function) @ \(url)" + (line.map { ":\($0)" } ?? "") }

        /// The frame in its authored file when the script has a source map,
        /// as Chrome's Initiator links read; unchanged otherwise.
        @MainActor func mapped(_ maps: DeveloperSourceMaps) -> Self {
            guard !isNative else { return self }
            let link = maps.linked(url: url, line: line, column: column)
            guard link.url != url || link.line != line else { return self }
            return Self(function: function, url: link.url, line: link.line, column: nil)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url == rhs.url && lhs.method == rhs.method && lhs.status == rhs.status && lhs.body == rhs.body
            && lhs.requestHeaders.map(\.name) == rhs.requestHeaders.map(\.name)
            && lhs.requestHeaders.map(\.value) == rhs.requestHeaders.map(\.value)
            && lhs.responseHeaders.map(\.name) == rhs.responseHeaders.map(\.name)
            && lhs.responseHeaders.map(\.value) == rhs.responseHeaders.map(\.value)
    }

    /// The body as bytes, whether WebKit sent it as text or base64.
    var bodyData: Data? {
        guard let body else { return nil }
        return base64Encoded ? Data(base64Encoded: body) : Data(body.utf8)
    }

    /// The body as text, if it is text.
    var bodyText: String? {
        guard let body else { return nil }
        guard base64Encoded else { return body }
        return Data(base64Encoded: body).flatMap { String(data: $0, encoding: .utf8) }
    }

    var queryParameters: [Header] {
        guard let items = URLComponents(string: url)?.queryItems else { return [] }
        return items.map { ($0.name, $0.value ?? "") }
    }

    /// The URL's query as sent, still percent-encoded.
    var rawQuery: String? {
        if let query = URLComponents(string: url)?.percentEncodedQuery { return query.isEmpty ? nil : query }
        guard let mark = url.firstIndex(of: "?") else { return nil }
        let query = url[url.index(after: mark)...].prefix { $0 != "#" }
        return query.isEmpty ? nil : String(query)
    }

    /// Chrome's NetworkRequest.parseParameters: pairs split at `&` and the
    /// first `=`; decoded as decodeURIComponent after `+` becomes a space,
    /// or left as written for "view URL-encoded".
    static func parameters(_ text: String, decoded: Bool) -> [Header] {
        guard !text.isEmpty else { return [] }
        func decode(_ part: Substring) -> String {
            guard decoded else { return String(part) }
            return part.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "(unable to decode value)"
        }
        return text.split(separator: "&", omittingEmptySubsequences: false).map { pair -> Header in
            guard let equals = pair.firstIndex(of: "=") else { return (decode(pair), "") }
            return (decode(pair[..<equals]), decode(pair[pair.index(after: equals)...]))
        }
    }

    func header(_ name: String, in list: [Header]) -> String? {
        list.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var requestContentType: String? { header("content-type", in: requestHeaders) }

    /// Form fields, for a urlencoded body; nil for any other kind.
    var formData: [Header]? {
        guard let postData, requestContentType?.lowercased().contains("application/x-www-form-urlencoded") == true else { return nil }
        var components = URLComponents()
        components.percentEncodedQuery = postData.replacingOccurrences(of: "+", with: "%20")
        return components.queryItems?.map { ($0.name, $0.value ?? "") }
    }

    /// Cookies sent with the request and set by the response, with every
    /// attribute their headers carry, as the Cookies tab's tables list them.
    var requestCookieList: [DeveloperRequestCookie] { DeveloperRequestCookie.requestCookies(requestHeaders) }
    var responseCookieList: [DeveloperRequestCookie] { DeveloperRequestCookie.responseCookies(responseHeaders) }

    /// The same cookies as name and value, for copying and HAR.
    var requestCookies: [Header] { requestCookieList.map { ($0.name, $0.value) } }
    var responseCookies: [Header] { responseCookieList.map { ($0.name, $0.value) } }

    /// JSON as JSON.stringify(JSON.parse(text), null, 2) writes it: keys
    /// in the order the text has them, not sorted.
    static func prettyJSON(_ text: String?) -> String? {
        DeveloperJSONValue.parse(text)?.pretty()
    }
}

extension DeveloperRequestDetails.StackFrame {
    init(_ raw: [String: Any]) {
        self.init(function: (raw["functionName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(anonymous)",
                  url: raw["url"] as? String ?? "", line: (raw["lineNumber"] as? Int).map { max(1, $0) },
                  column: (raw["columnNumber"] as? Int).map { max(1, $0) })
    }
}

/// The tabs DevTools shows for a selected request, in its order.
enum DeveloperRequestTab: String, CaseIterable, Identifiable {
    case headers = "Headers", payload = "Payload", preview = "Preview", response = "Response"
    case messages = "Messages", initiator = "Initiator", timing = "Timing", cookies = "Cookies"
    var id: Self { self }

    static func available(for request: DeveloperToolsSession.Request, details: DeveloperRequestDetails?) -> [Self] {
        allCases.filter { tab in
            switch tab {
            case .payload:
                return details.map { $0.postData != nil || $0.rawQuery != nil } ?? false
            case .cookies:
                return details.map { !$0.requestCookies.isEmpty || !$0.responseCookies.isEmpty } ?? false
            case .preview, .response:
                return request.type != "WebSocket"
            case .messages:
                return request.type == "WebSocket" || request.isEventSource
            default:
                return true
            }
        }
    }
}

struct DeveloperRequestDetailsView: View {
    @ObservedObject var session: DeveloperToolsSession
    let request: DeveloperToolsSession.Request
    @Binding var tab: DeveloperRequestTab
    let close: () -> Void

    @State private var details: DeveloperRequestDetails?
    @State private var loading = true
    @State private var expanded: Set<String> = ["General", "Response Headers", "Request Headers",
                                                 "Query String Parameters", "Form Data", "Request Payload",
                                                 "Request call stack", "Request initiator chain", "Server Timing"]
    /// Chrome's "Raw" checkbox per header section, "view source" per
    /// payload section, and "view URL-encoded" (as `<section>#encoded`).
    @State private var raw: Set<String> = []
    /// Header overrides, for "Override headers" and the purple headers.
    @ObservedObject private var localOverrides = DeveloperLocalOverrides.shared

    var body: some View {
        let tabs = DeveloperRequestTab.available(for: request, details: details)
        VStack(spacing: 0) {
            DeveloperTabBar(tabs, selection: $tab, title: \.rawValue,
                            identifier: { "developer-network-tab-\($0.rawValue.lowercased())" }, leading: {
                DeveloperPanelIcon(symbol: "xmark", title: "Close", action: close)
                    .padding(.leading, DeveloperToolsStyle.controlSpacing)
                    .accessibilityLabel("Close request details")
            }, trailing: { EmptyView() })
            Divider()

            content(tabs.contains(tab) ? tab : .headers)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(DeveloperToolsStyle.surface)
        }
        .task(id: request.id + "\(request.ended ?? -1)") {
            loading = details == nil
            details = await session.requestDetails(request.id)
            loading = false
        }
        .accessibilityIdentifier("developer-network-details")
    }

    @ViewBuilder
    private func content(_ tab: DeveloperRequestTab) -> some View {
        switch tab {
        case .headers: scrolling { headers }
        case .payload: scrolling { payload }
        case .preview: preview
        case .response: response
        case .initiator: scrolling { initiator }
        case .timing: scrolling { timing }
        case .cookies: cookies
        case .messages: DeveloperNetworkMessagesView(tools: session.networkTools, request: request)
        }
    }

    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) { content() }
                .padding(.vertical, DeveloperToolsStyle.controlSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Headers

    @ViewBuilder
    private var headers: some View {
        section("General") {
            pair("Request URL", details?.url ?? request.url)
            pair("Request Method", request.method)
            statusPair
            if let address = details?.remoteAddress { pair("Remote Address", address) }
            // The request's own policy, as Chrome shows it, else a header's.
            if let details, let policy = details.referrerPolicy
                ?? details.header("referrer-policy", in: details.requestHeaders)
                ?? details.header("referrer-policy", in: details.responseHeaders) {
                pair("Referrer Policy", policy)
            }
        }
        section("Response Headers", count: details?.responseHeaders.count, toggle: "Raw") {
            if let details, !details.responseHeaders.isEmpty {
                if raw.contains("Response Headers") {
                    code(DeveloperRequestCopy.responseHeaders(details))
                } else {
                    // Headers set by a .headers file are purple, as in Chrome.
                    let overridden = Set(localOverrides.headerOverrides(for: details.url).map { $0.name.lowercased() })
                    ForEach(Array(details.responseHeaders.enumerated()), id: \.offset) { _, header in
                        headerPair(header, overridden: overridden.contains(header.name.lowercased()))
                    }
                }
            } else {
                note(loading ? "Loading…" : "No response headers")
            }
            if DeveloperHeaderOverrides.target(for: details?.url ?? request.url) != nil {
                Button("Override headers") {
                    let response = (details?.responseHeaders ?? []).map { DeveloperHeaderOverrides.Header(name: $0.name, value: $0.value) }
                    localOverrides.overrideHeaders(url: details?.url ?? request.url, response: response, session: session)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(DeveloperToolsStyle.tint)
                .padding(.horizontal, DeveloperToolsStyle.gutter * 2)
                .padding(.vertical, 2)
                .accessibilityIdentifier("developer-network-override-headers")
            }
        }
        section("Request Headers", count: details?.requestHeaders.count, toggle: "Raw") {
            if let details, !details.requestHeaders.isEmpty {
                if raw.contains("Request Headers") {
                    code(DeveloperRequestCopy.requestHeaders(details))
                } else {
                    ForEach(Array(details.requestHeaders.enumerated()), id: \.offset) { _, header in headerPair(header) }
                }
            } else {
                note(loading ? "Loading…" : session.cacheDisabled ? "Provisional headers are shown."
                     : "Provisional headers are shown. Disable cache to see full headers.")
            }
        }
    }

    /// A header as received, its name in the server's own casing; right-
    /// click to copy its value or the whole `name: value` line, as in
    /// Chrome DevTools.
    private func headerPair(_ header: DeveloperRequestDetails.Header, overridden: Bool = false) -> some View {
        pair(header.name, header.value)
            .background(overridden ? Color.purple.opacity(0.12) : Color.clear)
            .overlay(alignment: .leading) {
                if overridden { Color.purple.frame(width: 2).padding(.leading, DeveloperToolsStyle.gutter) }
            }
            .help(overridden ? "Overridden by a .headers file in Local Overrides" : "")
            .contextMenu {
                Button("Copy value") { DeveloperToolsSession.copyToPasteboard(header.value) }
                Button("Copy header") { DeveloperToolsSession.copyToPasteboard(header.name + ": " + header.value) }
            }
    }

    /// Status Code, with Chrome's dot: green for success and 304, orange
    /// for other 3xx, red for errors and failures.
    private var statusPair: some View {
        pair("Status Code") {
            HStack(alignment: .center, spacing: 5) {
                if let color = statusColor {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                Text(statusLine).textSelection(.enabled)
            }
        }
        .contextMenu {
            Button("Copy value") { DeveloperToolsSession.copyToPasteboard(statusLine) }
        }
    }

    private var statusColor: Color? {
        if (request.failure ?? details?.failure) != nil { return .red }
        guard let status = request.status ?? details?.status else { return nil }
        if status < 300 || status == 304 { return .green }
        if status < 400 { return .orange }
        return .red
    }

    private var statusLine: String {
        if let failure = request.failure ?? details?.failure { return failure }
        guard let status = request.status ?? details?.status else { return "Pending" }
        let text = request.statusText ?? details?.statusText ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        let from: String = switch session.networkTools.extras[request.id]?.source ?? details?.source {
        case "memory-cache": " (from memory cache)"
        case "service-worker": " (from service worker)"
        default: request.cached ? " (from disk cache)" : ""
        }
        return "\(status) \(text)" + from
    }

    // MARK: Payload

    @ViewBuilder
    private var payload: some View {
        if let details {
            if let query = details.rawQuery {
                parameters("Query String Parameters", source: query)
            }
            if details.formData != nil, let body = details.postData {
                parameters("Form Data", source: body)
            } else if let body = details.postData {
                let json = DeveloperJSONValue.parse(body)
                let title = "Request Payload"
                section(title, links: json == nil ? [] : [sourceLink(title)]) {
                    if let json, !raw.contains(title) {
                        DeveloperJSONTree(root: json).id(body)
                    } else {
                        code(body)
                    }
                }
            }
        } else {
            note("Loading…")
        }
    }

    /// Query String Parameters or Form Data, as Chrome shows them: parsed
    /// and decoded, or as sent ("view URL-encoded"), or the whole string
    /// as sent ("view source").
    private func parameters(_ title: String, source: String) -> some View {
        let viewSource = raw.contains(title)
        let encoded = raw.contains(title + "#encoded")
        let pairs = DeveloperRequestDetails.parameters(source, decoded: !encoded)
        var links = [sourceLink(title)]
        if !viewSource {
            links.append(SectionLink(key: title + "#encoded", off: "view URL-encoded", on: "view decoded"))
        }
        return section(title, count: pairs.count, links: links) {
            if viewSource {
                code(source)
            } else {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, item in
                    pair(item.name, item.value)
                        .contextMenu {
                            Button("Copy value") { DeveloperToolsSession.copyToPasteboard(item.value) }
                        }
                }
            }
        }
    }

    private func sourceLink(_ title: String) -> SectionLink {
        SectionLink(key: title, off: "view source", on: "view parsed")
    }

    // MARK: Preview and Response

    @ViewBuilder
    private var preview: some View {
        if let details {
            let mime = (details.mimeType ?? request.mimeType ?? "").lowercased()
            if mime.hasPrefix("image/"), let data = details.bodyData, let image = NSImage(data: data) {
                VStack(spacing: DeveloperToolsStyle.gutter) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: min(image.size.width, 480), maxHeight: min(image.size.height, 320))
                        .background(DeveloperToolsStyle.raised)
                    Text("\(Int(image.size.width)) × \(Int(image.size.height)) · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)) · \(mime)")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let media = DeveloperResponseMedia.kind(mimeType: mime, url: details.url),
                      media != .font || details.bodyData != nil {
                // Chrome's font sample, or a player for audio and video.
                if media == .font, let data = details.bodyData {
                    DeveloperFontPreview(data: data).id(request.id + ":\(data.count)")
                } else {
                    DeveloperMediaPreview(data: details.bodyData, url: details.url,
                                          mimeType: details.mimeType ?? request.mimeType, audio: media == .audio)
                        .id(request.id)
                }
            } else if let text = details.bodyText, DeveloperJSONPreview<EmptyView>.looksLikeJSON(text, mimeType: mime) {
                // Chrome's JSON view; a body that only looked like JSON
                // shows as it would have otherwise.
                DeveloperJSONPreview(text: text, scrolls: true) { textPreview(details, mime: mime) }
                    .id(request.id + ":\(text.utf8.count)")
            } else {
                textPreview(details, mime: mime)
            }
        } else {
            note(loading ? "Loading…" : "This request has no preview available.")
        }
    }

    @ViewBuilder
    private func textPreview(_ details: DeveloperRequestDetails, mime: String) -> some View {
        if mime.contains("html"), let html = details.bodyText {
            DeveloperHTMLPreview(html: html, base: URL(string: details.url))
        } else {
            response
        }
    }

    @ViewBuilder
    private var response: some View {
        if let details {
            if let text = details.bodyText {
                let session = session
                DeveloperResponseSourceView(text: text, url: details.url, mimeType: details.mimeType ?? request.mimeType,
                                            evaluate: { session.evaluate($0) })
                    .id(request.id + ":\(text.utf8.count)")
            } else if let data = details.bodyData {
                // Chrome's binary view: Base64, Hex viewer or UTF-8.
                DeveloperBinaryResponseView(data: data)
                    .id(request.id + ":\(data.count)")
            } else if details.body != nil {
                note("This response is binary data (\(details.mimeType ?? "unknown type")).")
            } else {
                note("This request has no response data available.")
            }
        } else {
            note(loading ? "Loading…" : "This request has no response data available.")
        }
    }

    // MARK: Initiator, Timing, Cookies

    @ViewBuilder
    private var initiator: some View {
        if let frames = details?.frames, !frames.isEmpty {
            section("Request call stack") {
                // In the authored file when the script has a source map.
                ForEach(Array(frames.map { $0.mapped(session.sourceMaps) }.enumerated()), id: \.offset) { _, frame in
                    HStack(spacing: 0) {
                        Text(frame.function).font(DeveloperToolsStyle.code).lineLimit(1)
                        if !frame.url.isEmpty {
                            Text(" @ ").font(DeveloperToolsStyle.code).foregroundStyle(.secondary)
                            sourceLink(frame.location, url: frame.url, line: frame.line ?? 1, column: frame.column)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DeveloperToolsStyle.gutter * 2)
                }
            }
        }
        let chain = DeveloperNetworkInitiators.chain(for: request, initiator: details?.initiatorURL, in: session.requests)
        if chain.count < 2 && (details?.frames ?? []).isEmpty {
            note("No initiator data")
        } else if chain.count > 1 {
            section("Request initiator chain") {
                ForEach(Array(chain.enumerated()), id: \.offset) { index, link in
                    Group {
                        if link.current {
                            Text(link.url).font(.system(size: 11, weight: .semibold))
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        } else {
                            // The request's own initiator opens at the line that
                            // started it, when WebKit reports one.
                            let line = chain.indices.contains(index + 1) && chain[index + 1].current
                                ? details?.initiatorLine ?? 1 : 1
                            sourceLink(link.url, url: link.url, line: line, column: nil)
                        }
                    }
                    .padding(.leading, DeveloperToolsStyle.gutter * 2 + CGFloat(link.depth) * 14)
                    .padding(.trailing, DeveloperToolsStyle.gutter)
                }
            }
        }
    }

    /// A file:line that opens Sources there, as Chrome's links do.
    private func sourceLink(_ title: String, url: String, line: Int, column: Int?) -> some View {
        Button {
            session.revealSource(url: url, line: line, column: column)
        } label: {
            Text(title)
                .font(DeveloperToolsStyle.code)
                .underline()
                .foregroundStyle(DeveloperToolsStyle.tint)
                .lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .help("Open \(url):\(line) in Sources")
        .accessibilityIdentifier("developer-initiator-link")
        .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }

    @ViewBuilder
    private var timing: some View {
        let phases = DeveloperNetworkTiming.phases(for: request, timing: session.networkTools.extras[request.id]?.timing ?? [:])
        let total = max(request.time ?? 0, phases.map(\.end).max() ?? 0)
        let queueing = phases.first { $0.label == "Queueing" }.map { $0.end - $0.start } ?? 0
        if let header = DeveloperRequestTimingText.header(started: request.started, queueing: queueing,
                                                         origin: DeveloperNetworkTiming(session.requests).origin) {
            VStack(alignment: .leading, spacing: 2) {
                Text(header.queued)
                Text(header.started)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, DeveloperToolsStyle.gutter * 2)
            .padding(.top, DeveloperToolsStyle.controlSpacing)
            .accessibilityIdentifier("developer-network-timing-queued")
        }
        if phases.isEmpty {
            note("Timing is not available for this request yet.")
        }
        ForEach(DeveloperNetworkTiming.TimingSection.allCases, id: \.self) { group in
            let rows = phases.filter { $0.section == group }
            if !rows.isEmpty {
                HStack {
                    Text(group.rawValue).font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("DURATION").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, DeveloperToolsStyle.gutter * 2)
                .padding(.top, DeveloperToolsStyle.gutter)
                ForEach(rows, id: \.label) { phase in
                    HStack(spacing: DeveloperToolsStyle.gutter) {
                        Text(phase.label).frame(width: 170, alignment: .leading)
                        GeometryReader { geometry in
                            let start = total > 0 ? phase.start / total : 0
                            let width = total > 0 ? (phase.end - phase.start) / total : 0
                            Rectangle().fill(phase.color.opacity(0.85))
                                .frame(width: max(2, geometry.size.width * width), height: 8)
                                .offset(x: geometry.size.width * max(0, min(1, start)), y: (geometry.size.height - 8) / 2)
                        }
                        .frame(height: DeveloperToolsStyle.rowHeight)
                        Text(Self.duration(phase.end - phase.start)).monospacedDigit()
                            .frame(width: 80, alignment: .trailing)
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, DeveloperToolsStyle.gutter * 2)
                }
            }
        }
        if request.ended == nil {
            note("CAUTION: request is not finished yet!")
        }
        HStack {
            Text("Total").fontWeight(.semibold)
            Spacer()
            Text(request.time.map(Self.duration) ?? "Pending").monospacedDigit().fontWeight(.semibold)
        }
        .font(.system(size: 11))
        .padding(.horizontal, DeveloperToolsStyle.gutter * 2)
        .padding(.top, DeveloperToolsStyle.controlSpacing)
        let server = DeveloperNetworkTiming.serverTiming(details?.responseHeaders ?? [])
        if !server.isEmpty {
            section("Server Timing") {
                ForEach(Array(server.enumerated()), id: \.offset) { _, metric in
                    HStack {
                        Text(metric.description.isEmpty ? metric.name : metric.description)
                        Spacer()
                        Text(metric.duration.map(Self.duration) ?? "").monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, DeveloperToolsStyle.gutter * 2)
                }
            }
        }
    }

    /// Chrome's two cookie tables. A Cookie header carries only names and
    /// values, so a sent cookie's other columns stay empty, as Chrome
    /// leaves them for a cookie it no longer stores.
    @ViewBuilder
    private var cookies: some View {
        if let details {
            let sent = details.requestCookieList
            let set = details.responseCookieList
            if sent.isEmpty && set.isEmpty {
                note("This request has no cookies.")
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                VStack(alignment: .leading, spacing: DeveloperToolsStyle.controlSpacing) {
                    cookieHeading("Request Cookies")
                    if sent.isEmpty {
                        note("No request cookies were sent.")
                    } else {
                        DeveloperCookieTable(cookies: sent).id("request:" + request.id)
                    }
                    if !set.isEmpty {
                        cookieHeading("Response Cookies")
                        DeveloperCookieTable(cookies: set).id("response:" + request.id)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, DeveloperToolsStyle.controlSpacing)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            note(loading ? "Loading…" : "This request has no cookies.")
        }
    }

    private func cookieHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.rowHeight)
    }

    // MARK: Pieces

    /// One of Chrome's text buttons beside a section's title ("view
    /// source" / "view parsed"), on while `key` is in `raw`.
    private struct SectionLink {
        let key: String
        let off: String
        let on: String
    }

    private func section<Content: View>(_ title: String, count: Int? = nil, toggle: String? = nil,
                                        links: [SectionLink] = [],
                                        @ViewBuilder _ content: () -> Content) -> some View {
        let open = expanded.contains(title)
        let heading = title + (count.map { " (\($0))" } ?? "")
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                if open { expanded.remove(title) } else { expanded.insert(title) }
            } label: {
                HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                    Image(systemName: open ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                        .font(.system(size: 7)).foregroundStyle(.secondary)
                    Text(heading).font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DeveloperToolsStyle.gutter)
                .frame(height: DeveloperToolsStyle.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .leading) {
                if open, !links.isEmpty {
                    HStack(spacing: DeveloperToolsStyle.gutter) {
                        ForEach(links, id: \.key) { link in
                            let on = raw.contains(link.key)
                            Button(on ? link.on : link.off) {
                                if on { raw.remove(link.key) } else { raw.insert(link.key) }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5))
                            .foregroundStyle(DeveloperToolsStyle.tint)
                            .accessibilityIdentifier("developer-network-section-link")
                        }
                    }
                    // Just past the title, where Chrome puts them.
                    .padding(.leading, DeveloperToolsStyle.gutter + 7 + DeveloperToolsStyle.controlSpacing
                             + Self.titleWidth(heading) + DeveloperToolsStyle.gutter)
                }
            }
            .overlay(alignment: .trailing) {
                if let toggle, open {
                    Toggle(toggle, isOn: Binding(get: { raw.contains(title) }, set: { on in
                        if on { raw.insert(title) } else { raw.remove(title) }
                    }))
                    .toggleStyle(.developerCheckbox)
                    .controlSize(.small)
                    .font(.system(size: 10.5))
                    .padding(.trailing, DeveloperToolsStyle.gutter * 2)
                }
            }
            if open { content() }
        }
        .padding(.bottom, DeveloperToolsStyle.controlSpacing)
        .overlay(alignment: .bottom) { Rectangle().fill(DeveloperToolsStyle.rule.opacity(0.35)).frame(height: 1) }
    }

    private static func titleWidth(_ title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width)
    }

    private func pair(_ name: String, _ value: String) -> some View {
        pair(name) { Text(value).textSelection(.enabled) }
    }

    private func pair<Value: View>(_ name: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DeveloperToolsStyle.gutter) {
            Text(name + ":")
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .frame(minWidth: 120, maxWidth: 200, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11))
        .padding(.horizontal, DeveloperToolsStyle.gutter * 2)
        .padding(.vertical, 1)
    }

    private func code(_ text: String) -> some View {
        Text(text).font(DeveloperToolsStyle.code).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DeveloperToolsStyle.gutter * 2)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(DeveloperToolsStyle.gutter * 2)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private static func duration(_ milliseconds: Double) -> String {
        milliseconds.formatted(.number.precision(.fractionLength(milliseconds < 10 && milliseconds > 0 ? 2 : 1))) + " ms"
    }
}

/// An HTML response drawn as a page, without running its scripts or
/// loading anything else, as DevTools' Preview does.
private struct DeveloperHTMLPreview: NSViewRepresentable {
    let html: String
    let base: URL?

    func makeNSView(context: Context) -> WKWebViewPreview { WKWebViewPreview() }

    func updateNSView(_ view: WKWebViewPreview, context: Context) {
        view.show(html, base: base)
    }
}

final class WKWebViewPreview: NSView {
    private let web: WKWebView
    private var shown: String?

    override init(frame: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        web = WKWebView(frame: frame, configuration: configuration)
        super.init(frame: frame)
        web.autoresizingMask = [.width, .height]
        web.frame = bounds
        addSubview(web)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ html: String, base: URL?) {
        guard shown != html else { return }
        shown = html
        // No base URL: relative subresources stay unloaded, nothing reaches
        // the network from the preview.
        web.loadHTMLString(html, baseURL: nil)
    }
}
