import XCTest
@testable import Search

@MainActor
final class TabMemoryTests: XCTestCase {
    func testSharedRendererIsNotMisreportedAsPerTabSavings() {
        let readings = TabMemoryMonitor.readings(tabIDs: [UUID(), UUID()], processIDs: [42, 42], footprints: [42: 900])
        XCTAssertEqual(readings.count, 2)
        XCTAssertTrue(readings.allSatisfy(\.isSharedProcess))
        XCTAssertTrue(readings.allSatisfy { $0.bytes == nil && $0.estimatedSavingsBytes == nil })
    }

    func testUniqueRendererCanBecomeSleepEstimateOnce() {
        var cache = TabMemoryMonitor.SleepEstimates()
        let id = UUID()
        cache.record(id: id, pid: 21, bytes: 1234)
        XCTAssertEqual(cache.savings(for: id), 1234)
        XCTAssertNil(cache.savings(for: UUID()))
        cache.remove(id)
        XCTAssertNil(cache.savings(for: id))
    }

    func testUnavailableAndSharedProcessFootprintsStayUnknown() {
        let readings = TabMemoryMonitor.readings(tabIDs: [UUID(), UUID()], processIDs: [nil, 50], footprints: [:])
        XCTAssertTrue(readings.allSatisfy { $0.bytes == nil && $0.estimatedSavingsBytes == nil })
    }
}
