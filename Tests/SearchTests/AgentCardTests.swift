import AppKit
import SwiftUI
import XCTest
@testable import Search

/// A coding agent's card at the column's foot and its pill in the strip
/// (AgentBanner), drawn as "Update ready" is: its name never cut at the
/// narrowest column, the two cards stacked, and no Stop on the tab's row.
/// Drawn in borderless windows far off every screen, never activated.
/// SEARCH_RENDER_DIR, when set, keeps every picture there as a PNG.
@MainActor
final class AgentCardTests: XCTestCase {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restore: (() -> Void)?

    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers { browser.closeAll() }
        restore?()
        AgentControl.shared.showForTest(nil)
        Updater.shared.setStageForTest(.none)
        windows.removeAll()
        browsers.removeAll()
        try await Task.sleep(for: .milliseconds(200))
        try await super.tearDown()
    }

    /// "Claude Code" fits whole beside Stop in the narrowest column, roomy
    /// rows or not: column inset, card insets, gap, Stop; the icon only
    /// where there is room for it too (ViewThatFits).
    func testTheNameIsNeverCut() {
        for size in [CGFloat(12.5), 14] {
            let name = ("Claude Code" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width
            let stop = ("Stop" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width + 14
            let room = Metrics.sideMin - 20 - 10 - 6 - 8 - stop
            XCTAssertLessThan(name, room, "\(size) pt: \(name) wide in \(room)")
        }
    }

    func testDrawn() async throws {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        let before = (prefs.sidebar, prefs.glass, prefs.showsUpdateReady, prefs.updateHiddenBuild, prefs.sideHides,
                      prefs.sidePosition, prefs.sideWidth)
        restore = {
            (prefs.sidebar, prefs.glass, prefs.showsUpdateReady, prefs.updateHiddenBuild, prefs.sideHides,
             prefs.sidePosition, prefs.sideWidth) = before
        }
        prefs.sideHides = false
        prefs.sidePosition = .left
        prefs.showsUpdateReady = true
        prefs.updateHiddenBuild = 0
        let updater = Updater.shared, agents = AgentControl.shared

        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.welcoming = false
        browser.folded = false
        let tab = try XCTUnwrap(browser.tabs.last)
        tab.restore(url: URL(string: "about:blank#one")!, title: "I Found the Perfect Morning Stretch")
        tab.agent = true
        tab.agentWorking = true

        for glass in [false, true] {
            prefs.glass = glass
            for dark in [false, true] {
                let look = "\(glass ? "glass" : "solid")-\(dark ? "dark" : "light")"
                for width in [Metrics.sideMin, Metrics.side] {
                    prefs.sidebar = true
                    prefs.sideWidth = width
                    let name = "column-\(Int(width))-\(look)"
                    let column = try show(Column(browser: browser, prefs: prefs), width: width, height: 360, dark: dark)
                    updater.setStageForTest(.none)
                    agents.showForTest(nil)
                    let none = try await picture(column, nil)
                    agents.showForTest("Claude Code", in: browser)
                    let card = try await picture(column, "\(name)-agent")
                    XCTAssertGreaterThan(differs(none, card, rows: 360 - 36 - 40..<(360 - 36)), 40, "\(name): the card")
                    XCTAssertNotNil(agents.stopButton?.window, "\(name): Stop is drawn")
                    agents.showForTest("Claude Code", in: browser, busy: false)
                    _ = try await picture(column, "\(name)-agent-idle")
                    agents.showForTest("Claude Code", in: browser, auto: true)
                    _ = try await picture(column, "\(name)-agent-always")
                    agents.showForTest("Claude Code", in: browser)
                    updater.setStageForTest(.ready(release(700)))
                    let both = try await picture(column, "\(name)-both")
                    XCTAssertGreaterThan(differs(card, both, rows: 360 - 36 - 80..<(360 - 36)), 40, "\(name): both")
                    close(column)
                }

                prefs.sidebar = false
                let strip = try show(Strip(browser: browser, prefs: prefs), width: 900, height: Metrics.strip, dark: dark)
                updater.setStageForTest(.none)
                agents.showForTest(nil)
                let top = try await picture(strip, nil)
                agents.showForTest("Claude Code", in: browser)
                let pill = try await picture(strip, "strip-agent-\(look)")
                XCTAssertGreaterThan(differs(top, pill), 40, "\(look): the pill")
                XCTAssertNotNil(agents.stopButton?.window, "\(look): Stop in the strip")
                updater.setStageForTest(.ready(release(700)))
                _ = try await picture(strip, "strip-both-\(look)")
                agents.showForTest("Claude Code", in: browser, auto: true)
                _ = try await picture(strip, "strip-both-always-\(look)")
                close(strip)
            }
        }
    }

    // MARK: - drawing

    private func release(_ build: Int) -> Updater.Release {
        Updater.Release(version: "9.\(build)", build: build, archive: URL(fileURLWithPath: "/dev/null"),
                        dmg: URL(fileURLWithPath: "/dev/null"), sha256: nil, notes: nil, minimumSystemVersion: nil)
    }

    private struct Column: View {
        let browser: Browser
        @ObservedObject var prefs: Preferences
        var body: some View {
            ZStack {
                if prefs.glass { GlassGround(prefs: prefs, look: nil) }
                SideBar(browser: browser, prefs: prefs, onDrag: { _ in })
            }
        }
    }

    private struct Strip: View {
        let browser: Browser
        @ObservedObject var prefs: Preferences
        var body: some View {
            ZStack {
                if prefs.glass { GlassGround(prefs: prefs, look: nil) } else { Palette.ground }
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
        window.orderFrontRegardless()
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
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
        return Picture(rep: rep)
    }

    private func differs(_ a: Picture, _ b: Picture, rows: Range<Int>? = nil) -> Int {
        guard a.rep.pixelsWide == b.rep.pixelsWide, a.rep.pixelsHigh == b.rep.pixelsHigh else { return Int.max }
        let scale = Int(a.rep.pixelsWide) / max(1, Int(a.rep.size.width))
        let ys = rows.map { max(0, $0.lowerBound * scale)..<min(a.rep.pixelsHigh, $0.upperBound * scale) } ?? 0..<a.rep.pixelsHigh
        var count = 0
        for y in stride(from: ys.lowerBound, to: ys.upperBound, by: 1) {
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
