import AppKit
import XCTest
@testable import Search

@MainActor
final class DeveloperPerformanceScreenshotsTests: XCTestCase {
    typealias Timing = DeveloperToolsSession.Timing

    /// A 2×2 red PNG as base64.
    private func png() throws -> String {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<2 { for y in 0..<2 { rep.setColor(.red, atX: x, y: y) } }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:])).base64EncodedString()
    }

    func testProfileKeepsScreenshotsOutOfTheFlameChart() throws {
        let image = "data:image/png;base64," + (try png())
        let timings = [
            Timing(type: "Layout", start: 10, end: 10.05),
            Timing(type: "Screenshot", start: 10.02, end: 10.02, data: ["imageData": image]),
            Timing(type: "Screenshot", start: 10.2, end: 10.2, data: ["imageData": image]),
        ]
        let profile = DeveloperPerformanceProfile(timings)
        XCTAssertEqual(profile.events.map(\.type), ["Layout"])
        XCTAssertEqual(profile.screenshots.map(\.time).map { $0.rounded() }, [20, 200])
        XCTAssertEqual(profile.bounds.upperBound, 200, accuracy: 0.001)
        XCTAssertEqual(profile.screenshot(at: 150)?.time.rounded(), 20)
        XCTAssertEqual(profile.screenshot(at: 500)?.time.rounded(), 200)
        XCTAssertNil(profile.screenshot(at: 5))
        XCTAssertEqual(try XCTUnwrap(profile.screenshots.first?.image).size, NSSize(width: 2, height: 2))
        XCTAssertNotNil(DeveloperPerformanceScreenshots.image(try png()), "bare base64 decodes too")
    }

    func testStripPutsTheLatestFrameInEachSlot() {
        let shots = [0.0, 100, 700].map { DeveloperPerformanceScreenshot(time: $0, imageData: "\($0)") }
        let strip = DeveloperPerformanceScreenshots.strip(shots, duration: 1_000, width: 100, slot: 25)
        XCTAssertEqual(strip.map(\.x), [0, 25, 50, 75])
        XCTAssertEqual(strip.map(\.shot.time), [100, 100, 700, 700])
        XCTAssertTrue(DeveloperPerformanceScreenshots.strip([], duration: 1, width: 1, slot: 1).isEmpty)
    }

    func testScreenshotsRoundTripThroughAChromeTrace() throws {
        let base64 = try png()
        let timings = [Timing(type: "Layout", start: 1, end: 1.01),
                       Timing(type: "Screenshot", start: 1.005, end: 1.005, data: ["imageData": "data:image/png;base64," + base64])]
        let data = try DeveloperPerformanceTrace.export(timings)
        let events = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let shot = try XCTUnwrap(events.first { $0["name"] as? String == "Screenshot" })
        XCTAssertEqual(shot["cat"] as? String, "disabled-by-default-devtools.screenshot")
        XCTAssertEqual((shot["args"] as? [String: Any])?["snapshot"] as? String, base64)
        let back = try DeveloperPerformanceTrace.timings(from: data)
        XCTAssertEqual(back.filter { $0.type == "Screenshot" }.map(\.data["imageData"]), [base64])
        XCTAssertEqual(DeveloperPerformanceProfile(back).screenshots.count, 1)
    }

    func testChromeScreenshotsOffTheMainThreadAreRead() throws {
        let trace: [String: Any] = ["traceEvents": [
            ["name": "thread_name", "ph": "M", "pid": 1, "tid": 1, "ts": 0, "args": ["name": "CrRendererMain"]],
            ["name": "Layout", "ph": "X", "pid": 1, "tid": 1, "ts": 1_000, "dur": 50, "args": [:]],
            ["name": "Screenshot", "ph": "O", "id": "0x1", "pid": 2, "tid": 9, "ts": 1_020,
             "cat": "disabled-by-default-devtools.screenshot", "args": ["snapshot": "AAAA"]],
        ]]
        let timings = try DeveloperPerformanceTrace.timings(from: JSONSerialization.data(withJSONObject: trace))
        XCTAssertEqual(timings.map(\.type).sorted(), ["Layout", "Screenshot"])
    }
}
