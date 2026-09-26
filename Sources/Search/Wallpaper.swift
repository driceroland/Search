import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class Wallpaper: ObservableObject {
    static let shared = Wallpaper()

    @Published var enabled: Bool {
        didSet {
            settings.set(enabled, forKey: "wallpaper")
            if !enabled { image = nil; loaded = false }
        }
    }
    @Published var fit: Bool {
        didSet { settings.set(fit, forKey: "wallpaper.fit") }
    }
    @Published private(set) var image: CGImage?
    @Published private(set) var hasImage: Bool
    @Published private(set) var busy = false

    private let file: URL
    private let settings: UserDefaults
    private var loaded = false

    init(file: URL = Store.file("wallpaper.png"), settings: UserDefaults = Store.settings) {
        self.file = file
        self.settings = settings
        enabled = settings.bool(forKey: "wallpaper")
        fit = settings.bool(forKey: "wallpaper.fit")
        hasImage = FileManager.default.fileExists(atPath: file.path)
        if !hasImage { enabled = false; settings.set(false, forKey: "wallpaper") }
    }

    func load() async {
        guard enabled, hasImage, !loaded, !busy else { return }
        loaded = true
        busy = true
        defer { busy = false }
        let file = file
        let result = await Task.detached(priority: .utility) {
            try? Self.read(file)
        }.value
        guard let result else { enabled = false; return }
        if enabled { image = result }
    }

    func use(_ source: URL) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let file = file
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                let image = try Self.read(source)
                let data = NSMutableData()
                guard let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
                else { throw Failure.invalid }
                CGImageDestinationAddImage(output, image, nil)
                guard CGImageDestinationFinalize(output) else { throw Failure.invalid }
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Commit only a decoded copy; a failed replacement leaves the old image intact.
                try (data as Data).write(to: file, options: .atomic)
                return image
            }.value
            image = result
            hasImage = true
            loaded = true
            enabled = true
        } catch {
            enabled = false
        }
    }

    func remove() async {
        guard !busy else { return }
        busy = true
        enabled = false
        defer { busy = false }
        let file = file
        do {
            try await Task.detached(priority: .utility) {
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            }.value
            hasImage = false
            fit = false
        } catch { return }
    }

    nonisolated private static func read(_ url: URL) throws -> CGImage {
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true else { throw Failure.invalid }
        guard let bytes = size.fileSize, bytes <= 50 * 1024 * 1024 else { throw Failure.invalid }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.jpeg, .png, .heic, .heif].contains(where: { $0.identifier == type }),
              CGImageSourceGetCount(source) == 1
        else { throw Failure.invalid }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0, width * height <= 100_000_000
        else { throw Failure.invalid }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2560,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: thumbnail.width, height: thumbnail.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: color,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.invalid }
        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
        guard let image = context.makeImage() else { throw Failure.invalid }
        return image
    }

    private enum Failure: Error {
        case invalid
    }
}
