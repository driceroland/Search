import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class FloatViewportTests: XCTestCase {
    private var activationPolicy: NSApplication.ActivationPolicy!

    override class func setUp() {
        setenv("SEARCH_PROBE", "float-viewport-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
    }

    override func tearDown() {
        NSApp.setActivationPolicy(activationPolicy)
    }

    func testContainedVideoUsesNativeCropWithoutResizingThePage() throws {
        try withPage { floater, page in
            let sourceSize = page.frame.size
            let rect = NSRect(x: 100, y: 80, width: 640, height: 360)
            floater.lift(page, videoRect: rect)

            let panel = try XCTUnwrap(page.window)
            let ground = try XCTUnwrap(panel.contentView)
            let viewport = try XCTUnwrap(page.superview)
            XCTAssertFalse(Bench.onScreen(panel))
            XCTAssertTrue(floater.holds(page), "ownership must work through the native viewport")
            XCTAssertFalse(floater.holds(NSView()))
            XCTAssertTrue(viewport.superview === ground)
            XCTAssertEqual(page.frame.size, sourceSize)
            XCTAssertEqual(page.autoresizingMask, [])
            assertRect(viewport.bounds, equals: NSRect(origin: .zero, size: rect.size))
            XCTAssertEqual(viewport.frame, ground.bounds)
            XCTAssertEqual(viewport.layer?.masksToBounds, true)

            // DOM rectangles start at the top; the native view starts at the bottom.
            let nativeRect = NSRect(x: rect.minX, y: sourceSize.height - rect.maxY,
                                    width: rect.width, height: rect.height)
            assertRect(page.convert(nativeRect, to: ground), equals: ground.bounds)
        }
    }

    func testResizingNativeCropKeepsTheSourcePageAndCropBounds() throws {
        try withPage { floater, page in
            let rect = NSRect(x: 100, y: 80, width: 640, height: 360)
            floater.lift(page, videoRect: rect)
            let panel = try XCTUnwrap(page.window)
            let ground = try XCTUnwrap(panel.contentView)
            let viewport = try XCTUnwrap(page.superview)
            let sourceFrame = page.frame
            let sourceBounds = page.bounds

            for width in [CGFloat(520), 780, 300] {
                panel.setContentSize(NSSize(width: width, height: width * 9 / 16))
                ground.layoutSubtreeIfNeeded()
                XCTAssertFalse(Bench.onScreen(panel))
                XCTAssertEqual(page.frame, sourceFrame)
                XCTAssertEqual(page.bounds, sourceBounds)
                assertRect(viewport.bounds, equals: NSRect(origin: .zero, size: rect.size))
                assertRect(viewport.frame, equals: ground.bounds)
                let picture = NSRect(x: rect.minX, y: sourceBounds.height - rect.maxY,
                                     width: rect.width, height: rect.height)
                assertRect(page.convert(picture, to: ground), equals: ground.bounds)
                XCTAssertTrue(floater.holds(page))
            }
        }
    }

    func testPortraitCropControlsTheWindowAspectAndMinimumSize() throws {
        try withPage { floater, page in
            let rect = NSRect(x: 120, y: 40, width: 360, height: 640)
            floater.lift(page, videoRect: rect)
            let panel = try XCTUnwrap(page.window)
            let content = try XCTUnwrap(panel.contentView)
            XCTAssertFalse(Bench.onScreen(panel))
            // AppKit rounds the content frame to backing pixels.
            XCTAssertEqual(content.bounds.height, content.bounds.width * 640 / 360, accuracy: 1)
            XCTAssertEqual(panel.aspectRatio.height / panel.aspectRatio.width, 640 / 360, accuracy: 0.001)
            XCTAssertEqual(panel.minSize.width, 260, accuracy: 0.001)
            XCTAssertEqual(panel.minSize.height, 260 * 640 / 360, accuracy: 0.001)
        }
    }

    func testDefaultAndInvalidCropsKeepTheViewportFittingFallback() throws {
        let cases: [(String, NSRect?)] = [
            ("no crop", nil),
            ("partly outside", NSRect(x: -1, y: 20, width: 640, height: 360)),
            ("oversized", NSRect(x: 0, y: 0, width: 1001, height: 801)),
            ("zero width", NSRect(x: 20, y: 20, width: 0, height: 360)),
            ("negative height", NSRect(x: 20, y: 20, width: 640, height: -1)),
            ("nonfinite origin", NSRect(x: CGFloat.nan, y: 20, width: 640, height: 360)),
            ("nonfinite size", NSRect(x: 20, y: 20, width: CGFloat.infinity, height: 360)),
        ]
        for (name, rect) in cases {
            try withPage { floater, page in
                if let rect {
                    floater.lift(page, videoRect: rect)
                } else {
                    floater.lift(page)
                }
                let panel = try XCTUnwrap(page.window, name)
                let ground = try XCTUnwrap(panel.contentView, name)
                XCTAssertFalse(Bench.onScreen(panel), name)
                XCTAssertTrue(page.superview === ground, name)
                XCTAssertEqual(page.frame, ground.bounds, name)
                XCTAssertEqual(page.autoresizingMask, [.width, .height], name)
                XCTAssertTrue(floater.holds(page), name)

                panel.setContentSize(NSSize(width: 600, height: 337))
                ground.layoutSubtreeIfNeeded()
                assertRect(page.frame, equals: ground.bounds)
            }
        }
    }

    func testDropRestoresSourceStateAndLeavesFittingResizeToTheStage() throws {
        for rect in [nil, NSRect(x: 100, y: 80, width: 640, height: 360)] as [NSRect?] {
            try withPage { floater, page in
                let sourceFrame = page.frame
                let sourceMask = page.autoresizingMask
                floater.lift(page, videoRect: rect)
                let panel = try XCTUnwrap(page.window)
                let expectedFrame = rect == nil ? page.frame : sourceFrame
                floater.drop()

                XCTAssertFalse(floater.showing)
                XCTAssertFalse(floater.holds(page))
                XCTAssertNil(page.superview)
                XCTAssertNil(page.window)
                XCTAssertEqual(page.frame, expectedFrame)
                XCTAssertEqual(page.autoresizingMask, sourceMask)
                XCTAssertFalse(panel.isVisible)
            }
        }
    }

    func testDropRestoresTheOriginalWebMagnificationSetting() throws {
        for allowed in [false, true] {
            let web = WKWebView(frame: NSRect(x: 17, y: 29, width: 1000, height: 800))
            web.allowsMagnification = allowed
            try withPage(web) { floater, page in
                floater.lift(page, videoRect: NSRect(x: 100, y: 80, width: 640, height: 360))
                let panel = try XCTUnwrap(page.window)
                XCTAssertFalse(Bench.onScreen(panel))
                XCTAssertFalse(web.allowsMagnification)
                floater.drop()
                XCTAssertEqual(web.allowsMagnification, allowed)
            }
        }
    }

    func testCropMeasurementUsesPageZoomAndRejectsStaleOrMagnifiedViewports() {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        web.pageZoom = 2
        let picture = [50.0, 40, 320, 180]
        let viewport = [500.0, 400]
        XCTAssertEqual(Float.cropRect(picture: picture, viewport: viewport, for: web),
                       NSRect(x: 100, y: 80, width: 640, height: 360))
        web.setFrameSize(NSSize(width: 900, height: 800))
        XCTAssertNil(Float.cropRect(picture: picture, viewport: viewport, for: web))
        web.setFrameSize(NSSize(width: 1000, height: 800))
        web.magnification = 2
        XCTAssertNil(Float.cropRect(picture: picture, viewport: viewport, for: web))
    }

    func testWebViewTopOriginPictureMapsThroughTheNativeCropWhenResized() throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        try withPage(web) { floater, page in
            let picture = NSRect(x: 100, y: 80, width: 640, height: 360)
            floater.lift(page, videoRect: picture)
            let panel = try XCTUnwrap(page.window)
            let ground = try XCTUnwrap(panel.contentView)
            // WKWebView's coordinates, like the DOM, start at the top.
            XCTAssertTrue(web.isFlipped)
            assertRect(web.convert(picture, to: ground), equals: ground.bounds)
            panel.setContentSize(NSSize(width: 720, height: 405))
            ground.layoutSubtreeIfNeeded()
            assertRect(web.convert(picture, to: ground), equals: ground.bounds)
            XCTAssertEqual(web.bounds.size, NSSize(width: 1000, height: 800))
        }
    }

    private func withPage(_ supplied: NSView? = nil,
                          _ body: (Float, NSView) throws -> Void) rethrows {
        let source = NSWindow(contentRect: NSRect(x: -20000, y: -22000, width: 1300, height: 1000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        source.isReleasedWhenClosed = false
        let page = supplied ?? NSView(frame: NSRect(x: 17, y: 29, width: 1000, height: 800))
        page.autoresizingMask = [.minXMargin, .maxYMargin]
        source.contentView?.addSubview(page)
        let floater = Float()
        let previousAway = Float.benchAway
        Float.benchAway = NSPoint(x: -20000, y: -20000)
        defer {
            floater.drop()
            source.close()
            Float.benchAway = previousAway
        }
        XCTAssertFalse(Bench.onScreen(source))
        try body(floater, page)
    }

    private func assertRect(_ actual: NSRect, equals expected: NSRect,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.001, file: file, line: line)
    }
}
