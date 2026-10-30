import XCTest
import WebKit
@testable import Search

@MainActor
final class TabMemoryRegressionTests: XCTestCase {
    func testCurrentProcessCounterUsesStructureStorage() {
        let bytes = TabMemoryMonitor.physicalFootprint(of: getpid())
        XCTAssertNotNil(bytes)
        XCTAssertGreaterThan(bytes ?? 0, 1_048_576)
        XCTAssertLessThan(bytes ?? .max, 32 * 1_073_741_824)
        XCTAssertNil(TabMemoryMonitor.physicalFootprint(of: -1))
    }

    func testDuplicateRendererEstimatesAreNotAddedTwice() {
        var estimates = TabMemoryMonitor.SleepEstimates()
        let a = UUID(), b = UUID()
        estimates.record(id: a, pid: 42, bytes: 100)
        estimates.record(id: b, pid: 42, bytes: 100)
        XCTAssertNil(estimates.savings(for: a))
        XCTAssertNil(estimates.savings(for: b))
        XCTAssertNil(estimates.total)
    }

    func testSleepingEstimateSurvivesRefreshWithoutBuildingWebView() async {
        _ = NSApplication.shared
        let tab = Tab(configuration: WKWebViewConfiguration())
        tab.restore(url: URL(string: "https://example.com")!, title: "Sleeping")
        let monitor = TabMemoryMonitor(sampler: { _ in .init(footprints: [:], totalBytes: 1000) })
        monitor.didSleep(tab, processID: 42, bytes: 200)
        await monitor.refresh(tabs: [tab])
        XCTAssertTrue(monitor.reading(for: tab).isSleeping)
        XCTAssertEqual(monitor.reading(for: tab).estimatedSavingsBytes, 200)
        XCTAssertEqual(monitor.estimatedSavedBytes, 200)
        XCTAssertNil(tab.built)
        monitor.didWake(tab.id)
        XCTAssertNil(monitor.estimatedSavedBytes)
        XCTAssertNil(monitor.reading(for: tab).estimatedSavingsBytes)
    }

    func testRestoredSleepingTabHasUnknownSavingsAndPreviewDoesNotWakeIt() async {
        _ = NSApplication.shared
        let tab = Tab(configuration: WKWebViewConfiguration())
        tab.restore(url: URL(string: "https://example.com")!, title: "Never opened")
        let monitor = TabMemoryMonitor(sampler: { _ in .init(footprints: [:], totalBytes: nil) })
        await monitor.refresh(tabs: [tab])
        XCTAssertTrue(monitor.reading(for: tab).isSleeping)
        XCTAssertNil(monitor.reading(for: tab).estimatedSavingsBytes)
        XCTAssertNil(monitor.totalBytes)
        var called = false
        tab.preview(width: 200) { image in called = true; XCTAssertNil(image) }
        XCTAssertTrue(called)
        XCTAssertNil(tab.built)
    }

    func testSampleIdentityRejectsNavigationSleepWakeAndProcessChanges() {
        let url = URL(string: "https://example.com/a")!
        let original = TabMemoryMonitor.SampleIdentity(processID: 12, address: url, sleeping: false, generation: 0)
        XCTAssertTrue(TabMemoryMonitor.sampleIsCurrent(original, current: original))
        XCTAssertFalse(TabMemoryMonitor.sampleIsCurrent(original, current: .init(processID: 12, address: URL(string: "https://example.com/b"), sleeping: false, generation: 0)))
        XCTAssertFalse(TabMemoryMonitor.sampleIsCurrent(original, current: .init(processID: 13, address: url, sleeping: false, generation: 0)))
        XCTAssertFalse(TabMemoryMonitor.sampleIsCurrent(original, current: .init(processID: nil, address: url, sleeping: true, generation: 0)))
        XCTAssertFalse(TabMemoryMonitor.sampleIsCurrent(original, current: .init(processID: 12, address: url, sleeping: false, generation: 1)))
    }

    func testSharedRendererDoesNotGetSleepSavings() {
        _ = NSApplication.shared
        let tab = Tab(configuration: WKWebViewConfiguration())
        tab.restore(url: URL(string: "https://example.com")!, title: "Sleeping")
        let monitor = TabMemoryMonitor()
        monitor.didSleep(tab, processID: 12, bytes: 100, shared: true)
        XCTAssertTrue(monitor.reading(for: tab).isSharedProcess)
        XCTAssertNil(monitor.reading(for: tab).estimatedSavingsBytes)
        XCTAssertNil(monitor.estimatedSavedBytes)
    }
}
