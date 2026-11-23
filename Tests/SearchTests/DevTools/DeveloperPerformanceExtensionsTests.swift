import XCTest
@testable import Search

/// Chrome's Performance extensibility API: detail.devtools on marks and
/// measures and extended console.timeStamp calls, as custom tracks and
/// markers in a recording.
final class DeveloperPerformanceExtensionsTests: XCTestCase {
    typealias Timing = DeveloperToolsSession.Timing
    typealias Extensions = DeveloperPerformanceExtensions

    // MARK: detail.devtools

    func testATrackEntryMeasureIsRead() throws {
        let detail = try XCTUnwrap(Extensions.detail([
            "dataType": "track-entry", "track": "Image processing", "trackGroup": "My app", "color": "Tertiary-Dark",
            "tooltipText": "Resized 3 images", "properties": [["Images", "3"], ["Quality", 80], ["broken"]] as [[Any]],
        ] as [String: Any], for: "measure"))
        XCTAssertEqual(detail.dataType, .trackEntry)
        XCTAssertEqual(detail.track, "Image processing")
        XCTAssertEqual(detail.group, "My app")
        XCTAssertEqual(detail.color, "tertiary-dark")
        XCTAssertEqual(detail.tooltip, "Resized 3 images")
        XCTAssertEqual(detail.properties, [.init(key: "Images", value: "3"), .init(key: "Quality", value: "80")])

        // A measure's dataType is track-entry when it doesn't say.
        let plain = try XCTUnwrap(Extensions.detail(["track": "Work"] as [String: Any], for: "measure"))
        XCTAssertEqual(plain.dataType, .trackEntry)
        XCTAssertEqual(plain.color, "primary")
        XCTAssertNil(plain.group)
    }

    func testAMarkerMarkIsRead() throws {
        let detail = try XCTUnwrap(Extensions.detail([
            "dataType": "marker", "color": "error", "tooltipText": "Ready", "properties": [["Phase", "boot"]],
            // A marker has no track.
            "track": "ignored",
        ] as [String: Any], for: "mark"))
        XCTAssertEqual(detail.dataType, .marker)
        XCTAssertNil(detail.track)
        XCTAssertEqual(detail.color, "error")
        XCTAssertEqual(detail.properties, [.init(key: "Phase", value: "boot")])
    }

    func testInvalidOrOversizedDetailsAreIgnored() {
        XCTAssertNil(Extensions.detail(nil, for: "measure"))
        XCTAssertNil(Extensions.detail("track-entry", for: "measure"))
        XCTAssertNil(Extensions.detail(["dataType": "track-entry"] as [String: Any], for: "measure"), "no track")
        XCTAssertNil(Extensions.detail(["dataType": "track-entry", "track": "  "] as [String: Any], for: "measure"))
        XCTAssertNil(Extensions.detail(["dataType": "chart", "track": "A"] as [String: Any], for: "measure"))
        XCTAssertNil(Extensions.detail(["dataType": "marker"] as [String: Any], for: "measure"))
        XCTAssertNil(Extensions.detail(["track": "A"] as [String: Any], for: "mark"), "a mark is only a marker")
        XCTAssertNil(Extensions.detail(["dataType": "track-entry", "track": "A"] as [String: Any], for: "mark"))
        XCTAssertNil(Extensions.detail(["track": "A", "oversized": true] as [String: Any], for: "measure"))
        XCTAssertNil(Extensions.detail(["track": String(repeating: "t", count: 201)] as [String: Any], for: "measure"))
        XCTAssertNil(Extensions.detail(["track": "A", "tooltipText": String(repeating: "t", count: 1_001)] as [String: Any],
                                       for: "measure"))
        let many = (0..<51).map { ["key \($0)", "value"] }
        XCTAssertNil(Extensions.detail(["track": "A", "properties": many] as [String: Any], for: "measure"))
        let big = (0..<20).map { ["key \($0)", String(repeating: "v", count: 900)] }
        XCTAssertNil(Extensions.detail(["track": "A", "properties": big] as [String: Any], for: "measure"), "too much in all")
    }

    func testPaletteNamesMapToColors() {
        let names = ["primary", "primary-light", "primary-dark", "secondary", "secondary-light", "secondary-dark",
                     "tertiary", "tertiary-light", "tertiary-dark", "error", "warning"]
        XCTAssertEqual(Set(Extensions.palette.keys), Set(names))
        XCTAssertEqual(Set(names.map { "\(Extensions.rgb($0))" }).count, names.count, "each its own colour")
        XCTAssertEqual(Extensions.colorName("Warning"), "warning")
        XCTAssertEqual(Extensions.colorName(" error "), "error")
        XCTAssertEqual(Extensions.colorName("#ff0000"), "primary")
        XCTAssertEqual(Extensions.colorName(nil), "primary")
        XCTAssertEqual(Extensions.colorName(3), "primary")
        XCTAssertEqual(Extensions.rgb("nonsense"), Extensions.rgb("primary"))
        XCTAssertGreaterThan(Extensions.rgb("error").red, Extensions.rgb("error").blue)
        XCTAssertTrue(Extensions.isLight("primary-light"))
        XCTAssertTrue(Extensions.isLight("warning"))
        XCTAssertFalse(Extensions.isLight("primary-dark"))
    }

    // MARK: console.timeStamp

    func testTimeStampStartAndEndResolve() {
        let names: [String: Any] = ["boot": 12.5]
        XCTAssertEqual(Extensions.resolve(40, at: 100, names: names), 40)
        XCTAssertEqual(Extensions.resolve("boot", at: 100, names: names), 12.5, "a mark's name")
        XCTAssertEqual(Extensions.resolve("missing", at: 100, names: names), 100, "a name not found is the call's time")
        XCTAssertEqual(Extensions.resolve(nil, at: 100, names: names), 100)
        XCTAssertEqual(Extensions.resolve(Double.nan, at: 100, names: names), 100)
        XCTAssertEqual(Extensions.resolve(["object"], at: 100, names: names), 100)

        let stamp = Extensions.timeStamp(["label": "Decode", "at": 90, "start": "boot", "end": 60, "track": "Codec",
                                          "trackGroup": "Media", "color": "secondary", "names": names])
        XCTAssertEqual(stamp?.type, Extensions.type)
        XCTAssertEqual(stamp?.start, 12.5)
        XCTAssertEqual(stamp?.end, 60)
        XCTAssertEqual(stamp?.data["track"], "Codec")
        XCTAssertEqual(stamp?.data["trackGroup"], "Media")
        XCTAssertEqual(stamp?.data["color"], "secondary")
        XCTAssertEqual(stamp?.data["source"], "console.timeStamp")

        // An end before the start is put the right way round.
        let backwards = Extensions.timeStamp(["label": "B", "at": 90, "start": 80, "end": 20, "track": "T"])
        XCTAssertEqual(backwards?.start, 20)
        XCTAssertEqual(backwards?.end, 80)
        // Only a start: it runs to the call.
        let open = Extensions.timeStamp(["label": "O", "at": 90, "start": 30, "track": "T"])
        XCTAssertEqual(open?.start, 30)
        XCTAssertEqual(open?.end, 90)

        // Without a track, in Timings.
        let timing = Extensions.timeStamp(["label": "Plain", "at": 90, "start": 10])
        XCTAssertEqual(timing?.type, "PageTiming")
        XCTAssertEqual(timing?.data["kind"], "measure")
        let instant = Extensions.timeStamp(["label": "Now", "at": 90, "start": 90, "end": 90])
        XCTAssertEqual(instant?.data["kind"], "mark")
        XCTAssertNil(Extensions.timeStamp(["at": 90]), "no label")
    }

    // MARK: Recording

    func testThePagesExtensionsJoinTheRecording() throws {
        var record = [
            Timing(type: "RecordingBounds", start: 10, end: 12),
            Timing(type: "TimeStamp", start: 10.5, end: 10.5, data: ["message": "perch-sync 2000"]),
        ]
        let page: [String: Any] = ["now": 2_000, "extensions": [
            ["kind": "measure", "name": "Resize", "start": 1_900, "end": 2_100,
             "devtools": ["track": "Images", "trackGroup": "My app", "color": "tertiary", "tooltipText": "3 images",
                          "properties": [["Count", "3"]]] as [String: Any]],
            ["kind": "mark", "name": "Ready", "start": 2_200, "end": 2_200,
             "devtools": ["dataType": "marker", "color": "error"]],
            // Not one Chrome draws: a plain measure.
            ["kind": "measure", "name": "Odd", "start": 2_000, "end": 2_050, "devtools": ["dataType": "chart"]],
            // Before the recording: left out.
            ["kind": "measure", "name": "Early", "start": 100, "end": 200, "devtools": ["track": "Images"]],
        ] as [[String: Any]], "stamps": [
            ["label": "Decode", "at": 2_300, "start": 2_250, "track": "Codec"],
        ] as [[String: Any]]]
        DeveloperPerformancePageTimings.merge(page, into: &record, bounds: 10...12)

        let extensions = record.filter { $0.type == Extensions.type }
        XCTAssertEqual(extensions.map { $0.data["name"] }, ["Resize", "Ready", "Decode"])
        let resize = try XCTUnwrap(extensions.first)
        XCTAssertEqual(resize.start, 10.4, accuracy: 1e-9)
        XCTAssertEqual(resize.end, 10.6, accuracy: 1e-9)
        XCTAssertEqual(resize.data["source"], "performance.measure")
        XCTAssertEqual(Extensions.decode(resize.data["properties"]), [.init(key: "Count", value: "3")])
        XCTAssertEqual(record.filter { $0.type == "PageTiming" }.map { $0.data["name"] }, ["Odd"])

        let profile = DeveloperPerformanceProfile(record)
        XCTAssertEqual(profile.customTracks.map(\.name), ["Images", "Codec"])
        XCTAssertEqual(profile.customTracks.first?.group, "My app")
        XCTAssertEqual(profile.extensionMarkers.map(\.name), ["Ready"])
        XCTAssertEqual(profile.extensionMarkers.first?.color, "error")
        XCTAssertFalse(profile.events.contains { $0.type == Extensions.type }, "not flame chart records")

        let summary = try XCTUnwrap(profile.customSummary(.init(track: 0, index: 0)))
        XCTAssertEqual(summary.title, "Resize")
        XCTAssertEqual(summary.tooltip, "3 images")
        XCTAssertEqual(summary.group, "My app")
        XCTAssertEqual(summary.duration ?? 0, 200, accuracy: 1e-6)
        XCTAssertEqual(summary.properties, [.init(key: "Count", value: "3")])
        XCTAssertEqual(profile.customSummary(.init(track: nil, index: 0))?.kind, "Marker")
        XCTAssertNil(profile.customSummary(.init(track: 5, index: 0)))
    }

    func testTracksGroupAndOrderAsTheyFirstAppear() {
        func entry(_ track: String, _ group: String?, _ start: Double, _ end: Double) -> Timing {
            var data = ["kind": "track-entry", "name": "\(track) at \(start)", "track": track]
            if let group { data["trackGroup"] = group }
            return Timing(type: Extensions.type, start: start, end: end, data: data)
        }
        let profile = DeveloperPerformanceProfile([
            Timing(type: "RecordingBounds", start: 0, end: 10),
            entry("Loose", nil, 3, 4),
            entry("Network", "App", 2, 3),
            entry("Render", "App", 1, 2),
            entry("Solo", nil, 5, 6),
            entry("Render", "Other", 6, 7),
            // Overlapping: stacked into a second row.
            entry("Render", "App", 1.5, 1.8),
            entry("Render", "App", 1.9, 2.5),
        ])
        XCTAssertEqual(profile.customTracks.map(\.name), ["Render", "Network", "Loose", "Solo", "Render"])
        XCTAssertEqual(profile.customTracks.map(\.group), ["App", "App", nil, nil, "Other"])
        let render = profile.customTracks[0]
        XCTAssertEqual(render.entries.map(\.row), [0, 1, 1])
        XCTAssertEqual(render.rows, 2)
        XCTAssertEqual(profile.customEntry(track: 0, at: 1_600, row: 1), 1)
        XCTAssertNil(profile.customEntry(track: 0, at: 1_600, row: 2))
    }

    func testExtensionRecordsKeepTheirOwnBudget() {
        let page: [String: Any] = ["now": 0, "stamps": (0..<2_500).map {
            ["label": "s\($0)", "at": Double($0), "track": "T"] as [String: Any]
        }]
        let kept = Extensions.pageRecords(page)
        XCTAssertEqual(kept.count, Extensions.limit)
        XCTAssertEqual(kept.last?.data["name"], "s2499", "the newest are kept")

        var records = (0..<DeveloperToolsSession.timelineLimit).map {
            Timing(type: "FunctionCall", start: Double($0), end: Double($0))
        }
        records += (0..<2_500).map {
            Timing(type: Extensions.type, start: Double($0), end: Double($0), data: ["kind": "track-entry", "track": "T"])
        }
        let capped = DeveloperToolsSession.cappedTimeline(records)
        XCTAssertEqual(capped.filter { $0.type == Extensions.type }.count, Extensions.limit)
        XCTAssertEqual(capped.filter { $0.type == "FunctionCall" }.count, DeveloperToolsSession.timelineLimit)
    }

    func testSavedProfilesKeepCustomTracksAndMarkers() throws {
        let timings = [
            Timing(type: "RecordingBounds", start: 0, end: 1),
            Timing(type: Extensions.type, start: 0.1, end: 0.3, data: [
                "kind": "track-entry", "name": "Work", "track": "Jobs", "trackGroup": "App", "color": "warning",
                "tooltip": "Busy", "properties": Extensions.encode([.init(key: "Id", value: "7")]),
            ]),
            Timing(type: Extensions.type, start: 0.5, end: 0.5, data: ["kind": "marker", "name": "Done", "color": "tertiary"]),
        ]
        let saved = try DeveloperPerformanceTrace.export(timings)
        let profile = DeveloperPerformanceProfile(try DeveloperPerformanceTrace.timings(from: saved))
        XCTAssertEqual(profile.customTracks.map(\.name), ["Jobs"])
        let entry = try XCTUnwrap(profile.customTracks.first?.entries.first)
        XCTAssertEqual(entry.color, "warning")
        XCTAssertEqual(entry.tooltip, "Busy")
        XCTAssertEqual(entry.properties, [.init(key: "Id", value: "7")])
        XCTAssertEqual(profile.extensionMarkers.map(\.name), ["Done"])
    }
}
