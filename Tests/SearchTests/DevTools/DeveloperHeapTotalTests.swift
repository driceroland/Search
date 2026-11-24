import XCTest
@testable import Search

@MainActor
final class DeveloperHeapTotalTests: XCTestCase {
    func testTheTotalReadsAsChromeWritesIt() {
        XCTAssertEqual(DeveloperHeapTotal.size(4_230_000), "4.2 MB")
        XCTAssertEqual(DeveloperHeapTotal.size(nil), "–")
    }

    func testTheVMIsNamedByItsHost() {
        XCTAssertEqual(DeveloperHeapTotal.host(URL(string: "https://example.test/features")), "example.test")
        XCTAssertEqual(DeveloperHeapTotal.host(nil), "Page")
    }
}
