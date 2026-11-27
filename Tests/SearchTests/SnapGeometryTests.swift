import AppKit
import XCTest
@testable import Search

/// Capture…'s arithmetic (Snap.swift): what the page chose, in its CSS
/// pixels, as the rectangle WebKit is asked to draw, with no page or
/// screen; and the copy, on a pasteboard of its own rather than the Mac's.
@available(macOS 14, *)
final class SnapGeometryTests: XCTestCase {
    private let page = CGSize(width: 1200, height: 5000)

    func testAnAreaAtNoZoomIsWhatWasDragged() {
        let choice = SnapGeometry.Choice(kind: .area, rect: CGRect(x: 10, y: 20, width: 300, height: 200),
                                         scroll: CGPoint(x: 0, y: 800), document: page)
        let plan = SnapGeometry.plan(choice, zoom: 1, backing: 2)
        XCTAssertEqual(plan, SnapGeometry.Plan(rect: CGRect(x: 10, y: 20, width: 300, height: 200), width: nil, cropped: false))
    }

    func testPageZoomMakesEachCSSPixelBigger() {
        let choice = SnapGeometry.Choice(kind: .element, rect: CGRect(x: 100, y: 40, width: 200, height: 80), document: page)
        let plan = SnapGeometry.plan(choice, zoom: 1.5, backing: 2)
        XCTAssertEqual(plan?.rect, CGRect(x: 150, y: 60, width: 300, height: 120))
        XCTAssertNil(plan?.width)
    }

    func testAPinchZoomMovesAndScalesTheViewport() {
        let choice = SnapGeometry.Choice(kind: .area, rect: CGRect(x: 60, y: 50, width: 100, height: 100),
                                         document: page, offset: CGPoint(x: 50, y: 40), scale: 2)
        XCTAssertEqual(SnapGeometry.plan(choice, zoom: 1, backing: 1)?.rect, CGRect(x: 20, y: 20, width: 200, height: 200))
    }

    func testAnElementIsCutToThePage() {
        // Wider than the page and starting above it: only the page's part.
        let choice = SnapGeometry.Choice(kind: .element, rect: CGRect(x: -20, y: -400, width: 1300, height: 700),
                                         scroll: CGPoint(x: 0, y: 100), document: page)
        XCTAssertEqual(SnapGeometry.plan(choice, zoom: 1, backing: 2)?.rect, CGRect(x: 0, y: -100, width: 1200, height: 400))
    }

    func testTheWholePageStartsAboveTheScroll() {
        let choice = SnapGeometry.Choice(kind: .page, scroll: CGPoint(x: 0, y: 1234), document: CGSize(width: 1200, height: 3000))
        let plan = SnapGeometry.plan(choice, zoom: 1, backing: 2)
        XCTAssertEqual(plan?.rect, CGRect(x: 0, y: -1234, width: 1200, height: 3000))
        XCTAssertNil(plan?.width)
        XCTAssertEqual(plan?.cropped, false)
    }

    func testAWholePageIsTakenAtItsOwnSizeWhateverThePinch() {
        let choice = SnapGeometry.Choice(kind: .page, document: CGSize(width: 1000, height: 2000), scale: 2)
        let plan = SnapGeometry.plan(choice, zoom: 1, backing: 2)
        XCTAssertEqual(plan?.rect.size, CGSize(width: 2000, height: 4000))
        XCTAssertEqual(plan?.width, 1000)
    }

    func testAnEndlessPageGivesItsTop() {
        let choice = SnapGeometry.Choice(kind: .page, document: CGSize(width: 800, height: 100_000))
        let plan = SnapGeometry.plan(choice, zoom: 1, backing: 1)
        XCTAssertEqual(plan?.rect.height, SnapGeometry.tallest)
        XCTAssertEqual(plan?.cropped, true)
    }

    func testAPictureTooBigToHoldIsMadeSmaller() {
        let choice = SnapGeometry.Choice(kind: .page, document: CGSize(width: 2000, height: 20_000))
        // 2000 × 20000 × 2² = 160 M pixels, past the 64 M budget.
        let plan = SnapGeometry.plan(choice, zoom: 1, backing: 2)
        let width = try! XCTUnwrap(plan?.width)
        XCTAssertLessThan(width, 2000)
        let pixels = width * (width / 2000 * 20_000) * 4
        XCTAssertLessThanOrEqual(pixels, SnapGeometry.budget)
        XCTAssertGreaterThan(pixels, SnapGeometry.budget * 0.99)
    }

    func testNothingThereIsNothingTaken() {
        let off = SnapGeometry.Choice(kind: .area, rect: CGRect(x: 0, y: -900, width: 100, height: 100),
                                      scroll: CGPoint(x: 0, y: 0), document: page)
        XCTAssertNil(SnapGeometry.plan(off, zoom: 1, backing: 2))
        let speck = SnapGeometry.Choice(kind: .element, rect: CGRect(x: 5, y: 5, width: 1, height: 40), document: page)
        XCTAssertNil(SnapGeometry.plan(speck, zoom: 1, backing: 2))
    }

    func testTheChoiceAsThePagePostsIt() {
        let posted: [String: Any] = ["kind": "element", "x": 1.5, "y": 2, "w": 30, "h": 40, "sx": 0, "sy": 600,
                                     "dw": 1200, "dh": 5000, "vx": 0, "vy": 0, "vs": 1]
        XCTAssertEqual(SnapGeometry.Choice(posted),
                       SnapGeometry.Choice(kind: .element, rect: CGRect(x: 1.5, y: 2, width: 30, height: 40),
                                           scroll: CGPoint(x: 0, y: 600), document: page))
        XCTAssertNil(SnapGeometry.Choice(nil))
        XCTAssertNil(SnapGeometry.Choice(["kind": "screen"]))
    }

    func testTheFileIsNamedForTheTimeNotTheSite() {
        let date = Date(timeIntervalSince1970: 1_795_000_000)
        XCTAssertEqual(SnapGeometry.fileName(date, in: TimeZone(identifier: "UTC")!), "Capture 2026-11-18 at 11.06.40.png")
    }

    func testTheCopyIsAPNGAndAPrivateTabsIsTransient() throws {
        let image = NSImage(size: NSSize(width: 4, height: 3), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let data = try XCTUnwrap(SnapGeometry.png(image))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data.png))
        XCTAssertEqual(rep.size, NSSize(width: 4, height: 3))

        let board = NSPasteboard(name: NSPasteboard.Name("search.snap.test.\(getpid())"))
        defer { board.releaseGlobally() }
        SnapGeometry.copy(png: data.png, tiff: data.tiff, passing: true, to: board)
        XCTAssertEqual(board.data(forType: .png), data.png)
        XCTAssertNotNil(board.data(forType: .tiff))
        XCTAssertNotNil(board.data(forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))

        SnapGeometry.copy(png: data.png, tiff: data.tiff, passing: false, to: board)
        XCTAssertNil(board.data(forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
    }
    func testAWholePageIsDrawnAtTheScreensScale() {
        let drawn = SnapGeometry.raster(CGSize(width: 1180, height: 5040), backing: 2)
        XCTAssertEqual(drawn?.size, CGSize(width: 1180, height: 5040))
        XCTAssertEqual(drawn?.scale, 2)
        XCTAssertEqual(drawn?.cropped, false)
    }

    func testAWholePagePastTheCapsIsItsTopAndSmaller() {
        let long = SnapGeometry.raster(CGSize(width: 800, height: 100_000), backing: 1)
        XCTAssertEqual(long?.size, CGSize(width: 800, height: SnapGeometry.tallest))
        XCTAssertEqual(long?.cropped, true)
        let big = try! XCTUnwrap(SnapGeometry.raster(CGSize(width: 2000, height: 20_000), backing: 2))
        XCTAssertLessThan(big.scale, 2)
        XCTAssertLessThanOrEqual(2000 * big.scale * 20_000 * big.scale, SnapGeometry.budget * 1.0001)
        XCTAssertNil(SnapGeometry.raster(.zero, backing: 2))
    }

    /// A tall page as WebKit's PDF has it: green at its top, red at its
    /// bottom, and both in the picture, the right way up.
    func testThePDFsBottomIsDrawnNotLeftWhite() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 100, height: 3000)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let pdf = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdf.beginPDFPage(nil)
        pdf.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        pdf.fill(CGRect(x: 0, y: 0, width: 100, height: 200))       // the bottom
        pdf.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        pdf.fill(CGRect(x: 0, y: 2900, width: 100, height: 100))    // the top
        pdf.endPDFPage()
        pdf.closePDF()

        let drawn = try XCTUnwrap(SnapGeometry.draw(pdf: data as Data, backing: 2))
        XCTAssertEqual(drawn.image.size, NSSize(width: 100, height: 3000))
        XCTAssertFalse(drawn.cropped)
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(drawn.image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        XCTAssertEqual(rep.pixelsWide, 200)
        XCTAssertEqual(rep.pixelsHigh, 6000)
        let top = try XCTUnwrap(rep.colorAt(x: 100, y: 20)?.usingColorSpace(.sRGB))
        let middle = try XCTUnwrap(rep.colorAt(x: 100, y: 3000)?.usingColorSpace(.sRGB))
        let bottom = try XCTUnwrap(rep.colorAt(x: 100, y: 5980)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(top.greenComponent, 0.8); XCTAssertLessThan(top.redComponent, 0.4)
        XCTAssertGreaterThan(middle.blueComponent, 0.9)
        XCTAssertGreaterThan(bottom.redComponent, 0.8); XCTAssertLessThan(bottom.greenComponent, 0.4)
    }
}

/// Copy captures only (idea 1250): off unless asked for, so a capture is
/// still copied and saved; on, it is only copied and no file is named.
@available(macOS 14, *)
@MainActor
final class SnapCopyOnlyTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testOffUnlessAskedForAndAChoiceStands() {
        let key = "pages.capture.copyOnly"
        let saved = Store.settings.object(forKey: key)
        defer { Store.settings.set(saved, forKey: key) }
        Store.settings.removeObject(forKey: key)
        XCTAssertFalse(Preferences().copiesCapturesOnly)
        XCTAssertNil(Store.settings.object(forKey: key), "nothing written just for reading it")
        Store.settings.set(true, forKey: key)
        XCTAssertTrue(Preferences().copiesCapturesOnly)
    }

    func testCopyOnlyNamesNoFile() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snap-copy-only-\(UUID().uuidString)")
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertNil(SnapGeometry.file(copyOnly: true, in: folder, at: date))
        let file = try XCTUnwrap(SnapGeometry.file(copyOnly: false, in: folder, at: date))
        XCTAssertEqual(file.deletingLastPathComponent().path, folder.path)
        XCTAssertEqual(file.lastPathComponent, SnapGeometry.fileName(date))
    }

    func testTheRowSitsUnderCapturePages() throws {
        let row = try XCTUnwrap(SettingsIndex.item("pages.capture.copyOnly"))
        XCTAssertEqual(row.parent, "pages.capture")
        XCTAssertEqual(row.group, "pages")
        XCTAssertEqual(row.keys, ["pages.capture.copyOnly"])
        let prefs = Preferences()
        let captures = prefs.capturesPages
        defer { prefs.capturesPages = captures }
        prefs.capturesPages = false
        XCTAssertFalse(SettingsIndex.applies(row, prefs), "nothing to copy with Capture pages off")
        prefs.capturesPages = true
        XCTAssertTrue(SettingsIndex.applies(row, prefs))
    }
}
