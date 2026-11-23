import XCTest
@testable import Search

/// Performance's CPU track: CPUProfiler.trackingUpdate read into samples
/// with their thread breakdown, and the samples' budget.
final class DeveloperPerformanceCPUTests: XCTestCase {
    private typealias Timing = DeveloperToolsSession.Timing

    private let update: [String: Any] = [
        "timestamp": 2.5, "usage": 42.0,
        "threads": [
            ["name": "Main Thread", "usage": 20.0, "type": "main"],
            ["name": "Worker", "usage": 6.0, "type": "webkit", "targetId": "worker-1"],
            ["name": "Worker", "usage": 4.0, "type": "webkit", "targetId": "worker-2"],
            ["name": "JIT", "usage": 7.0, "type": "webkit"],
            ["name": "Other", "usage": 5.0],
        ] as [[String: Any]],
    ]

    func testAnUpdateBecomesASampleWithItsThreads() throws {
        let timing = try XCTUnwrap(DeveloperPerformanceCPU.timing(update, since: 1))
        XCTAssertEqual(timing.type, "CPUSample")
        XCTAssertEqual(timing.start, 2.5)
        let sample = try XCTUnwrap(DeveloperPerformanceCPU.sample(timing.data, at: 1_500))
        XCTAssertEqual(sample.time, 1_500)
        XCTAssertEqual(sample.usage, 42)
        XCTAssertEqual(sample.main, 20)
        XCTAssertEqual(sample.workers, 10)
        XCTAssertEqual(sample.workerCount, 2)
        XCTAssertEqual(sample.webkit, 7)
        XCTAssertEqual(sample.other, 5)
        XCTAssertTrue(sample.hasThreads)
    }

    func testUpdatesBeforeTheRecordingOrWithoutUsageAreSkipped() {
        XCTAssertNil(DeveloperPerformanceCPU.timing(update, since: 3))
        XCTAssertNil(DeveloperPerformanceCPU.timing(["timestamp": 4.0]))
        let bare = DeveloperPerformanceCPU.timing(["timestamp": 4.0, "usage": 12.5])
        XCTAssertEqual(bare?.data, ["usage": "12.5"])
        XCTAssertEqual(bare.flatMap { DeveloperPerformanceCPU.sample($0.data, at: 0) }?.hasThreads, false)
    }

    func testTheProfileKeepsSamplesInTimeOrderOutOfTheFlameChart() {
        let profile = DeveloperPerformanceProfile([
            Timing(type: "RecordingBounds", start: 0, end: 2),
            DeveloperPerformanceCPU.timing(["timestamp": 1.0, "usage": 30.0])!,
            DeveloperPerformanceCPU.timing(["timestamp": 0.5, "usage": 10.0])!,
        ])
        XCTAssertEqual(profile.cpu.map(\.time), [500, 1_000])
        XCTAssertEqual(profile.cpu.map(\.usage), [10, 30])
        XCTAssertTrue(profile.events.isEmpty)
        XCTAssertFalse(profile.isEmpty)
        XCTAssertEqual(DeveloperPerformanceCPU.sample(at: 700, in: profile.cpu)?.usage, 30, "a reading covers the time before it")
        XCTAssertNil(DeveloperPerformanceCPU.sample(at: 1_200, in: profile.cpu))
    }

    func testSamplesAreThinnedEvenlyToTheirBudget() {
        let samples = (0..<10).map { DeveloperPerformanceCPU.Sample(time: Double($0), usage: 1) }
        XCTAssertEqual(DeveloperPerformanceCPU.budgeted(samples, limit: 4).map(\.time), [0, 2, 5, 7])
        XCTAssertEqual(DeveloperPerformanceCPU.budgeted(samples, limit: 20).count, 10)
        XCTAssertEqual(DeveloperPerformanceCPU.budgeted(samples, limit: 0).count, 0)
    }

    func testACappedRecordingKeepsSamplesWithinTheirBudget() {
        var records = (0..<(DeveloperToolsSession.timelineLimit + 10)).map {
            Timing(type: "Layout", start: Double($0), end: Double($0))
        }
        records += (0..<(DeveloperPerformanceCPU.limit + 50)).map {
            DeveloperPerformanceCPU.timing(["timestamp": Double($0), "usage": 5.0])!
        }
        let capped = DeveloperToolsSession.cappedTimeline(records)
        XCTAssertEqual(capped.filter { $0.type == "CPUSample" }.count, DeveloperPerformanceCPU.limit)
        XCTAssertEqual(capped.filter { $0.type == "Layout" }.count, DeveloperToolsSession.timelineLimit)
    }

    func testUsageIsLabelledAsAPercentage() {
        XCTAssertEqual(DeveloperPerformanceCPU.percent(42), "42%")
        XCTAssertEqual(DeveloperPerformanceCPU.percent(2.26), "2.3%")
        XCTAssertEqual(DeveloperPerformanceCPU.percent(0), "0%")
    }
}
