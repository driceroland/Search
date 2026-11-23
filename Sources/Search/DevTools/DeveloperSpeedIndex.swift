import AppKit
import WebKit

// MARK: Speed Index

/// Lighthouse's Speed Index, computed the way speedline does: each frame's
/// colour histogram (near-white pixels left out) against the first and the
/// last frame gives its visual progress, and Speed Index is the area above
/// the progress curve. WebKit's inspector records no filmstrip, so the
/// frames are snapshots of the view taken while the page loads.
enum DeveloperSpeedIndex {
    static let bins = 256

    /// Per-channel histograms (R, G, B: 768 counts) of an image, without
    /// pixels whose channels are all 249 or more, as speedline's
    /// isWhitePixel leaves them out.
    static func histogram(_ image: CGImage) -> [Int] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? histogram(rgba: pixels) : Array(repeating: 0, count: bins * 3)
    }

    static func histogram(rgba pixels: [UInt8]) -> [Int] {
        var counts = Array(repeating: 0, count: bins * 3)
        var index = 0
        while index + 3 < pixels.count {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            index += 4
            if r >= 249 && g >= 249 && b >= 249 { continue }
            counts[r] += 1
            counts[bins + g] += 1
            counts[bins * 2 + b] += 1
        }
        return counts
    }

    /// speedline's calculateFrameProgress, 0...1, in whole percent as
    /// speedline floors it.
    static func progress(_ current: [Int], initial: [Int], target: [Int]) -> Double {
        var total = 0, matched = 0
        for bin in 0..<Swift.min(current.count, initial.count, target.count) {
            let currentDiff = abs(current[bin] - initial[bin])
            let targetDiff = abs(target[bin] - initial[bin])
            matched += Swift.min(currentDiff, targetDiff)
            total += targetDiff
        }
        return total == 0 ? 1 : (Double(matched) * 100 / Double(total)).rounded(.down) / 100
    }

    /// Speed Index in ms from frames timed from navigation start, each
    /// showing the screen from its time until the next frame's (or `end`,
    /// when the filmstrip stopped). Before First Contentful Paint the screen
    /// still shows the page from before the reload, so it counts as blank;
    /// a frame that was still on screen at First Contentful Paint counts
    /// from then. Nil when the filmstrip stopped before First Contentful Paint.
    static func speedIndex(_ frames: [(ms: Double, histogram: [Int])], fcp: Double?, end: Double? = nil) -> Double? {
        guard let fcp, let last = frames.last, (end ?? last.ms) >= fcp else { return nil }
        let blank = Array(repeating: 0, count: bins * 3)
        let target = last.histogram
        var points: [(ms: Double, progress: Double)] = [(0, 0)]
        for (index, frame) in frames.enumerated() {
            let until = index + 1 < frames.count ? frames[index + 1].ms : Swift.max(end ?? frame.ms, frame.ms)
            let from = Swift.max(frame.ms, fcp)
            guard from <= until, from > 0 || until > 0 else { continue }
            points.append((from, progress(frame.histogram, initial: blank, target: target)))
        }
        var area = 0.0
        for (index, point) in points.enumerated().dropLast() {
            area += (1 - point.progress) * (points[index + 1].ms - point.ms)
        }
        return Swift.max(area, fcp)
    }
}

/// Snapshots of a web view at roughly 60 Hz for Lighthouse and
/// Performance. Performance also keeps a bounded JPEG filmstrip. A coarser
/// cadence dates visual changes later. At 100 ms intervals, Speed Index
/// came out 60–120 ms above Chrome's for the same paints. Only frames that
/// differ from the previous one are kept.
@MainActor
final class DeveloperFilmstripRecorder {
    private(set) var frames: [(time: Date, histogram: [Int])] = []
    private(set) var images: [(time: Date, jpeg: String)] = []
    /// Snapshots taken, the unchanged ones included, and when the last was.
    private(set) var captured = 0
    private(set) var lastCapture: Date?
    private var task: Task<Void, Never>?
    let interval: Duration
    let limit: Int
    private let keepsImages: Bool
    private let imageWidth: CGFloat
    private let imageLimit: Int

    init(interval: Duration = .milliseconds(16), limit: Int = 3_000, images: Bool = false,
         imageWidth: CGFloat = 240, imageLimit: Int = 300) {
        self.interval = interval
        self.limit = limit
        keepsImages = images
        self.imageWidth = imageWidth
        self.imageLimit = imageLimit
    }

    func start(_ web: WKWebView) {
        frames = []
        images = []
        captured = 0
        lastCapture = nil
        task?.cancel()
        let width = keepsImages ? imageWidth : 160
        task = Task { [weak self, weak web] in
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = NSNumber(value: Double(width))
            configuration.afterScreenUpdates = false
            while !Task.isCancelled, let web, let self {
                if let image = try? await web.takeSnapshot(configuration: configuration),
                   let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    guard !Task.isCancelled else { return }
                    // Timed when it came back: a snapshot shows what was on
                    // screen by then, never later.
                    self.record(Date(), DeveloperSpeedIndex.histogram(cg), image: self.keepsImages ? cg : nil)
                }
                if self.captured >= self.limit { return }
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    func record(_ time: Date, _ histogram: [Int], image: CGImage? = nil) {
        captured += 1
        lastCapture = time
        guard frames.last?.histogram != histogram else { return }
        frames.append((time, histogram))
        if keepsImages, images.count < imageLimit, let image,
           let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.6]) {
            images.append((time, jpeg.base64EncodedString()))
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// The frames timed in ms from `origin` (the page's performance.timeOrigin).
    func timed(from origin: Date) -> [(ms: Double, histogram: [Int])] {
        frames.map { ($0.time.timeIntervalSince(origin) * 1_000, $0.histogram) }
    }
}
