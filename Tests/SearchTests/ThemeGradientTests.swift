import AppKit
import XCTest
@testable import Search

/// A space's gradient (ThemeGradient.swift): kept beside its colour, read
/// from lists that never had one, mixed in OKLab, held to the wash's
/// lightness so the chrome stays as legible as with a colour, and synced
/// as an item a Search from before gradients carries along untouched.
@MainActor
final class SpaceGradientTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override class func tearDown() {
        if let world = Store.world, world.hasPrefix("space-gradient-") {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults.standard.removePersistentDomain(forName: "com.officecommun.search.test.\(world)")
        }
        super.tearDown()
    }

    private let blue = "#4285F5", orange = "#F59E33", violet = "#9E66E6"

    // MARK: - stored

    func testMissingFieldsTakeTheirDefaults() throws {
        let gradient = try JSONDecoder().decode(ThemeGradient.self, from: Data(##"{"colours":["#4285F5","#F59E33"]}"##.utf8))
        XCTAssertEqual(gradient.angle, ThemeGradient.defaultAngle)
        XCTAssertFalse(gradient.grain)
        XCTAssertTrue(gradient.usable)
    }

    // MARK: - colour

    func testOKLabGoesBackToTheSameColour() {
        for hex in ThemeGradient.swatches.map(\.hex) + ["#000000", "#FFFFFF", "#FF0000", "#00FF00", "#0000FF", "#7F7F7F", blue] {
            XCTAssertEqual(OKLab(hex: hex)?.hex, hex.uppercased(), hex)
        }
        XCTAssertNil(OKLab(hex: "#12345"))
        XCTAssertNil(OKLab(hex: "#GGGGGG"))
        XCTAssertEqual(OKLab(hex: "ffffff")?.L ?? 0, 1, accuracy: 1e-4)
        XCTAssertEqual(OKLab(hex: "#000000")?.L ?? 1, 0, accuracy: 1e-4)
    }

    /// Ends are the colours themselves; the middle of blue to orange is as
    /// coloured as they are, where a plain mix in OKLab or sRGB goes grey.
    func testTheMiddleIsNoGreyerThanTheEnds() throws {
        let ends = ThemeGradient(colours: [blue, orange]).drawn
        let first = OKLab.along(ends, at: 0), last = OKLab.along(ends, at: 1)
        XCTAssertEqual(first.hex, ends[0].hex)
        XCTAssertEqual(last.hex, ends[1].hex)
        let middle = OKLab.along(ends, at: 0.5)
        XCTAssertGreaterThanOrEqual(middle.chroma, min(ends[0].chroma, ends[1].chroma) * 0.99)
        let plain = OKLab(L: (ends[0].L + ends[1].L) / 2, a: (ends[0].a + ends[1].a) / 2, b: (ends[0].b + ends[1].b) / 2)
        XCTAssertLessThan(plain.chroma, middle.chroma * 0.5, "a straight mix would have gone grey")
        // Lightness runs evenly from one to the other.
        var last0 = ends[0].L
        for step in 1...20 {
            let l = OKLab.along(ends, at: Double(step) / 20).L
            XCTAssertEqual(l - last0, (ends[1].L - ends[0].L) / 20, accuracy: 1e-9)
            last0 = l
        }
    }

    /// Neighbouring stops are close enough that SwiftUI's blend between
    /// them can't show as a band or a kink, for every preset.
    func testStopsAreEvenAndClose() {
        for (name, preset) in ThemeGradient.presets {
            let stops = preset.stops()
            XCTAssertEqual(stops.count, 24, name)
            XCTAssertEqual(stops.first?.location, 0)
            XCTAssertEqual(stops.last?.location, 1)
            let lab = (0..<24).map { OKLab.along(preset.drawn, at: Double($0) / 23) }
            for (a, b) in zip(lab, lab.dropFirst()) {
                let distance = ((a.L - b.L) * (a.L - b.L) + (a.a - b.a) * (a.a - b.a) + (a.b - b.b) * (a.b - b.b)).squareRoot()
                XCTAssertLessThan(distance, 0.03, name)
            }
        }
    }

    /// Whatever is picked, what is drawn sits in the band of the plain
    /// colours' lightness, with no more chroma than they have.
    func testEveryColourIsHeldToTheWashsBand() {
        let extremes = ["#000000", "#FFFFFF", "#FF0000", "#00FF00", "#0000FF", "#FFFF00", "#00FFFF", "#FF00FF"]
        for hex in extremes + ThemeGradient.swatches.map(\.hex) {
            let held = OKLab(hex: hex)!.held
            XCTAssertTrue(OKLab.lightnessBand.contains(held.L), hex)
            XCTAssertLessThanOrEqual(held.chroma, OKLab.mostChroma + 1e-9, hex)
        }
        // The plain colours are already in it: the band is theirs.
        for colour in Tints.colours.dropFirst() {
            let c = NSColor(colour).usingColorSpace(.sRGB)!
            let lab = OKLab(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
            XCTAssertTrue(OKLab.lightnessBand.contains(lab.L), "\(lab.L)")
        }
    }

    /// The contrast the chrome is drawn for, checked on the ground washed
    /// at full strength with the worst colours there are: the live tab's
    /// grey and the one under the pointer stay as far from the ground as
    /// with the plain colours, and the ink keeps far more than AA, in the
    /// light and the dark, on the column's ground and on the white.
    func testTheGreysAndTheInkKeepTheirContrast() {
        func luminance(_ c: (Double, Double, Double)) -> Double {
            func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
        }
        func ratio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
        func over(_ grey: Double, _ colour: (Double, Double, Double), _ alpha: Double) -> (Double, Double, Double) {
            (grey * (1 - alpha) + colour.0 * alpha, grey * (1 - alpha) + colour.1 * alpha, grey * (1 - alpha) + colour.2 * alpha)
        }
        let plain = Tints.colours.dropFirst().map { colour -> (Double, Double, Double) in
            let c = NSColor(colour).usingColorSpace(.sRGB)!
            return (c.redComponent, c.greenComponent, c.blueComponent)
        }
        let picked = ["#000000", "#FFFFFF", "#FF0000", "#00FF00", "#0000FF", "#FFFF00"].map { OKLab(hex: $0)!.held.srgb }
            + ThemeGradient.presets.flatMap { preset in (0...10).map { OKLab.along(preset.gradient.drawn, at: Double($0) / 10).srgb } }
        // (ground, live tab, pointer, ink, wash strength), light then dark,
        // the column's ground then the white.
        let grounds: [(Double, Double, Double, Double, Double)] = [
            (0.955, 0.895, 0.915, 0.09, Tints.washLight), (1.0, 0.937, 0.965, 0.09, Tints.washLight),
            (0.075, 0.155, 0.13, 0.93, Tints.washDark), (0.11, 0.175, 0.15, 0.93, Tints.washDark),
        ]
        for (ground, live, hover, ink, alpha) in grounds {
            func step(_ colour: (Double, Double, Double), _ grey: Double) -> Double {
                ratio(luminance(over(ground, colour, alpha)), luminance((grey, grey, grey)))
            }
            let worstPlainLive = plain.map { step($0, live) }.min()!
            let worstPlainHover = plain.map { step($0, hover) }.min()!
            let worstPlainInk = plain.map { step($0, ink) }.min()!
            for colour in picked {
                XCTAssertGreaterThanOrEqual(step(colour, live), worstPlainLive * 0.97, "live tab on \(ground): \(colour)")
                XCTAssertGreaterThanOrEqual(step(colour, hover), worstPlainHover * 0.97, "hover on \(ground): \(colour)")
                XCTAssertGreaterThanOrEqual(step(colour, ink), worstPlainInk * 0.97, "ink on \(ground): \(colour)")
                XCTAssertGreaterThan(step(colour, ink), 7, "ink, AAA, on \(ground): \(colour)")
            }
        }
    }

    // MARK: - strength

    /// Subtle draws exactly as before strengths: the same stops, opacity
    /// and grain, and a plain colour as itself.
    func testSubtleIsTheWashAsItWas() {
        for (_, preset) in ThemeGradient.presets {
            for dark in [false, true] {
                XCTAssertEqual(preset.stops(strength: .subtle, dark: dark), preset.stops())
            }
        }
        XCTAssertEqual(ThemeStrength.subtle.opacity(dark: false), Tints.washLight)
        XCTAssertEqual(ThemeStrength.subtle.opacity(dark: true), Tints.washDark)
        XCTAssertEqual(ThemeStrength.subtle.grain(dark: false), Grain.light)
        XCTAssertEqual(Tints.toned(2, .subtle, dark: true), Tints.colours[2])
        // Each step is stronger than the last, in both.
        for dark in [false, true] {
            XCTAssertLessThan(ThemeStrength.subtle.opacity(dark: dark), ThemeStrength.rich.opacity(dark: dark))
            XCTAssertLessThan(ThemeStrength.rich.opacity(dark: dark), ThemeStrength.vivid.opacity(dark: dark))
        }
    }

    /// Rich and Vivid at their worst: every colour there is, toned and
    /// washed at full strength over the column's ground and the white, in
    /// the light and the dark. The ground stays on its side, so the
    /// window's own ink is the one that reads (it never needs to turn
    /// over); the ink keeps AAA; a tab's quiet title, now black or white
    /// with alpha, keeps about the step it has on the plain ground; and the
    /// live tab's and the pointer's greys keep theirs.
    func testRichAndVividKeepTheChromeLegible() {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func luminance(_ c: (Double, Double, Double)) -> Double { 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2) }
        func ratio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
        func over(_ base: (Double, Double, Double), _ top: (Double, Double, Double), _ alpha: Double) -> (Double, Double, Double) {
            (base.0 * (1 - alpha) + top.0 * alpha, base.1 * (1 - alpha) + top.1 * alpha, base.2 * (1 - alpha) + top.2 * alpha)
        }
        let plain = Tints.colours.dropFirst().map { colour -> OKLab in
            let c = NSColor(colour).usingColorSpace(.sRGB)!
            return OKLab(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
        }
        // The band's corners at full chroma, round the wheel, and everything offered.
        var picked = plain + ThemeGradient.swatches.map { OKLab(hex: $0.hex)!.held }
        for hue in stride(from: 0.0, to: 360, by: 15) {
            for lightness in [OKLab.lightnessBand.lowerBound, OKLab.lightnessBand.upperBound] {
                picked.append(OKLab(lightness: lightness, chroma: OKLab.mostChroma, hue: hue).held)
            }
        }
        picked += ["#000000", "#FFFFFF", "#FF0000", "#00FF00", "#0000FF", "#FFFF00"].map { OKLab(hex: $0)!.held }

        // (ground, ink, quiet title as alpha, live, pointer, the opaque quiet grey; dark?)
        let grounds: [(Double, Double, Double, Double, Double, Double, Bool)] = [
            (0.955, 0.09, 0.4241, 0.0628, 0.0419, 0.55, false), (1.0, 0.09, 0.45, 0.063, 0.035, 0.55, false),
            (0.075, 0.93, 0.5459, 0.0865, 0.0595, 0.58, true), (0.11, 0.93, 0.5281, 0.073, 0.045, 0.58, true),
        ]
        for strength in [ThemeStrength.rich, .vivid] {
            for (ground, ink, quiet, live, hover, opaqueQuiet, dark) in grounds {
                let shade = dark ? 1.0 : 0.0
                let g = (ground, ground, ground)
                let plainQuiet = ratio(luminance(g), luminance((opaqueQuiet, opaqueQuiet, opaqueQuiet)))
                let plainLive = ratio(luminance(g), luminance(over(g, (shade, shade, shade), live)))
                let plainHover = ratio(luminance(g), luminance(over(g, (shade, shade, shade), hover)))
                var colours = picked.map { strength.tone($0, dark: dark).srgb }
                for (_, preset) in ThemeGradient.presets {
                    let toned = preset.drawn.map { strength.tone($0, dark: dark) }
                    colours += (0...10).map { OKLab.along(toned, at: Double($0) / 10).srgb }
                }
                for colour in colours {
                    let washed = over(g, colour, strength.opacity(dark: dark))
                    let lum = luminance(washed)
                    let what = "\(strength) on \(ground): \(colour)"
                    // The ink the window has is the one that reads: no turning over.
                    let own = ratio(lum, luminance((ink, ink, ink)))
                    let other = ratio(lum, dark ? luminance((0.09, 0.09, 0.09)) : luminance((0.93, 0.93, 0.93)))
                    XCTAssertGreaterThan(own, other * 2, "the ink stays the window's own: \(what)")
                    XCTAssertGreaterThan(own, 7, "ink, AAA: \(what)")
                    let title = ratio(lum, luminance(over(washed, (shade, shade, shade), quiet)))
                    XCTAssertGreaterThanOrEqual(title, plainQuiet * (dark ? 0.68 : 0.9), "quiet title: \(what)")
                    XCTAssertGreaterThan(title, dark ? 4 : 2.6, "quiet title: \(what)")
                    let liveStep = ratio(lum, luminance(over(washed, (shade, shade, shade), live)))
                    XCTAssertGreaterThanOrEqual(liveStep, plainLive * 0.93, "live tab: \(what)")
                    let hoverStep = ratio(lum, luminance(over(washed, (shade, shade, shade), hover)))
                    XCTAssertGreaterThanOrEqual(hoverStep, plainHover * 0.97, "pointer: \(what)")
                }
            }
        }
    }

    /// Stronger is richer: Vivid's ground carries more colour than Subtle's
    /// in both appearances, so the choice is worth having.
    func testVividIsRicherThanSubtle() {
        func washed(_ strength: ThemeStrength, _ lab: OKLab, dark: Bool) -> OKLab {
            let ground = dark ? 0.075 : 0.955, (r, g, b) = strength.tone(lab, dark: dark).srgb, a = strength.opacity(dark: dark)
            return OKLab(r: ground * (1 - a) + r * a, g: ground * (1 - a) + g * a, b: ground * (1 - a) + b * a)
        }
        for swatch in ThemeGradient.swatches.prefix(12) {
            let lab = OKLab(hex: swatch.hex)!.held
            for dark in [false, true] {
                XCTAssertGreaterThan(washed(.vivid, lab, dark: dark).chroma, washed(.subtle, lab, dark: dark).chroma * 2, swatch.name)
                XCTAssertGreaterThan(washed(.rich, lab, dark: dark).chroma, washed(.subtle, lab, dark: dark).chroma * 1.5, swatch.name)
            }
        }
    }

    /// One line across the window: the column at the left edge shows the
    /// window's first stretch of it, not the whole of it squeezed in.
    func testItRunsAcrossTheWindow() {
        let room = CGSize(width: 1000, height: 600)
        let down = ThemeGradient(colours: [blue, orange], angle: 180)
        let whole = down.points(frame: CGRect(origin: .zero, size: room), room: room)
        XCTAssertEqual(whole.start.x, 0.5, accuracy: 1e-9); XCTAssertEqual(whole.start.y, 0, accuracy: 1e-9)
        XCTAssertEqual(whole.end.x, 0.5, accuracy: 1e-9); XCTAssertEqual(whole.end.y, 1, accuracy: 1e-9)
        let right = ThemeGradient(colours: [blue, orange], angle: 90)
        let column = right.points(frame: CGRect(x: 0, y: 0, width: 250, height: 600), room: room)
        XCTAssertEqual(column.start.x, 0, accuracy: 1e-9)
        XCTAssertEqual(column.end.x, 4, accuracy: 1e-9, "the column is a quarter of the way")
        let bar = right.points(frame: CGRect(x: 250, y: 0, width: 750, height: 30), room: room)
        XCTAssertEqual(bar.start.x, -1.0 / 3, accuracy: 1e-9, "the bar carries on where the column stopped")
        // Diagonal: long enough that the window's far corners fall square
        // on the line's ends, as in CSS — the corners get the end colours.
        let diagonal = ThemeGradient(colours: [blue, orange], angle: 135).points(frame: CGRect(origin: .zero, size: room), room: room)
        let start = CGPoint(x: diagonal.start.x * room.width, y: diagonal.start.y * room.height)
        let end = CGPoint(x: diagonal.end.x * room.width, y: diagonal.end.y * room.height)
        let along = CGPoint(x: end.x - start.x, y: end.y - start.y)
        func t(_ p: CGPoint) -> Double { ((p.x - start.x) * along.x + (p.y - start.y) * along.y) / (along.x * along.x + along.y * along.y) }
        XCTAssertEqual(t(.zero), 0, accuracy: 1e-9)
        XCTAssertEqual(t(CGPoint(x: room.width, y: room.height)), 1, accuracy: 1e-9)
        XCTAssertEqual(diagonal.start.x + diagonal.end.x, 1, accuracy: 1e-9)
        // Off screen, with no window: the box is its own.
        let alone = down.points(frame: CGRect(x: 40, y: 40, width: 200, height: 100), room: .zero)
        XCTAssertEqual(alone.start.y, 0, accuracy: 1e-9); XCTAssertEqual(alone.end.y, 1, accuracy: 1e-9)
    }

    // MARK: - the window

    func testFoundInSettings() {
        XCTAssertTrue(SettingsIndex.find("gradient").contains { $0.id == "note.spaceGradient" })
        XCTAssertTrue(SettingsIndex.find("space colour").contains { $0.id == "note.spaceGradient" })
    }

    // MARK: - sync

}
