import XCTest
@testable import Search

final class DeveloperDeviceModeTests: XCTestCase {
    func testDraggingTheRightEdgeChangesTheWidthByTwiceThePointerTravel() {
        let start = DeveloperViewportResize.Size(width: 400, height: 800)
        let wider = DeveloperViewportResize.size(from: start, translation: CGSize(width: 25, height: 40), scale: 0.5,
                                                 edges: .right)
        XCTAssertEqual(wider, .init(width: 500, height: 800))
        let notCentred = DeveloperViewportResize.size(from: start, translation: CGSize(width: 25, height: 0), scale: 0.5,
                                                      edges: .right, centred: false)
        XCTAssertEqual(notCentred.width, 450)
    }

    func testDraggingTheBottomEdgeFollowsThePointer() {
        let start = DeveloperViewportResize.Size(width: 400, height: 800)
        let taller = DeveloperViewportResize.size(from: start, translation: CGSize(width: 90, height: 30), scale: 0.5,
                                                  edges: .bottom)
        XCTAssertEqual(taller, .init(width: 400, height: 860))
        let corner = DeveloperViewportResize.size(from: start, translation: CGSize(width: -10, height: -10), scale: 1,
                                                  edges: .corner)
        XCTAssertEqual(corner, .init(width: 380, height: 790))
    }

    func testResizeIsClampedToChromesLimits() {
        let start = DeveloperViewportResize.Size(width: 60, height: 9_990)
        let size = DeveloperViewportResize.size(from: start, translation: CGSize(width: -500, height: 500), scale: 1,
                                                edges: .corner)
        XCTAssertEqual(size, .init(width: 50, height: 9_999))
    }

    func testResizingAPresetSwitchesToResponsiveAtItsSize() throws {
        var settings = DeveloperViewportSettings()
        let device = try XCTUnwrap(DeveloperDevices.builtIn.first { $0.title == "iPhone SE" })
        settings.select(device)
        settings.rotate()
        XCTAssertEqual(settings.width, 667)
        settings.resize(width: 700)
        XCTAssertTrue(settings.isResponsive)
        XCTAssertEqual(settings.width, 700)
        XCTAssertEqual(settings.height, 375)
        XCTAssertEqual(settings.deviceScaleFactor, 2)
    }

    func testArrowKeysStepByOneOrTen() {
        XCTAssertEqual(DeveloperViewportSettings.stepped(390, up: true, shift: false), 391)
        XCTAssertEqual(DeveloperViewportSettings.stepped(390, up: false, shift: true), 380)
        XCTAssertEqual(DeveloperViewportSettings.stepped(52, up: false, shift: true), 50)
    }

    func testSettingsSurviveEncodingAndResetKeepsTheMenuChoices() throws {
        var settings = DeveloperViewportSettings()
        settings.set(width: 512, height: 600)
        settings.zoom = .fixed(1.5)
        settings.showRulers = true
        settings.showDeviceType = true
        let decoded = try JSONDecoder().decode(DeveloperViewportSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        var reset = decoded
        reset.reset()
        XCTAssertEqual(reset.width, 390)
        XCTAssertEqual(reset.zoom, .fit)
        XCTAssertTrue(reset.showRulers)
        XCTAssertTrue(reset.showDeviceType)
        XCTAssertFalse(reset.showMediaQueries)
    }

    func testAnOlderSaveWithFewerKeysStillLoads() throws {
        let old = Data(#"{"responsiveWidth": 800, "responsiveHeight": 600, "landscape": false}"#.utf8)
        let settings = try JSONDecoder().decode(DeveloperViewportSettings.self, from: old)
        XCTAssertEqual(settings.width, 800)
        XCTAssertEqual(settings.height, 600)
        XCTAssertFalse(settings.showRulers)
        XCTAssertEqual(settings.zoom, .fit)
    }

    func testRulerTicksSpaceOutWithTheScale() {
        XCTAssertEqual(DeveloperViewportRuler.spacing(scale: 1).minor, 5)
        XCTAssertEqual(DeveloperViewportRuler.spacing(scale: 1).major, 50)
        XCTAssertEqual(DeveloperViewportRuler.spacing(scale: 0.5).minor, 10)
        XCTAssertEqual(DeveloperViewportRuler.spacing(scale: 0.5).major, 100)
        let ticks = DeveloperViewportRuler.ticks(length: 100, scale: 1)
        XCTAssertEqual(ticks.first, .init(position: 0, kind: .major))
        XCTAssertEqual(ticks.first { $0.position == 25 }?.kind, .medium)
        XCTAssertEqual(ticks.first { $0.position == 5 }?.kind, .minor)
        XCTAssertEqual(ticks.last, .init(position: 100, kind: .major))
    }

    func testMediaQueriesBecomeChromesThreeKinds() {
        let queries = DeveloperMediaQuery.parse([
            "(max-width: 600px)", "screen and (min-width: 48em)", "(min-width: 400px) and (max-width: 799.5px)",
            "print", "(orientation: landscape)", "(width >= 1200px)", "(300px < width <= 500px)",
            "(max-width: 600px), (min-width: 1024px)",
        ])
        XCTAssertEqual(queries.filter { $0.kind == .max }.map(\.max), [600])
        XCTAssertEqual(queries.filter { $0.kind == .min }.map(\.min), [768, 1024, 1200])
        let ranges = queries.filter { $0.kind == .range }
        XCTAssertEqual(Set(ranges.map { [$0.min ?? 0, $0.max ?? 0] }), [[400, 800], [301, 500]])
        XCTAssertEqual(queries.first { $0.kind == .min }?.width, 768)
        XCTAssertEqual(ranges.first?.width, ranges.first?.max)
    }

    func testThrottlingPresetsUseTheirNetworkHalf() {
        XCTAssertEqual(DeveloperViewportThrottling.midTier.condition, .fast4G)
        XCTAssertEqual(DeveloperViewportThrottling.lowEnd.condition, .slow4G)
        XCTAssertEqual(DeveloperViewportThrottling(.offline), .offline)
        XCTAssertNil(DeveloperViewportThrottling(.threeG))
    }
}
