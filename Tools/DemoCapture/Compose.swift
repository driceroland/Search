import AVFoundation
import AppKit
import CoreImage
import CoreMedia
import Foundation

// `demo-capture compose --plan PLAN.json`: the recorded window onto a
// background, with its shadow and rounded corners, the pointer drawn in,
// and the camera's gentle zoom, every frame at a steady rate, piped as raw
// pixels to ffmpeg (libx264, and ProRes beside it if asked).
//
// The plan is ./demo's (Tools/demo/plan.py): every number that needs
// thinking — where the window sits, where the pointer is in each frame, the
// camera — is worked out there and tested there. Here it is only drawn.

struct Plan: Decodable {
    struct Background: Decodable {
        var image: String?
        var blur: Double?
        /// Top and bottom of the default gradient, then soft blobs: [r, g, b, a, x, y, radius] in 0…1 of the frame.
        var colors: [[Double]]?
        var blobs: [[Double]]?
    }
    struct Shadow: Decodable {
        var blur: Double
        var y: Double
        var alpha: Double
    }
    var capture: String
    var stamps: String
    var out: String
    var prores: String?
    var ffmpeg: String
    var width: Int
    var height: Int
    var fps: Int
    var crf: Int?
    var preset: String?
    /// The wall clock time of the video's first frame.
    var start: Double
    var frames: Int
    var background: Background
    /// Where the window goes, in output pixels from the top left: x, y, w, h.
    var window: [Double]
    var radius: Double
    var shadows: [Shadow]
    var border: Double?
    /// The window's size in points, as the pointer track measures it.
    var windowPoints: [Double]
    /// Per frame: x, y (window points from its top left), scale, opacity.
    var cursor: [[Double]]?
    /// Per frame: centre x, centre y (output pixels), zoom.
    var camera: [[Double]]?
    /// The pointer's size: 1 is the Mac's own against the window's points.
    var cursorSize: Double?
    /// Write this frame of the output as a PNG too (for checking), if set.
    var still: Int?
    var stillPath: String?
}

struct Stamps: Decodable {
    var hostToWall: Double
    var stamps: [Double]
}

enum ComposeError: Error, CustomStringConvertible {
    case reader(String)
    case ffmpeg(String)
    var description: String {
        switch self {
        case .reader(let why): return "reading the recording: \(why)"
        case .ffmpeg(let why): return "ffmpeg: \(why)"
        }
    }
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB,
              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
}

/// A rect given from the top left, in a context whose origin is its bottom left.
func flip(_ r: CGRect, height: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
}

func background(_ plan: Plan) -> CGImage {
    let w = plan.width, h = plan.height
    let ctx = makeContext(w, h)
    let full = CGRect(x: 0, y: 0, width: w, height: h)
    if let path = plan.background.image,
       let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
       let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
        // Aspect-fill.
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let k = max(CGFloat(w) / iw, CGFloat(h) / ih)
        let drawn = CGRect(x: (CGFloat(w) - iw * k) / 2, y: (CGFloat(h) - ih * k) / 2, width: iw * k, height: ih * k)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: drawn)
    } else {
        let colors = plan.background.colors ?? [[0.86, 0.87, 0.89, 1], [0.72, 0.74, 0.78, 1]]
        let gradient = CGGradient(colorsSpace: sRGB, colors: colors.map {
            CGColor(colorSpace: sRGB, components: [$0[0], $0[1], $0[2], $0.count > 3 ? $0[3] : 1])!
        } as CFArray, locations: nil)!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        for blob in plan.background.blobs ?? [] where blob.count >= 7 {
            let c = CGColor(colorSpace: sRGB, components: [blob[0], blob[1], blob[2], blob[3]])!
            let clear = CGColor(colorSpace: sRGB, components: [blob[0], blob[1], blob[2], 0])!
            let g = CGGradient(colorsSpace: sRGB, colors: [c, clear] as CFArray, locations: [0, 1])!
            let centre = CGPoint(x: blob[4] * Double(w), y: Double(h) - blob[5] * Double(h))
            ctx.drawRadialGradient(g, startCenter: centre, startRadius: 0, endCenter: centre,
                                   endRadius: blob[6] * Double(max(w, h)), options: [])
        }
    }
    var image = ctx.makeImage()!
    let blur = plan.background.blur ?? (plan.background.image == nil ? 0 : 0)
    if blur > 0 {
        let ci = CIImage(cgImage: image).clampedToExtent()
            .applyingGaussianBlur(sigma: blur * Double(h) / 1080).cropped(to: full)
        let context = CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB])
        if let blurred = context.createCGImage(ci, from: full, format: .BGRA8, colorSpace: sRGB) { image = blurred }
    }
    // The window's shadow, under where it will be drawn.
    let base = makeContext(w, h)
    base.draw(image, in: full)
    let rect = flip(CGRect(x: plan.window[0], y: plan.window[1], width: plan.window[2], height: plan.window[3]), height: CGFloat(h))
    let shape = CGPath(roundedRect: rect, cornerWidth: plan.radius, cornerHeight: plan.radius, transform: nil)
    for shadow in plan.shadows {
        base.saveGState()
        base.setShadow(offset: CGSize(width: 0, height: -shadow.y), blur: shadow.blur,
                       color: CGColor(colorSpace: sRGB, components: [0, 0, 0, shadow.alpha]))
        base.addPath(shape)
        base.setFillColor(CGColor(colorSpace: sRGB, components: [0, 0, 0, 1])!)
        base.fillPath()
        base.restoreGState()
    }
    return base.makeImage()!
}

/// The Mac's arrow, drawn: its tip at (0, 0), y down, in points.
func arrowPath() -> CGPath {
    let p = CGMutablePath()
    let points: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16.6), CGPoint(x: 3.9, y: 12.9), CGPoint(x: 6.5, y: 19.0),
        CGPoint(x: 9.2, y: 17.9), CGPoint(x: 6.7, y: 11.9), CGPoint(x: 11.9, y: 11.9),
    ]
    p.addLines(between: points)
    p.closeSubpath()
    return p
}

func drawCursor(_ ctx: CGContext, at tip: CGPoint, size: CGFloat, alpha: CGFloat) {
    guard alpha > 0.001 else { return }
    let path = arrowPath()
    ctx.saveGState()
    ctx.setAlpha(alpha)
    // In a top-left, y-down frame of the pointer's own, at its size.
    ctx.translateBy(x: tip.x, y: tip.y)
    ctx.scaleBy(x: size, y: -size)
    ctx.setShadow(offset: CGSize(width: 0, height: -1.2 * size), blur: 3.0 * size,
                  color: CGColor(colorSpace: sRGB, components: [0, 0, 0, 0.35]))
    ctx.setLineJoin(.round)
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(colorSpace: sRGB, components: [1, 1, 1, 1])!)
    ctx.setLineWidth(2.4)
    ctx.strokePath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.addPath(path)
    ctx.setFillColor(CGColor(colorSpace: sRGB, components: [0, 0, 0, 1])!)
    ctx.fillPath()
    ctx.restoreGState()
}

/// Frames of the recording one after another, each with the wall time it was drawn.
final class Frames {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let walls: [Double]
    private var index = 0

    init(movie: String, stamps: Stamps) throws {
        let asset = AVURLAsset(url: URL(fileURLWithPath: movie))
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var track: AVAssetTrack?
        Task {
            track = try? await asset.loadTracks(withMediaType: .video).first
            semaphore.signal()
        }
        semaphore.wait()
        guard let track else { throw ComposeError.reader("no video in \(movie)") }
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw ComposeError.reader(reader.error?.localizedDescription ?? "cannot read") }
        walls = stamps.stamps.map { $0 + stamps.hostToWall }
    }

    /// The next frame and when it was drawn, or nil at the end.
    func next() -> (CGImage, Double)? {
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = sample.imageBuffer else { continue }
            defer { index += 1 }
            // The k-th frame written is the k-th stamp (no reordering); a
            // movie with more frames than stamps (a synthetic one) runs at
            // its own timestamps.
            let wall = index < walls.count ? walls[index] : (walls.last ?? 0) + sample.presentationTimeStamp.seconds
            guard let image = cgImage(buffer) else { continue }
            return (image, wall)
        }
        return nil
    }

    private func cgImage(_ buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        let data = Data(bytes: base, count: row * h)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row, space: sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

func ffmpegArguments(_ plan: Plan) -> [String] {
    var args = ["-hide_banner", "-loglevel", "error", "-y",
                "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(plan.width)x\(plan.height)", "-r", "\(plan.fps)", "-i", "-",
                "-c:v", "libx264", "-crf", "\(plan.crf ?? 16)", "-preset", plan.preset ?? "slow", "-pix_fmt", "yuv420p",
                "-vf", "scale=out_color_matrix=bt709:out_range=tv",
                "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
                "-movflags", "+faststart", plan.out]
    if let prores = plan.prores {
        args += ["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le",
                 "-vf", "scale=out_color_matrix=bt709",
                 "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", prores]
    }
    return args
}

func compose(planPath: String) throws {
    let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: URL(fileURLWithPath: planPath)))
    let stamps = try JSONDecoder().decode(Stamps.self, from: Data(contentsOf: URL(fileURLWithPath: plan.stamps)))
    let frames = try Frames(movie: plan.capture, stamps: stamps)
    let w = plan.width, h = plan.height
    let H = CGFloat(h)
    let base = background(plan)
    let windowRect = CGRect(x: plan.window[0], y: plan.window[1], width: plan.window[2], height: plan.window[3])
    let pointScale = windowRect.width / plan.windowPoints[0]
    let shape = CGPath(roundedRect: flip(windowRect, height: H), cornerWidth: plan.radius, cornerHeight: plan.radius, transform: nil)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: plan.ffmpeg)
    process.arguments = ffmpegArguments(plan)
    let pipe = Pipe()
    process.standardInput = pipe
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    let writer = pipe.fileHandleForWriting

    let ctx = makeContext(w, h)
    ctx.interpolationQuality = .high
    var current = frames.next()
    var upcoming = frames.next()
    let started = Date()
    for k in 0..<plan.frames {
        let t = plan.start + Double(k) / Double(plan.fps)
        while let next = upcoming, next.1 <= t {
            current = next
            upcoming = frames.next()
        }
        ctx.saveGState()
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        // The camera: zoom about a point of the frame (top-left pixels).
        if let camera = plan.camera, k < camera.count, camera[k].count >= 3, camera[k][2] != 1 {
            let c = camera[k]
            ctx.translateBy(x: CGFloat(w) / 2, y: H / 2)
            ctx.scaleBy(x: c[2], y: c[2])
            ctx.translateBy(x: -c[0], y: -(H - c[1]))
        }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let (image, _) = current {
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            ctx.draw(image, in: flip(windowRect, height: H))
            ctx.restoreGState()
        }
        if let border = plan.border, border > 0 {
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.setStrokeColor(CGColor(colorSpace: sRGB, components: [0, 0, 0, 0.22])!)
            ctx.setLineWidth(border)
            ctx.strokePath()
            ctx.restoreGState()
        }
        if let cursor = plan.cursor, k < cursor.count, cursor[k].count >= 4 {
            let c = cursor[k]
            let tip = CGPoint(x: windowRect.minX + c[0] * pointScale, y: H - (windowRect.minY + c[1] * pointScale))
            drawCursor(ctx, at: tip, size: pointScale * (plan.cursorSize ?? 1) * c[2], alpha: c[3])
        }
        ctx.restoreGState()
        guard let data = ctx.data else { break }
        if let still = plan.still, still == k, let path = plan.stillPath, let image = ctx.makeImage() {
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        do {
            try writer.write(contentsOf: Data(bytesNoCopy: data, count: w * h * 4, deallocator: .none))
        } catch {
            throw ComposeError.ffmpeg("it stopped taking frames: " + (String(data: errors.fileHandleForReading.availableData, encoding: .utf8) ?? ""))
        }
        if k % 120 == 0 {
            FileHandle.standardError.write("compose: frame \(k)/\(plan.frames) (\(Int(Date().timeIntervalSince(started))) s)\n".data(using: .utf8)!)
        }
    }
    try writer.close()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ComposeError.ffmpeg(String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "failed")
    }
    say(["composed": plan.out, "frames": plan.frames, "seconds": Date().timeIntervalSince(started)])
}
