import CoreGraphics
import XCTest
@testable import Search

/// The Performance monitor's pure logic: the ring buffer, per-second
/// rates, the readings in words, the charts' scales and the history.
final class DeveloperPerformanceMonitorTests: XCTestCase {
    private typealias Metric = DeveloperPerformanceMetric
    private typealias Scale = DeveloperChartScale

    // MARK: Ring buffer

    func testTheRingBufferKeepsTheNewestElementsOldestFirst() {
        var ring = DeveloperRingBuffer<Int>(capacity: 3)
        XCTAssertTrue(ring.isEmpty)
        XCTAssertNil(ring.last)
        ring.append(1)
        ring.append(2)
        XCTAssertEqual(ring.elements, [1, 2])
        ring.append(3)
        ring.append(4)
        ring.append(5)
        XCTAssertEqual(ring.elements, [3, 4, 5])
        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring.last, 5)
        ring.append(6)
        ring.append(7)
        ring.append(8)
        XCTAssertEqual(ring.elements, [6, 7, 8], "wrapping exactly round leaves the order as it was")
        ring.removeAll()
        XCTAssertTrue(ring.isEmpty)
        ring.append(9)
        XCTAssertEqual(ring.elements, [9])
    }

    func testARingBufferHoldsAtLeastOne() {
        var ring = DeveloperRingBuffer<String>(capacity: 0)
        ring.append("a")
        ring.append("b")
        XCTAssertEqual(ring.elements, ["b"])
    }

    // MARK: Rates

    func testARateIsTheCountsChangeOverTheTimeBetweenReadings() {
        var meter = DeveloperRateMeter()
        XCTAssertNil(meter.rate(count: 10, at: 100), "the first reading has nothing to compare with")
        XCTAssertEqual(meter.rate(count: 13, at: 101) ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(meter.rate(count: 13, at: 102) ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(meter.rate(count: 23, at: 104) ?? -1, 5, accuracy: 1e-9, "two seconds, ten more")
    }

    func testARateStartsOverWhenTheCountGoesBackOrNoTimePasses() {
        var meter = DeveloperRateMeter()
        _ = meter.rate(count: 50, at: 10)
        XCTAssertNil(meter.rate(count: 2, at: 11), "the frontend's counter started again")
        XCTAssertEqual(meter.rate(count: 4, at: 12) ?? -1, 2, accuracy: 1e-9)
        XCTAssertNil(meter.rate(count: 6, at: 12))
        meter.reset()
        XCTAssertNil(meter.rate(count: 100, at: 20))
    }

    // MARK: Formatting

    func testReadingsAreWrittenAsChromeWritesThem() {
        XCTAssertEqual(Metric.cpu.format(12.345), "12.3%")
        XCTAssertEqual(Metric.cpu.format(0), "0.0%")
        XCTAssertEqual(Metric.cpu.format(-0.01), "0.0%")
        XCTAssertEqual(Metric.domNodes.format(1204), "1,204")
        XCTAssertEqual(Metric.documents.format(1), "1")
        XCTAssertEqual(Metric.frames.format(2.6), "3")
        XCTAssertEqual(Metric.layouts.format(3), "3.0")
        XCTAssertEqual(Metric.styleRecalcs.format(0.26), "0.3")
        XCTAssertEqual(Metric.jsHeap.format(512), "512 B")
        XCTAssertEqual(Metric.jsHeap.format(8_400_000), "8.4 MB")
        XCTAssertEqual(Metric.jsHeap.format(123_000_000), "123 MB")
        XCTAssertEqual(Metric.jsHeap.format(2_500), "2.5 kB")
        XCTAssertEqual(Metric.jsHeap.format(1_200_000_000), "1.2 GB")
    }

    func testAMissingReadingIsNA() {
        XCTAssertEqual(Metric.cpu.format(nil), "n/a")
        XCTAssertEqual(Metric.eventListeners.format(nil), "n/a")
        XCTAssertEqual(Metric.jsHeap.format(.nan), "n/a")
        XCTAssertEqual(Metric.layouts.format(.infinity), "n/a")
    }

    func testEventListenersAreNeverAvailableAndTheRatesNeedTheTimeline() {
        XCTAssertTrue(Metric.eventListeners.neverAvailable)
        XCTAssertEqual(Metric.allCases.filter(\.neverAvailable), [.eventListeners])
        XCTAssertEqual(Set(Metric.allCases.filter(\.needsTimeline)), [.layouts, .styleRecalcs])
        XCTAssertTrue(Metric.layouts.unavailableReason.contains("Performance panel"))
        XCTAssertEqual(Metric.defaults, [.cpu, .jsHeap, .domNodes, .eventListeners])
        XCTAssertEqual(Metric.allCases.map(\.rawValue), [
            "CPU usage", "JS heap size", "DOM Nodes", "JS event listeners", "Documents", "Document Frames",
            "Layouts / sec", "Style recalcs / sec",
        ])
    }

    // MARK: Scale

    func testTheScalesTopIsARoundNumberOverTheLargestReading() {
        XCTAssertEqual(Scale.niceMaximum(0), 1)
        XCTAssertEqual(Scale.niceMaximum(0.7), 1)
        XCTAssertEqual(Scale.niceMaximum(1), 2, "a little headroom over the reading")
        XCTAssertEqual(Scale.niceMaximum(3), 5)
        XCTAssertEqual(Scale.niceMaximum(7), 10)
        XCTAssertEqual(Scale.niceMaximum(150), 200)
        XCTAssertEqual(Scale.niceMaximum(420), 500)
        XCTAssertEqual(Scale.niceMaximum(4_800_000), 10_000_000)
        XCTAssertEqual(Scale.niceMaximum(.nan, floor: 5), 5)
        XCTAssertEqual(Scale.niceMaximum(30, floor: 100), 100)
    }

    func testCPUStartsAtAHundredPercentAndCountsAtTen() {
        let low = [DeveloperMetricSample(time: 0, value: 12), DeveloperMetricSample(time: 1, value: nil)]
        XCTAssertEqual(Scale.maximum(low, metric: .cpu), 100)
        XCTAssertEqual(Scale.maximum(low, metric: .domNodes), 20)
        XCTAssertEqual(Scale.maximum([DeveloperMetricSample(time: 0, value: 130)], metric: .cpu), 200)
        XCTAssertEqual(Scale.maximum([], metric: .documents), 10)
        XCTAssertEqual(Scale.maximum([], metric: .jsHeap), 1_000_000)
    }

    func testASampleLandsByItsAgeAcrossAndItsValueUp() {
        let size = CGSize(width: 600, height: 100)
        let now = DeveloperMetricSample(time: 60, value: 50)
        let point = Scale.point(now, value: 50, now: 60, maximum: 100, size: size)
        XCTAssertEqual(point.x, 600, accuracy: 1e-9)
        XCTAssertEqual(point.y, 50, accuracy: 1e-9)
        let old = Scale.point(DeveloperMetricSample(time: 30, value: 0), value: 0, now: 60, maximum: 100, size: size)
        XCTAssertEqual(old.x, 300, accuracy: 1e-9)
        XCTAssertEqual(old.y, 100, accuracy: 1e-9)
        let over = Scale.point(now, value: 250, now: 60, maximum: 100, size: size)
        XCTAssertEqual(over.y, 0, accuracy: 1e-9, "past the top is drawn at the top")
        let none = Scale.point(now, value: 5, now: 60, maximum: 0, size: size)
        XCTAssertEqual(none.y, 100, accuracy: 1e-9)
    }

    func testTheLineBreaksAtAMissingReadingAndReachesTheLeftEdge() {
        let size = CGSize(width: 60, height: 10)
        let samples = [
            DeveloperMetricSample(time: 10, value: 1),
            DeveloperMetricSample(time: 30, value: 2),
            DeveloperMetricSample(time: 50, value: 3),
            DeveloperMetricSample(time: 80, value: 4),
            DeveloperMetricSample(time: 90, value: nil),
            DeveloperMetricSample(time: 95, value: 5),
            DeveloperMetricSample(time: 100, value: 6),
        ]
        let runs = Scale.segments(samples, now: 100, maximum: 10, size: size)
        XCTAssertEqual(runs.count, 2)
        // From 30, the last reading before the window's start at 40, off the left edge.
        XCTAssertEqual(runs[0].map(\.x), [-10, 10, 40])
        XCTAssertEqual(runs[1].map(\.x), [55, 60])
        XCTAssertEqual(runs[1].last?.y ?? -1, 4, accuracy: 1e-9)
        XCTAssertTrue(Scale.segments([], now: 100, maximum: 10, size: size).isEmpty)
        XCTAssertTrue(Scale.segments([DeveloperMetricSample(time: 99, value: nil)], now: 100, maximum: 10, size: size).isEmpty)
    }

    func testTheTimeGridFallsEveryTenSecondsOnTheClock() {
        XCTAssertEqual(Scale.gridTimes(now: 125), [120, 110, 100, 90, 80, 70])
        XCTAssertEqual(Scale.gridTimes(now: 120), [120, 110, 100, 90, 80, 70])
        XCTAssertEqual(Scale.gridTimes(now: 5, window: 20, step: 5), [5, 0, -5, -10])
        XCTAssertEqual(Scale.gridTimes(now: 5, step: 0), [])
    }

    // MARK: Page counts and history

    func testThePagesCountsAreReadAndBadOnesDropped() {
        let counts = DeveloperPageCounts(raw: ["nodes": 1204, "documents": 2, "frames": 3])
        XCTAssertEqual(counts, DeveloperPageCounts(nodes: 1204, documents: 2, frames: 3))
        XCTAssertEqual(DeveloperPageCounts(raw: ["nodes": -1, "documents": "2"]), DeveloperPageCounts())
        XCTAssertEqual(DeveloperPageCounts(raw: nil), DeveloperPageCounts())
        XCTAssertTrue(DeveloperPageCounts.expression.contains("getElementsByTagName(\"*\")"))
    }

    func testTheHistoryKeepsEachMetricAndTurnsTimelineCountsIntoRates() {
        var history = DeveloperPerformanceHistory()
        history.add(.cpu, 10, at: 1)
        history.add(.cpu, 20, at: 2)
        XCTAssertEqual(history.samples(.cpu).map(\.value), [10, 20])
        XCTAssertEqual(history.latest(.cpu, now: 3), 20)
        XCTAssertNil(history.latest(.cpu, now: 30), "a reading from long ago isn't a reading now")

        history.addPage(DeveloperPageCounts(nodes: 100, documents: 1, frames: 1), at: 2)
        XCTAssertEqual(history.latest(.domNodes, now: 2), 100)
        XCTAssertEqual(history.samples(.eventListeners).count, 1)
        XCTAssertNil(history.latest(.eventListeners, now: 2))

        history.addTimeline(layouts: 5, styles: 10, at: 10)
        history.addTimeline(layouts: 8, styles: 10, at: 11)
        XCTAssertEqual(history.latest(.layouts, now: 11), 3)
        XCTAssertEqual(history.latest(.styleRecalcs, now: 11), 0)
        history.addTimeline(layouts: nil, styles: nil, at: 12)
        XCTAssertNil(history.latest(.layouts, now: 12), "no recording: n/a")
        history.addTimeline(layouts: 9, styles: 11, at: 13)
        XCTAssertNil(history.latest(.layouts, now: 13), "after a gap the rate starts over")

        history.removeAll()
        XCTAssertTrue(history.samples(.cpu).isEmpty)
    }

    func testTheHistoryHoldsMoreThanTheWindowAtTwoReadingsASecond() {
        XCTAssertGreaterThanOrEqual(Double(DeveloperPerformanceHistory.capacity), Scale.window * 2)
        var history = DeveloperPerformanceHistory()
        for second in 0..<500 { history.add(.cpu, Double(second), at: Double(second)) }
        XCTAssertEqual(history.samples(.cpu).count, DeveloperPerformanceHistory.capacity)
        XCTAssertEqual(history.samples(.cpu).last?.value, 499)
    }
}
