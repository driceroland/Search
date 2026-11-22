import SwiftUI
import AppKit

/// A painted background behind the blank tab. Off unless asked for.
enum HomeTheme: String, CaseIterable, Identifiable {
    case off
    case openRoad, desertHighway, coastalCliffs, mountainLake, riceTerraces
    case northernLights, saturnRise, moonscape, cityAtNight, monsoonForest
    case stickers, solid, gradient, custom

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
            case .wall: return .openRoad
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
        case .openRoad, .desertHighway, .coastalCliffs, .mountainLake, .riceTerraces,
             .northernLights, .saturnRise, .moonscape, .cityAtNight, .monsoonForest: return .wall
        case .stickers: return .stickers
        case .solid: return .solid
        case .gradient: return .gradient
        case .custom: return .image
        }
    }

    var title: String {
        switch self {
        case .off: return "Off"
        case .openRoad: return "Open Road"
        case .desertHighway: return "Desert Highway"
        case .coastalCliffs: return "Coastal Cliffs"
        case .mountainLake: return "Mountain Lake"
        case .riceTerraces: return "Rice Terraces"
        case .northernLights: return "Northern Lights"
        case .saturnRise: return "Saturn Rise"
        case .moonscape: return "Moonscape"
        case .cityAtNight: return "City at Night"
        case .monsoonForest: return "Monsoon Forest"
        case .stickers: return "Stickers"
        case .solid: return "Solid colour"
        case .gradient: return "Gradient"
        case .custom: return "Image"
        }
    }

    /// The ten wall paintings (the first family).
    static let walls: [HomeTheme] = [.openRoad, .desertHighway, .coastalCliffs, .mountainLake, .riceTerraces,
                                     .northernLights, .saturnRise, .moonscape, .cityAtNight, .monsoonForest]

    /// Reads a stored name.
    static func stored(_ name: String) -> HomeTheme? {
        return HomeTheme(rawValue: name)
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

enum StickerPack: String, CaseIterable, Identifiable, Codable {
    case space, roadTrip, ocean, jungle, streetFood, retroTech, weather, music, wonders, search
    var id: String { rawValue }
    var title: String {
        switch self {
        case .space: return "Space"
        case .roadTrip: return "Road Trip"
        case .ocean: return "Ocean"
        case .jungle: return "Jungle"
        case .streetFood: return "Street Food"
        case .retroTech: return "Retro Tech"
        case .weather: return "Weather"
        case .music: return "Music"
        case .wonders: return "Wonders"
        case .search: return "Search"
        }
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
    /// 0...1: how many stickers.
    var density = 0.5
    /// 0...1: how big a sticker is.
    var scale = 0.5
    var pack = StickerPack.space
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

typealias RGB = (Double, Double, Double)

/// Turns a pigment into a colour for the light or dark look. Dark walls are
/// the same pigments taken down; a night scene is kept brighter there. In
/// the light look a night scene is only lifted a touch: lifting it toward
/// grey, as an earlier pass did, washed its colour out to a dull haze.
struct Pen {
    var dark: Bool
    var night = false
    func callAsFunction(_ c: RGB, _ alpha: Double = 1) -> Color {
        var c = c
        if night && !dark { c = (c.0 * 0.9 + 0.08, c.1 * 0.9 + 0.08, c.2 * 0.9 + 0.08) }
        let k = dark ? (night ? 0.8 : 0.42) : 1
        return Color(red: c.0 * k, green: c.1 * k, blue: c.2 * k).opacity(alpha)
    }
}

/// A small generator with a fixed seed, so a wall is the same wall on every
/// render: SystemRandomNumberGenerator would give a new one each time.
struct Seeded: RandomNumberGenerator {
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
        let dark: Bool, scale: CGFloat
    }
    private static var made: [Key: NSImage] = [:]
    private static var order: [Key] = []

    static func image(_ theme: HomeTheme, _ tuning: HomeTuning, size: CGSize,
                      dark: Bool, scale: CGFloat) -> NSImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let key = Key(theme: theme, tuning: tuning, width: Int(size.width), height: Int(size.height),
                      dark: dark, scale: scale)
        if let image = made[key] { return image }
        let ground = groundColour(dark: dark)
        let canvas = Canvas { context, size in
            HomeBackground.paint(theme, tuning, in: &context, size: size, dark: dark, ground: ground)
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
    /// A thumbnail is drawn at exactly its size.
    var thumbnail = false
    /// A different wall or pack each day; decided here, when the tab is drawn.
    var shuffle = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var scale

    /// Today's wall: the chosen one, or with Shuffle the family's pick for
    /// this date (the day number steps through the family, so no two days
    /// in a row are the same). A date check, not a timer.
    private var today: (theme: HomeTheme, tuning: HomeTuning) {
        guard shuffle, !thumbnail, theme == .stickers || theme.family == .wall else { return (theme, tuning) }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        if theme == .stickers {
            var t = tuning
            t.pack = StickerPack.allCases[day % StickerPack.allCases.count]
            return (theme, t)
        }
        return (HomeTheme.walls[day % HomeTheme.walls.count], tuning)
    }

    var body: some View {
        let theme = today.theme
        return GeometryReader { box in
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
                    }
                default:
                    if let made = HomeRender.image(theme, shown, size: drawn(box.size),
                                                   dark: scheme == .dark, scale: pixels(box.size)) {
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
        var t = today.tuning
        if thumbnail { t.intensity = 1 }
        return t
    }

    /// A preview is painted as a full-size window would be and shrunk to fit
    /// (so stickers are in proportion, not a cropped corner), at
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

    /// A fixed number from a name (FNV-1a), so a wall is the same on every render.
    static func seed(_ name: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in name.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return h
    }

    fileprivate static func paint(_ theme: HomeTheme, _ t: HomeTuning, in context: inout GraphicsContext,
                                  size: CGSize, dark: Bool, ground: Color) {
        guard size.width > 1, size.height > 1 else { return }
        let m = min(size.width, size.height)
        let whole = CGRect(origin: .zero, size: size)
        let pen = Pen(dark: dark)
        switch theme {
        case .stickers:
            HomeStickers.paint(context, size: size, t: t, dark: dark)
        case .solid:
            context.fill(Path(whole), with: .color(pen(channels(t.solid))))
        case .gradient:
            let a = t.angle * .pi / 180
            let d = CGPoint(x: cos(a), y: sin(a))
            let half = (abs(size.width * d.x) + abs(size.height * d.y)) / 2
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            context.fill(Path(whole), with: .linearGradient(
                Gradient(colors: [pen(channels(t.gradientA)), pen(channels(t.gradientB))]),
                startPoint: CGPoint(x: mid.x - d.x * half, y: mid.y - d.y * half),
                endPoint: CGPoint(x: mid.x + d.x * half, y: mid.y + d.y * half)))
        case .off, .custom:
            break
        default:
            HomeWalls.paint(theme, context, size: size, dark: dark)
        }
        // Intensity: the theme blended toward the plain ground.
        if t.intensity < 0.999 {
            context.fill(Path(whole), with: .color(ground.opacity(1 - max(0, t.intensity))))
        }
    }
}
