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
    /// pixels whose channels are all above 249, as speedline leaves them out.
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
            if r > 249 && g > 249 && b > 249 { continue }
            counts[r] += 1
            counts[bins + g] += 1
            counts[bins * 2 + b] += 1
        }
        return counts
    }

    /// speedline's calculateFrameProgress, 0...1.
    static func progress(_ current: [Int], initial: [Int], target: [Int]) -> Double {
        var total = 0, matched = 0
        for bin in 0..<Swift.min(current.count, initial.count, target.count) {
            let currentDiff = abs(current[bin] - initial[bin])
            let targetDiff = abs(target[bin] - initial[bin])
            matched += Swift.min(currentDiff, targetDiff)
            total += targetDiff
        }
        return total == 0 ? 1 : Double(matched) / Double(total)
    }

    /// Speed Index in ms from frames timed from navigation start. Frames
    /// before First Contentful Paint still show the page that was there
    /// before the reload, so they count as blank; the result is never below
    /// First Contentful Paint, as in Lighthouse.
    static func speedIndex(_ frames: [(ms: Double, histogram: [Int])], fcp: Double?) -> Double? {
        guard let fcp, let last = frames.last, last.ms >= fcp else { return nil }
        let blank = Array(repeating: 0, count: bins * 3)
        let target = last.histogram
        var points: [(ms: Double, progress: Double)] = [(0, 0)]
        for frame in frames where frame.ms > 0 {
            let value = frame.ms < fcp ? 0 : progress(frame.histogram, initial: blank, target: target)
            points.append((frame.ms, value))
        }
        var area = 0.0
        for (index, point) in points.enumerated().dropLast() {
            area += (1 - point.progress) * (points[index + 1].ms - point.ms)
        }
        return Swift.max(area, fcp)
    }
}

/// Snapshots of a web view every `interval` while a page loads.
@MainActor
final class DeveloperFilmstripRecorder {
    private(set) var frames: [(time: Date, histogram: [Int])] = []
    private var task: Task<Void, Never>?
    let interval: Duration

    init(interval: Duration = .milliseconds(100)) { self.interval = interval }

    func start(_ web: WKWebView) {
        frames = []
        task?.cancel()
        task = Task { [weak self, weak web] in
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = 160
            configuration.afterScreenUpdates = false
            while !Task.isCancelled, let web, let self {
                let time = Date()
                if let image = try? await web.takeSnapshot(configuration: configuration),
                   let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    self.frames.append((time, DeveloperSpeedIndex.histogram(cg)))
                }
                if self.frames.count >= 400 { return }
                try? await Task.sleep(for: self.interval)
            }
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
