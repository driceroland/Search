import AppKit
import SwiftUI
import XCTest
@testable import Search

/// A pinned square whose page plays sound, or was muted, wears the speaker
/// the icons-only column's tiles wear, in its bottom corner (idea 1328): in
/// the column and across the top. Drawn in borderless windows that are
/// never ordered in, never activated. SEARCH_RENDER_DIR, when set, keeps
/// every picture there as a PNG.
@MainActor
final class PinSpeakerTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restore: (() -> Void)?

    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        // Its pins unpinned: left in the space, the next test's window
        // (PinStuckTests) opened with them.
        for browser in browsers {
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            browser.closeAll()
        }
        restore?()
        windows.removeAll()
        browsers.removeAll()
        try await Task.sleep(for: .milliseconds(200))
        try await super.tearDown()
    }

    func testWhenTheSpeakerShows() {
        _ = NSApplication.shared
        let tab = Search.Tab(configuration: Web.configuration(space: Space.firstID))
        tab.pin = "P"
        XCTAssertFalse(CornerSpeaker.shows(for: tab), "a quiet page")
        tab.noisy = true
        XCTAssertTrue(CornerSpeaker.shows(for: tab), "a page playing sound")
        tab.noisy = false
        tab.muted = true
        XCTAssertTrue(CornerSpeaker.shows(for: tab), "a muted page: its speaker unmutes it")
    }

    func testDrawnOnPinnedSquares() async throws {
        let prefs = Shared.prefs
        let before = (prefs.sidebar, prefs.sideHides, prefs.sidePosition, prefs.sideWidth, prefs.glass)
        restore = { (prefs.sidebar, prefs.sideHides, prefs.sidePosition, prefs.sideWidth, prefs.glass) = before }
        prefs.sideHides = false
        prefs.sidePosition = .left
        prefs.glass = false

        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.welcoming = false
        browser.folded = false
        let pins = (0..<3).map { i -> Search.Tab in
            let tab = Search.Tab(configuration: Web.configuration(space: browser.spaceID))
            tab.setAddressOptimistically(URL(string: "about:blank#pin\(i)")!)
            tab.pin = ["M", "Y", "S"][i]
            tab.pinID = UUID()
            browser.prepare(tab)
            browser.insert(tab, at: i)
            return tab
        }
        let playing = pins[1]

        for dark in [false, true] {
            let look = dark ? "dark" : "light"
            prefs.sidebar = true
            prefs.sideWidth = Metrics.side
            let column = try show(Column(browser: browser, prefs: prefs), width: Metrics.side, height: 240, dark: dark)
            playing.noisy = false
            playing.muted = false
            let quiet = try await picture(column, "column-quiet-\(look)")
            playing.noisy = true
            let loud = try await picture(column, "column-playing-\(look)")
            XCTAssertGreaterThan(differs(quiet, loud), 20, "\(look): the column's square says it plays")
            playing.noisy = false
            playing.muted = true
            let muted = try await picture(column, "column-muted-\(look)")
            XCTAssertGreaterThan(differs(loud, muted), 4, "\(look): the muted speaker is another")
            close(column)

            prefs.sidebar = false
            let strip = try show(Strip(browser: browser, prefs: prefs), width: 900, height: Metrics.strip, dark: dark)
            playing.muted = false
            let top = try await picture(strip, "strip-quiet-\(look)")
            playing.noisy = true
            let topLoud = try await picture(strip, "strip-playing-\(look)")
            XCTAssertGreaterThan(differs(top, topLoud), 20, "\(look): the strip's square says it plays")
            playing.noisy = false
            close(strip)
        }
    }

    // MARK: - drawing

    private struct Column: View {
        let browser: Browser
        @ObservedObject var prefs: Preferences
        var body: some View {
            ZStack {
                Palette.ground
                SideBar(browser: browser, prefs: prefs, onDrag: { _ in })
            }
        }
    }

    private struct Strip: View {
        let browser: Browser
        @ObservedObject var prefs: Preferences
        var body: some View {
            ZStack {
                Palette.ground
                TabBar(browser: browser)
            }
        }
    }

    private struct Picture { let rep: NSBitmapImageRep }

    private func show<V: View>(_ view: V, width: CGFloat, height: CGFloat, dark: Bool) throws -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        windows.append(window)
        return host
    }

    private func close(_ host: NSView) {
        guard let window = host.window else { return }
        window.contentView = nil
        window.close()
        windows.removeAll { $0 === window }
    }

    private func picture(_ host: NSView, _ name: String?) async throws -> Picture {
        try await Task.sleep(for: .milliseconds(450))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let name, let folder = ProcessInfo.processInfo.environment["SEARCH_RENDER_DIR"] {
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("pin-speaker-\(name).png"))
        }
        return Picture(rep: rep)
    }

    private func differs(_ a: Picture, _ b: Picture) -> Int {
        guard a.rep.pixelsWide == b.rep.pixelsWide, a.rep.pixelsHigh == b.rep.pixelsHigh else { return Int.max }
        var count = 0
        for y in 0..<a.rep.pixelsHigh {
            for x in 0..<a.rep.pixelsWide {
                guard let p = a.rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let q = b.rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent)
                    + abs(p.blueComponent - q.blueComponent) > 0.06 { count += 1 }
            }
        }
        return count
    }
}
