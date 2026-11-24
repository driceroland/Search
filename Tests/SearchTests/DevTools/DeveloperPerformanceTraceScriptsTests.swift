import XCTest
@testable import Search

/// Performance › Save profile with "Include script content and source
/// maps": the scripts and maps written as Chrome writes them, and read back
/// for the JavaScript insights.
final class DeveloperPerformanceTraceScriptsTests: XCTestCase {
    private typealias Timing = DeveloperToolsSession.Timing
    private typealias Trace = DeveloperPerformanceTrace

    private let timings = [Timing(type: "TimerFire", start: 1.0, end: 1.01)]

    private func script(_ url: String, mapURL: String?) throws -> DeveloperPerformanceScript {
        let text = #"{"version":3,"sources":["webpack://app/node_modules/lodash/a.js"],"mappings":"AAAA"}"#
        return DeveloperPerformanceScript(url: url, text: String(repeating: "x", count: 2_000),
                                          map: try DeveloperSourceMap(text: text, mapURL: mapURL, scriptURL: url),
                                          mapText: text, mapURL: mapURL)
    }

    func testScriptsAndSourceMapsRoundTripInChromesFormat() throws {
        let scripts = [try script("https://example.com/app.js", mapURL: "https://example.com/app.js.map"),
                       try script("https://example.com/admin.js", mapURL: nil)]
        let data = try Trace.export(timings, url: "https://example.com/", scripts: scripts)

        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(file["traceEvents"] as? [[String: Any]])
        let rundowns = events.filter { $0["name"] as? String == "ScriptRundown" }
        XCTAssertEqual(rundowns.count, 2)
        let maps = try XCTUnwrap((file["metadata"] as? [String: Any])?["sourceMaps"] as? [[String: Any]])
        XCTAssertEqual(maps.first?["url"] as? String, "https://example.com/app.js")
        XCTAssertEqual(maps.first?["sourceMapUrl"] as? String, "https://example.com/app.js.map")
        XCTAssertEqual((maps.first?["sourceMap"] as? [String: Any])?["mappings"] as? String, "AAAA")

        let loaded = try Trace.recording(from: data)
        XCTAssertEqual(loaded.timings.map(\.type), ["TimerFire"], "the script events aren't records")
        XCTAssertEqual(loaded.scripts?.map(\.url), scripts.map(\.url))
        XCTAssertEqual(loaded.scripts?.map(\.text), scripts.map(\.text))
        XCTAssertEqual(loaded.scripts?.map(\.map), scripts.map(\.map))
        XCTAssertEqual(loaded.scripts?.map(\.mapURL), scripts.map(\.mapURL))

        // Saved again, the file keeps them; and they feed the insights.
        XCTAssertEqual(try Trace.recording(from: Trace.export(loaded.timings, scripts: loaded.scripts)).scripts?.map(\.map),
                       scripts.map(\.map))
        let profile = DeveloperPerformanceProfile(loaded.timings)
        let insight = try XCTUnwrap(DeveloperPerformanceInsights.duplicatedJavaScript(profile, scripts: loaded.scripts ?? []))
        XCTAssertEqual(insight.verdict, .fail)
    }

    func testChromesSplitSourcesJoinAndPlainFilesHaveNone() throws {
        let data = { (isolate: String, id: Int) in ["isolate": isolate, "scriptId": id] as [String: Any] }
        func event(_ name: String, _ fields: [String: Any]) -> [String: Any] {
            ["name": name, "ph": "I", "ts": 1, "args": ["data": fields]]
        }
        let events = [
            event("ScriptRundown", data("0x1", 7).merging(["url": "https://example.com/big.js"]) { a, _ in a }),
            event("ScriptRundownSource", data("0x1", 7).merging(["sourceText": "world", "splitIndex": 1]) { a, _ in a }),
            event("ScriptRundownSource", data("0x1", 7).merging(["sourceText": "hello ", "splitIndex": 0]) { a, _ in a }),
            // A script whose text wasn't included.
            event("ScriptRundown", data("0x1", 8).merging(["url": "https://example.com/other.js"]) { a, _ in a }),
        ]
        let scripts = try XCTUnwrap(Trace.traceScripts(events, metadata: nil))
        XCTAssertEqual(scripts.map(\.url), ["https://example.com/big.js"])
        XCTAssertEqual(scripts.first?.text, "hello world")
        XCTAssertNil(scripts.first?.map)
        XCTAssertNil(try Trace.recording(from: Trace.export(timings)).scripts)
    }
}
