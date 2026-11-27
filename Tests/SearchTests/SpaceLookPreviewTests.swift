import AppKit
import SwiftUI
import XCTest
@testable import Search

/// The look picker's preview shows the space's colour as the window will
/// wear it (idea 1040): the colour at full read far brighter than the
/// column turned out, in dark mode above all. For every colour and
/// strength, in light and dark, the preview's ground is the column's.
/// Rendered offscreen in an NSHostingView that is never put in a window.
@available(macOS 14, *)
@MainActor
final class SpaceLookPreviewTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private func picture(_ view: some View, dark: Bool) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func colour(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        return rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) ?? .clear
    }

    func testThePreviewIsTheColumnsColour() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let previous = (browser.prefs.usesSpaces, browser.prefs.glass)
        defer { (browser.prefs.usesSpaces, browser.prefs.glass) = previous }
        browser.prefs.usesSpaces = true
        browser.prefs.glass = false
        let id = browser.space.id
        let was = (browser.space.colour, browser.space.strength)
        defer { browser.restoreLook(id, colour: was.0, gradient: nil, strength: was.1) }
        for dark in [true, false] {
            for strength in SpaceStrength.allCases {
                for index in 1..<Spaces.colours.count {
                    browser.chooseLook(id, .colour(index))
                    browser.setSpaceStrength(id, to: strength)
                    let picker = try picture(SpaceLookPicker(browser: browser, id: id), dark: dark)
                    let column = try picture(
                        ZStack { (browser.asCards ? Palette.frame : Palette.ground); SpaceWash(look: browser.space.look) }
                            .environment(\.washStrength, strength)
                            .frame(width: 40, height: 40),
                        dark: dark)
                    // Inside the preview's top left, clear of its icon, its name and its rim.
                    let shown = colour(picker, 30, 30), worn = colour(column, 20, 20)
                    let label = "\(dark ? "dark" : "light"), \(strength.name), \(Spaces.colourNames[index])"
                    XCTAssertEqual(shown.redComponent, worn.redComponent, accuracy: 2 / 255, label)
                    XCTAssertEqual(shown.greenComponent, worn.greenComponent, accuracy: 2 / 255, label)
                    XCTAssertEqual(shown.blueComponent, worn.blueComponent, accuracy: 2 / 255, label)
                }
            }
        }
    }
}
