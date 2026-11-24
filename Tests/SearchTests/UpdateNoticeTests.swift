import AppKit
import SwiftUI
import XCTest
@testable import Search

/// "Update ready" (UpdateNotice.swift): at the foot of the column and as a
/// pill at the strip's far end while a newer build waits, never otherwise.
/// Drawn in borderless windows far off every screen, never activated; what
/// is compared is the picture itself, against the same view with no update.
/// SEARCH_RENDER_DIR, when set, keeps every picture there as a PNG.
@MainActor
final class UpdateNoticeTests: XCTestCase {
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
        Updater.shared.setStageForTest(.none)
        windows.removeAll()
        browsers.removeAll()
        try await Task.sleep(for: .milliseconds(200))
        try await super.tearDown()
    }

    private func release(_ build: Int) -> Updater.Release {
        Updater.Release(version: "9.\(build)", build: build, archive: URL(fileURLWithPath: "/dev/null"),
                        dmg: URL(fileURLWithPath: "/dev/null"), sha256: nil, notes: nil, minimumSystemVersion: nil)
    }

    func testWhatShowsForEachStage() {
        let next = release(500)
        XCTAssertEqual(UpdateNotice.shown(.ready(next), on: true, hidden: 0)?.kind, .ready)
        XCTAssertEqual(UpdateNotice.shown(.waiting(next), on: true, hidden: 0)?.kind, .waiting)
        XCTAssertNil(UpdateNotice.shown(.none, on: true, hidden: 0))
        XCTAssertNil(UpdateNotice.shown(.fetching(next), on: true, hidden: 0), "nothing while it downloads")
        XCTAssertNil(UpdateNotice.shown(.offered(next), on: true, hidden: 0), "a disk image offered stays in the menu")
        XCTAssertNil(UpdateNotice.shown(.ready(next), on: false, hidden: 0), "switched off")
        XCTAssertNil(UpdateNotice.shown(.ready(next), on: true, hidden: 500), "put away")
        XCTAssertEqual(UpdateNotice.shown(.ready(release(501)), on: true, hidden: 500)?.build, 501, "a newer build shows again")
        XCTAssertEqual(UpdateNotice.title(.ready), "Update ready")
        XCTAssertEqual(UpdateNotice.button(.waiting), "Install")
    }

    func testOnByDefaultAndInSettings() throws {
        let item = try XCTUnwrap(SettingsIndex.items.first { $0.id == "updates.notice" })
        XCTAssertEqual(item.keys, [UpdateNotice.key])
        XCTAssertEqual(item.page, .about)
        let fresh = UserDefaults(suiteName: "update-notice-\(getpid())")!
        XCTAssertNil(fresh.object(forKey: UpdateNotice.key))
        XCTAssertTrue(fresh.object(forKey: UpdateNotice.key) as? Bool ?? true, "on unless switched off")
    }

    /// The column and the strip, ready and not, glass on and off, light and
    /// dark; put away, a newer build, and the switch off.
    func testDrawnOnlyWhileAnUpdateWaits() async throws {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        let before = (prefs.sidebar, prefs.glass, prefs.showsUpdateReady, prefs.updateHiddenBuild, prefs.sideHides, prefs.sidePosition)
        restore = {
            (prefs.sidebar, prefs.glass, prefs.showsUpdateReady, prefs.updateHiddenBuild, prefs.sideHides, prefs.sidePosition) = before
        }
        prefs.sideHides = false
        prefs.sidePosition = .left
        prefs.showsUpdateReady = true
        prefs.updateHiddenBuild = 0
        let updater = Updater.shared

        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.welcoming = false
        browser.folded = false
        browser.tabs.last?.restore(url: URL(string: "about:blank#one")!, title: "A page")

        for glass in [false, true] {
            prefs.glass = glass
            for dark in [false, true] {
                let look = "\(glass ? "glass" : "solid")-\(dark ? "dark" : "light")"
                // The column.
                prefs.sidebar = true
                let column = try show(Column(browser: browser, prefs: prefs), width: Metrics.side, height: 400, dark: dark)
                updater.setStageForTest(.none)
                let none = try await picture(column, "column-none-\(look)")
                updater.setStageForTest(.ready(release(700)))
                let ready = try await picture(column, "column-ready-\(look)")
                let band = 400 - 36 - Int(prefs.sideRow) - 8
                XCTAssertGreaterThan(differs(none, ready, rows: band..<(400 - 36)), 40,
                                     "\(look): the row is drawn just above the foot")
                updater.setStageForTest(.waiting(release(700)))
                let waiting = try await picture(column, "column-waiting-\(look)")
                XCTAssertGreaterThan(differs(none, waiting, rows: band..<(400 - 36)), 40, "\(look): Update available too")
                updater.setStageForTest(.fetching(release(700)))
                let shot1 = try await picture(column, nil)
                XCTAssertEqual(differs(none, shot1), 0, "\(look): nothing while it downloads")
                updater.setStageForTest(.offered(release(700)))
                let shot2 = try await picture(column, nil)
                XCTAssertEqual(differs(none, shot2), 0, "\(look): nothing for a disk image offered")
                // Put away; a newer one; switched off.
                updater.setStageForTest(.ready(release(700)))
                prefs.updateHiddenBuild = 700
                let shot3 = try await picture(column, "column-hidden-\(look)")
                XCTAssertEqual(differs(none, shot3), 0, "\(look): put away stays away")
                updater.setStageForTest(.ready(release(701)))
                let shot4 = try await picture(column, nil)
                XCTAssertGreaterThan(differs(none, shot4, rows: band..<(400 - 36)), 40,
                                     "\(look): a newer build shows again")
                prefs.showsUpdateReady = false
                let shot5 = try await picture(column, "column-off-\(look)")
                XCTAssertEqual(differs(none, shot5), 0, "\(look): the switch off")
                prefs.showsUpdateReady = true
                prefs.updateHiddenBuild = 0
                close(column)

                // The strip.
                prefs.sidebar = false
                let strip = try show(Strip(browser: browser, prefs: prefs), width: 900, height: Metrics.strip, dark: dark)
                updater.setStageForTest(.none)
                let top = try await picture(strip, "strip-none-\(look)")
                updater.setStageForTest(.ready(release(700)))
                let pill = try await picture(strip, "strip-ready-\(look)")
                XCTAssertGreaterThan(differs(top, pill), 40, "\(look): the pill is drawn in the strip")
                prefs.updateHiddenBuild = 700
                let shot6 = try await picture(strip, nil)
                XCTAssertEqual(differs(top, shot6), 0, "\(look): the pill put away too")
                prefs.updateHiddenBuild = 0
                prefs.showsUpdateReady = false
                let shot7 = try await picture(strip, nil)
                XCTAssertEqual(differs(top, shot7), 0, "\(look): no pill with the switch off")
                prefs.showsUpdateReady = true
                close(strip)
            }
        }
    }

    // MARK: - drawing

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

    private struct Picture {
        let rep: NSBitmapImageRep
    }

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

    /// Pixels that differ between two pictures, within rows (points from the
    /// top) when given.
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
