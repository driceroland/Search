import Foundation

/// Script text and an already attached source map included in a trace export.
struct DeveloperPerformanceScript: Equatable {
    let url: String
    let text: String
    var mapText: String? = nil
    var mapURL: String? = nil

    static let byteLimit = 16 * 1024 * 1024
    static let scriptLimit = 200
    var bytes: Int { text.utf8.count + (mapText?.utf8.count ?? 0) }

    /// Read resources WebKit already loaded for this recording. Never fetch
    /// them, or include a different document's or a private tab's scripts.
    @MainActor
    static func captured(_ session: DeveloperToolsSession, timings: [DeveloperToolsSession.Timing]) async -> [Self] {
        guard session.timelineIsCurrentDocument, !DevHost.isPrivate(session.web) else { return [] }
        let requested = Set(DeveloperPerformanceProfile(timings).network.compactMap { request -> String? in
            let mime = request.mimeType?.lowercased() ?? ""
            guard !request.isRedirect, request.resourceType == "Script" || mime.contains("javascript") || mime.contains("ecmascript"),
                  let url = URL(string: request.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil else { return nil }
            return request.url
        })
        guard !requested.isEmpty,
              let response = try? await session.command("Page.getResourceTree"),
              let tree = response["frameTree"] as? [String: Any],
              session.timelineIsCurrentDocument else { return [] }
        var resources: [DeveloperToolsSession.Resource] = []
        DeveloperToolsSession.addResources(tree, to: &resources)
        var remaining = byteLimit
        var seen = Set<String>()
        var scripts: [Self] = []
        for resource in resources where resource.type == "Script" && requested.contains(resource.url) {
            guard remaining > 0, scripts.count < scriptLimit else { break }
            guard session.timelineIsCurrentDocument else { return [] }
            guard seen.insert(resource.url).inserted,
                  let text = try? await session.bridge("""
                  const result = await searchInspector.command("Page.getResourceContent", resource);
                  const text = result.content;
                  return !result.base64Encoded && typeof text === "string" && text.length <= limit ? text : null;
                  """, ["resource": ["frameId": resource.frame, "url": resource.url], "limit": min(2_000_000, remaining)]) as? String,
                  text.utf8.count <= remaining else { continue }
            guard session.timelineIsCurrentDocument else { return [] }
            let entry = session.sourceMaps.recordedScriptMap(for: resource.url)
            let map = entry?.exportText.flatMap { $0.utf8.count <= remaining - text.utf8.count ? $0 : nil }
            let script = Self(url: resource.url, text: text, mapText: map, mapURL: map == nil ? nil : entry?.mapURL)
            scripts.append(script)
            remaining -= script.bytes
        }
        return scripts
    }
}
