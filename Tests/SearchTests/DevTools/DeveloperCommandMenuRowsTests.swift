import AppKit
import WebKit
import XCTest
@testable import Search

/// The command menu's ">" rows for features Search has, worded as Chrome's,
/// and Capture area screenshot's rectangle.
@MainActor
final class DeveloperCommandMenuRowsTests: XCTestCase {
    func testCommandsListSupportedChromesRows() async throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = PageView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        let browser = Browser(record: WindowRecord())
        let context = DeveloperToolsContext(session: session, tools: DeveloperTools.shared,
                                            shell: DeveloperToolsShell.shared, browser: browser)
        let titles = Set(DeveloperCommandMenu.commands(in: context).map(\.title))
        for title in [
            "Pause script execution", "Deactivate breakpoints", "Disable cache (while DevTools is open)",
            "Show Request conditions",
            "Show paint flashing rectangles", "Show layer borders", "Emulate blurred vision",
            "Do not emulate any vision deficiency", "Toggle device toolbar", "Show rulers", "Clear site data",
            "Capture screenshot", "Capture full size screenshot", "Capture node screenshot", "Capture area screenshot",
        ] {
            XCTAssertTrue(titles.contains(title), "missing \(title)")
        }
        for position in DeveloperDockPosition.allCases {
            XCTAssertTrue(titles.contains(position.title), "missing \(position.title)")
        }
        // Rendering's page-side emulations, as Chrome's command menu words them.
        for title in [
            "Show layout shift regions", "Show frames per second (FPS) meter", "Emulate a focused page",
            "Emulate CSS forced-colors: active", "Emulate CSS forced-colors: none", "Do not emulate CSS forced-colors",
            "Emulate CSS prefers-contrast: less", "Emulate CSS prefers-contrast: custom",
            "Emulate CSS prefers-reduced-transparency: reduce", "Emulate CSS prefers-reduced-data: reduce",
            "Emulate CSS color-gamut: p3", "Do not emulate CSS color-gamut",
        ] {
            XCTAssertTrue(titles.contains(title), "missing \(title)")
        }
        // The preference commands set WebKit's own UserPreferenceValue names,
        // which it takes capitalized and nothing else.
        let commands = DeveloperCommandMenu.commands(in: context)
        func run(_ title: String) { commands.first { $0.title == title }?.run() }
        run("Emulate CSS prefers-color-scheme: dark")
        run("Emulate CSS prefers-reduced-motion: reduce")
        run("Emulate CSS forced-colors: active")
        XCTAssertEqual(session.rendering.options.colorScheme, "Dark")
        XCTAssertEqual(session.rendering.options.reducedMotion, "Reduce")
        XCTAssertEqual(session.rendering.options.forcedColors, "active")
        // Nothing for what WebKit can't do.
        XCTAssertFalse(titles.contains { $0.localizedCaseInsensitiveContains("scrolling performance") })
        XCTAssertFalse(titles.contains { $0.localizedCaseInsensitiveContains("AVIF") })
        await DeveloperTestSupport.finish(session, page: page, keeping: tab, browser)
    }

    func testAreaIsTheDraggedRectangleInsideThePage() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertEqual(DeveloperScreenshot.area(from: CGPoint(x: 50, y: 60), to: CGPoint(x: 10, y: 20), in: bounds),
                       CGRect(x: 10, y: 20, width: 40, height: 40))
        XCTAssertEqual(DeveloperScreenshot.area(from: CGPoint(x: 350, y: 250), to: CGPoint(x: 500, y: 400), in: bounds),
                       CGRect(x: 350, y: 250, width: 50, height: 50))
        XCTAssertNil(DeveloperScreenshot.area(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 6, y: 5), in: bounds))
        XCTAssertNil(DeveloperScreenshot.area(from: CGPoint(x: 500, y: 500), to: CGPoint(x: 600, y: 600), in: bounds))
    }

    func testNativeContrastGoesToWebKitByItsName() {
        var options = DeveloperRendering.Options()
        options.contrast = "more"
        XCTAssertEqual(options.payload(nativeContrast: true)["contrast"] as? String, "More")
        XCTAssertTrue(options.payload(nativeContrast: false)["contrast"] is NSNull)
        XCTAssertNil(options.pageState(nativeContrast: true).media["prefers-contrast"])
        XCTAssertEqual(options.pageState(nativeContrast: false).media["prefers-contrast"], "more")
        options.contrast = "less"
        XCTAssertTrue(options.payload(nativeContrast: true)["contrast"] is NSNull)
        XCTAssertEqual(options.pageState(nativeContrast: true).media["prefers-contrast"], "less")
    }
}
