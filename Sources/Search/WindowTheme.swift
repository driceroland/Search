import SwiftUI
import AppKit

// The window tint spans the sidebar, bookmarks bar and the frame around
// the page. Its gradient runs across the whole window so the colour lines
// up between those surfaces. Full strength draws the selected sRGB colours
// directly. The softer strengths tone them before blending with the chrome.

struct ThemeGradient: Codable, Equatable, Hashable {
    /// The colours in the order they run, "#RRGGBB" in sRGB: two or three.
    var colours: [String]
    /// The way it runs, in degrees as CSS has them: 0 up, 90 right, 180 down.
    var angle: Double
    /// A faint, still grain over it.
    var grain: Bool

    static let defaultAngle: Double = 135
    static let most = 3

    init(colours: [String], angle: Double = ThemeGradient.defaultAngle, grain: Bool = false) {
        self.colours = colours
        self.angle = angle
        self.grain = grain
    }

    private enum CodingKeys: String, CodingKey { case colours, angle, grain }

    /// Never fails: a gradient that doesn't read is no gradient (see
    /// `usable`), and the colour stands. Failing here would fail the whole
    /// theme.
    init(from decoder: Decoder) throws {
        let fields = try? decoder.container(keyedBy: CodingKeys.self)
        colours = (try? fields?.decodeIfPresent([String].self, forKey: .colours)) ?? []
        angle = (try? fields?.decodeIfPresent(Double.self, forKey: .angle)).flatMap { $0?.isFinite == true ? $0 : nil } ?? Self.defaultAngle
        grain = (try? fields?.decodeIfPresent(Bool.self, forKey: .grain)) ?? false
    }

    /// The colours as drawn: the first three that read, each held to the
    /// wash's band of lightness and chroma.
    var drawn: [OKLab] { sourceColours.map(\.held) }

    private var sourceColours: [OKLab] {
        Array(colours.lazy.compactMap(OKLab.init(hex:)).prefix(Self.most))
    }

    /// Two colours or more that read; otherwise the colour stands.
    var usable: Bool { sourceColours.count >= 2 }

    /// What the gradient is drawn with: its colours mixed in OKLab at
    /// `count` stops, evenly spaced. SwiftUI blends between neighbours,
    /// which are close enough that how it blends doesn't show.
    func stops(count: Int = 24, strength: ThemeStrength = .subtle, dark: Bool = false) -> [Gradient.Stop] {
        let lab = strength == .full ? sourceColours : drawn.map { strength.tone($0, dark: dark) }
        guard lab.count >= 2 else { return [] }
        return (0..<count).map { step in
            let t = Double(step) / Double(count - 1)
            let (r, g, b) = OKLab.along(lab, at: t).srgb
            return Gradient.Stop(color: Color(.sRGB, red: r, green: g, blue: b), location: t)
        }
    }

    /// Its first colour as drawn.
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

    static let presets: [(name: String, gradient: ThemeGradient)] = [
        ("Sunrise", ThemeGradient(colours: [swatch("Amber"), swatch("Pink")])),
        ("Lagoon", ThemeGradient(colours: [swatch("Teal"), swatch("Blue")])),
        ("Orchard", ThemeGradient(colours: [swatch("Lime"), swatch("Teal")])),
        ("Dusk", ThemeGradient(colours: [swatch("Indigo"), swatch("Magenta"), swatch("Orange")])),
        ("Glacier", ThemeGradient(colours: [swatch("Cyan"), swatch("Indigo")])),
        ("Ember", ThemeGradient(colours: [swatch("Red"), swatch("Amber")])),
    ]

    /// A first gradient from a colour: that colour, if there is one, into the
    /// hue beside it; Lagoon otherwise.
    static func starting(from colour: Int) -> ThemeGradient {
        let from = ["", "Blue", "Green", "Orange", "Red", "Violet"]
        let to = ["", "Violet", "Teal", "Pink", "Amber", "Pink"]
        guard from.indices.contains(colour), colour > 0 else { return presets[1].gradient }
        return ThemeGradient(colours: [swatch(from[colour]), swatch(to[colour])])
    }
}

/// The window tint's coverage. Full uses an opaque tint and the original colours.
enum ThemeStrength: String, CaseIterable, Codable, Hashable {
    case subtle, rich, vivid, full

    var name: String {
        switch self {
        case .subtle: return "Subtle"
        case .rich: return "Rich"
        case .vivid: return "Vivid"
        case .full: return "Full"
        }
    }

    /// Never fails: a strength a newer Search writes, or one that doesn't
    /// read, is Subtle. Failing here would fail the whole theme.
    init(from decoder: Decoder) throws {
        let text = try? decoder.singleValueContainer().decode(String.self)
        self = text.flatMap(ThemeStrength.init(rawValue:)) ?? .subtle
    }

    /// How much of the colour the chrome wears. Subtle is the colour's
    /// wash as it always was (Tints.washLight, washDark).
    func opacity(dark: Bool) -> Double {
        switch self {
        case .subtle: return dark ? Tints.washDark : Tints.washLight
        case .rich: return dark ? 0.22 : 0.18
        case .vivid: return dark ? 0.40 : 0.30
        case .full: return 1
        }
    }

    /// The colour as this strength washes with it: more chroma, and its
    /// lightness held so the washed ground stays light in a light window
    /// (Vivid: no darker than 0.62) and deep in a dark one (Rich: no
    /// lighter than 0.72, Vivid: 0.48 to 0.58). Subtle is the colour as held.
    func tone(_ colour: OKLab, dark: Bool) -> OKLab {
        let (boost, band): (Double, ClosedRange<Double>) = {
            switch self {
            case .subtle, .full: return (1, 0...1)
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
        case .vivid, .full: return base * 1.5
        }
    }
}

/// The colour of the whole browser, set once in Settings › Themes, as Arc
/// colours its window: a colour or a gradient, and how strongly. Nothing
/// set is the look Search always
/// had, and nothing is written for it.
struct BrowserTheme: Codable, Equatable {
    var colour = 0
    var gradient: ThemeGradient?
    var strength = ThemeStrength.subtle

    init() {}

    private enum CodingKeys: String, CodingKey { case colour, gradient, strength }

    /// Never fails: what doesn't read is no colour at all.
    init(from decoder: Decoder) throws {
        let fields = try? decoder.container(keyedBy: CodingKeys.self)
        colour = (try? fields?.decodeIfPresent(Int.self, forKey: .colour)) ?? 0
        gradient = (try? fields?.decodeIfPresent(ThemeGradient.self, forKey: .gradient)) ?? nil
        strength = (try? fields?.decodeIfPresent(ThemeStrength.self, forKey: .strength)) ?? .subtle
    }

    var look: ThemeLook? {
        if let gradient, gradient.usable { return .gradient(gradient) }
        return colour > 0 && Tints.colours.indices.contains(colour) ? .colour(colour) : nil
    }

    static func read(_ text: String?) -> BrowserTheme? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BrowserTheme.self, from: data)
    }

    var text: String {
        let coder = JSONEncoder()
        coder.outputFormatting = [.sortedKeys]
        return (try? coder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// What the chrome is washed with: one of Tints.colours, or a gradient.
/// Nil is nothing at all, the look there always was.
enum ThemeLook: Equatable {
    case colour(Int)
    case gradient(ThemeGradient)
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
/// ThemeGradient.points). Zero off screen, where each draws its own.
private struct WashRoomKey: EnvironmentKey {
    static let defaultValue = CGSize.zero
}

/// How strongly the window's colour washes the chrome, set once for the
/// whole window beside washRoom, so every ThemeWash draws alike.
private struct WashStrengthKey: EnvironmentKey {
    static let defaultValue = ThemeStrength.subtle
}

extension EnvironmentValues {
    var washRoom: CGSize {
        get { self[WashRoomKey.self] }
        set { self[WashRoomKey.self] = newValue }
    }

    var washStrength: ThemeStrength {
        get { self[WashStrengthKey.self] }
        set { self[WashStrengthKey.self] = newValue }
    }
}

/// The window's gradient, at the wash's strength, and its grain.
struct GradientWash: View {
    let gradient: ThemeGradient
    let strength: ThemeStrength
    @Environment(\.washRoom) private var room
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let ends = gradient.points(frame: geo.frame(in: .global), room: room)
            let dark = scheme == .dark
            ZStack {
                LinearGradient(stops: gradient.stops(strength: strength, dark: dark), startPoint: ends.start, endPoint: ends.end)
                    .opacity(strength.opacity(dark: dark))
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

// MARK: - the picker

/// The solid colours a tab group can wear, for its picker.
struct ColourSwatches: View {
    let selected: Int?
    let choose: (Int) -> Void
    static let dot: CGFloat = 22

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Tints.colours.indices, id: \.self) { index in
                Self.swatch(selected: selected == index, name: Tints.colourNames[index],
                            action: { choose(index) }) {
                    if index == 0 {
                        ZStack {
                            Circle().strokeBorder(Palette.faint, lineWidth: 1)
                            Rectangle().fill(Palette.faint).frame(width: 1, height: Self.dot - 4)
                                .rotationEffect(.degrees(45))
                        }
                    } else {
                        Circle().fill(Tints.colours[index])
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

/// The colours the window and tab groups can wear.
enum Tints {
    /// A handful, picked to read on the light ground and the dark one
    /// alike. The first stands for none and is never drawn.
    static let colours: [Color] = [
        Color(red: 0.45, green: 0.47, blue: 0.52), // none
        Color(red: 0.26, green: 0.52, blue: 0.96), // blue
        Color(red: 0.20, green: 0.66, blue: 0.45), // green
        Color(red: 0.96, green: 0.62, blue: 0.20), // orange
        Color(red: 0.90, green: 0.33, blue: 0.40), // red
        Color(red: 0.62, green: 0.40, blue: 0.90), // violet
    ]
    static let colourNames = ["None", "Blue", "Green", "Orange", "Red", "Violet"]

    /// How much of the window's colour the chrome behind the tabs wears: the
    /// column, the strip, the bookmarks bar and the ground around the page's
    /// card, never the page. Faint, as Arc's themes are: enough to see at
    /// the edge of the eye, not so much that a
    /// tab's grey or a title's ink reads any differently. The dark ground
    /// swallows more of a colour, so it takes a little more.
    static let washLight = 0.07
    static let washDark = 0.11

    /// The wash for colour COLOUR, or nil for none: no colour, or an index
    /// out of range from a newer Search. Nil draws nothing at all, so a
    /// window without a colour looks exactly as it always did.
    static func wash(_ colour: Int?, dark: Bool) -> Double? {
        guard let colour, colour > 0, colours.indices.contains(colour) else { return nil }
        return dark ? washDark : washLight
    }

    /// Colour COLOUR as STRENGTH washes with it (ThemeStrength.tone): the
    /// colour itself at Subtle, so that wash is exactly as it always was.
    static func toned(_ colour: Int, _ strength: ThemeStrength, dark: Bool) -> Color {
        guard strength != .subtle, strength != .full, colours.indices.contains(colour),
              let c = NSColor(colours[colour]).usingColorSpace(.sRGB) else { return colours.indices.contains(colour) ? colours[colour] : .clear }
        let (r, g, b) = strength.tone(OKLab(r: c.redComponent, g: c.greenComponent, b: c.blueComponent), dark: dark).srgb
        return Color(.sRGB, red: r, green: g, blue: b)
    }
}

struct ThemeWash: View {
    let look: ThemeLook?
    @Environment(\.colorScheme) private var scheme
    /// Set for the whole window (see washStrength).
    @Environment(\.washStrength) private var strength

    var body: some View {
        ZStack {
            switch look {
            case .colour(let colour)?:
                if Tints.wash(colour, dark: scheme == .dark) != nil {
                    Tints.toned(colour, strength, dark: scheme == .dark).opacity(strength.opacity(dark: scheme == .dark))
                }
            case .gradient(let gradient)?:
                // One gradient for another crossfades, as a colour does.
                GradientWash(gradient: gradient, strength: strength)
                    .id(gradient)
                    .transition(.opacity)
            case nil:
                EmptyView()
            }
        }
        .allowsHitTesting(false)
        .animation(Motion.quick, value: look)
        .animation(Motion.quick, value: strength)
    }
}

extension Browser {
    /// What the chrome is washed with (see Tints.wash): the browser's own
    /// colour or gradient (Settings › Themes), or nothing.
    var wash: ThemeLook? { prefs.browserTheme.look }

    /// How strongly the wash is drawn.
    var washStrength: ThemeStrength { wash == nil ? .subtle : prefs.browserTheme.strength }
}
