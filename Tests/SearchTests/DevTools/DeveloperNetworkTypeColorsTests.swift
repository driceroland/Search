import XCTest
@testable import Search

/// Network's "Color-code resource types" colours, and the flame chart's
/// Modern and Classic scrolling.
final class DeveloperNetworkTypeColorsTests: XCTestCase {
    private typealias Colors = DeveloperNetworkTypeColors

    func testKindsTakeChromesColours() {
        XCTAssertEqual(Colors.hsl(for: .document), .init(hue: 215, saturation: 1, lightness: 0.8))
        XCTAssertEqual(Colors.hsl(for: .stylesheet), .init(hue: 272, saturation: 0.64, lightness: 0.8))
        XCTAssertEqual(Colors.hsl(for: .script), .init(hue: 31, saturation: 1, lightness: 0.8))
        XCTAssertEqual(Colors.hsl(for: .fetch), .init(hue: 53, saturation: 1, lightness: 0.8))
        XCTAssertEqual(Colors.hsl(for: .font), .init(hue: 8, saturation: 1, lightness: 0.8))
        XCTAssertEqual(Colors.hsl(for: .image), Colors.hsl(for: .media))
        XCTAssertEqual(Colors.hsl(for: .other).saturation, 0)
        XCTAssertEqual(Colors.hsl(for: .socket), Colors.hsl(for: .other))
        XCTAssertEqual(Colors.hsl(for: .manifest), Colors.hsl(for: .other))
    }

    func testKindsThatDifferLookDifferent() {
        let distinct: [DeveloperRequestKind] = [.document, .stylesheet, .script, .fetch, .image, .font, .wasm, .other]
        XCTAssertEqual(Set(distinct.map(Colors.hsl(for:))).count, distinct.count)
    }

    func testHSLConvertsToRGB() {
        let blue = Colors.hsl(for: .document).rgb
        XCTAssertEqual(blue.red, 0.6, accuracy: 0.001)
        XCTAssertEqual(blue.green, 0.7667, accuracy: 0.001)
        XCTAssertEqual(blue.blue, 1, accuracy: 0.001)
        let grey = Colors.HSL(hue: 0, saturation: 0, lightness: 0.7).rgb
        XCTAssertEqual(grey.red, 0.7, accuracy: 0.001)
        XCTAssertEqual(grey.green, 0.7, accuracy: 0.001)
        XCTAssertEqual(grey.blue, 0.7, accuracy: 0.001)
        let purple = Colors.hsl(for: .stylesheet).rgb
        XCTAssertGreaterThan(purple.blue, purple.green)
        XCTAssertGreaterThan(purple.red, purple.green)
    }

    func testModernScrollMovesAndCommandZooms() {
        typealias Move = DeveloperFlameChartNavigation.Move
        let modern = DeveloperFlameChartNavigation.modern
        XCTAssertEqual(modern.move(dx: 3, dy: 5, zoomKey: false, shift: false), Move(pan: 3, scroll: 5))
        XCTAssertEqual(modern.move(dx: 0, dy: 5, zoomKey: false, shift: true), Move(pan: 5))
        XCTAssertEqual(modern.move(dx: 0, dy: 5, zoomKey: true, shift: false), Move(zoom: 5))
    }

    func testClassicScrollZoomsAndShiftMoves() {
        typealias Move = DeveloperFlameChartNavigation.Move
        let classic = DeveloperFlameChartNavigation.classic
        XCTAssertEqual(classic.move(dx: 0, dy: 5, zoomKey: false, shift: false), Move(zoom: 5))
        XCTAssertEqual(classic.move(dx: 2, dy: 0, zoomKey: false, shift: false), Move(pan: 2))
        XCTAssertEqual(classic.move(dx: 0, dy: 5, zoomKey: false, shift: true), Move(scroll: 5))
        // A mouse wheel with Shift arrives as a sideways scroll.
        XCTAssertEqual(classic.move(dx: 4, dy: 0, zoomKey: false, shift: true), Move(scroll: 4))
    }
}
