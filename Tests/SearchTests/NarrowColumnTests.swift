import AppKit
import SwiftUI
import XCTest
@testable import Search

/// The column narrowed by its edge, from its usual width to the least, with
/// a button per space and the fold door on and off (idea 1010): its rows
/// keep their insets on both sides, the foot stays inside it, and the
/// first door of the lights' row stays clear of the zoom button. Drawn in
/// a borderless window far off every screen, never activated; what is
/// measured is the picture itself.
@MainActor
final class NarrowColumnTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?

    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers { browser.closeAll() }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
        try await Task.sleep(for: .milliseconds(250))
        try await super.tearDown()
    }

    /// The column's width while its edge is held, as the window has it.
    private final class Held: ObservableObject {
        @Published var width: CGFloat?
    }

    private struct Column: View {
        let browser: Browser
        @ObservedObject var prefs: Preferences
        @ObservedObject var held: Held
        var body: some View {
            SideBar(browser: browser, prefs: prefs, onDrag: { held.width = $0 })
                .frame(width: held.width ?? prefs.columnWidth, height: NarrowColumnTests.height)
        }
    }

    static let height: CGFloat = 400

    func testInsetsAndLightsAtEveryWidth() async throws {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let previous = (prefs.sidebar, prefs.usesSpaces, prefs.spaceButtons, prefs.foldButton, prefs.sideWidth, prefs.sideHides)
        restorePreferences = {
            (prefs.sidebar, prefs.usesSpaces, prefs.spaceButtons, prefs.foldButton, prefs.sideWidth, prefs.sideHides) = previous
        }
        prefs.sidebar = true
        prefs.sideHides = false
        prefs.usesSpaces = true
        prefs.sideWidth = Metrics.side
        let zoom = zoomEnd()

        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.welcoming = false
        browser.folded = false
        browser.tabs.last?.restore(url: URL(string: "about:blank#one")!, title: "A rather long title for a row of the column")
        for name in ["Work", "Home", "Read", "Code"] { browser.addSpace(named: name) }
        browser.switchSpace(index: 0)

        let held = Held()
        let host = NSHostingView(rootView: Column(browser: browser, prefs: prefs, held: held))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: Metrics.side, height: Self.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        windows.append(window)

        for (buttons, fold) in [(false, false), (true, false), (false, true), (true, true)] {
            prefs.spaceButtons = buttons
            prefs.foldButton = fold
            var usual: (lead: CGFloat, trail: CGFloat)?
            prefs.sideWidth = Metrics.side
            // The edge held and pulled in, a step at a time, then let go at
            // the least width, as a hand does it (Bench "edgetime").
            let steps = Array(stride(from: Metrics.side, through: Metrics.sideMin, by: -8))
            for (step, width) in (steps + [Metrics.sideMin]).enumerated() {
                let letGo = step == steps.count
                if letGo {
                    prefs.sideWidth = width
                    NotificationCenter.default.post(name: Bench.edgeHeld, object: nil)
                } else {
                    NotificationCenter.default.post(name: Bench.edgeHeld, object: width)
                }
                window.setFrame(NSRect(x: -20_000, y: -20_000, width: width, height: Self.height), display: false)
                try await Task.sleep(for: .milliseconds(500))
                let shot = try picture(host, width: width)
                let label = "space buttons \(buttons), fold door \(fold), width \(Int(width))\(letGo ? " let go" : "")"
                let row = try XCTUnwrap(shot.span(56), "\(label): the tab's row is drawn")
                let lead = row.lowerBound, trail = width - row.upperBound
                print(String(format: "%@: row lead %.1f trail %.1f, first door %.1f (zoom ends %.1f), foot %.1f–%.1f",
                             label, lead, trail, shot.span(26)?.lowerBound ?? -1, zoom,
                             shot.span(Self.height - 23)?.lowerBound ?? -1, shot.span(Self.height - 23)?.upperBound ?? -1))
                if let usual {
                    XCTAssertEqual(lead, usual.lead, accuracy: 1, "\(label): the row keeps its left inset")
                    XCTAssertEqual(trail, usual.trail, accuracy: 1, "\(label): and its right one")
                } else {
                    usual = (lead, trail)
                    XCTAssertEqual(lead, trail, accuracy: 1, "\(label): at the usual width the insets match")
                }
                // The first door's glyph, at least 4 in from its box: the box
                // clear of the zoom button.
                let door = try XCTUnwrap(shot.span(26), "\(label): the lights' row has its doors")
                XCTAssertGreaterThanOrEqual(door.lowerBound, zoom + 4, "\(label): the first door is clear of the zoom button")
                XCTAssertLessThanOrEqual(door.upperBound, width - 6, "\(label): and the last inside the column")
                if let foot = shot.span(Self.height - 23) {
                    XCTAssertGreaterThanOrEqual(foot.lowerBound, 8, "\(label): the foot starts inside the column")
                    XCTAssertLessThanOrEqual(foot.upperBound, width - 8, "\(label): and ends inside it")
                }
            }
        }
    }

    /// Where the zoom button ends, from the column's left edge: the close
    /// button's centre as Lights puts it, and AppKit's own sizes and spacing.
    private func zoomEnd() -> CGFloat {
        let titled = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        titled.isReleasedWhenClosed = false
        defer { titled.close() }
        guard let close = titled.standardWindowButton(.closeButton)?.frame,
              let zoom = titled.standardWindowButton(.zoomButton)?.frame else { return 79 }
        return Lights.centre.x - close.width / 2 + (zoom.minX - close.minX) + zoom.width
    }

    private struct Shot {
        let rep: NSBitmapImageRep
        let scale: CGFloat
        let ground: NSColor

        func colour(_ x: Int, _ y: CGFloat) -> NSColor {
            rep.colorAt(x: x, y: Int(y * scale))?.usingColorSpace(.deviceRGB) ?? ground
        }
        /// Where anything but the column's ground is drawn along a line,
        /// short of the edge's own line at the far end.
        func span(_ y: CGFloat) -> ClosedRange<CGFloat>? {
            let xs = (0..<(rep.pixelsWide - Int(3 * scale))).filter { x in
                let c = colour(x, y)
                return abs(c.redComponent - ground.redComponent) + abs(c.greenComponent - ground.greenComponent)
                    + abs(c.blueComponent - ground.blueComponent) > 0.02
            }
            guard let first = xs.first, let last = xs.last else { return nil }
            return CGFloat(first) / scale...CGFloat(last + 1) / scale
        }
    }

    private func picture(_ host: NSView, width: CGFloat) throws -> Shot {
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / width
        let ground = rep.colorAt(x: rep.pixelsWide / 2, y: Int(300 * scale))?.usingColorSpace(.deviceRGB) ?? .white
        return Shot(rep: rep, scale: scale, ground: ground)
    }
}
