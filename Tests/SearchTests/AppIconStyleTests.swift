import XCTest
@testable import Search

/// The custom app icon (AppIconStyle): which shade the mark takes on a light
/// or a dark picture, and what Auto, Light and Dark each do about it.
@MainActor
final class AppIconStyleTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    /// A 64-point picture of one grey.
    private func solid(_ grey: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: grey, green: grey, blue: grey, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return ctx.makeImage()!
    }

    /// How bright the icon is at the right end of the pill, where the mark
    /// is solid (the S is cut out of the left end).
    private func markBrightness(_ icon: NSImage) -> CGFloat {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: 700, y: 512)?.brightnessComponent ?? -1
    }

    private func look(_ mark: IconMark) -> AppIconStyle.Look {
        .init(blur: 0, frost: 0.02, grain: 0, mark: mark)
    }

    func testAutoPutsADarkMarkOnALightPictureAndTheReverse() throws {
        let onLight = try XCTUnwrap(AppIconStyle.render(solid(1), look(.auto)))
        let onDark = try XCTUnwrap(AppIconStyle.render(solid(0), look(.auto)))
        XCTAssertLessThan(markBrightness(onLight), 0.3)
        XCTAssertGreaterThan(markBrightness(onDark), 0.7)
    }

    func testLightAndDarkAreTheirOwnWhateverThePicture() throws {
        let light = try XCTUnwrap(AppIconStyle.render(solid(1), look(.light)))
        let dark = try XCTUnwrap(AppIconStyle.render(solid(0), look(.dark)))
        XCTAssertGreaterThan(markBrightness(light), 0.7)
        XCTAssertLessThan(markBrightness(dark), 0.3)
    }

    func testTheDefaultsAreAmongTheSteps() {
        XCTAssertTrue(AppIconStyle.blurSteps.contains(15))
        XCTAssertTrue(AppIconStyle.frostSteps.contains(0.02))
        XCTAssertTrue(AppIconStyle.grainSteps.contains(0.1))
    }
}
