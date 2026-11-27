import AppKit
import SwiftUI
import XCTest
@testable import Search

/// Back, forward and reload beside the window's buttons (#1633, idea 1276),
/// drawn offscreen, never in a window: their symbols sit on the line through
/// the centres of the window's three buttons, and with nowhere to go they are
/// dimmed but still plain to see.
@available(macOS 14, *)
@MainActor
final class HelmAlignTests: XCTestCase {
    override class func setUp() { TestWorld.enter(); super.setUp() }

    /// Rows of ink, darkest ink, drawn on white in a band as tall as the
    /// strip the lights are centred in.
    private func ink(_ view: some View, band: CGFloat) throws -> (top: CGFloat, bottom: CGFloat, darkest: CGFloat) {
        let host = NSHostingView(rootView: view.frame(width: 120, height: band).background(Color.white))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = CGRect(x: 0, y: 0, width: 120, height: band)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / band
        var top = Int.max, bottom = -1
        var darkest: CGFloat = 1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let level = min(c.redComponent, c.greenComponent, c.blueComponent)
                if level < 0.97 { top = min(top, y); bottom = max(bottom, y) }
                darkest = min(darkest, level)
            }
        }
        XCTAssertLessThan(top, Int.max, "nothing drawn")
        return (CGFloat(top) / scale, CGFloat(bottom + 1) / scale, darkest)
    }

    func testOnTheLightsLineAndDimmedNotGone() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        // A new tab: nowhere to go back or forward to, so all three dimmed.
        let band = Lights.centre.y * 2
        let drawn = try ink(Helm(browser: browser), band: band)
        let centre = (drawn.top + drawn.bottom) / 2
        XCTAssertEqual(centre, Lights.centre.y, accuracy: 0.5, "the symbols' middle is the lights' middle")
        // Dimmed, the ground's grey at half: still a clear mark on white.
        XCTAssertLessThan(drawn.darkest, 0.85, "dimmed doors are still plain to see")
        XCTAssertGreaterThan(drawn.darkest, 0.4, "and plainly dimmer than a door that can be used")
    }
}
