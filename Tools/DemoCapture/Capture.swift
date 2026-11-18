import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

// One window, recorded by ScreenCaptureKit: only that window's own pixels,
// never the screen around it, nor the pointer. Frames come only when the
// window changed (an idle window sends none); each is kept with the time
// it was drawn, and the composer holds the last one until the next.

/// Host time (the clock ScreenCaptureKit stamps frames with) to the wall
/// clock the demo runner writes its events in.
func hostToWall() -> Double {
    let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    return Date().timeIntervalSince1970 - host
}

enum CaptureError: Error, CustomStringConvertible {
    case noWindow(UInt32)
    case writer(String)
    var description: String {
        switch self {
        case .noWindow(let id): return "ScreenCaptureKit lists no window \(id) (the probe's window must be ordered in: run `stage on` first)"
        case .writer(let why): return "could not write the recording: \(why)"
        }
    }
}

/// The window by its CGWindowID, off screen ones included.
func shareableWindow(_ id: UInt32) async throws -> SCWindow {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.noWindow(id) }
    return window
}

final class WindowRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let window: SCWindow
    let size: CGSize
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "demo.capture")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private(set) var complete = 0
    private(set) var idle = 0
    private(set) var other = 0
    private(set) var dropped = 0
    private(set) var stamps: [Double] = []
    private(set) var stopError: String?
    /// Every complete frame, as it arrives (the selftest looks at them).
    var onFrame: ((CVPixelBuffer, Double) -> Void)?
    /// The first complete frame's host time.
    private(set) var first: Double?
    private var firstWaiters: [CheckedContinuation<Void, Never>] = []

    /// scale: pixels per point of the window (2 for Retina-sharp video).
    init(window: SCWindow, scale: CGFloat) {
        self.window = window
        // Even sizes: H.264/HEVC want them.
        let w = (Int((window.frame.width * scale).rounded()) / 2) * 2
        let h = (Int((window.frame.height * scale).rounded()) / 2) * 2
        size = CGSize(width: w, height: h)
    }

    func record(to url: URL, codec: String) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ]
        switch codec {
        case "prores":
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes422HQ
        case "h264":
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
            settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: 80_000_000,
                                                         AVVideoAllowFrameReorderingKey: false,
                                                         AVVideoExpectedSourceFrameRateKey: 60]
        default:
            // HEVC at a bitrate that leaves text sharp: an intermediate, re-encoded by the composer.
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: 90_000_000,
                                                         AVVideoAllowFrameReorderingKey: false,
                                                         AVVideoExpectedSourceFrameRateKey: 60]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw CaptureError.writer("the writer takes no video input") }
        writer.add(input)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    func start(fps: Int) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 8
        config.scalesToFit = true
        if #available(macOS 14.0, *) {
            config.ignoreShadowsSingleWindow = true
            // A window wholly or partly off every screen is clipped to the
            // screens unless told otherwise (SCStream.h).
            config.ignoreGlobalClipSingleWindow = true
            config.captureResolution = .best
            config.shouldBeOpaque = true
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    /// Until the first complete frame, or the time is up. True if one came.
    func waitFirst(timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if queue.sync(execute: { first != nil }) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return queue.sync { first != nil }
    }

    func stop() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                guard let writer = self.writer, writer.status == .writing else { done.resume(); return }
                self.input?.markAsFinished()
                writer.finishWriting {
                    if writer.status == .failed { self.stopError = writer.error?.localizedDescription }
                    done.resume()
                }
            }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw)
        else { other += 1; return }
        switch status {
        case .complete: break
        case .idle: idle += 1; return
        default: other += 1; return
        }
        guard let buffer = sample.imageBuffer else { other += 1; return }
        let pts = sample.presentationTimeStamp
        let seconds = pts.seconds
        complete += 1
        if first == nil {
            first = seconds
            if let writer, writer.status == .unknown {
                writer.startWriting()
                writer.startSession(atSourceTime: pts)
            }
        }
        onFrame?(buffer, seconds)
        if let input, let adaptor, writer?.status == .writing {
            if input.isReadyForMoreMediaData, adaptor.append(buffer, withPresentationTime: pts) {
                stamps.append(seconds)
            } else {
                dropped += 1
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stopError = error.localizedDescription
    }
}
