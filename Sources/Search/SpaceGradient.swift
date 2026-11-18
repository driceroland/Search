import SwiftUI
import AppKit

// A space's gradient: two or three colours instead of one, the way Arc and
// Ardia theme a space. Only for whoever wants one (the space's menu ›
// Colour › Gradient…): a space without one is washed with its colour, or
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
    func stops(count: Int = 24) -> [Gradient.Stop] {
        let lab = drawn
        guard lab.count >= 2 else { return [] }
        return (0..<count).map { step in
            let t = Double(step) / Double(count - 1)
            let (r, g, b) = OKLab.along(lab, at: t).srgb
            return Gradient.Stop(color: Color(.sRGB, red: r, green: g, blue: b), location: t)
        }
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

extension EnvironmentValues {
    var washRoom: CGSize {
        get { self[WashRoomKey.self] }
        set { self[WashRoomKey.self] = newValue }
    }
}

/// A space's gradient, at the wash's strength, and its grain.
struct GradientWash: View {
    let gradient: SpaceGradient
    let strength: Double
    @Environment(\.washRoom) private var room
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let ends = gradient.points(frame: geo.frame(in: .global), room: room)
            ZStack {
                LinearGradient(stops: gradient.stops(), startPoint: ends.start, endPoint: ends.end)
                    .opacity(strength)
                if gradient.grain {
                    Image(nsImage: Grain.tile)
                        .resizable(resizingMode: .tile)
                        .opacity(scheme == .dark ? Grain.dark : Grain.light)
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

// MARK: - the editor

/// Gradient…: the colours, the way they run and the grain, in a small
/// popover by the space's icon. Every change is made to the space as it is
/// made, so the window itself is the preview; Done (or a click elsewhere)
/// keeps it, Remove Gradient or Cancel gives the space back its colour.
struct GradientEditor: View {
    let apply: (SpaceGradient?) -> Void
    let close: () -> Void
    let hadOne: Bool
    @State private var draft: SpaceGradient
    /// The colour the swatches set.
    @State private var well = 0

    init(start: SpaceGradient, hadOne: Bool, apply: @escaping (SpaceGradient?) -> Void, close: @escaping () -> Void) {
        _draft = State(initialValue: start)
        self.hadOne = hadOne
        self.apply = apply
        self.close = close
    }

    static let directions: [(angle: Double, symbol: String, name: String)] = [
        (0, "arrow.up", "Up"), (45, "arrow.up.right", "Up and right"), (90, "arrow.right", "Right"),
        (135, "arrow.down.right", "Down and right"), (180, "arrow.down", "Down"), (225, "arrow.down.left", "Down and left"),
        (270, "arrow.left", "Left"), (315, "arrow.up.left", "Up and left"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(stops: draft.stops(), startPoint: draft.points(frame: CGRect(x: 0, y: 0, width: 1, height: 1), room: .zero).start,
                                     endPoint: draft.points(frame: CGRect(x: 0, y: 0, width: 1, height: 1), room: .zero).end))
                .overlay {
                    if draft.grain {
                        Image(nsImage: Grain.tile).resizable(resizingMode: .tile).opacity(0.10)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                .frame(height: 52)
                .accessibilityHidden(true)

            HStack(spacing: 10) {
                ForEach(SpaceGradient.presets, id: \.name) { preset in
                    Button { draft.colours = preset.gradient.colours } label: {
                        Circle()
                            .fill(LinearGradient(stops: preset.gradient.stops(count: 8), startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 22, height: 22)
                            .padding(3)
                            .overlay(Circle().strokeBorder(draft.colours == preset.gradient.colours ? Palette.ink.opacity(0.55) : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                    .accessibilityLabel(preset.name)
                }
            }

            section("Colours") {
                HStack(spacing: 8) {
                    ForEach(draft.colours.indices, id: \.self) { index in
                        Button { well = index } label: {
                            Circle()
                                .fill(colour(draft.colours[index]))
                                .frame(width: 20, height: 20)
                                .padding(3)
                                .overlay(Circle().strokeBorder(well == index ? Palette.ink.opacity(0.55) : Palette.hairline, lineWidth: well == index ? 1.5 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Colour \(index + 1)")
                    }
                    Spacer(minLength: 0)
                    if draft.colours.count < SpaceGradient.most {
                        small("plus", "Add a Colour") {
                            draft.colours.append(draft.colours.last ?? SpaceGradient.swatches[0].hex)
                            well = draft.colours.count - 1
                        }
                    } else {
                        small("minus", "Remove the Last Colour") {
                            draft.colours.removeLast()
                            well = min(well, draft.colours.count - 1)
                        }
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 9), count: 7), alignment: .leading, spacing: 9) {
                    ForEach(SpaceGradient.swatches, id: \.hex) { swatch in
                        Button { if draft.colours.indices.contains(well) { draft.colours[well] = swatch.hex } } label: {
                            Circle()
                                .fill(colour(swatch.hex))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
                                .overlay {
                                    if draft.colours.indices.contains(well), draft.colours[well] == swatch.hex {
                                        Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(swatch.name)
                        .accessibilityLabel(swatch.name)
                    }
                }
            }

            section("Direction") {
                HStack(spacing: 2) {
                    ForEach(Self.directions, id: \.angle) { direction in
                        let on = Int(draft.angle.rounded()) == Int(direction.angle)
                        Button { draft.angle = direction.angle } label: {
                            Image(systemName: direction.symbol)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(on ? Palette.ink : Palette.muted)
                                .frame(width: 26, height: 22)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Palette.hover.opacity(0.9) : .clear))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(on ? Palette.hairline : .clear, lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(direction.name)
                        .accessibilityLabel(direction.name)
                    }
                }
            }

            HStack {
                Text("Grain")
                    .font(.system(size: 12))
                Spacer()
                Toggle("Grain", isOn: $draft.grain)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }

            Divider()

            HStack {
                // The space as it was: its colour. Cancel, for one that
                // had no gradient when the editor opened.
                Button(hadOne ? "Remove Gradient" : "Cancel") { apply(nil); close() }
                    .controlSize(.small)
                Spacer()
                Button("Done") { close() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 266)
        .onChange(of: draft) { _, now in apply(now) }
        .onAppear { apply(draft) }
    }

    private func colour(_ hex: String) -> Color {
        guard let lab = OKLab(hex: hex) else { return .gray }
        let (r, g, b) = lab.srgb
        return Color(.sRGB, red: r, green: g, blue: b)
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            content()
        }
    }

    private func small(_ symbol: String, _ name: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Palette.hover))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
    }
}

/// The editor, shown by the space's icon where the menu was opened.
@MainActor
enum GradientPopover {
    private static var shown: NSPopover?
    /// Where the space's menu was last opened, on screen: the icon.
    static var anchor: NSPoint?

    static func show(for browser: Browser) {
        // A probe's window is never shown (Tests/space_gradient.py sets the
        // gradient through the bench), and a popover is a window.
        guard ProcessInfo.processInfo.environment["SEARCH_PROBE"] == nil,
              let window = browser.window, window.isVisible, let content = window.contentView else { return }
        shown?.close()
        let space = browser.space
        let editor = GradientEditor(
            start: space.gradient.flatMap { $0.usable ? $0 : nil } ?? SpaceGradient.starting(from: space.colour),
            hadOne: space.gradient?.usable == true,
            apply: { [weak browser] gradient in browser?.setSpaceGradient(space.id, to: gradient) },
            close: { shown?.close() })
        let host = NSHostingController(rootView: editor)
        host.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = !Motion.instant
        shown = popover

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
        let column = browser.prefs.sidebar
        let edge: NSRectEdge = column
            ? (browser.prefs.sidePosition == .right ? .minX : .maxX)
            : (flipped ? .maxY : .minY)
        popover.show(relativeTo: spot, of: content, preferredEdge: edge)
    }
}
