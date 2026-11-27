import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

/// The shade of the mark on a picture's icon.
enum IconMark: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// The Dock icon, drawn from a picture of the person's own: the picture on
/// the plate, blurred, frosted and grained to taste, with the mark over it in
/// a dark or light shade of what the picture is. The mark and the plate keep
/// the proportions of Icon/icon.swift, so it is still plainly Search.
///
/// Set while the app runs (NSApp.applicationIconImage), at once, with no
/// restart: the Dock, ⌘Tab and About show it. The icon file in the app is not
/// touched, so an update never meets a changed bundle, and Search shows its
/// own icon again while closed. Nothing is set until someone chooses a
/// picture.
@MainActor
final class AppIconStyle: ObservableObject {
    static let shared = AppIconStyle()

    // MARK: The choices

    /// Softening, in points of the 824-point plate.
    static let blurSteps: [Double] = [0, 5, 10, 15, 20]
    /// White laid over the picture: 0 shows it as it is, 1 is a white plate.
    static let frostSteps: [Double] = [0, 0.02, 0.05, 0.1, 0.15, 0.2]
    /// Film grain: 0 none, 0.1 faint, 0.2 strong.
    static let grainSteps: [Double] = [0, 0.05, 0.1, 0.15, 0.2]
    /// With the mark on Auto: a plate lighter than this gets the dark mark.
    static let lightAbove = 0.55

    static func blurLabel(_ v: Double) -> String { v == 0 ? "Off" : "\(Int(v))" }
    static func percentLabel(_ v: Double) -> String { v == 0 ? "Off" : "\(Int((v * 100).rounded()))%" }

    @Published var mark: IconMark {
        didSet { Store.settings.set(mark.rawValue, forKey: "appicon.mark"); refresh() }
    }
    @Published var blur: Double {
        didSet { Store.settings.set(blur, forKey: "appicon.blur"); refresh() }
    }
    @Published var frost: Double {
        didSet { Store.settings.set(frost, forKey: "appicon.frost"); refresh() }
    }
    @Published var grain: Double {
        didSet { Store.settings.set(grain, forKey: "appicon.grain"); refresh() }
    }

    /// A picture is chosen, and is the icon now.
    @Published private(set) var isCustom = false
    /// The icon as it is with the choices above: what Settings shows, and
    /// what the Dock has. Nil until a picture is chosen.
    @Published private(set) var preview: NSImage?

    private static let imageKey = "appicon.image"
    private var picture: CGImage?

    private init() {
        let store = Store.settings
        mark = store.string(forKey: "appicon.mark").flatMap(IconMark.init) ?? .auto
        blur = Self.snap(store.object(forKey: "appicon.blur") as? Double, Self.blurSteps, 15)
        frost = Self.snap(store.object(forKey: "appicon.frost") as? Double, Self.frostSteps, 0.02)
        grain = Self.snap(store.object(forKey: "appicon.grain") as? Double, Self.grainSteps, 0.1)
    }

    /// A stored value on the nearest step, so an edited default can't leave
    /// every choice unlit.
    private static func snap(_ value: Double?, _ steps: [Double], _ fallback: Double) -> Double {
        guard let value else { return fallback }
        return steps.min { abs($0 - value) < abs($1 - value) } ?? fallback
    }

    // MARK: Lifecycle

    /// At launch: puts the chosen picture's icon on, if there is one. After
    /// the run loop has started, as NSApp isn't there before it.
    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let path = Store.settings.string(forKey: Self.imageKey),
                  let image = NSImage(contentsOfFile: path),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            picture = cg
            isCustom = true
            refresh()
        }
    }

    /// Asks for a picture; the icon changes at once. A file that isn't a
    /// picture, or can't be copied, leaves what there was.
    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let kept = Self.keep(url) else {
            NSSound.beep()
            return
        }
        Store.settings.set(kept, forKey: Self.imageKey)
        picture = cg
        isCustom = true
        refresh()
    }

    /// Back to Search's own icon; the kept copy goes. The choices stay, for
    /// the next picture.
    func reset() {
        if let path = Store.settings.string(forKey: Self.imageKey), path.hasPrefix(Self.folder.path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        Store.settings.removeObject(forKey: Self.imageKey)
        picture = nil
        preview = nil
        isCustom = false
        NSApp?.applicationIconImage = nil
    }

    /// Draws again with the choices as they are, and puts it on.
    private func refresh() {
        guard let picture,
              let icon = Self.render(picture, Look(blur: blur, frost: frost, grain: grain, mark: mark)) else { return }
        preview = icon
        NSApp?.applicationIconImage = icon
    }

    // MARK: The kept copy

    /// A copy, so moving or deleting the original never changes the icon.
    private static var folder: URL {
        Store.folder.appendingPathComponent("Icon", isDirectory: true)
    }

    private static func keep(_ source: URL) -> String? {
        let files = FileManager.default
        // The kept copy chosen again: removing the old one would delete it.
        if source.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path) { return source.path }
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            // One picture at a time, so none pile up.
            for old in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? files.removeItem(at: old)
            }
            let target = folder.appendingPathComponent("icon." + (source.pathExtension.isEmpty ? "img" : source.pathExtension))
            try files.copyItem(at: source, to: target)
            return target.path
        } catch {
            return nil
        }
    }

    // MARK: Drawing

    struct Look {
        var blur: Double
        var frost: Double
        var grain: Double
        var mark: IconMark
    }

    private static let ciContext = CIContext()

    /// The icon for a picture; nil when it can't be drawn.
    static func render(_ picture: CGImage, _ look: Look) -> NSImage? {
        // Apple's grid, as in Icon/icon.swift: the plate is 824 of 1024.
        let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
        let radius = plate.width * 0.2237
        let square = CGRect(origin: .zero, size: plate.size)

        // The middle square of the picture, brought to the plate's size.
        let w = CGFloat(picture.width), h = CGFloat(picture.height)
        let side = min(w, h)
        guard side > 0 else { return nil }
        let crop = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
        let fitted = CIImage(cgImage: picture)
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: plate.width / side, y: plate.width / side))

        // Blurred from its edges outward, so the blur doesn't fade at the
        // border; then frosted with white, then grained.
        var glass = fitted.clampedToExtent()
        if look.blur > 0 { glass = glass.applyingGaussianBlur(sigma: look.blur) }
        glass = glass.cropped(to: square)
        if look.frost > 0 {
            glass = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: look.frost))
                .cropped(to: square)
                .composited(over: glass)
        }
        if look.grain > 0, let noise = CIFilter(name: "CIRandomGenerator")?.outputImage {
            // Grey noise at the grain's strength, soft-lit over the plate so
            // it adds texture without shifting the colour.
            let grey = noise.cropped(to: square)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                    "inputGVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                    "inputBVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: look.grain),
                ])
            glass = grey.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: glass])
        }
        guard let plateImage = ciContext.createCGImage(glass, from: square) else { return nil }

        // What the plate is on average decides the mark: dark on light, light
        // on dark, in the picture's own hue, so it sits in the picture.
        let average = glass.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: square)])
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(average, toBitmap: &pixel, rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let r = Double(pixel[0]) / 255, g = Double(pixel[1]) / 255, b = Double(pixel[2]) / 255
        let luma = 0.299 * r + 0.587 * g + 0.114 * b
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        let darkMark: Bool
        switch look.mark {
        case .auto: darkMark = luma > lightAbove
        case .light: darkMark = false
        case .dark: darkMark = true
        }
        let markColor = (darkMark
            ? NSColor(hue: hue, saturation: min(saturation, 0.6), brightness: 0.14, alpha: 1)
            : NSColor(hue: hue, saturation: saturation * 0.25, brightness: 0.97, alpha: 1)).cgColor

        // The mark at three quarters of the plate, as in icon.swift. The
        // path is made here, once, rather than each time the icon is drawn.
        let markWidth = plate.width * 0.754
        let markHeight = markWidth * Logomark.canvas.height / Logomark.canvas.width
        let markRect = CGRect(x: plate.midX - markWidth / 2, y: plate.midY - markHeight / 2,
                              width: markWidth, height: markHeight)
        let markPath = Logomark().path(in: markRect).cgPath
        let shape = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let picturePlate = NSImage(cgImage: plateImage, size: plate.size)

        // Flipped, so the mark's path (y grows downward) goes in as it is.
        return NSImage(size: NSSize(width: 1024, height: 1024), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // A soft shadow under the plate, as every icon on the Dock has.
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 30, color: NSColor.black.withAlphaComponent(0.22).cgColor)
            ctx.addPath(shape)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            // The picture, inside the plate's corners.
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            picturePlate.draw(in: plate, from: .zero, operation: .sourceOver, fraction: 1,
                              respectFlipped: true, hints: nil)
            ctx.restoreGState()

            // A pale edge, the way glass has one.
            ctx.addPath(shape)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(3)
            ctx.strokePath()

            // The mark: a pill with an S cut out of it, so even-odd.
            ctx.addPath(markPath)
            ctx.setFillColor(markColor)
            ctx.fillPath(using: .evenOdd)
            return true
        }
    }
}
