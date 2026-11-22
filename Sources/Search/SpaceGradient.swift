import SwiftUI
import AppKit

// A space's gradient: two or three colours instead of one, the way Arc and
// Ardia theme a space. Only for whoever wants one (the space's menu ›
// Colour…, see SpaceLookPicker below): a space without one is washed with its colour, or
// nothing, exactly as before, and reads and writes spaces.json as it
// always did. Removing it gives the space back its colour.
//
// The gradient takes the colour's place wherever the wash is drawn — the
// column or the strip, the bookmarks bar, the ground around the page's
// card — at the same strength (Spaces.washLight, washDark). It runs across
// the window, not across each of those on its own, so where the column
// meets the ground the colours carry on.
//
// The colours are mixed in OKLab, keeping the chroma of the ends, so the
// middle of blue to orange is as bright and as coloured as they are rather
// than a grey. Each colour's lightness is held to the band the plain
// colours sit in: whatever is picked, the wash moves the ground no further
// than they do, and the greys of the live tab and the one under the
// pointer keep their step from it.
//
// Drawn once, as a gradient of stops; nothing moves while it stays, and a
// change crossfades once, as the colour's does. The grain is one small
// tile of noise, made once and laid over it.

struct SpaceGradient: Codable, Equatable, Hashable {
    /// The colours in the order they run, "#RRGGBB" in sRGB: two or three.
    var colours: [String]
    /// The way it runs, in degrees as CSS has them: 0 up, 90 right, 180 down.
    var angle: Double
    /// A faint, still grain over it.
    var grain: Bool

    static let defaultAngle: Double = 135
    static let most = 3

    init(colours: [String], angle: Double = SpaceGradient.defaultAngle, grain: Bool = false) {
        self.colours = colours
        self.angle = angle
        self.grain = grain
    }

    private enum CodingKeys: String, CodingKey { case colours, angle, grain }

    /// Never fails: a gradient that doesn't read is no gradient (see
    /// `usable`), and the space keeps its colour. Failing here would fail
    /// the whole list of spaces.
    init(from decoder: Decoder) throws {
        let fields = try? decoder.container(keyedBy: CodingKeys.self)
        colours = (try? fields?.decodeIfPresent([String].self, forKey: .colours)) ?? []
        angle = (try? fields?.decodeIfPresent(Double.self, forKey: .angle)).flatMap { $0?.isFinite == true ? $0 : nil } ?? Self.defaultAngle
        grain = (try? fields?.decodeIfPresent(Bool.self, forKey: .grain)) ?? false
    }

    /// The colours as drawn: the first three that read, each held to the
    /// wash's band of lightness and chroma.
    var drawn: [OKLab] {
        Array(colours.compactMap(OKLab.init(hex:)).prefix(Self.most)).map(\.held)
    }

    /// Two colours or more that read; otherwise the space's colour stands.
    var usable: Bool { drawn.count >= 2 }

    /// What the gradient is drawn with: its colours mixed in OKLab at
    /// `count` stops, evenly spaced. SwiftUI blends between neighbours,
    /// which are close enough that how it blends doesn't show.
    func stops(count: Int = 24, strength: SpaceStrength = .subtle, dark: Bool = false) -> [Gradient.Stop] {
        let lab = drawn.map { strength.tone($0, dark: dark) }
        guard lab.count >= 2 else { return [] }
        return (0..<count).map { step in
            let t = Double(step) / Double(count - 1)
            let (r, g, b) = OKLab.along(lab, at: t).srgb
            return Gradient.Stop(color: Color(.sRGB, red: r, green: g, blue: b), location: t)
        }
    }

    /// The one colour it is, "#RRGGBB", when every colour is the same: a
    /// colour of one's own (SpaceLookChoice.customColour).
    var single: String? {
        let picked = colours.prefix(Self.most).map { $0.uppercased() }
        guard picked.count >= 2, let first = picked.first, picked.allSatisfy({ $0 == first }),
              OKLab(hex: first) != nil else { return nil }
        return first.hasPrefix("#") ? first : "#" + first
    }

    /// A colour of one's own exactly as picked, in sRGB: unlike a
    /// gradient's colours it is not held to the wash's band, and it is laid
    /// on solid, not as a tint. Picking #000000 makes the chrome black.
    var exact: Color? {
        guard let hex = single, let lab = OKLab(hex: hex) else { return nil }
        let (r, g, b) = lab.srgb
        return Color(.sRGB, red: r, green: g, blue: b)
    }

    /// The appearance the chrome takes on a colour of one's own: dark (light
    /// ink) on a dark colour, light (dark ink) on a light one, whichever ink
    /// stands further from it, as WCAG measures contrast. Nil for any other
    /// look, which is a tint over the window's own ground and keeps its ink.
    var scheme: ColorScheme? {
        guard let hex = single, let lab = OKLab(hex: hex) else { return nil }
        return OKLab.prefersLightInk(lab) ? .dark : .light
    }

    /// Its first colour as drawn: for the space's dot and its menu.
    var lead: Color? {
        drawn.first.map { lab in let (r, g, b) = lab.srgb; return Color(.sRGB, red: r, green: g, blue: b) }
    }

    /// Where it starts and ends, as unit points of a box at `frame` in a
    /// window `room` big: the line through the window's middle at `angle`,
    /// long enough that the window's corners lie on its ends, as in CSS.
    /// The column, the bars and the ground then each show their part of
    /// one gradient. No room (drawn off screen) is the box alone.
    func points(frame: CGRect, room: CGSize) -> (start: UnitPoint, end: UnitPoint) {
        let box = room.width > 0 && room.height > 0 ? CGRect(origin: .zero, size: room) : CGRect(origin: frame.origin, size: frame.size)
        let radians = angle * .pi / 180
        let dx = sin(radians), dy = -cos(radians)
        let length = abs(box.width * dx) + abs(box.height * dy)
        let mid = CGPoint(x: box.midX, y: box.midY)
        let start = CGPoint(x: mid.x - dx * length / 2, y: mid.y - dy * length / 2)
        let end = CGPoint(x: mid.x + dx * length / 2, y: mid.y + dy * length / 2)
        func unit(_ p: CGPoint) -> UnitPoint {
            UnitPoint(x: frame.width > 0 ? (p.x - frame.minX) / frame.width : 0,
                      y: frame.height > 0 ? (p.y - frame.minY) / frame.height : 0)
        }
        return (unit(start), unit(end))
    }

    // MARK: - choices

    /// The colours the editor offers: twelve hues at one lightness and
    /// chroma, so each washes as strongly as the next, and two quiet ones.
    static let swatches: [(name: String, hex: String)] = {
        let hues: [(String, Double)] = [
            ("Red", 25), ("Orange", 55), ("Amber", 85), ("Lime", 125), ("Green", 150), ("Teal", 185), ("Cyan", 215),
            ("Blue", 250), ("Indigo", 275), ("Violet", 300), ("Magenta", 330), ("Pink", 355),
        ]
        return hues.map { ($0.0, OKLab(lightness: 0.70, chroma: 0.14, hue: $0.1).hex) }
            + [("Graphite", OKLab(lightness: 0.62, chroma: 0.015, hue: 260).hex),
               ("Sand", OKLab(lightness: 0.78, chroma: 0.045, hue: 75).hex)]
    }()

    private static func swatch(_ name: String) -> String { swatches.first { $0.name == name }?.hex ?? "#808080" }

    static let presets: [(name: String, gradient: SpaceGradient)] = [
        ("Sunrise", SpaceGradient(colours: [swatch("Amber"), swatch("Pink")])),
        ("Lagoon", SpaceGradient(colours: [swatch("Teal"), swatch("Blue")])),
        ("Orchard", SpaceGradient(colours: [swatch("Lime"), swatch("Teal")])),
        ("Dusk", SpaceGradient(colours: [swatch("Indigo"), swatch("Magenta"), swatch("Orange")])),
        ("Glacier", SpaceGradient(colours: [swatch("Cyan"), swatch("Indigo")])),
        ("Ember", SpaceGradient(colours: [swatch("Red"), swatch("Amber")])),
    ]

    /// A first gradient for a space: its colour, if it has one, into the
    /// hue beside it; Lagoon otherwise.
    static func starting(from colour: Int) -> SpaceGradient {
        let from = ["", "Blue", "Green", "Orange", "Red", "Violet"]
        let to = ["", "Violet", "Teal", "Pink", "Amber", "Pink"]
        guard from.indices.contains(colour), colour > 0 else { return presets[1].gradient }
        return SpaceGradient(colours: [swatch(from[colour]), swatch(to[colour])])
    }
}

/// How strongly a space's colour or gradient washes the chrome. Subtle is
/// the faint wash every space had; Rich and Vivid are for whoever wants the
/// colour seen, closer to Arc's saturated themes (the Colour… picker's
/// Strength). Nil in spaces.json is Subtle, so a list from before reads
/// and writes as it did.
///
/// Stronger, the wash stays on its side of the window's appearance: in a
/// light window a deeper tint the ink still reads on, in a dark one a deep
/// colour the light ink reads on. So the column's ink never has to turn
/// over; the colour's lightness is held further for that (`tone`), and the
/// greys and the tab titles are black or white with alpha (see Greys),
/// keeping their step from whatever ground they land on. Checked against
/// the worst colours in SpaceGradientTests.
enum SpaceStrength: String, CaseIterable, Codable, Hashable {
    case subtle, rich, vivid

    var name: String {
        switch self {
        case .subtle: return "Subtle"
        case .rich: return "Rich"
        case .vivid: return "Vivid"
        }
    }

    /// Never fails: a strength a newer Search writes, or one that doesn't
    /// read, is Subtle. Failing here would fail the whole list of spaces.
    init(from decoder: Decoder) throws {
        let text = try? decoder.singleValueContainer().decode(String.self)
        self = text.flatMap(SpaceStrength.init(rawValue:)) ?? .subtle
    }

    /// How much of the colour the chrome wears. Subtle is the colour's
    /// wash as it always was (Spaces.washLight, washDark).
    func opacity(dark: Bool) -> Double {
        switch self {
        case .subtle: return dark ? Spaces.washDark : Spaces.washLight
        case .rich: return dark ? 0.22 : 0.18
        case .vivid: return dark ? 0.40 : 0.30
        }
    }

    /// The colour as this strength washes with it: more chroma, and its
    /// lightness held so the washed ground stays light in a light window
    /// (Vivid: no darker than 0.62) and deep in a dark one (Rich: no
    /// lighter than 0.72, Vivid: 0.48 to 0.58). Subtle is the colour as held.
    func tone(_ colour: OKLab, dark: Bool) -> OKLab {
        let (boost, band): (Double, ClosedRange<Double>) = {
            switch self {
            case .subtle: return (1, 0...1)
            case .rich: return (1.15, dark ? 0...0.72 : 0...1)
            case .vivid: return (1.3, dark ? 0.48...0.58 : 0.62...1)
            }
        }()
        // No more chroma than the band allows a colour, however strong: a
        // blue already near it would otherwise wash the column royal blue.
        let chroma = colour.chroma, wanted = min(chroma * boost, max(chroma, OKLab.mostChroma))
        let scale = chroma > 1e-9 ? wanted / chroma : 1
        return OKLab(L: min(max(colour.L, band.lowerBound), band.upperBound), a: colour.a * scale, b: colour.b * scale)
    }

    /// The grain, a touch stronger on a stronger colour, or it is lost in it.
    func grain(dark: Bool) -> Double {
        let base = dark ? Grain.dark : Grain.light
        switch self {
        case .subtle: return base
        case .rich: return base * 1.25
        case .vivid: return base * 1.5
        }
    }
}

extension Space {
    /// How strongly it washes the chrome: Subtle unless chosen.
    var washStrength: SpaceStrength { strength ?? .subtle }
}

/// What a space washes the chrome with: one of Spaces.colours, or its
/// gradient. Nil is nothing at all, the look every space had before.
enum SpaceLook: Equatable {
    case colour(Int)
    case gradient(SpaceGradient)
}

extension Space {
    var look: SpaceLook? {
        if let gradient, gradient.usable { return .gradient(gradient) }
        return colour > 0 && Spaces.colours.indices.contains(colour) ? .colour(colour) : nil
    }
}

// MARK: - OKLab

/// A colour in Björn Ottosson's OKLab: L from black (0) to white (1), a and
/// b its two opponent axes. Even steps in it look even, which sRGB's don't.
struct OKLab: Equatable {
    var L: Double
    var a: Double
    var b: Double

    init(L: Double, a: Double, b: Double) { self.L = L; self.a = a; self.b = b }

    init(lightness: Double, chroma: Double, hue degrees: Double) {
        let h = degrees * .pi / 180
        self.init(L: lightness, a: chroma * cos(h), b: chroma * sin(h))
    }

    init(r: Double, g: Double, b blue: Double) {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (lr, lg, lb) = (linear(r), linear(g), linear(blue))
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    /// "#RRGGBB" or "RRGGBB"; nil for anything else.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, text.allSatisfy(\.isHexDigit), let value = UInt32(text, radix: 16) else { return nil }
        self.init(r: Double((value >> 16) & 0xFF) / 255, g: Double((value >> 8) & 0xFF) / 255, b: Double(value & 0xFF) / 255)
    }

    var chroma: Double { (a * a + b * b).squareRoot() }

    /// WCAG's relative luminance, 0 (black) to 1 (white).
    var luminance: Double {
        let (r, g, b) = linear
        func clamp(_ c: Double) -> Double { min(max(c, 0), 1) }
        return 0.2126 * clamp(r) + 0.7152 * clamp(g) + 0.0722 * clamp(b)
    }

    /// Whether the dark window's ink (Palette.ink's 0.93 grey) reads better
    /// on `ground` than the light window's (its 0.09 grey).
    static func prefersLightInk(_ ground: OKLab) -> Bool {
        func grey(_ white: Double) -> Double { OKLab(r: white, g: white, b: white).luminance }
        func contrast(_ x: Double, _ y: Double) -> Double { (max(x, y) + 0.05) / (min(x, y) + 0.05) }
        let y = ground.luminance
        return contrast(y, grey(0.93)) > contrast(y, grey(0.09))
    }

    /// Linear sRGB, unclamped: outside 0…1 is outside what sRGB can show.
    var linear: (Double, Double, Double) {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    private var inGamut: Bool {
        let (r, g, b) = linear
        let e = 1e-6
        return r >= -e && r <= 1 + e && g >= -e && g <= 1 + e && b >= -e && b <= 1 + e
    }

    /// Gamma-encoded sRGB, 0…1. A colour sRGB can't show keeps its
    /// lightness and hue and loses only as much chroma as it must.
    var srgb: (Double, Double, Double) {
        var colour = self
        if !inGamut {
            var low = 0.0, high = 1.0
            for _ in 0..<16 {
                let mid = (low + high) / 2
                if OKLab(L: L, a: a * mid, b: b * mid).inGamut { low = mid } else { high = mid }
            }
            colour = OKLab(L: L, a: a * low, b: b * low)
        }
        func encode(_ c: Double) -> Double {
            let c = min(max(c, 0), 1)
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        let (r, g, b) = colour.linear
        return (encode(r), encode(g), encode(b))
    }

    var hex: String {
        let (r, g, b) = srgb
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// The band a wash colour is held to: the plain colours' own, about
    /// 0.6 to 0.8. A near-black or near-white washed at their strength
    /// would move the ground as far as the grey of the live tab is from it.
    static let lightnessBand = 0.56...0.80
    static let mostChroma = 0.20

    var held: OKLab {
        let lightness = min(max(L, Self.lightnessBand.lowerBound), Self.lightnessBand.upperBound)
        let scale = chroma > Self.mostChroma ? Self.mostChroma / chroma : 1
        return OKLab(L: lightness, a: a * scale, b: b * scale)
    }

    /// Between `self` and `other` at t: straight across OKLab for the hue,
    /// with the chroma going evenly from one end's to the other's, so the
    /// middle is no greyer than the ends.
    func mix(_ other: OKLab, _ t: Double) -> OKLab {
        var out = OKLab(L: L + (other.L - L) * t, a: a + (other.a - a) * t, b: b + (other.b - b) * t)
        let wanted = chroma + (other.chroma - chroma) * t
        let has = out.chroma
        if has > 1e-4 { out.a *= wanted / has; out.b *= wanted / has }
        return out
    }

    /// Along a run of colours, evenly spaced, at t in 0…1.
    static func along(_ colours: [OKLab], at t: Double) -> OKLab {
        guard colours.count > 1 else { return colours.first ?? OKLab(L: 0.7, a: 0, b: 0) }
        let spot = min(max(t, 0), 1) * Double(colours.count - 1)
        let at = min(Int(spot), colours.count - 2)
        return colours[at].mix(colours[at + 1], spot - Double(at))
    }
}

// MARK: - drawing

/// The window's size, for a gradient to run across the whole of it (see
/// SpaceGradient.points). Zero off screen, where each draws its own.
private struct WashRoomKey: EnvironmentKey {
    static let defaultValue = CGSize.zero
}

/// How strongly the space on screen washes the chrome, set once for the
/// whole window beside washRoom, so every SpaceWash draws alike.
private struct WashStrengthKey: EnvironmentKey {
    static let defaultValue = SpaceStrength.subtle
}

extension EnvironmentValues {
    var washRoom: CGSize {
        get { self[WashRoomKey.self] }
        set { self[WashRoomKey.self] = newValue }
    }

    var washStrength: SpaceStrength {
        get { self[WashStrengthKey.self] }
        set { self[WashStrengthKey.self] = newValue }
    }
}

/// A space's gradient, at the wash's strength, and its grain.
struct GradientWash: View {
    let gradient: SpaceGradient
    let strength: SpaceStrength
    @Environment(\.washRoom) private var room
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let ends = gradient.points(frame: geo.frame(in: .global), room: room)
            let dark = scheme == .dark
            ZStack {
                if let exact = gradient.exact {
                    // A colour of one's own: as picked, solid.
                    exact
                } else {
                    LinearGradient(stops: gradient.stops(strength: strength, dark: dark), startPoint: ends.start, endPoint: ends.end)
                        .opacity(strength.opacity(dark: dark))
                }
                if gradient.grain {
                    Image(nsImage: Grain.tile)
                        .resizable(resizingMode: .tile)
                        .opacity(strength.grain(dark: dark))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The grain: noise, half lighter and half darker than what is under it,
/// in one tile made the first time it is wanted, and tiled. Never moves.
enum Grain {
    /// How much of the tile shows. Faint enough to be felt, not seen as dots.
    static let light = 0.035
    static let dark = 0.04

    @MainActor static let tile: NSImage = {
        let side = 128
        // The same noise every launch: a little generator of our own.
        var seed: UInt32 = 0x9E3779B9
        func next() -> Double {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            return Double(seed) / Double(UInt32.max)
        }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: side * 4, bitsPerPixel: 32)
        if let pixels = rep?.bitmapData {
            for i in 0..<(side * side) {
                // Premultiplied: white or black, by how far from the middle.
                let v = next() * 2 - 1
                let alpha = UInt8(min(abs(v), 1) * 255)
                let ink: UInt8 = v > 0 ? alpha : 0
                pixels[i * 4] = ink; pixels[i * 4 + 1] = ink; pixels[i * 4 + 2] = ink; pixels[i * 4 + 3] = alpha
            }
        }
        // Two pixels a point: one grain to a pixel on a Retina screen.
        let image = NSImage(size: NSSize(width: side / 2, height: side / 2))
        if let rep { image.addRepresentation(rep) }
        return image
    }()
}

// MARK: - choosing

/// What a space wears, as the picker names it: nothing, one of the colours,
/// one of the ready-made gradients, a gradient of one's own, or a colour of
/// one's own (any colour at all, picked in the field; kept as a gradient
/// whose colours are all that one, so it is drawn, held and saved as every
/// gradient is).
enum SpaceLookChoice: Equatable {
    case none
    case colour(Int)
    case preset(Int)
    case custom
    case customColour
}

extension Space {
    var lookChoice: SpaceLookChoice {
        if let gradient, gradient.usable {
            if gradient.single != nil { return .customColour }
            let at = SpaceGradient.presets.firstIndex { $0.gradient.colours == gradient.colours }
            return at.map(SpaceLookChoice.preset) ?? .custom
        }
        return colour > 0 && Spaces.colours.indices.contains(colour) ? .colour(colour) : .none
    }

    /// What the picker's preview says it is.
    var lookName: String {
        switch lookChoice {
        case .none: return "No colour"
        case .colour(let colour): return Spaces.colourNames[colour]
        case .preset(let at): return SpaceGradient.presets[at].name
        case .custom: return "Custom gradient"
        case .customColour: return gradient?.single ?? "Custom colour"
        }
    }
}

extension Browser {
    /// A choice in the picker, made to the space at once: the window is the
    /// preview. A colour (or none) takes the gradient away; a ready-made
    /// gradient keeps the direction and grain the space's gradient had.
    func chooseLook(_ id: UUID, _ choice: SpaceLookChoice) {
        guard let space = spaces.first(where: { $0.id == id }) else { return }
        let current = space.gradient.flatMap { $0.usable ? $0 : nil }
        switch choice {
        case .none: setSpaceColour(id, to: 0)
        case .colour(let colour): setSpaceColour(id, to: colour)
        case .preset(let at):
            guard SpaceGradient.presets.indices.contains(at) else { return }
            setSpaceGradient(id, to: SpaceGradient(colours: SpaceGradient.presets[at].gradient.colours,
                                                   angle: current?.angle ?? SpaceGradient.defaultAngle,
                                                   grain: current?.grain ?? false))
        case .custom:
            setSpaceGradient(id, to: current ?? SpaceGradient.starting(from: space.colour))
        case .customColour:
            chooseCustomColour(id, current?.single ?? current?.colours.first ?? SpaceGradient.swatches[7].hex)
        }
    }

    /// A colour of one's own, any "#RRGGBB": the field's pick.
    func chooseCustomColour(_ id: UUID, _ hex: String) {
        guard OKLab(hex: hex) != nil, let space = spaces.first(where: { $0.id == id }) else { return }
        let current = space.gradient.flatMap { $0.usable ? $0 : nil }
        setSpaceGradient(id, to: SpaceGradient(colours: [hex, hex], angle: current?.angle ?? SpaceGradient.defaultAngle,
                                               grain: current?.grain ?? false))
    }

    /// The space's own gradient changed by `change`: its current one, or a
    /// first one from its colour.
    func editGradient(_ id: UUID, _ change: (inout SpaceGradient) -> Void) {
        guard let space = spaces.first(where: { $0.id == id }) else { return }
        var gradient = space.gradient.flatMap { $0.usable ? $0 : nil } ?? SpaceGradient.starting(from: space.colour)
        change(&gradient)
        setSpaceGradient(id, to: gradient)
    }

    /// Back to a look as it was: Escape in the picker.
    func restoreLook(_ id: UUID, colour: Int, gradient: SpaceGradient?, strength: SpaceStrength? = nil) {
        setSpaceColour(id, to: colour)
        if gradient != nil { setSpaceGradient(id, to: gradient) }
        setSpaceStrength(id, to: strength ?? .subtle)
    }
}

// MARK: - the picker

/// The solid colours used by both the Space and tab group pickers.
struct ColourSwatches: View {
    let selected: Int?
    let choose: (Int) -> Void
    static let dot: CGFloat = 22

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Spaces.colours.indices, id: \.self) { index in
                Self.swatch(selected: selected == index, name: Spaces.colourNames[index],
                            action: { choose(index) }) {
                    if index == 0 {
                        ZStack {
                            Circle().strokeBorder(Palette.faint, lineWidth: 1)
                            Rectangle().fill(Palette.faint).frame(width: 1, height: Self.dot - 4)
                                .rotationEffect(.degrees(45))
                        }
                    } else {
                        Circle().fill(Spaces.colours[index])
                    }
                }
            }
        }
    }

    /// One size for every choice: the dot, and a ring round the one chosen.
    static func swatch(selected: Bool, name: String, action: @escaping () -> Void,
                        @ViewBuilder _ fill: () -> some View) -> some View {
        Button(action: action) {
            fill()
                .frame(width: Self.dot, height: Self.dot)
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Palette.ink.opacity(0.75) : .clear, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Colour…: everything a space can wear, in one popover by its icon. At the
/// top, the space's icon on its look and the look's name; under it the
/// colours with None, then the ready-made gradients, then a gradient of
/// one's own, folded until wanted. The ring is on what the space has. Every
/// pick is made to the space at once, so the window is the preview too; a
/// click elsewhere keeps it, Escape puts back what was there.
struct SpaceLookPicker: View {
    @ObservedObject var browser: Browser
    let id: UUID
    @State private var customOpen: Bool
    @State private var fieldOpen: Bool
    /// The colour the swatches below the wells set.
    @State private var well = 0

    static let width: CGFloat = 288

    init(browser: Browser, id: UUID, customOpen: Bool? = nil) {
        self.browser = browser
        self.id = id
        let space = browser.spaces.first { $0.id == id } ?? browser.space
        _customOpen = State(initialValue: customOpen ?? (space.lookChoice == .custom))
        _fieldOpen = State(initialValue: space.lookChoice == .customColour)
    }

    private var space: Space { browser.spaces.first { $0.id == id } ?? browser.space }
    private var choice: SpaceLookChoice { space.lookChoice }
    private var solidColour: Int? {
        switch choice {
        case .none: return 0
        case .colour(let index): return index
        default: return nil
        }
    }
    /// The gradient the custom part shows: the space's, or the one a first
    /// change would make.
    private var shownGradient: SpaceGradient {
        space.gradient.flatMap { $0.usable ? $0 : nil } ?? SpaceGradient.starting(from: space.colour)
    }

    static let directions: [(angle: Double, symbol: String, name: String)] = [
        (0, "arrow.up", "Up"), (45, "arrow.up.right", "Up and right"), (90, "arrow.right", "Right"),
        (135, "arrow.down.right", "Down and right"), (180, "arrow.down", "Down"), (225, "arrow.down.left", "Down and left"),
        (270, "arrow.left", "Left"), (315, "arrow.up.left", "Up and left"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            preview

            section("Colour") {
                ColourSwatches(selected: solidColour) { index in
                    browser.chooseLook(id, index == 0 ? .none : .colour(index))
                }
            }

            section("Gradient") {
                HStack(spacing: 10) {
                    ForEach(SpaceGradient.presets.indices, id: \.self) { at in
                        let preset = SpaceGradient.presets[at]
                        ColourSwatches.swatch(selected: choice == .preset(at), name: preset.name,
                                              action: { browser.chooseLook(id, .preset(at)) }) {
                            Circle().fill(LinearGradient(stops: preset.gradient.stops(count: 8),
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                    }
                }
            }

            section("Strength") { strengthControl }

            // With the window as glass (Settings › Appearance › Window ›
            // Glass): how much of the colour lies over it, and its grain.
            // For every space alike, as the glass is the window's.
            if browser.prefs.glass {
                section("Glass") {
                    VStack(alignment: .leading, spacing: 10) {
                        GlassSlider(name: "Transparency", value: Binding(get: { browser.prefs.glassClear }, set: { browser.prefs.glassClear = $0 }))
                        GlassSlider(name: "Grain", value: Binding(get: { browser.prefs.glassGrain }, set: { browser.prefs.glassGrain = $0 }))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                fold("Custom colour", open: $fieldOpen, chosen: choice == .customColour)
                if fieldOpen {
                    ColourField(hex: fieldHex) { hex in browser.chooseCustomColour(id, hex) }
                        .transition(.opacity)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                fold("Custom gradient", open: $customOpen, chosen: choice == .custom)
                if customOpen { custom.transition(.opacity) }
            }
        }
        .padding(16)
        .frame(width: Self.width, alignment: .leading)
    }

    // MARK: pieces

    /// White on the colours and gradients, which are held light enough for
    /// it; on a colour of one's own, whichever ink reads on it.
    private var previewInk: Color {
        choice == .customColour && shownGradient.scheme == .light ? Color.black.opacity(0.85) : .white
    }

    private var previewShadow: Double {
        choice == .none || (choice == .customColour && shownGradient.scheme == .light) ? 0 : 0.18
    }

    /// What the colour field starts on: the space's own colour if it has
    /// one, else the colour or gradient it wears, else blue.
    private var fieldHex: String {
        if let gradient = space.gradient, gradient.usable { return gradient.single ?? gradient.colours[0] }
        if case .colour(let index) = choice {
            let names = ["", "Blue", "Green", "Orange", "Red", "Violet"]
            if names.indices.contains(index), let hex = SpaceGradient.swatches.first(where: { $0.name == names[index] })?.hex { return hex }
        }
        return SpaceGradient.swatches[7].hex
    }

    /// A folded part's heading: a chevron, its name, and a dot when what
    /// it makes is what the space has.
    private func fold(_ title: String, open: Binding<Bool>, chosen: Bool) -> some View {
        Button {
            withAnimation(Motion.quick) { open.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                if chosen {
                    Circle().fill(Palette.ink.opacity(0.7)).frame(width: 5, height: 5)
                        .accessibilityLabel("Chosen")
                }
            }
            .foregroundStyle(Palette.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The space's icon on its look, as large as the eye needs to see which
    /// it is, and the look's name.
    private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return ZStack(alignment: .bottomLeading) {
            switch choice {
            case .none: shape.fill(Palette.hover)
            case .colour(let colour): shape.fill(Spaces.colours[colour])
            case .customColour:
                shape.fill(shownGradient.exact ?? Palette.hover)
            case .preset, .custom:
                let ends = shownGradient.points(frame: CGRect(x: 0, y: 0, width: 1, height: 1), room: .zero)
                shape.fill(LinearGradient(stops: shownGradient.stops(), startPoint: ends.start, endPoint: ends.end))
                    .overlay {
                        if shownGradient.grain {
                            Image(nsImage: Grain.tile).resizable(resizingMode: .tile).opacity(0.10).clipShape(shape)
                        }
                    }
            }
            Image(systemName: space.symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(choice == .none ? Palette.muted : previewInk)
                .shadow(color: .black.opacity(previewShadow), radius: 2, y: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(space.lookName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(choice == .none ? Palette.muted : previewInk.opacity(0.92))
                .shadow(color: .black.opacity(previewShadow), radius: 2, y: 1)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
        .frame(height: 76)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(space.name): \(space.lookName)")
    }

    /// Subtle, Rich or Vivid, for the colour and the gradient alike, in
    /// the same small segmented row as the gradient's directions. With no
    /// colour there is nothing to strengthen: shown, but not to be had.
    private var strengthControl: some View {
        let current = space.washStrength
        let off = choice == .none || choice == .customColour
        return HStack(spacing: 0) {
            ForEach(SpaceStrength.allCases, id: \.self) { strength in
                let on = current == strength
                Button { browser.setSpaceStrength(id, to: strength) } label: {
                    Text(strength.name)
                        .font(.system(size: 11, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? Palette.ink : Palette.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Palette.ground)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(strength.name)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.hover))
        .opacity(off ? 0.45 : 1)
        .disabled(off)
        .help(choice == .customColour ? "A colour of your own is shown exactly as picked"
              : off ? "Choose a colour or a gradient first" : "How strongly the space's colour shows")
    }

    private var custom: some View {
        let gradient = shownGradient
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ForEach(gradient.colours.indices, id: \.self) { index in
                    ColourSwatches.swatch(selected: well == index, name: "Colour \(index + 1)", action: { well = index }) {
                        Circle().fill(colour(gradient.colours[index]))
                    }
                }
                if gradient.colours.count < SpaceGradient.most {
                    round("plus", "Add a Colour") {
                        browser.editGradient(id) { $0.colours.append($0.colours.last ?? SpaceGradient.swatches[0].hex) }
                        well = min(gradient.colours.count, SpaceGradient.most - 1)
                    }
                } else {
                    round("minus", "Remove the Last Colour") {
                        browser.editGradient(id) { $0.colours.removeLast() }
                        well = min(well, gradient.colours.count - 2)
                    }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(ColourSwatches.dot), spacing: 10), count: 7), alignment: .leading, spacing: 10) {
                ForEach(SpaceGradient.swatches, id: \.hex) { pick in
                    let on = gradient.colours.indices.contains(well) && gradient.colours[well] == pick.hex
                    Button {
                        browser.editGradient(id) { if $0.colours.indices.contains(well) { $0.colours[well] = pick.hex } }
                    } label: {
                        Circle().fill(colour(pick.hex))
                            .frame(width: ColourSwatches.dot, height: ColourSwatches.dot)
                            .overlay {
                                if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(pick.name)
                    .accessibilityLabel(pick.name)
                }
            }
            HStack(spacing: 0) {
                ForEach(Self.directions, id: \.angle) { direction in
                    let on = Int(gradient.angle.rounded()) == Int(direction.angle)
                    Button { browser.editGradient(id) { $0.angle = direction.angle } } label: {
                        Image(systemName: direction.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(on ? Palette.ink : Palette.muted)
                            .frame(width: 30, height: 22)
                            .background {
                                if on {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Palette.ground)
                                        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(direction.name)
                    .accessibilityLabel(direction.name)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.hover))
            // On glass the glass's own Grain, above, is the grain there is.
            if !browser.glassy {
                HStack {
                    Text("Grain").font(.system(size: 12)).foregroundStyle(Palette.ink)
                    Spacer()
                    Toggle("Grain", isOn: Binding(get: { gradient.grain }, set: { on in browser.editGradient(id) { $0.grain = on } }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            content()
        }
    }

    private func round(_ symbol: String, _ name: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Palette.muted)
                .frame(width: ColourSwatches.dot, height: ColourSwatches.dot)
                .background(Circle().fill(Palette.hover))
                .padding(3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
    }

    private func colour(_ hex: String) -> Color {
        guard let lab = OKLab(hex: hex) else { return .gray }
        let (r, g, b) = lab.srgb
        return Color(.sRGB, red: r, green: g, blue: b)
    }
}

/// Any colour at all, picked as a web page's <input type=color> picks one:
/// a field of saturation across and brightness down for the hue chosen in
/// the bar under it, and the colour's hex to read or type. Dragging moves
/// the space's colour with it, a few times a second so spaces.json isn't
/// written at every pixel, and once more where the drag ends.
struct ColourField: View {
    /// The colour the space has, "#RRGGBB": the field follows it when it
    /// changes from elsewhere.
    let hex: String
    let choose: (String) -> Void

    @State private var hue: Double = 0.6
    @State private var saturation: Double = 0.6
    @State private var brightness: Double = 0.8
    @State private var text = ""
    @State private var dragging = false
    @State private var lastSent = Date.distantPast

    static let fieldHeight: CGFloat = 132
    static let barHeight: CGFloat = 12

    private var picked: Color { Color(hue: hue, saturation: saturation, brightness: brightness) }

    private var pickedHex: String {
        let colour = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
            .usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X", Int((colour.redComponent * 255).rounded()),
                      Int((colour.greenComponent * 255).rounded()), Int((colour.blueComponent * 255).rounded()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            field
            bar
            HStack(spacing: 8) {
                Circle().fill(picked)
                    .frame(width: ColourSwatches.dot, height: ColourSwatches.dot)
                    .overlay(Circle().strokeBorder(Palette.faint, lineWidth: 1))
                TextField("#RRGGBB", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 96)
                    .onSubmit { typed() }
                    .accessibilityLabel("Hex colour")
                Spacer(minLength: 0)
            }
        }
        .onAppear { take(hex) }
        .onChange(of: hex) { _, now in if !dragging, now.uppercased() != pickedHex { take(now) } }
    }

    /// Saturation from left to right, brightness from top to bottom.
    private var field: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(hue: hue, saturation: 1, brightness: 1))
                LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                Circle()
                    .strokeBorder(.white, lineWidth: 2)
                    .background(Circle().fill(picked))
                    .shadow(color: .black.opacity(0.35), radius: 1.5)
                    .frame(width: 14, height: 14)
                    .offset(x: saturation * size.width - 7, y: (1 - brightness) * size.height - 7)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.faint, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    saturation = min(max(drag.location.x / max(size.width, 1), 0), 1)
                    brightness = 1 - min(max(drag.location.y / max(size.height, 1), 0), 1)
                    moved(final: false)
                }
                .onEnded { _ in moved(final: true) })
        }
        .frame(height: Self.fieldHeight)
        .accessibilityElement()
        .accessibilityLabel("Saturation and brightness")
        .accessibilityValue(pickedHex)
    }

    /// The hues, red round to red.
    private var bar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Color(hue: $0, saturation: 1, brightness: 1) },
                                              startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().strokeBorder(Palette.faint, lineWidth: 1))
                Circle()
                    .strokeBorder(.white, lineWidth: 2)
                    .background(Circle().fill(Color(hue: hue, saturation: 1, brightness: 1)))
                    .shadow(color: .black.opacity(0.35), radius: 1.5)
                    .frame(width: Self.barHeight + 4, height: Self.barHeight + 4)
                    .offset(x: hue * (width - Self.barHeight - 4))
                    .allowsHitTesting(false)
            }
            .frame(height: Self.barHeight + 4)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    hue = min(max(drag.location.x / max(width, 1), 0), 0.9999)
                    moved(final: false)
                }
                .onEnded { _ in moved(final: true) })
        }
        .frame(height: Self.barHeight + 4)
        .accessibilityElement()
        .accessibilityLabel("Hue")
        .accessibilityValue("\(Int((hue * 360).rounded())) degrees")
        .accessibilityAdjustableAction { direction in
            hue = (hue + (direction == .increment ? 1.0 : -1.0) / 36 + 1).truncatingRemainder(dividingBy: 1)
            moved(final: true)
        }
    }

    private func moved(final: Bool) {
        dragging = !final
        text = pickedHex
        let now = Date()
        guard final || now.timeIntervalSince(lastSent) > 0.12 else { return }
        lastSent = now
        choose(pickedHex)
    }

    private func typed() {
        var entry = text.trimmingCharacters(in: .whitespaces).uppercased()
        if !entry.hasPrefix("#") { entry = "#" + entry }
        // #RGB is #RRGGBB, as on the web.
        if entry.count == 4 { entry = "#" + entry.dropFirst().map { "\($0)\($0)" }.joined() }
        guard OKLab(hex: entry) != nil else { text = pickedHex; return }
        take(entry)
        choose(entry)
    }

    private func take(_ hex: String) {
        guard let lab = OKLab(hex: hex) else { return }
        let (r, g, b) = lab.srgb
        let colour = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        // A grey has no hue of its own: keep the one the bar is on.
        if colour.saturationComponent > 0.001 { hue = colour.hueComponent }
        saturation = colour.saturationComponent
        brightness = colour.brightnessComponent
        text = hex.uppercased()
    }
}

/// The picker, shown by the space's icon where its menu was opened.
@MainActor
enum SpaceLookPopover {
    private final class Watch: NSObject, NSPopoverDelegate {
        var keys: Any?
        func popoverDidClose(_ notification: Notification) {
            if let keys { NSEvent.removeMonitor(keys) }
            keys = nil
            SpaceLookPopover.shown = nil
        }
    }

    fileprivate static var shown: NSPopover?
    private static let watch = Watch()
    /// Where the space's menu was last opened, on screen: the icon.
    static var anchor: NSPoint?

    static func show(for browser: Browser) {
        // A probe's window is never shown (Tests/space_gradient.py chooses
        // through the bench), and a popover is a window.
        guard ProcessInfo.processInfo.environment["SEARCH_PROBE"] == nil,
              let window = browser.window, window.isVisible, let content = window.contentView else { return }
        shown?.close()
        let space = browser.space
        let before = (colour: space.colour, gradient: space.gradient, strength: space.strength)
        let host = NSHostingController(rootView: SpaceLookPicker(browser: browser, id: space.id))
        host.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = !Motion.instant
        popover.delegate = watch
        shown = popover
        // Escape puts back what the space had; a click elsewhere keeps it.
        watch.keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak browser, weak popover] event in
            guard event.keyCode == 53, let popover, event.window === popover.contentViewController?.view.window else { return event }
            browser?.restoreLook(space.id, colour: before.colour, gradient: before.gradient, strength: before.strength)
            popover.close()
            return nil
        }

        let flipped = content.isFlipped
        var spot: NSRect
        if let anchor {
            let point = content.convert(window.convertPoint(fromScreen: anchor), from: nil)
            spot = NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
        } else {
            let bounds = content.bounds
            spot = NSRect(x: bounds.minX + 24, y: flipped ? bounds.maxY - 24 : bounds.minY + 24, width: 1, height: 1)
        }
        if !content.bounds.contains(spot.origin) { spot.origin = NSPoint(x: content.bounds.midX, y: content.bounds.midY) }
        let edge: NSRectEdge = browser.prefs.sidebar
            ? (browser.prefs.sidePosition == .right ? .minX : .maxX)
            : (flipped ? .maxY : .minY)
        popover.show(relativeTo: spot, of: content, preferredEdge: edge)
    }
}

/// One of the glass's amounts: its name, and under it a plain slider as
/// wide as there is room for.
struct GlassSlider: View {
    let name: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
            Slider(value: $value, in: 0...1)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(name)
        }
    }
}
