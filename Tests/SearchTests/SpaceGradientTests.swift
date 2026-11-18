import AppKit
import XCTest
@testable import Search

/// A space's gradient (SpaceGradient.swift): kept beside its colour, read
/// from lists that never had one, mixed in OKLab, held to the wash's
/// lightness so the chrome stays as legible as with a colour, and synced
/// as an item a Search from before gradients carries along untouched.
@MainActor
final class SpaceGradientTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "space-gradient-\(getpid())", 1)
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

    /// A list from before gradients reads as it did, and is written back
    /// byte for byte the same: no "gradient" key appears.
    func testOldSpacesReadAndWriteAsBefore() throws {
        let old = #"[{"id":"00000000-0000-0000-0000-000000000001","name":"Personal","colour":0},{"colour":2,"icon":"leaf","id":"6F1C2D3E-0000-4000-8000-000000000002","name":"Work","sharesSignIns":true}]"#
        let spaces = try JSONDecoder().decode([Space].self, from: Data(old.utf8))
        XCTAssertEqual(spaces.map(\.name), ["Personal", "Work"])
        XCTAssertNil(spaces[0].gradient)
        XCTAssertNil(spaces[1].gradient)
        XCTAssertNil(spaces[0].look)
        XCTAssertEqual(spaces[1].look, .colour(2))
        let written = String(decoding: try JSONEncoder().encode(spaces), as: UTF8.self)
        XCTAssertFalse(written.contains("gradient"), written)
    }

    func testAGradientGoesAndComesBack() throws {
        var space = Space(id: UUID(), name: "Studio", colour: 3)
        space.gradient = SpaceGradient(colours: [blue, orange, violet], angle: 45, grain: true)
        let back = try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(space))
        XCTAssertEqual(back, space)
        XCTAssertEqual(back.colour, 3, "the colour is kept beside it")
        XCTAssertEqual(back.look, .gradient(space.gradient!))
    }

    func testMissingFieldsTakeTheirDefaults() throws {
        let gradient = try JSONDecoder().decode(SpaceGradient.self, from: Data(##"{"colours":["#4285F5","#F59E33"]}"##.utf8))
        XCTAssertEqual(gradient.angle, SpaceGradient.defaultAngle)
        XCTAssertFalse(gradient.grain)
        XCTAssertTrue(gradient.usable)
    }

    /// A gradient that doesn't read — damaged, or from a newer Search that
    /// writes it otherwise — costs the space its gradient, never the list.
    func testADamagedGradientNeverCostsTheList() throws {
        for damaged in ["5", #""x""#, #"{"colours":"red"}"#, ##"{"colours":["#12"],"angle":"wide"}"##, #"{"colours":[1,2]}"#, "[]", "null"] {
            let text = #"[{"id":"00000000-0000-0000-0000-000000000001","name":"Personal","colour":4,"gradient":"# + damaged + "}]"
            let spaces = try JSONDecoder().decode([Space].self, from: Data(text.utf8))
            XCTAssertEqual(spaces.count, 1, damaged)
            XCTAssertEqual(spaces[0].look, .colour(4), "falls back to the colour: \(damaged)")
        }
    }

    func testFewerThanTwoColoursIsTheColourAndMoreThanThreeAreThree() {
        var space = Space(id: UUID(), name: "One", colour: 1)
        space.gradient = SpaceGradient(colours: [blue])
        XCTAssertEqual(space.look, .colour(1))
        space.gradient = SpaceGradient(colours: [blue, "nonsense"])
        XCTAssertEqual(space.look, .colour(1))
        space.colour = 0
        XCTAssertNil(space.look, "no colour and no usable gradient: nothing, as before")
        space.gradient = SpaceGradient(colours: [blue, orange, violet, blue])
        XCTAssertEqual(space.gradient?.drawn.count, 3)
    }

    // MARK: - colour

    func testOKLabGoesBackToTheSameColour() {
        for hex in SpaceGradient.swatches.map(\.hex) + ["#000000", "#FFFFFF", "#FF0000", "#00FF00", "#0000FF", "#7F7F7F", blue] {
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
        let ends = SpaceGradient(colours: [blue, orange]).drawn
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
        for (name, preset) in SpaceGradient.presets {
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
        for hex in extremes + SpaceGradient.swatches.map(\.hex) {
            let held = OKLab(hex: hex)!.held
            XCTAssertTrue(OKLab.lightnessBand.contains(held.L), hex)
            XCTAssertLessThanOrEqual(held.chroma, OKLab.mostChroma + 1e-9, hex)
        }
        // The plain colours are already in it: the band is theirs.
        for colour in Spaces.colours.dropFirst() {
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
        let plain = Spaces.colours.dropFirst().map { colour -> (Double, Double, Double) in
            let c = NSColor(colour).usingColorSpace(.sRGB)!
            return (c.redComponent, c.greenComponent, c.blueComponent)
        }
        let picked = ["#000000", "#FFFFFF", "#FF0000", "#00FF00", "#0000FF", "#FFFF00"].map { OKLab(hex: $0)!.held.srgb }
            + SpaceGradient.presets.flatMap { preset in (0...10).map { OKLab.along(preset.gradient.drawn, at: Double($0) / 10).srgb } }
        // (ground, live tab, pointer, ink, wash strength), light then dark,
        // the column's ground then the white.
        let grounds: [(Double, Double, Double, Double, Double)] = [
            (0.955, 0.895, 0.915, 0.09, Spaces.washLight), (1.0, 0.937, 0.965, 0.09, Spaces.washLight),
            (0.075, 0.155, 0.13, 0.93, Spaces.washDark), (0.11, 0.175, 0.15, 0.93, Spaces.washDark),
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

    /// One line across the window: the column at the left edge shows the
    /// window's first stretch of it, not the whole of it squeezed in.
    func testItRunsAcrossTheWindow() {
        let room = CGSize(width: 1000, height: 600)
        let down = SpaceGradient(colours: [blue, orange], angle: 180)
        let whole = down.points(frame: CGRect(origin: .zero, size: room), room: room)
        XCTAssertEqual(whole.start.x, 0.5, accuracy: 1e-9); XCTAssertEqual(whole.start.y, 0, accuracy: 1e-9)
        XCTAssertEqual(whole.end.x, 0.5, accuracy: 1e-9); XCTAssertEqual(whole.end.y, 1, accuracy: 1e-9)
        let right = SpaceGradient(colours: [blue, orange], angle: 90)
        let column = right.points(frame: CGRect(x: 0, y: 0, width: 250, height: 600), room: room)
        XCTAssertEqual(column.start.x, 0, accuracy: 1e-9)
        XCTAssertEqual(column.end.x, 4, accuracy: 1e-9, "the column is a quarter of the way")
        let bar = right.points(frame: CGRect(x: 250, y: 0, width: 750, height: 30), room: room)
        XCTAssertEqual(bar.start.x, -1.0 / 3, accuracy: 1e-9, "the bar carries on where the column stopped")
        // Diagonal: long enough that the window's far corners fall square
        // on the line's ends, as in CSS — the corners get the end colours.
        let diagonal = SpaceGradient(colours: [blue, orange], angle: 135).points(frame: CGRect(origin: .zero, size: room), room: room)
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

    func testTheWashFollowsTheGradientAndFallsBackToTheColour() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let oldUsesSpaces = browser.prefs.usesSpaces
        let oldSpaces = browser.spaces
        defer {
            browser.closeAll()
            browser.prefs.usesSpaces = oldUsesSpaces
            browser.spaces = oldSpaces
        }
        browser.prefs.usesSpaces = true
        let first = browser.spaceID
        let second = UUID()
        browser.spaces = [Space(id: first, name: "First", colour: 0), Space(id: second, name: "Second", colour: 2)]
        browser.closeAll()
        browser.showRow([], active: nil, blank: true)

        let gradient = SpaceGradient(colours: [blue, violet], angle: 90, grain: true)
        browser.setSpaceGradient(second, to: gradient)
        XCTAssertNil(browser.wash, "the space on screen has neither")
        browser.switchSpace(to: second)
        XCTAssertEqual(browser.wash, .gradient(gradient))
        XCTAssertNil(browser.washColour)

        browser.setSpaceGradient(second, to: nil)
        XCTAssertEqual(browser.wash, .colour(2), "removed: back to its colour")
        browser.setSpaceGradient(second, to: SpaceGradient(colours: [blue]))
        XCTAssertEqual(browser.wash, .colour(2), "one colour is no gradient")

        browser.setSpaceGradient(second, to: gradient)
        browser.setSpaceColour(second, to: 4)
        XCTAssertEqual(browser.wash, .colour(4), "a colour picked replaces the gradient")
        XCTAssertNil(browser.space.gradient)

        browser.setSpaceGradient(second, to: gradient)
        browser.makingSpace = true
        XCTAssertNil(browser.wash, "the card for a new space has none yet")
        browser.makingSpace = false
        browser.prefs.usesSpaces = false
        XCTAssertNil(browser.wash, "spaces off, no wash")
        browser.prefs.usesSpaces = true
        browser.switchSpace(to: first)
        XCTAssertNil(browser.wash)
    }

    /// The picker: what it rings, what its preview says, and what each
    /// choice does to the space. One item in the space's menu opens it.
    func testThePickerChoosesAndNamesTheLook() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let oldUsesSpaces = browser.prefs.usesSpaces
        let oldSpaces = browser.spaces
        defer {
            browser.closeAll()
            browser.prefs.usesSpaces = oldUsesSpaces
            browser.spaces = oldSpaces
        }
        browser.prefs.usesSpaces = true
        let id = browser.spaceID
        browser.spaces = [Space(id: id, name: "Home", colour: 0)]
        XCTAssertEqual(browser.space.lookChoice, .none)
        XCTAssertEqual(browser.space.lookName, "No colour")

        browser.chooseLook(id, .colour(2))
        XCTAssertEqual(browser.space.lookChoice, .colour(2))
        XCTAssertEqual(browser.space.lookName, "Green")

        browser.chooseLook(id, .custom)
        XCTAssertEqual(browser.space.gradient, SpaceGradient.starting(from: 2), "a first gradient, from its colour")
        XCTAssertEqual(browser.space.lookChoice, .custom)
        XCTAssertEqual(browser.space.colour, 2, "the colour kept beside it")

        browser.editGradient(id) { $0.angle = 270; $0.grain = true }
        browser.chooseLook(id, .preset(3))
        XCTAssertEqual(browser.space.lookChoice, .preset(3))
        XCTAssertEqual(browser.space.lookName, SpaceGradient.presets[3].name)
        XCTAssertEqual(browser.space.gradient?.angle, 270, "a ready-made gradient keeps the direction")
        XCTAssertEqual(browser.space.gradient?.grain, true, "and the grain")

        browser.editGradient(id) { $0.colours[0] = SpaceGradient.swatches[0].hex }
        XCTAssertEqual(browser.space.lookChoice, .custom, "changed: its own now")

        browser.chooseLook(id, .none)
        XCTAssertNil(browser.space.gradient)
        XCTAssertEqual(browser.space.lookChoice, .none)

        // Escape: back to what it had when the picker opened.
        let had = SpaceGradient(colours: SpaceGradient.presets[1].gradient.colours, angle: 90)
        browser.restoreLook(id, colour: 4, gradient: had)
        XCTAssertEqual(browser.space.gradient, had)
        XCTAssertEqual(browser.space.colour, 4)
        browser.restoreLook(id, colour: 4, gradient: nil)
        XCTAssertEqual(browser.space.lookChoice, .colour(4))

        let titles = SpaceMenu.menu(for: browser).items.map(\.title)
        XCTAssertTrue(titles.contains("Colour…"))
        XCTAssertFalse(titles.contains("Colour"), "no submenu")
        XCTAssertNil(SpaceMenu.menu(for: browser).items.first { $0.title == "Colour…" }?.submenu)
    }

    func testFoundInSettings() {
        XCTAssertTrue(SettingsIndex.find("gradient").contains { $0.id == "note.spaceGradient" })
        XCTAssertTrue(SettingsIndex.find("space colour").contains { $0.id == "note.spaceGradient" })
    }

    // MARK: - sync

    func testAGradientSyncsAsAnItemOfItsOwn() {
        var studio = Space(id: UUID(), name: "Studio", colour: 2, sharesSignIns: true)
        let plain = SyncItems.spaces([Space.first(), studio])
        XCTAssertFalse(plain.keys.contains { $0.hasPrefix("gradient:") }, "no gradient, no new item")
        studio.gradient = SpaceGradient(colours: [blue, orange], angle: 45, grain: true)
        let items = SyncItems.spaces([Space.first(), studio])
        XCTAssertEqual(items[SyncItems.spaceKey(studio.id)], plain[SyncItems.spaceKey(studio.id)],
                       "the space's own item reads as an older Search writes it")
        XCTAssertNotNil(items[SyncItems.gradientKey(studio.id)])
        let back = SyncItems.applySpaces(items, to: [], profile: Profile.personalID, home: Space.firstID)
        XCTAssertEqual(back.first { $0.id == studio.id }?.gradient, studio.gradient)
        XCTAssertEqual(SyncItems.spaces(back), items)
        // Removed on one Mac: gone from the other.
        let gone = SyncItems.applySpaces(plain, to: back, profile: Profile.personalID, home: Space.firstID)
        XCTAssertNil(gone.first { $0.id == studio.id }?.gradient)
        XCTAssertEqual(gone.first { $0.id == studio.id }?.colour, 2)
    }

    /// A Search from before gradients doesn't read the item: it neither
    /// deletes it nor writes the space back without it, so the gradient
    /// outlives a pass there.
    func testAnOlderSearchCarriesTheGradientAlong() {
        var studio = Space(id: UUID(), name: "Studio", colour: 2, sharesSignIns: true)
        studio.gradient = SpaceGradient(colours: [blue, orange])
        let newer = SyncMerge.pass(current: SyncItems.spaces([Space.first(), studio]), base: nil, theirs: [],
                                   device: "new", now: 1000)
        // The older one's items: the same space, no gradient item at all.
        var older = studio
        older.gradient = nil
        let olderUnderstood: (String, String) -> Bool = { key, text in
            key.hasPrefix("gradient:") ? false : SyncItems.understood(key, text)
        }
        let after = SyncMerge.pass(current: SyncItems.spaces([Space.first(), older]), base: newer, theirs: [newer],
                                   device: "old", now: 2000, understood: olderUnderstood)
        XCTAssertEqual(after[SyncItems.gradientKey(studio.id)]?.v, newer[SyncItems.gradientKey(studio.id)]?.v)
        XCTAssertEqual(after[SyncItems.spaceKey(studio.id)], newer[SyncItems.spaceKey(studio.id)], "nothing restamped")
        XCTAssertTrue(SyncItems.understood(SyncItems.gradientKey(studio.id), newer[SyncItems.gradientKey(studio.id)]!.v!))
    }
}
