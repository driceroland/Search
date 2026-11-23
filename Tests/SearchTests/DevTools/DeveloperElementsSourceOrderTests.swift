import XCTest
@testable import Search

final class DeveloperElementsSourceOrderTests: XCTestCase {
    // 1 ─┬─ 2 ─┬─ 4
    //    │     └─ 5 (no box)
    //    └─ 3 ─── 6
    private let tree: [Int: [Int]] = [1: [2, 3], 2: [4, 5], 3: [6]]

    func testDescendantsAreNumberedDepthFirstInDocumentOrder() {
        let badges = DeveloperSourceOrder.badges(under: 1, children: { tree[$0] ?? [] }, numbered: { _ in true })
        XCTAssertEqual(badges.map(\.node), [2, 4, 5, 3, 6])
        XCTAssertEqual(badges.map(\.number), [1, 2, 3, 4, 5])
    }

    func testElementsWithoutABoxAreSkippedAndTheNumbersStayConsecutive() {
        let badges = DeveloperSourceOrder.badges(under: 1, children: { tree[$0] ?? [] }, numbered: { $0 != 5 })
        XCTAssertEqual(badges, [.init(node: 2, number: 1), .init(node: 4, number: 2),
                                .init(node: 3, number: 3), .init(node: 6, number: 4)])
    }

    func testTheRootIsNotNumbered() {
        let badges = DeveloperSourceOrder.badges(under: 3, children: { tree[$0] ?? [] }, numbered: { _ in true })
        XCTAssertEqual(badges, [.init(node: 6, number: 1)])
        XCTAssertTrue(DeveloperSourceOrder.badges(under: 6, children: { tree[$0] ?? [] }, numbered: { _ in true }).isEmpty)
    }

    func testTheBadgesStopAtTheCap() {
        let wide = Array(2...1_500)
        let badges = DeveloperSourceOrder.badges(under: 1, children: { $0 == 1 ? wide : [] }, numbered: { _ in true })
        XCTAssertEqual(badges.count, DeveloperSourceOrder.cap)
        XCTAssertEqual(badges.last, .init(node: 1_001, number: 1_000))
        XCTAssertEqual(DeveloperSourceOrder.badges(under: 1, children: { tree[$0] ?? [] }, numbered: { _ in true }, cap: 2)
            .map(\.node), [2, 4])
    }

    func testTheSummary() {
        XCTAssertEqual(DeveloperSourceOrder.summary(shown: 0, capped: false), "No source order information available")
        XCTAssertNil(DeveloperSourceOrder.summary(shown: 12, capped: false))
        XCTAssertEqual(DeveloperSourceOrder.summary(shown: 1_000, capped: true), "Showing source order for the first 1000 elements")
    }
}
