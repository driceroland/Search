import AppKit
import SwiftUI
import XCTest
@testable import Search

/// The doors (the puzzle, Bookmarks, Back, Forward, Reload) and a tab's
/// letter rest in the ground's own grey, as the tab titles beside them do:
/// black or white let through, so they stand off whatever lies under them.
/// They rested in an opaque mid grey, the same on any ground, which on
/// glass with Transparency all the way up is the desktop itself: a mid-grey
/// wallpaper or window behind matched it and they were gone, while the
/// titles beside them still read. On the plain ground nothing changes.
/// Rendered offscreen in an NSHostingView that is never put in a window.
@MainActor
final class RestingInkTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    /// The view over a ground of one grey, at twice the points, so a
    /// symbol's stroke has pixels it covers whole.
    private func picture(_ view: some View, on ground: Color, dark: Bool, side: CGFloat = 26) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: side, height: side).background(ground))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: side, height: side)
        host.layoutSubtreeIfNeeded()
        let pixels = Int(side * 2)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func grey(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .clear
        return (c.redComponent + c.greenComponent + c.blueComponent) / 3
    }

    /// The grey of the pixel that stands furthest off the ground: the
    /// symbol's ink where it covers a pixel whole.
    private func ink(_ rep: NSBitmapImageRep, ground: CGFloat) -> CGFloat {
        var furthest = ground
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let v = grey(rep, x, y)
                if abs(v - ground) > abs(furthest - ground) { furthest = v }
            }
        }
        return furthest
    }

    /// Where the tab titles' grey lands over a ground: Greys.white's muted,
    /// black at 0.45 in a light window, white at 0.5281 in a dark one.
    private func titles(over ground: CGFloat, dark: Bool) -> CGFloat {
        dark ? 0.5281 + (1 - 0.5281) * ground : (1 - 0.45) * ground
    }

    func testDoorsAndLettersStandOffAnyGroundAsTheTitlesDo() throws {
        _ = NSApplication.shared
        // The letter drawn large, so its strokes cover pixels whole: its
        // grey doesn't change with its size. It lies on its own faint
        // square, ink at 0.06.
        let views: [(String, AnyView, CGFloat, CGFloat)] = [
            ("the puzzle", AnyView(Door(icon: "puzzlepiece.extension") {}), 26, 0),
            ("Bookmarks", AnyView(Door(icon: "bookmark") {}), 26, 0),
            ("Reload", AnyView(Door(icon: "arrow.clockwise") {}), 26, 0),
            ("a tab's letter", AnyView(Mark(icon: nil, letter: "G", size: 48)), 48, 0.06),
        ]
        for dark in [true, false] {
            let inkGrey: CGFloat = dark ? 0.93 : 0.09
            for step in 0...20 {
                let g = CGFloat(step) / 20
                for (name, view, side, square) in views {
                    let rep = try picture(view, on: Color(.sRGB, white: g), dark: dark, side: side)
                    let ground = grey(rep, 0, 0)
                    let under = square * inkGrey + (1 - square) * ground
                    let drawn = ink(rep, ground: under)
                    let label = "\(name), \(dark ? "dark" : "light"), on \(String(format: "%.2f", g))"
                    XCTAssertEqual(drawn, titles(over: under, dark: dark), accuracy: 0.035, label)
                }
            }
        }
    }

    func testOnThePlainGroundTheyAreTheGreyTheyWere() throws {
        _ = NSApplication.shared
        for dark in [true, false] {
            let rep = try picture(Door(icon: "bookmark") {}, on: Palette.ground, dark: dark)
            let ground = grey(rep, 0, 0)
            let muted: CGFloat = dark ? 0.58 : 0.55
            XCTAssertEqual(ink(rep, ground: ground), muted, accuracy: 2 / 255, dark ? "dark" : "light")
        }
    }
}
