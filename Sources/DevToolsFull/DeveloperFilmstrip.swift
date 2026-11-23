import AppKit
import WebKit

/// Performance's screenshots: the view snapshotted about every 16 ms while a
/// recording captures, small, kept as JPEG only when a frame differs from
/// the one before (compared at 16 × 16). In memory only, with the recording.
@MainActor
final class DeveloperFilmstripRecorder {
    private(set) var images: [(time: Date, jpeg: String)] = []
    private var last: [UInt8]?
    private var task: Task<Void, Never>?
    let interval: Duration
    private let imageWidth: CGFloat
    private let imageLimit: Int

    init(interval: Duration = .milliseconds(16), imageWidth: CGFloat = 240, imageLimit: Int = 300) {
        self.interval = interval
        self.imageWidth = imageWidth
        self.imageLimit = imageLimit
    }

    func start(_ web: WKWebView) {
        images = []
        last = nil
        task?.cancel()
        let width = imageWidth
        task = Task { [weak self, weak web] in
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = NSNumber(value: Double(width))
            configuration.afterScreenUpdates = false
            while !Task.isCancelled, let web, let self, self.images.count < self.imageLimit {
                if let image = try? await web.takeSnapshot(configuration: configuration),
                   let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    guard !Task.isCancelled else { return }
                    // Timed when it came back: a snapshot shows what was on
                    // screen by then, never later.
                    self.record(Date(), cg)
                }
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    private func record(_ time: Date, _ image: CGImage) {
        let print = Self.fingerprint(image)
        guard print != last else { return }
        last = print
        if let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.6]) {
            images.append((time, jpeg.base64EncodedString()))
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// The image drawn at 16 × 16: equal for frames that look the same.
    private static func fingerprint(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        return pixels
    }
}
