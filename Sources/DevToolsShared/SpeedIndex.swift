import AppKit

// Histogram and progress calculation adapted from Speedline
// (https://github.com/paulirish/speedline/tree/626ed07ca71ea91991fb033e659dc7e2f81f2e6c).
// Copyright (c) Pierre-Marie Dartus. See THIRD_PARTY_NOTICES.md.

/// Lighthouse's Speed Index, computed the way speedline does: each frame's
/// colour histogram (near-white pixels left out) against the first and the
/// last frame gives its visual progress, and Speed Index is the area above
/// the progress curve. WebKit's inspector records no filmstrip, so the
/// frames are snapshots of the view taken while the page loads.
enum SpeedIndex {
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
