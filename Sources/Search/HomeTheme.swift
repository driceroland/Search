import SwiftUI
import AppKit

/// A painted background behind the blank tab. Off unless asked for.
enum HomeTheme: String, CaseIterable, Identifiable {
    case off
    case solid, gradient, custom

    var id: String { rawValue }

    /// The groups the Themes page offers, each with its own presets.
    enum Family: String, CaseIterable, Identifiable {
        case off, solid, gradient, image
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: return "Off"
            case .solid: return "Solid colour"
            case .gradient: return "Gradient"
            case .image: return "Image"
            }
        }
        /// What choosing the family alone puts on the wall.
        var first: HomeTheme {
            switch self {
            case .off: return .off
            case .solid: return .solid
            case .gradient: return .gradient
            case .image: return .custom
            }
        }
    }

    var family: Family {
        switch self {
        case .off: return .off
        case .solid: return .solid
        case .gradient: return .gradient
        case .custom: return .image
        }
    }

    var title: String {
        switch self {
        case .off: return "Off"
        case .solid: return "Solid colour"
        case .gradient: return "Gradient"
        case .custom: return "Image"
        }
    }

    /// Where a chosen image is kept: a copy, so moving or deleting the
    /// original never leaves the home screen bare.
    static var folder: URL {
        Store.folder.appendingPathComponent("Theme", isDirectory: true)
    }

    /// Copies a picture into the theme folder and returns where it went.
    /// Nil when it can't be copied; the caller then keeps what it had.
    static func keep(_ source: URL) -> String? {
        let files = FileManager.default
        // The kept copy chosen again: removing the old one would delete it.
        if source.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path) { return source.path }
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
    var solid = "#E8DFD0"
    var gradientA = "#E9B8A0"
    var gradientB = "#8E86B8"
    var angle = 150.0

    init() {}

    /// What a new install's new tab starts with: the same pink as the
    /// window (BrowserTheme.standard).
    static let standard: HomeTuning = {
        var tuning = HomeTuning()
        tuning.solid = "#ED7DFF"
        return tuning
    }()

    /// Tolerant: a line from another build with fewer or more knobs is read
    /// as far as it goes, and the rest is the default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HomeTuning()
        intensity = (try? c.decodeIfPresent(Double.self, forKey: .intensity)) ?? d.intensity
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
    private static var order: [Key] = []

    static func image(_ theme: HomeTheme, _ tuning: HomeTuning, size: CGSize,
                      dark: Bool, scale: CGFloat, calm: Bool) -> NSImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let key = Key(theme: theme, tuning: tuning, width: Int(size.width), height: Int(size.height),
                      dark: dark, scale: scale, calm: calm)
        if let image = made[key] { return image }
        let ground = groundColour(dark: dark)
        let canvas = Canvas { context, size in
            HomeBackground.paint(theme, tuning, in: &context, size: size, ground: ground, dark: dark, calm: calm)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        // A full-window image is tens of megabytes at Retina scale, so only a
        // handful are kept: the current one and the few a resize or a look
        // change steps through. Older sizes and themes go first.
        if made.count >= 4, let oldest = order.first { made[oldest] = nil; order.removeFirst() }
        order.append(key)
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
    /// at exactly as many pixels as it will be shown in.
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
        RadialGradient(colors: [Palette.ground.opacity(0.5), Palette.ground.opacity(0)],
                       center: .center, startRadius: 0, endRadius: 320)
    }

    /// Up to the next 64 points, so a window being dragged wider makes one
    /// image per step and not one per pixel.
    private func rounded(_ size: CGSize) -> CGSize {
        guard !thumbnail else { return size }
        return CGSize(width: (size.width / 64).rounded(.up) * 64, height: (size.height / 64).rounded(.up) * 64)
    }

    /// Whether the chosen picture can be read; a missing one is Off. Kept
    /// once decoded, since the body runs on every resize; keyed by the file's
    /// date too, because a new pick is copied to the same name.
    @MainActor private static var picture: (key: String, image: NSImage)?
    @MainActor static func load(_ path: String?) -> NSImage? {
        guard let path, !path.isEmpty,
              let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return nil }
        let key = path + "@\(date.timeIntervalSince1970)"
        if let picture, picture.key == key { return picture.image }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        picture = (key, image)
        return image
    }

    // MARK: - painting

    static func channels(_ hex: String) -> (Double, Double, Double) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let n = UInt32(digits, radix: 16) else { return (0.53, 0.53, 0.53) }
        return (Double((n >> 16) & 255) / 255, Double((n >> 8) & 255) / 255, Double(n & 255) / 255)
    }

    private static func colour(_ hex: String, dark: Bool) -> Color {
        guard dark, let lab = OKLab(hex: hex) else { return Color(hex: hex) }
        let (r, g, b) = lab.darkFull.srgb
        return Color(.sRGB, red: r, green: g, blue: b)
    }

    fileprivate static func paint(_ theme: HomeTheme, _ t: HomeTuning, in context: inout GraphicsContext,
                                  size: CGSize, ground: Color, dark: Bool, calm: Bool) {
        guard size.width > 1, size.height > 1 else { return }
        let m = min(size.width, size.height)
        let whole = CGRect(origin: .zero, size: size)
        switch theme {
        case .solid:
            context.fill(Path(whole), with: .color(colour(t.solid, dark: dark)))
        case .gradient:
            let a = t.angle * .pi / 180
            let d = CGPoint(x: cos(a), y: sin(a))
            let half = (abs(size.width * d.x) + abs(size.height * d.y)) / 2
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            context.fill(Path(whole), with: .linearGradient(
                Gradient(colors: [colour(t.gradientA, dark: dark), colour(t.gradientB, dark: dark)]),
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
                Gradient(colors: [ground.opacity(0.5), ground.opacity(0)]),
                center: centre, startRadius: 0, endRadius: max(120, m * 0.42)))
        }
    }
}
