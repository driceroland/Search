import SwiftUI
import AppKit

/// A painted background behind the blank tab. Off unless asked for.
enum HomeTheme: String, CaseIterable, Identifiable {
    case off, limewash, fresco, mural, terrazzo, botanical, stickers, solid, gradient, custom

    var id: String { rawValue }

    /// The groups the Themes page offers, each with its own presets.
    enum Family: String, CaseIterable, Identifiable {
        case off, wall, stickers, solid, gradient, image
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: return "Off"
            case .wall: return "Wall painting"
            case .stickers: return "Stickers"
            case .solid: return "Solid colour"
            case .gradient: return "Gradient"
            case .image: return "Image"
            }
        }
        /// What choosing the family alone puts on the wall.
        var first: HomeTheme {
            switch self {
            case .off: return .off
            case .wall: return .limewash
            case .stickers: return .stickers
            case .solid: return .solid
            case .gradient: return .gradient
            case .image: return .custom
            }
        }
    }

    var family: Family {
        switch self {
        case .off: return .off
        case .limewash, .fresco, .mural, .terrazzo, .botanical: return .wall
        case .stickers: return .stickers
        case .solid: return .solid
        case .gradient: return .gradient
        case .custom: return .image
        }
    }

    var title: String {
        switch self {
        case .off: return "Off"
        case .limewash: return "Limewash"
        case .fresco: return "Fresco"
        case .mural: return "Mural"
        case .terrazzo: return "Terrazzo"
        case .botanical: return "Botanical"
        case .stickers: return "Stickers"
        case .solid: return "Solid colour"
        case .gradient: return "Gradient"
        case .custom: return "Image"
        }
    }

    /// The five walls (the first family).
    static let walls: [HomeTheme] = [.limewash, .fresco, .mural, .terrazzo, .botanical]

    /// Where a chosen image is kept: a copy, so moving or deleting the
    /// original never leaves the home screen bare.
    static var folder: URL {
        Store.folder.appendingPathComponent("Theme", isDirectory: true)
    }

    /// Copies a picture into the theme folder and returns where it went.
    /// Nil when it can't be copied; the caller then keeps what it had.
    static func keep(_ source: URL) -> String? {
        let files = FileManager.default
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent("home." + (source.pathExtension.isEmpty ? "img" : source.pathExtension))
            // One picture at a time: the old one goes, so none pile up.
            for old in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where old.lastPathComponent.hasPrefix("home.") { try? files.removeItem(at: old) }
            try files.copyItem(at: source, to: target)
            return target.path
        } catch {
            return nil
        }
    }

    /// Drops the kept copy, if any.
    static func forget(_ path: String?) {
        guard let path, path.hasPrefix(folder.path) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Asks for a picture; nil when cancelled or not copied.
    @MainActor
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return keep(url)
    }
}

enum StickerPack: String, CaseIterable, Identifiable, Codable {
    case playful, space, nature
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum GradientPreset: String, CaseIterable, Identifiable {
    case dusk, sea, peach, mint, mono
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colours: (a: String, b: String, angle: Double) {
        switch self {
        case .dusk: return ("#E9B8A0", "#8E86B8", 150)
        case .sea: return ("#BFE0DC", "#5E8FA8", 160)
        case .peach: return ("#FBE0C8", "#F0A58F", 135)
        case .mint: return ("#DDF0DC", "#8FC7AA", 140)
        case .mono: return ("#F1EFEB", "#B9B5AE", 90)
        }
    }
}

/// What the sliders and pickers on the Themes page set, kept as one line of
/// JSON in the settings so a new knob never needs a new key.
struct HomeTuning: Codable, Equatable, Hashable {
    /// 0...1: how far the theme is blended from the plain ground.
    var intensity = 1.0
    /// 0...1: how many stickers, how many terrazzo chips.
    var density = 0.5
    /// 0...1: how big a sticker is.
    var scale = 0.5
    var pack = StickerPack.playful
    var solid = "#E8DFD0"
    var gradientA = "#E9B8A0"
    var gradientB = "#8E86B8"
    var angle = 150.0

    init() {}

    /// Tolerant: a line from another build with fewer or more knobs is read
    /// as far as it goes, and the rest is the default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HomeTuning()
        intensity = (try? c.decodeIfPresent(Double.self, forKey: .intensity)) ?? d.intensity
        density = (try? c.decodeIfPresent(Double.self, forKey: .density)) ?? d.density
        scale = (try? c.decodeIfPresent(Double.self, forKey: .scale)) ?? d.scale
        pack = (try? c.decodeIfPresent(StickerPack.self, forKey: .pack)) ?? d.pack
        solid = (try? c.decodeIfPresent(String.self, forKey: .solid)) ?? d.solid
        gradientA = (try? c.decodeIfPresent(String.self, forKey: .gradientA)) ?? d.gradientA
        gradientB = (try? c.decodeIfPresent(String.self, forKey: .gradientB)) ?? d.gradientB
        angle = (try? c.decodeIfPresent(Double.self, forKey: .angle)) ?? d.angle
    }

    static func read(_ text: String?) -> HomeTuning? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HomeTuning.self, from: data)
    }

    var text: String {
        let coder = JSONEncoder()
        coder.outputFormatting = [.sortedKeys]
        return (try? coder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

extension Color {
    /// "#RRGGBB"; anything else is a mid grey rather than a crash.
    init(hex: String) {
        let c = HomeBackground.channels(hex)
        self.init(red: c.0, green: c.1, blue: c.2)
    }

    var hex: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#888888" }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}

/// A small generator with a fixed seed, so a wall is the same wall on every
/// render: SystemRandomNumberGenerator would give a new one each time.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Renders a theme once into an image and remembers it. Nothing here runs
/// on a timer or per frame: the image is made when the theme, its settings,
/// the size, the appearance or the screen's scale is new, and shown as it is
/// until one of them changes.
@MainActor
enum HomeRender {
    private struct Key: Hashable {
        let theme: HomeTheme, tuning: HomeTuning, width: Int, height: Int
        let dark: Bool, scale: CGFloat, calm: Bool
    }
    private static var made: [Key: NSImage] = [:]

    static func image(_ theme: HomeTheme, _ tuning: HomeTuning, size: CGSize,
                      dark: Bool, scale: CGFloat, calm: Bool) -> NSImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let key = Key(theme: theme, tuning: tuning, width: Int(size.width), height: Int(size.height),
                      dark: dark, scale: scale, calm: calm)
        if let image = made[key] { return image }
        let ground = groundColour(dark: dark)
        let canvas = Canvas { context, size in
            HomeBackground.paint(theme, tuning, in: &context, size: size, dark: dark, ground: ground, calm: calm)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        // A few at a time: a window dragged wide leaves one per step behind.
        if made.count >= 24 { made.removeAll() }
        let image = NSImage(cgImage: cg, size: size)
        made[key] = image
        return image
    }

    /// The window's ground in the given look, resolved now rather than when
    /// drawn, so the render doesn't depend on whichever appearance is current.
    private static func groundColour(dark: Bool) -> Color {
        var colour = Color(white: dark ? 0.1 : 1)
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            if let rgb = Palette.NS.ground.usingColorSpace(.sRGB) { colour = Color(nsColor: rgb) }
        }
        return colour
    }
}

/// The background itself: a rendered image, or the chosen picture.
struct HomeBackground: View {
    let theme: HomeTheme
    var tuning = HomeTuning()
    var image: String?
    /// A thumbnail is drawn at exactly its size and without the calm patch
    /// the address field sits on.
    var thumbnail = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { box in
            ZStack {
                Palette.ground
                switch theme {
                case .off:
                    EmptyView()
                case .custom:
                    if let picture = HomeBackground.load(image) {
                        Image(nsImage: picture)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: box.size.width, height: box.size.height)
                            .clipped()
                        Palette.ground.opacity(1 - shown.intensity)
                        if !thumbnail { calm }
                    }
                default:
                    if let made = HomeRender.image(theme, shown, size: drawn(box.size),
                                                   dark: scheme == .dark, scale: pixels(box.size), calm: !thumbnail) {
                        Image(nsImage: made)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: box.size.width, height: box.size.height)
                            .clipped()
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A preview shows the theme whole and at full strength, so the families
    /// can be told apart; Intensity is for the real background.
    private var shown: HomeTuning {
        var t = tuning
        if thumbnail { t.intensity = 1 }
        return t
    }

    /// A preview is painted as a full-size window would be and shrunk to fit
    /// (so stickers and chips are in proportion, not a cropped corner), at
    /// exactly as many pixels as it will be shown in.
    private static let reference: CGFloat = 480

    private func drawn(_ box: CGSize) -> CGSize {
        guard thumbnail else { return rounded(box) }
        guard box.width > 0 else { return box }
        return CGSize(width: HomeBackground.reference, height: (HomeBackground.reference * box.height / box.width).rounded())
    }

    private func pixels(_ box: CGSize) -> CGFloat {
        thumbnail && box.width > 0 ? scale * box.width / HomeBackground.reference : scale
    }

    private var calm: some View {
        RadialGradient(colors: [Palette.ground.opacity(0.7), Palette.ground.opacity(0)],
                       center: .center, startRadius: 20, endRadius: 360)
    }

    /// Up to the next 64 points, so a window being dragged wider makes one
    /// image per step and not one per pixel.
    private func rounded(_ size: CGSize) -> CGSize {
        guard !thumbnail else { return size }
        return CGSize(width: (size.width / 64).rounded(.up) * 64, height: (size.height / 64).rounded(.up) * 64)
    }

    /// Whether the chosen picture can be read; a missing one is Off.
    static func load(_ path: String?) -> NSImage? {
        guard let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return NSImage(contentsOfFile: path)
    }

    // MARK: - painting

    private typealias RGB = (Double, Double, Double)

    static func channels(_ hex: String) -> (Double, Double, Double) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let n = UInt32(digits, radix: 16) else { return (0.53, 0.53, 0.53) }
        return (Double((n >> 16) & 255) / 255, Double((n >> 8) & 255) / 255, Double(n & 255) / 255)
    }

    private static func colour(_ c: RGB, _ dark: Bool, _ alpha: Double = 1) -> Color {
        // Dark walls are the same pigments, taken down and muted.
        let k = dark ? 0.42 : 1
        return Color(red: c.0 * k, green: c.1 * k, blue: c.2 * k).opacity(alpha)
    }

    private static func blob(_ rng: inout Seeded, in size: CGSize, radius: ClosedRange<CGFloat>) -> CGRect {
        let w = CGFloat.random(in: radius, using: &rng) * max(size.width, size.height)
        let h = w * CGFloat.random(in: 0.5...0.9, using: &rng)
        return CGRect(x: CGFloat.random(in: -0.1...1.0, using: &rng) * size.width - w / 2,
                      y: CGFloat.random(in: -0.1...1.0, using: &rng) * size.height - h / 2,
                      width: w, height: h)
    }

    fileprivate static func paint(_ theme: HomeTheme, _ t: HomeTuning, in context: inout GraphicsContext,
                                  size: CGSize, dark: Bool, ground: Color, calm: Bool) {
        guard size.width > 1, size.height > 1 else { return }
        var rng = Seeded(0xC0FFEE &* UInt64(theme.rawValue.count + 3) &+ UInt64(t.pack.rawValue.count))
        let m = min(size.width, size.height)
        let whole = CGRect(origin: .zero, size: size)
        switch theme {
        case .limewash:
            let tones: [RGB] = [(0.93, 0.89, 0.82), (0.90, 0.85, 0.77), (0.95, 0.92, 0.86), (0.88, 0.82, 0.74)]
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(colour(tones[0], dark)))
            for _ in 0..<46 {
                let r = blob(&rng, in: size, radius: 0.12...0.4)
                let tone = tones[Int.random(in: 0..<tones.count, using: &rng)]
                context.fill(Path(ellipseIn: r), with: .color(colour(tone, dark, 0.28)))
            }
            // Faint brush strokes: long thin slanted lines.
            for _ in 0..<70 {
                let x = CGFloat.random(in: 0...size.width, using: &rng)
                let y = CGFloat.random(in: 0...size.height, using: &rng)
                let len = CGFloat.random(in: 0.08...0.25, using: &rng) * m
                var p = Path()
                p.move(to: CGPoint(x: x, y: y))
                p.addLine(to: CGPoint(x: x + len, y: y - len * 0.12))
                context.stroke(p, with: .color(colour((1, 1, 1), dark, dark ? 0.04 : 0.18)), lineWidth: 1.2)
            }
        case .fresco:
            let tones: [RGB] = [(0.80, 0.52, 0.40), (0.84, 0.68, 0.38), (0.62, 0.70, 0.58), (0.90, 0.82, 0.70)]
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(colour(tones[3], dark)))
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: m * 0.07))
                for i in 0..<9 {
                    let r = blob(&rng, in: size, radius: 0.3...0.6)
                    layer.fill(Path(ellipseIn: r), with: .color(colour(tones[i % 3], dark, 0.55)))
                }
            }
        case .mural:
            let sky: RGB = (0.93, 0.86, 0.72), sun: RGB = (0.86, 0.60, 0.30)
            let teal: RGB = (0.36, 0.55, 0.52), rust: RGB = (0.72, 0.38, 0.28), olive: RGB = (0.55, 0.56, 0.36)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(colour(sky, dark)))
            context.fill(Path(ellipseIn: CGRect(x: size.width * 0.74 - m * 0.16, y: size.height * 0.2 - m * 0.16,
                                                width: m * 0.32, height: m * 0.32)), with: .color(colour(sun, dark)))
            // Arches along the left, hills along the bottom.
            for i in 0..<3 {
                let w = m * 0.2, x = size.width * 0.04 + CGFloat(i) * (w + m * 0.03)
                let h = m * (0.45 + 0.12 * CGFloat(i))
                var arch = Path()
                arch.move(to: CGPoint(x: x, y: size.height))
                arch.addLine(to: CGPoint(x: x, y: size.height - h + w / 2))
                arch.addArc(center: CGPoint(x: x + w / 2, y: size.height - h + w / 2), radius: w / 2,
                            startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                arch.addLine(to: CGPoint(x: x + w, y: size.height))
                arch.closeSubpath()
                context.fill(arch, with: .color(colour(i % 2 == 0 ? rust : teal, dark)))
            }
            for (i, c) in [olive, teal].enumerated() {
                var hill = Path()
                let base = size.height * (0.86 + 0.06 * CGFloat(i))
                hill.move(to: CGPoint(x: 0, y: size.height))
                hill.addLine(to: CGPoint(x: 0, y: base))
                hill.addCurve(to: CGPoint(x: size.width, y: base - m * 0.05),
                              control1: CGPoint(x: size.width * 0.3, y: base - m * (0.2 - 0.1 * CGFloat(i))),
                              control2: CGPoint(x: size.width * 0.65, y: base + m * 0.1))
                hill.addLine(to: CGPoint(x: size.width, y: size.height))
                hill.closeSubpath()
                context.fill(hill, with: .color(colour(c, dark)))
            }
        case .terrazzo:
            let chips: [RGB] = [(0.78, 0.45, 0.36), (0.40, 0.55, 0.50), (0.85, 0.72, 0.45), (0.55, 0.50, 0.55)]
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(colour((0.92, 0.89, 0.84), dark)))
            let count = Int(min(400, max(40, size.width * size.height / 5000 * (0.4 + t.density * 1.2))))
            for _ in 0..<count {
                let c = CGPoint(x: CGFloat.random(in: 0...size.width, using: &rng),
                                y: CGFloat.random(in: 0...size.height, using: &rng))
                let r = CGFloat.random(in: 0.008...0.03, using: &rng) * m
                var p = Path()
                let points = Int.random(in: 5...7, using: &rng)
                for k in 0..<points {
                    let a = Double(k) / Double(points) * 2 * .pi
                    let rr = r * CGFloat.random(in: 0.55...1.2, using: &rng)
                    let pt = CGPoint(x: c.x + rr * CGFloat(cos(a)), y: c.y + rr * 0.8 * CGFloat(sin(a)))
                    k == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
                p.closeSubpath()
                context.fill(p, with: .color(colour(chips[Int.random(in: 0..<chips.count, using: &rng)], dark, 0.85)))
            }
        case .botanical:
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(colour((0.91, 0.92, 0.86), dark)))
            let greens: [RGB] = [(0.42, 0.55, 0.40), (0.52, 0.64, 0.46), (0.33, 0.46, 0.36)]
            // Fronds grow in from the left and right edges only.
            for side in [0, 1] {
                for i in 0..<5 {
                    let y = size.height * (0.1 + 0.2 * CGFloat(i)) + CGFloat.random(in: -0.04...0.04, using: &rng) * size.height
                    let x = side == 0 ? CGFloat(-4) : size.width + 4
                    let dir: CGFloat = side == 0 ? 1 : -1
                    let length = CGFloat.random(in: 0.12...0.24, using: &rng) * m
                    let tilt = CGFloat.random(in: -0.5...0.5, using: &rng)
                    let tip = CGPoint(x: x + dir * length, y: y + tilt * length)
                    let mid = CGPoint(x: (x + tip.x) / 2, y: (y + tip.y) / 2)
                    var stem = Path()
                    stem.move(to: CGPoint(x: x, y: y))
                    stem.addQuadCurve(to: tip, control: CGPoint(x: mid.x, y: mid.y - length * 0.25))
                    context.stroke(stem, with: .color(colour(greens[2], dark, 0.8)), lineWidth: 1.6)
                    for k in 1...5 {
                        let t = CGFloat(k) / 6
                        let base = CGPoint(x: x + (tip.x - x) * t, y: y + (tip.y - y) * t - sin(t * .pi) * length * 0.12)
                        for flip in [CGFloat(-1), 1] {
                            let leaf = length * 0.32 * (1.1 - t * 0.5)
                            let end = CGPoint(x: base.x + dir * leaf * 0.5, y: base.y + flip * leaf)
                            var p = Path()
                            p.move(to: base)
                            p.addQuadCurve(to: end, control: CGPoint(x: base.x + dir * leaf * 0.7, y: base.y + flip * leaf * 0.1))
                            p.addQuadCurve(to: base, control: CGPoint(x: base.x - dir * leaf * 0.1, y: base.y + flip * leaf * 0.7))
                            context.fill(p, with: .color(colour(greens[(k + Int(flip) + 1) % 3], dark, 0.75)))
                        }
                    }
                }
            }
        case .stickers:
            context.fill(Path(whole), with: .color(colour((0.95, 0.93, 0.89), dark)))
            paintStickers(&context, size: size, t: t, dark: dark, rng: &rng)
        case .solid:
            context.fill(Path(whole), with: .color(colour(channels(t.solid), dark)))
        case .gradient:
            let a = t.angle * .pi / 180
            let d = CGPoint(x: cos(a), y: sin(a))
            let half = (abs(size.width * d.x) + abs(size.height * d.y)) / 2
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            context.fill(Path(whole), with: .linearGradient(
                Gradient(colors: [colour(channels(t.gradientA), dark), colour(channels(t.gradientB), dark)]),
                startPoint: CGPoint(x: mid.x - d.x * half, y: mid.y - d.y * half),
                endPoint: CGPoint(x: mid.x + d.x * half, y: mid.y + d.y * half)))
        case .off, .custom:
            break
        }
        // Intensity: the theme blended toward the plain ground.
        if t.intensity < 0.999 {
            context.fill(Path(whole), with: .color(ground.opacity(1 - max(0, t.intensity))))
        }
        if calm {
            // Lower contrast where the address field sits.
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            context.fill(Path(whole), with: .radialGradient(
                Gradient(colors: [ground.opacity(0.7), ground.opacity(0)]),
                center: centre, startRadius: 20, endRadius: max(120, m * 0.55)))
        }
    }

    // MARK: - stickers

    private enum Kind { case star, heart, smiley, flower, lightning, planet, cloud }

    private static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    /// A sticker's body in a unit square around the origin, and the details
    /// painted over it: (path, filled?, colour index, line width).
    private static func shape(_ kind: Kind) -> (body: Path, details: [(Path, Bool, Int, CGFloat)]) {
        switch kind {
        case .star:
            var p = Path()
            for k in 0..<10 {
                let a = -Double.pi / 2 + Double(k) * .pi / 5
                let r: CGFloat = k % 2 == 0 ? 1 : 0.45
                let pt = CGPoint(x: r * CGFloat(cos(a)), y: r * CGFloat(sin(a)))
                k == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.closeSubpath()
            return (p, [])
        case .heart:
            var p = Path()
            p.move(to: CGPoint(x: 0, y: 0.85))
            p.addCurve(to: CGPoint(x: -0.95, y: -0.25), control1: CGPoint(x: -0.3, y: 0.6), control2: CGPoint(x: -0.95, y: 0.25))
            p.addCurve(to: CGPoint(x: 0, y: -0.45), control1: CGPoint(x: -0.95, y: -0.85), control2: CGPoint(x: -0.2, y: -0.9))
            p.addCurve(to: CGPoint(x: 0.95, y: -0.25), control1: CGPoint(x: 0.2, y: -0.9), control2: CGPoint(x: 0.95, y: -0.85))
            p.addCurve(to: CGPoint(x: 0, y: 0.85), control1: CGPoint(x: 0.95, y: 0.25), control2: CGPoint(x: 0.3, y: 0.6))
            p.closeSubpath()
            return (p, [])
        case .smiley:
            var mouth = Path()
            mouth.addArc(center: CGPoint(x: 0, y: 0.05), radius: 0.55, startAngle: .degrees(25), endAngle: .degrees(155), clockwise: false)
            return (circle(0, 0, 1), [(circle(-0.35, -0.25, 0.12), true, 9, 0), (circle(0.35, -0.25, 0.12), true, 9, 0),
                                       (mouth, false, 9, 0.12)])
        case .flower:
            var p = Path()
            for k in 0..<5 {
                let a = Double(k) * 2 * .pi / 5 - .pi / 2
                p.addPath(circle(0.6 * CGFloat(cos(a)), 0.6 * CGFloat(sin(a)), 0.4))
            }
            p.addPath(circle(0, 0, 0.6))
            return (p, [(circle(0, 0, 0.3), true, 1, 0)])
        case .lightning:
            var p = Path()
            let pts = [(0.15, -1.0), (-0.6, 0.15), (-0.1, 0.15), (-0.3, 1.0), (0.6, -0.2), (0.05, -0.2)]
            for (i, pt) in pts.enumerated() {
                let q = CGPoint(x: pt.0, y: pt.1)
                i == 0 ? p.move(to: q) : p.addLine(to: q)
            }
            p.closeSubpath()
            return (p, [])
        case .planet:
            let ring = Path(ellipseIn: CGRect(x: -1.1, y: -0.28, width: 2.2, height: 0.56))
                .applying(CGAffineTransform(rotationAngle: -0.35))
            var body = circle(0, 0, 0.7)
            body.addPath(ring.strokedPath(StrokeStyle(lineWidth: 0.16)))
            return (body, [(ring, false, 1, 0.16)])
        case .cloud:
            var p = Path()
            p.addPath(circle(-0.5, 0.1, 0.42))
            p.addPath(circle(0, -0.2, 0.55))
            p.addPath(circle(0.5, 0.1, 0.42))
            p.addRoundedRect(in: CGRect(x: -0.92, y: 0.1, width: 1.84, height: 0.52), cornerSize: CGSize(width: 0.26, height: 0.26))
            return (p, [])
        }
    }

    private static func paintStickers(_ context: inout GraphicsContext, size: CGSize, t: HomeTuning, dark: Bool,
                                      rng: inout Seeded) {
        let kinds: [Kind]
        let palette: [RGB]
        switch t.pack {
        case .playful:
            kinds = [.star, .heart, .smiley, .lightning, .flower]
            palette = [(0.95, 0.45, 0.45), (0.98, 0.80, 0.30), (0.40, 0.70, 0.90), (0.55, 0.80, 0.55), (0.85, 0.55, 0.85)]
        case .space:
            kinds = [.star, .planet, .star, .lightning, .cloud]
            palette = [(0.45, 0.40, 0.85), (0.95, 0.80, 0.35), (0.35, 0.65, 0.85), (0.85, 0.50, 0.70)]
        case .nature:
            kinds = [.flower, .cloud, .flower, .heart]
            palette = [(0.55, 0.78, 0.55), (0.95, 0.65, 0.70), (0.98, 0.82, 0.45), (0.50, 0.72, 0.85)]
        }
        let m = min(size.width, size.height)
        let area = Double(size.width * size.height) / (1200 * 800)
        let count = max(5, min(60, Int((6 + t.density * 26) * max(0.5, area))))
        let base = m * (0.035 + 0.07 * CGFloat(t.scale))
        var placed: [(CGPoint, CGFloat)] = []
        for i in 0..<count {
            let r = base * CGFloat.random(in: 0.8...1.2, using: &rng)
            var spot: CGPoint?
            for _ in 0..<60 {
                let c = CGPoint(x: CGFloat.random(in: 0.04...0.96, using: &rng) * size.width,
                                y: CGFloat.random(in: 0.05...0.95, using: &rng) * size.height)
                // Out of the middle, where the address field is.
                let dx = (c.x - size.width / 2) / (size.width * 0.3), dy = (c.y - size.height / 2) / (size.height * 0.25)
                if dx * dx + dy * dy < 1 { continue }
                if placed.contains(where: { hypot($0.0.x - c.x, $0.0.y - c.y) < ($0.1 + r) * 1.3 }) { continue }
                spot = c
                break
            }
            guard let c = spot else { continue }
            placed.append((c, r))
            let kind = kinds[i % kinds.count]
            let main = palette[Int.random(in: 0..<palette.count, using: &rng)]
            let accent = palette[Int.random(in: 0..<palette.count, using: &rng)]
            let tilt = Double.random(in: -25...25, using: &rng)
            let parts = shape(kind)
            let ink = colour((0.2, 0.18, 0.22), dark, dark ? 0.9 : 0.75)
            let colours: [Color] = [colour(main, dark), colour(accent, dark)]
            var local = context
            local.translateBy(x: c.x, y: c.y)
            local.rotate(by: .degrees(tilt))
            local.scaleBy(x: r, y: r)
            // The die-cut edge and its shadow, then the sticker on top.
            local.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(dark ? 0.5 : 0.22), radius: 0.12 * r / 1, x: 0, y: 0.06 * r))
                layer.stroke(parts.body, with: .color(colour((1, 1, 1), dark)),
                             style: StrokeStyle(lineWidth: 0.34, lineCap: .round, lineJoin: .round))
                layer.fill(parts.body, with: .color(colour((1, 1, 1), dark)))
            }
            local.fill(parts.body, with: .color(colours[0]))
            for (path, filled, which, width) in parts.details {
                let paint: Color = which == 9 ? ink : colours[min(which, 1)]
                if filled { local.fill(path, with: .color(paint)) }
                else { local.stroke(path, with: .color(paint), style: StrokeStyle(lineWidth: width, lineCap: .round)) }
            }
        }
    }
}
