import AppKit

/// Picks the color the chrome should take from a snapshot of the page's top edge.
enum DominantColor {
    /// The most common color across the image's width, ignoring minority content such as a logo or
    /// nav text that touches the edge. The image is squeezed to a row of samples, the samples are
    /// grouped coarsely, and the largest group's average is returned.
    static func of(_ image: CGImage) -> NSColor? {
        let samples = 32
        var pixels = [UInt8](repeating: 0, count: samples * 4)
        guard
            let context = CGContext(
                data: &pixels, width: samples, height: 1, bitsPerComponent: 8, bytesPerRow: samples * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: samples, height: 1))

        var groups: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        for index in 0..<samples {
            let (red, green, blue) = (Int(pixels[index * 4]), Int(pixels[index * 4 + 1]), Int(pixels[index * 4 + 2]))
            let key = (red >> 4) << 8 | (green >> 4) << 4 | blue >> 4
            let group = groups[key] ?? (0, 0, 0, 0)
            groups[key] = (group.count + 1, group.red + red, group.green + green, group.blue + blue)
        }
        guard let winner = groups.values.max(by: { $0.count < $1.count }) else { return nil }
        let scale = 255 * CGFloat(winner.count)
        return NSColor(
            srgbRed: CGFloat(winner.red) / scale, green: CGFloat(winner.green) / scale,
            blue: CGFloat(winner.blue) / scale, alpha: 1)
    }
}
