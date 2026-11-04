import XCTest
@testable import Search

/// Spaces brought over from Arc keep their icon (#832).
final class ArcIconTests: XCTestCase {
    func testArcsOwnIcons() {
        XCTAssertEqual(Arc.symbol(emoji: nil, arcIcon: "bulb", name: "Work"), "lightbulb")
        XCTAssertEqual(Arc.symbol(emoji: nil, arcIcon: "leaf", name: "Work"), "leaf")
        XCTAssertEqual(Arc.symbol(emoji: nil, arcIcon: "star", name: "Work"), "sparkles")
        XCTAssertEqual(Arc.symbol(emoji: nil, arcIcon: "pizza", name: "Perso"), "cup.and.saucer")
    }

    func testEveryArcIconIsOneOfSearchs() {
        for name in ["construction", "people", "star", "bulb", "leaf", "pizza"] {
            XCTAssertTrue(Spaces.icons.contains(Arc.symbol(emoji: nil, arcIcon: name, name: "")), name)
        }
    }

    func testAnUnknownArcIconFallsBackToTheName() {
        XCTAssertEqual(Arc.symbol(emoji: nil, arcIcon: "rocket", name: "Home"), "house")
        XCTAssertEqual(Arc.symbol(emoji: "🤖", name: "Work"), "sparkles")
    }
}
