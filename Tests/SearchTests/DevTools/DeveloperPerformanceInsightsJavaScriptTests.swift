import XCTest
@testable import Search

/// Performance › Insights' Duplicated JavaScript and Legacy JavaScript
/// (DeveloperPerformanceInsightsJavaScript, DeveloperLegacyJavaScript), over
/// hand-made scripts and source maps.
final class DeveloperPerformanceInsightsJavaScriptTests: XCTestCase {
    typealias Timing = DeveloperToolsSession.Timing
    typealias Insights = DeveloperPerformanceInsights
    typealias Legacy = DeveloperLegacyJavaScript

    /// Base64 VLQ, as a source map's `mappings` spell each segment.
    private func vlq(_ values: [Int]) -> String {
        let digits = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        var out = ""
        for value in values {
            var rest = value < 0 ? ((-value) << 1) | 1 : value << 1
            repeat {
                var digit = rest & 31
                rest >>= 5
                if rest > 0 { digit |= 32 }
                out.append(digits[digit])
            } while rest > 0
        }
        return out
    }

    /// A map of one generated line: each source starting at a column, in order.
    private func map(_ sources: [String], columns: [Int]) throws -> DeveloperSourceMap {
        var segments: [String] = []
        var previous = 0
        for (index, column) in columns.enumerated() {
            segments.append(vlq([column - previous, index == 0 ? 0 : 1, 0, 0]))
            previous = column
        }
        return try DeveloperSourceMap(json: ["version": 3, "sources": sources, "mappings": segments.joined(separator: ",")],
                                      base: nil)
    }

    private func script(_ url: String, length: Int, map: DeveloperSourceMap?) -> DeveloperPerformanceScript {
        DeveloperPerformanceScript(url: url, text: String(repeating: "x", count: length), map: map)
    }

    private func profile(_ urls: [String]) -> DeveloperPerformanceProfile {
        DeveloperPerformanceProfile([Timing(type: "RecordingBounds", start: 0, end: 5)] + urls.enumerated().map { index, url in
            Timing(type: "NetworkRequest", start: 0.1 * Double(index + 1), end: 0.1 * Double(index + 2),
                   data: ["url": url, "resourceType": "Script", "status": "200"])
        })
    }

    // MARK: Duplicated JavaScript

    /// Two bundles both carrying lodash's a.js (under different webpack
    /// prefixes) and a small util.js; a third script has no map.
    private func bundles() throws -> [DeveloperPerformanceScript] {
        let first = try map(["webpack://app/node_modules/lodash/a.js", "webpack://app/src/util.js",
                             "webpack://app/src/main.js"], columns: [0, 1_200, 1_500])
        let second = try map(["webpack://admin/./node_modules/lodash/a.js", "webpack://app/src/util.js",
                              "webpack://admin/src/other.js"], columns: [0, 1_000, 1_300])
        return [script("https://example.com/app.js", length: 2_000, map: first),
                script("https://example.com/admin.js", length: 1_500, map: second),
                script("https://example.com/plain.js", length: 5_000, map: nil)]
    }

    func testGeneratedSizesRunEachMappingToTheNextOrTheLineEnd() throws {
        let sizes = try XCTUnwrap(Insights.generatedSizes(
            map(["a.js", "b.js", "c.js"], columns: [0, 1_200, 1_500]), text: String(repeating: "x", count: 2_000)))
        // The last runs to the line's end and its newline.
        XCTAssertEqual(sizes, [0: 1_200, 1: 300, 2: 501])
        // A map reaching past the text isn't the script's.
        XCTAssertNil(Insights.generatedSizes(try map(["a.js", "b.js"], columns: [0, 50]), text: "short"))
    }

    func testDuplicatedSourcesAcrossTwoMapsAreFoundAndSmallCopiesLeftOut() throws {
        let (duplication, grouped) = Insights.scriptDuplication(try bundles())
        XCTAssertEqual(duplication.map(\.source), ["node_modules/lodash/a.js"])
        let lodash = try XCTUnwrap(duplication.first)
        // Largest copy kept; the other is the waste.
        XCTAssertEqual(lodash.duplicates, [.init(script: "https://example.com/app.js", size: 1_200),
                                           .init(script: "https://example.com/admin.js", size: 1_000)])
        XCTAssertEqual(lodash.estimatedDuplicateBytes, 1_000)
        // util.js is in both, but at 300 bytes a copy is under Chrome's 512.
        XCTAssertFalse(duplication.contains { $0.source.hasSuffix("util.js") })
        XCTAssertEqual(grouped.map(\.source), ["node_modules/lodash"])
        XCTAssertEqual(grouped.first?.estimatedDuplicateBytes, 1_000)
    }

    func testAPackagesFilesAreGroupedEvenWhenEachFileIsInOneBundle() throws {
        let first = try map(["webpack://a/node_modules/react/index.js", "webpack://a/src/a.js"], columns: [0, 600])
        let second = try map(["webpack://b/node_modules/react/cjs/react.js", "webpack://b/src/b.js"], columns: [0, 700])
        let (duplication, grouped) = Insights.scriptDuplication([
            script("https://example.com/a.js", length: 800, map: first),
            script("https://example.com/b.js", length: 900, map: second),
        ])
        XCTAssertTrue(duplication.isEmpty)
        XCTAssertEqual(grouped.map(\.source), ["node_modules/react"])
        XCTAssertEqual(grouped.first?.duplicates.map(\.size), [700, 600])
        XCTAssertEqual(grouped.first?.estimatedDuplicateBytes, 600)
    }

    func testSourcesAreNormalizedAsChromeDoes() {
        XCTAssertEqual(Insights.normalizedSource("webpack:///./node_modules/a/node_modules/b/x.js?"), "node_modules/b/x.js")
        XCTAssertEqual(Insights.normalizedSource("webpack://app/src/x.js"), "webpack://app/src/x.js")
        XCTAssertEqual(Insights.nodeModuleName("node_modules/@babel/runtime/helpers/x.js"), "@babel/runtime")
        XCTAssertEqual(Insights.nodeModuleName("node_modules/react/index.js"), "react")
        XCTAssertTrue(Insights.isIgnoredSource("webpack://app/webpack/bootstrap"))
        XCTAssertTrue(Insights.isIgnoredSource("webpack://app/external \"jQuery\""))
    }

    func testDuplicatedJavaScriptInsight() throws {
        let scripts = try bundles()
        let recording = profile(scripts.map(\.url))
        let insight = try XCTUnwrap(Insights.duplicatedJavaScript(recording, scripts: scripts))
        XCTAssertEqual(insight.title, "Duplicated JavaScript")
        XCTAssertEqual(insight.verdict, .fail)
        XCTAssertTrue(insight.headline?.hasPrefix("Est savings") == true)
        XCTAssertEqual(insight.rows.map(\.label), ["node_modules/lodash"])
        XCTAssertEqual(insight.ranges.count, 2)

        let clean = try XCTUnwrap(Insights.duplicatedJavaScript(recording, scripts: [scripts[0], scripts[2]]))
        XCTAssertEqual(clean.verdict, .pass)
        XCTAssertEqual(clean.headline, "No duplicated JavaScript found")
    }

    func testCompressionRatioTurnsTextBytesIntoTransferBytes() {
        var bar = DeveloperPerformanceProfile.NetworkBar(url: "https://example.com/a.js", start: 0, end: 1)
        XCTAssertEqual(Insights.compressionRatio(nil, contentLength: 1_000), 1)
        XCTAssertEqual(Insights.compressionRatio(bar, contentLength: 1_000), 1)
        bar.encoding = "br"
        bar.transferSize = 250
        bar.decodedSize = 1_000
        XCTAssertEqual(Insights.compressionRatio(bar, contentLength: 1_000), 0.25, accuracy: 0.0001)
        bar.source = "memory-cache"
        XCTAssertEqual(Insights.compressionRatio(bar, contentLength: 1_000), 0.33, accuracy: 0.0001)
    }

    // MARK: Legacy JavaScript

    private let polyfilled = """
    String.prototype.startsWith = function (s) { return this.indexOf(s) === 0; };
    Array.prototype['at'] = function (n) { return this[n]; };
    Object.defineProperty(Array.prototype, 'findLast', { value: function () {} });
    no(Object,{entries:r},{entries:function(){return Object.entries!==r}});
    e({target:"Array",proto:true},{fill:fill});
    require("core-js/modules/es.object.values.js");
    function _classCallCheck(a, n) { if (!(a instanceof n)) throw new TypeError("Cannot call a class as a function"); }
    regeneratorRuntime.awrap(x);
    """

    func testLegacyPatternsFoundInASnippet() {
        let found = Legacy.matches(in: polyfilled)
        XCTAssertEqual(Set(found), [
            "String.prototype.startsWith", "Array.prototype.at", "Array.prototype.findLast", "Object.entries",
            "Array.prototype.fill", "Object.values", Legacy.classesTransform, Legacy.regeneratorTransform,
        ])
        // Each once.
        XCTAssertEqual(found.count, Set(found).count)
        XCTAssertTrue(Legacy.matches(in: "const a = [1, 2].at(-1); class B {}").isEmpty)
    }

    func testLegacyModulesFoundInSourceMapSources() {
        let result = Legacy.detect("var a = 1;", sources: [
            "webpack://app/node_modules/focus-visible/dist/focus-visible.js",
            "webpack://app/node_modules/core-js/modules/es.array.flat.js",
            "webpack://app/src/index.js",
        ])
        XCTAssertEqual(result.matches, ["Array.prototype.flat", "focus-visible"])
    }

    func testLegacyMatchesSortAsJavaScriptDoes() {
        let result = Legacy.detect(polyfilled)
        XCTAssertEqual(result.matches, [
            Legacy.classesTransform, Legacy.regeneratorTransform, "Array.prototype.at", "Array.prototype.fill",
            "Array.prototype.findLast", "Object.entries", "Object.values", "String.prototype.startsWith",
        ])
        XCTAssertGreaterThan(result.estimatedByteSavings, 0)
    }

    func testLegacyWastedBytesEstimates() {
        // A polyfill costs its modules, each counted once.
        let modules = Set(DeveloperLegacyJavaScriptData.dependencies["Array.prototype.at"] ?? [])
        let size = modules.reduce(0) { $0 + DeveloperLegacyJavaScriptData.moduleSizes[$1] }
        XCTAssertGreaterThan(size, 0)
        XCTAssertEqual(Legacy.estimatedWastedBytes("", matches: ["Array.prototype.at"]), size)
        // Modules shared by several polyfills count once, and never more
        // than Lighthouse's maximum.
        let every = DeveloperLegacyJavaScriptData.polyfills.map(\.name)
        let union = Set(every.flatMap { DeveloperLegacyJavaScriptData.dependencies[$0] ?? [] })
        let total = union.reduce(0) { $0 + DeveloperLegacyJavaScriptData.moduleSizes[$1] }
        XCTAssertEqual(Legacy.estimatedWastedBytes("", matches: every), min(total, DeveloperLegacyJavaScriptData.maxSize))
        XCTAssertLessThan(total, every.reduce(0) { sum, name in
            sum + (DeveloperLegacyJavaScriptData.dependencies[name] ?? []).reduce(0) { $0 + DeveloperLegacyJavaScriptData.moduleSizes[$1] }
        })
        // Classes: 1,000 bytes and each further _classCallCheck call.
        let classes = "function _classCallCheck(a, n) { throw new TypeError(\"Cannot call a class as a function\"); }"
            + " _classCallCheck(this, A);"
        XCTAssertEqual(Legacy.detect(classes).estimatedByteSavings, 1_000 + "_classCallCheck()".count)
        // Regenerator: 80 bytes an await.
        XCTAssertEqual(Legacy.detect("regeneratorRuntime.awrap(a); regeneratorRuntime.awrap(b);").estimatedByteSavings, 160)
    }

    func testLegacyJavaScriptInsightSkipsSmallScriptsAndSmallSavings() throws {
        let padding = String(repeating: " ", count: 6_000)
        let scripts = [
            DeveloperPerformanceScript(url: "https://example.com/old.js", text: "Array.prototype.at = function(){};" + padding),
            // Under 5,000 characters: not checked.
            DeveloperPerformanceScript(url: "https://example.com/tiny.js", text: "Array.prototype.at = function(){};"),
            // Under 5,000 bytes of savings: not reported.
            DeveloperPerformanceScript(url: "https://example.com/class.js",
                                       text: "throw new TypeError(\"Cannot call a class as a function\");" + padding),
        ]
        let found = Insights.legacyFindings(scripts)
        XCTAssertEqual(found.map(\.url), ["https://example.com/old.js"])
        XCTAssertEqual(found.first?.matches, ["Array.prototype.at"])

        let recording = profile(scripts.map(\.url))
        let insight = try XCTUnwrap(Insights.legacyJavaScript(recording, scripts: scripts))
        XCTAssertEqual(insight.title, "Legacy JavaScript")
        XCTAssertEqual(insight.verdict, .fail)
        XCTAssertEqual(insight.rows.map(\.label), ["old.js"])
        XCTAssertEqual(insight.rows.first?.detail, "Array.prototype.at")

        let clean = try XCTUnwrap(Insights.legacyJavaScript(recording, scripts: [scripts[1]]))
        XCTAssertEqual(clean.verdict, .pass)
        XCTAssertEqual(clean.headline, "No legacy JavaScript found")
    }

    func testAllIncludesTheJavaScriptInsightsOnlyWithScripts() throws {
        let scripts = try bundles()
        let recording = profile(scripts.map(\.url))
        XCTAssertFalse(Insights.all(recording).contains { Insights.javaScriptKinds.contains($0.kind) })
        let kinds = Insights.all(recording, scripts: scripts).map(\.kind)
        XCTAssertTrue(kinds.contains(.duplicatedJavaScript))
        XCTAssertTrue(kinds.contains(.legacyJavaScript))
    }
}
