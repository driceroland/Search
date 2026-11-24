import Foundation

/// A script the recording loaded, as the JavaScript insights read it: its
/// text as WebKit holds it (Page.getResourceContent) and the source map it
/// names, when DevTools loaded one.
struct DeveloperPerformanceScript: Equatable {
    let url: String
    var text: String
    var map: DeveloperSourceMap?
    /// The map's JSON as read, and where from (nil for a data: URL), for a
    /// trace saved with its scripts (DeveloperPerformanceTrace).
    var mapText: String? = nil
    var mapURL: String? = nil
}

/// Insights over the page's scripts' code, as Chrome DevTools' Duplicated
/// JavaScript and Legacy JavaScript check them (Chrome's trace engine's
/// ScriptDuplication and Lighthouse's legacy-javascript). Unlike the other
/// insights they need more than the recording: the scripts' text and source
/// maps, read from the page once the recording stops
/// (`scripts(_:profile:)`), or from a file saved with "Include script
/// content and source maps".
extension DeveloperPerformanceInsights {
    typealias Script = DeveloperPerformanceScript

    static let javaScriptKinds: Set<Insight.Kind> = [.duplicatedJavaScript, .legacyJavaScript]

    static func isScript(_ bar: Profile.NetworkBar) -> Bool {
        if bar.resourceType == "Script" { return true }
        let type = (bar.mimeType ?? "").lowercased()
        return type.contains("javascript") || type.contains("ecmascript")
    }

    /// The scripts the recording requested whose text the page still has,
    /// with their maps. Nil when there are none: the recording isn't the
    /// page's (one opened from a file, or the page has moved on).
    @MainActor
    static func scripts(_ session: DeveloperToolsSession, profile: Profile) async -> [Script]? {
        let requested = Set(profile.network.filter { !$0.isRedirect && isScript($0) }.map { stripped($0.url) })
        guard !requested.isEmpty, let contents = await DeveloperLighthouseModel.contents(session) else { return nil }
        var seen = Set<String>()
        let scripts = contents.filter {
            $0.kind == .script && requested.contains(stripped($0.url)) && seen.insert(stripped($0.url)).inserted
        }.map { content -> Script in
            let entry = session.sourceMaps.scriptEntry(for: content.url)
            return Script(url: content.url, text: content.text, map: entry?.map, mapText: entry?.text, mapURL: entry?.mapURL)
        }
        return scripts.isEmpty ? nil : scripts
    }

    /// Both cards, for scripts read from the page.
    static func javaScriptInsights(_ profile: Profile, scripts: [Script]) -> [Insight] {
        [duplicatedJavaScript(profile, scripts: scripts), legacyJavaScript(profile, scripts: scripts)].compactMap { $0 }
    }

    /// Chrome leaves out extensions' scripts.
    static func isExtension(_ url: String) -> Bool {
        let scheme = URL(string: url)?.scheme?.lowercased() ?? ""
        return scheme.hasSuffix("-extension")
    }

    // MARK: Compression

    /// Chrome's estimateCompressionRatioForScript: how much smaller the
    /// script was on the network than its text, so savings in the text
    /// become savings in transfer. From a cache, Chrome guesses a script
    /// gzips to a third.
    static func compressionRatio(_ bar: Profile.NetworkBar?, contentLength: Int) -> Double {
        guard let bar else { return 1 }
        var decoded = Double(contentLength)
        if let size = bar.decodedSize, size > 0 { decoded = size }
        guard decoded > 0 else { return 1 }
        // Chrome's isRequestServedFromBrowserCache: a 304, or next to
        // nothing over the network.
        var cached = bar.status == 304 || (bar.source?.lowercased().contains("cache") ?? false)
        if let transfer = bar.transferSize, transfer / decoded < 0.01 { cached = true }
        let compressed: Double
        if cached {
            compressed = (decoded * 0.33).rounded()
        } else if let encoding = bar.encoding?.lowercased(), ["gzip", "br", "deflate", "zstd"].contains(encoding),
                  let transfer = bar.transferSize {
            compressed = transfer
        } else {
            compressed = decoded
        }
        return compressed > 0 ? compressed / decoded : 1
    }

    static func ratios(_ profile: Profile, scripts: [Script]) -> [String: Double] {
        var ratios: [String: Double] = [:]
        for script in scripts {
            ratios[script.url] = compressionRatio(request(for: script.url, in: profile), contentLength: script.text.utf16.count)
        }
        return ratios
    }

    // MARK: Duplicated JavaScript

    /// Chrome's ScriptDuplication thresholds: a copy under 512 bytes, or
    /// under a tenth of the largest copy, doesn't count.
    static let duplicateMinimum = 512
    static let duplicateRelativeMinimum = 0.1

    /// How many bytes of a script each of its map's sources accounts for,
    /// by index into `sources`, as Chrome's computeGeneratedFileSizes
    /// counts them: each mapping runs to the next one on its line, or to
    /// the line's end and its newline. Nil when the map points outside the
    /// text: it isn't this script's.
    static func generatedSizes(_ map: DeveloperSourceMap, text: String) -> [Int: Int]? {
        let lines = text.utf16.split(separator: 10, omittingEmptySubsequences: false).map(\.count)
        var files: [Int: Int] = [:]
        let mappings = map.mappings
        for (index, mapping) in mappings.enumerated() {
            guard let source = mapping.source else { continue }
            guard lines.indices.contains(mapping.generatedLine) else { return nil }
            let line = lines[mapping.generatedLine]
            guard mapping.generatedColumn <= line else { return nil }
            let size: Int
            if index + 1 < mappings.count, mappings[index + 1].generatedLine == mapping.generatedLine {
                let next = mappings[index + 1].generatedColumn
                guard next <= line else { return nil }
                size = next - mapping.generatedColumn
            } else {
                size = line - mapping.generatedColumn + 1
            }
            files[source, default: 0] += size
        }
        return files
    }

    /// A source map `sources` entry as Chrome compares them: without
    /// webpack's trailing ?, and a dependency from its last node_modules on.
    static func normalizedSource(_ source: String) -> String {
        var source = source
        if source.hasSuffix("?") { source.removeLast() }
        if let found = source.range(of: "node_modules", options: .backwards) { source = String(source[found.lowerBound...]) }
        return source
    }

    /// Bundle overhead and module shims, which every bundle has.
    static func isIgnoredSource(_ source: String) -> Bool {
        source.contains("webpack/bootstrap") || source.contains("(webpack)/buildin") || source.contains("external ")
    }

    /// The package a node_modules path is in: "react", "@babel/runtime".
    static func nodeModuleName(_ source: String) -> String {
        let last = source.components(separatedBy: "node_modules/").last ?? source
        let parts = last.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        if last.hasPrefix("@"), parts.count > 1 { return parts[0] + "/" + parts[1] }
        return parts.first ?? last
    }

    struct Duplicate: Equatable {
        /// The script's address.
        let script: String
        /// Bytes of the script that map to the source, in transfer size.
        var size: Int
    }

    struct Duplication: Equatable {
        let source: String
        /// Largest first: the first is the copy kept.
        var duplicates: [Duplicate]
        /// Every copy but the first.
        var estimatedDuplicateBytes = 0
    }

    /// Chrome's computeScriptDuplication: each source that two or more of
    /// the scripts' maps name, with each copy's size (by `generatedSizes`,
    /// times the script's compression ratio). `grouped` puts a package's
    /// files together under node_modules/<package>, as Chrome's table
    /// shows them. A script without a map takes no part.
    static func scriptDuplication(_ scripts: [Script], ratios: [String: Double] = [:])
        -> (duplication: [Duplication], grouped: [Duplication]) {
        var duplication: [Duplication] = []
        var index: [String: Int] = [:]
        for script in scripts where !isExtension(script.url) {
            guard let map = script.map, !script.text.isEmpty,
                  let sizes = generatedSizes(map, text: script.text) else { continue }
            let ratio = ratios[script.url] ?? 1
            for (position, source) in map.sources.enumerated() where !isIgnoredSource(source) {
                // A source no mapping reaches has no size, and Chrome's drops out.
                guard let size = sizes[position] else { continue }
                let key = normalizedSource(source)
                let copy = Duplicate(script: script.url, size: Int((Double(size) * ratio).rounded()))
                if let at = index[key] {
                    duplication[at].duplicates.append(copy)
                } else {
                    index[key] = duplication.count
                    duplication.append(Duplication(source: key, duplicates: [copy]))
                }
            }
        }
        // Grouped before the small copies are dropped, as Chrome groups them.
        var grouped: [Duplication] = []
        var groupIndex: [String: Int] = [:]
        for entry in duplication {
            guard entry.source.contains("node_modules") else {
                groupIndex[entry.source] = grouped.count
                grouped.append(entry)
                continue
            }
            let key = "node_modules/" + nodeModuleName(entry.source)
            let at: Int
            if let found = groupIndex[key] {
                at = found
            } else {
                at = grouped.count
                groupIndex[key] = at
                grouped.append(Duplication(source: key, duplicates: []))
            }
            for copy in entry.duplicates {
                if let existing = grouped[at].duplicates.firstIndex(where: { $0.script == copy.script }) {
                    grouped[at].duplicates[existing].size += copy.size
                } else {
                    grouped[at].duplicates.append(copy)
                }
            }
        }
        return (sortedBySavings(normalizedDuplication(duplication)), sortedBySavings(normalizedDuplication(grouped)))
    }

    /// Chrome's normalizeDuplication: copies largest first, the small ones
    /// dropped, and sources left with one copy gone.
    static func normalizedDuplication(_ list: [Duplication]) -> [Duplication] {
        list.compactMap { entry in
            var entry = entry
            entry.duplicates = entry.duplicates.enumerated()
                .sorted { $0.element.size != $1.element.size ? $0.element.size > $1.element.size : $0.offset < $1.offset }
                .map(\.element)
            if entry.duplicates.count > 1, let largest = entry.duplicates.first.map({ Double($0.size) }) {
                entry.duplicates = entry.duplicates.filter { Double($0.size) / largest >= duplicateRelativeMinimum }
            }
            entry.duplicates = entry.duplicates.filter { $0.size >= duplicateMinimum }
            guard entry.duplicates.count > 1 else { return nil }
            entry.estimatedDuplicateBytes = entry.duplicates.dropFirst().reduce(0) { $0 + $1.size }
            return entry
        }
    }

    private static func sortedBySavings(_ list: [Duplication]) -> [Duplication] {
        list.enumerated().sorted {
            $0.element.estimatedDuplicateBytes != $1.element.estimatedDuplicateBytes
                ? $0.element.estimatedDuplicateBytes > $1.element.estimatedDuplicateBytes : $0.offset < $1.offset
        }.map(\.element)
    }

    static func duplicatedJavaScript(_ profile: Profile, scripts: [Script]) -> Insight? {
        let (duplication, grouped) = scriptDuplication(scripts, ratios: ratios(profile, scripts: scripts))
        // As Chrome: the savings are every copy but the first, of each source.
        let wasted = duplication.reduce(0) { $0 + $1.estimatedDuplicateBytes }
        let rows = grouped.prefix(20).enumerated().map { index, entry in
            let copies = entry.duplicates.map { "\(file($0.script)) \(DeveloperMetricFormat.bytes(Double($0.size)))" }
            let bar = entry.duplicates.first.flatMap { request(for: $0.script, in: profile) }
            return Row(id: index, label: entry.source,
                       value: DeveloperMetricFormat.bytes(Double(entry.estimatedDuplicateBytes)),
                       detail: copies.joined(separator: ", "), range: bar.map { $0.start...$0.end }, failing: true)
        }
        var involved: [String] = []
        for copy in duplication.flatMap(\.duplicates) where !involved.contains(copy.script) { involved.append(copy.script) }
        return Insight(kind: .duplicatedJavaScript, title: "Duplicated JavaScript",
                       verdict: duplication.isEmpty ? .pass : .fail,
                       explanation: "Remove large, duplicate JavaScript modules from bundles to reduce unnecessary "
                           + "bytes consumed by network activity.",
                       headline: duplication.isEmpty ? "No duplicated JavaScript found"
                           : "Est savings \(DeveloperMetricFormat.bytes(Double(wasted)))",
                       rows: Array(rows), ranges: requestRanges(involved, in: profile))
    }

    // MARK: Legacy JavaScript

    /// Chrome's: a script under 5,000 characters isn't checked, nor are
    /// savings under 5,000 bytes (before compression) reported.
    static let legacyByteThreshold = 5_000

    struct LegacyFinding: Equatable {
        let url: String
        /// In transfer size.
        let wasted: Int
        let matches: [String]
    }

    /// Each script's polyfills and transforms, most savings first.
    static func legacyFindings(_ scripts: [Script], ratios: [String: Double] = [:]) -> [LegacyFinding] {
        var found: [LegacyFinding] = []
        for script in scripts where !isExtension(script.url) && script.text.utf16.count >= legacyByteThreshold {
            let result = DeveloperLegacyJavaScript.detect(script.text, sources: script.map?.sources)
            guard result.estimatedByteSavings >= legacyByteThreshold else { continue }
            let wasted = Int((Double(result.estimatedByteSavings) * (ratios[script.url] ?? 1)).rounded())
            found.append(LegacyFinding(url: script.url, wasted: wasted, matches: result.matches))
        }
        return found.enumerated().sorted {
            $0.element.wasted != $1.element.wasted ? $0.element.wasted > $1.element.wasted : $0.offset < $1.offset
        }.map(\.element)
    }

    static func legacyJavaScript(_ profile: Profile, scripts: [Script]) -> Insight? {
        let findings = legacyFindings(scripts, ratios: ratios(profile, scripts: scripts))
        let wasted = findings.reduce(0) { $0 + $1.wasted }
        let rows = findings.prefix(20).enumerated().map { index, finding in
            let bar = request(for: finding.url, in: profile)
            return Row(id: index, label: file(finding.url), value: DeveloperMetricFormat.bytes(Double(finding.wasted)),
                       detail: finding.matches.joined(separator: ", "), range: bar.map { $0.start...$0.end },
                       failing: true)
        }
        return Insight(kind: .legacyJavaScript, title: "Legacy JavaScript", verdict: findings.isEmpty ? .pass : .fail,
                       explanation: "Polyfills and transforms enable older browsers to use new JavaScript features. "
                           + "However, many aren’t necessary for modern browsers. Consider modifying your JavaScript "
                           + "build process to not transpile Baseline features, unless you know you must support "
                           + "older browsers.",
                       headline: findings.isEmpty ? "No legacy JavaScript found"
                           : "Est savings \(DeveloperMetricFormat.bytes(Double(wasted)))",
                       rows: Array(rows), ranges: requestRanges(findings.map(\.url), in: profile))
    }
}
