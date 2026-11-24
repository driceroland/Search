import AppKit
import SwiftUI
import WebKit

/// Network settings › Capture screenshots, as Chrome's filmstrip: while
/// it's on and requests are loading, the page is snapshotted about every
/// 100 ms, small, up to 60 frames. Nothing runs while it's off.
@MainActor
final class DeveloperNetworkFilmstrip: ObservableObject {
    typealias Request = DeveloperToolsSession.Request

    struct Frame: Identifiable, Equatable {
        let id: Int
        /// When it was taken, on WebKit's network clock in seconds.
        let time: Double
        let image: NSImage

        static func == (left: Frame, right: Frame) -> Bool { left.id == right.id && left.time == right.time }
    }

    /// Chrome keeps a recording's screenshots to about this many.
    nonisolated static let limit = 60
    /// Seconds between screenshots.
    nonisolated static let interval = 0.1
    /// The width, in pixels, a screenshot is kept at.
    nonisolated static let pixelWidth = 280
    /// Requests pending longer than this (an open stream, say) no longer
    /// count as loading.
    nonisolated static let staleAfter = 30.0

    @Published private(set) var frames: [Frame] = []
    private var nextID = 0
    private var capturing = false

    /// Whether another screenshot is due: something is loading, the last
    /// one was a moment ago, and the recording has room.
    nonisolated static func shouldCapture(count: Int, last: Double?, now: Double, loading: Bool) -> Bool {
        guard loading, count < limit else { return false }
        guard let last else { return true }
        // A little early is fine: the timer that asks isn't exact.
        return now - last >= interval * 0.9
    }

    /// Whether a request is still loading, started within `staleAfter`.
    nonisolated static func loading(_ requests: [Request], now: Double) -> Bool {
        requests.suffix(300).contains { request in
            guard request.ended == nil, request.failure == nil, let started = request.started else { return false }
            return now - started <= staleAfter
        }
    }

    /// The wall clock less WebKit's network clock, read from a request
    /// that has both; nil before any request.
    nonisolated static func clockOffset(_ requests: [Request]) -> Double? {
        requests.lazy.compactMap { request in
            request.originalURL == nil ? request.wallStarted.flatMap { wall in request.started.map { wall - $0 } } : nil
        }.first
    }

    /// The requests finished by the moment a screenshot was taken, which a
    /// click on it lists, as in Chrome.
    nonisolated static func finished(by time: Double, _ rows: [Request]) -> [Request] {
        rows.filter { $0.ended.map { $0 <= time } ?? false }
    }

    /// Adds a screenshot, unless the recording is full.
    func append(_ image: NSImage, at time: Double) {
        guard frames.count < Self.limit else { return }
        frames.append(Frame(id: nextID, time: time, image: image))
        nextID += 1
    }

    func clear() {
        if !frames.isEmpty { frames = [] }
    }

    /// Takes a screenshot of the inspected page when one is due.
    func captureIfDue(_ session: DeveloperToolsSession) async {
        guard !capturing, frames.count < Self.limit, let web = session.web else { return }
        let requests = session.requests
        guard let offset = Self.clockOffset(requests) else { return }
        let now = Date().timeIntervalSince1970 - offset
        guard Self.shouldCapture(count: frames.count, last: frames.last?.time, now: now,
                                 loading: Self.loading(requests, now: now)) else { return }
        capturing = true
        defer { capturing = false }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        configuration.snapshotWidth = NSNumber(value: Double(Self.pixelWidth))
        let image: NSImage? = await withCheckedContinuation { continuation in
            web.takeSnapshot(with: configuration) { image, _ in continuation.resume(returning: image) }
        }
        guard let image else { return }
        append(Self.scaled(image, width: Self.pixelWidth), at: now)
    }

    /// The screenshot redrawn at `width` pixels, so a retina snapshot
    /// doesn't keep four times the memory.
    static func scaled(_ image: NSImage, width: Int) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let height = max(1, Int((size.height / size.width * CGFloat(width)).rounded()))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return image }
        bitmap.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: bitmap.size)
        result.addRepresentation(bitmap)
        return result
    }
}

/// The filmstrip row above the request list: each screenshot with its time
/// since the recording began. A click lists the requests finished by then
/// (and a second click lists them all again); resting on one shows it larger.
struct DeveloperNetworkFilmstripView: View {
    @ObservedObject var filmstrip: DeveloperNetworkFilmstrip
    /// The recording's start, in WebKit's seconds.
    let origin: Double
    @Binding var selected: Double?
    @State private var hovered: Int?

    static let height: CGFloat = 84

    var body: some View {
        Group {
            if filmstrip.frames.isEmpty {
                Text("Screenshots are captured while the page loads. Reload the page to capture them.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: DeveloperToolsStyle.rowHeight, alignment: .center)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(filmstrip.frames) { frame in thumbnail(frame) }
                    }
                    .padding(.horizontal, DeveloperToolsStyle.gutter)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
                .frame(height: Self.height)
            }
        }
        .background(DeveloperToolsStyle.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(DeveloperToolsStyle.rule.opacity(0.55)).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Screenshots")
        .accessibilityIdentifier("developer-network-filmstrip")
    }

    private func label(_ frame: DeveloperNetworkFilmstrip.Frame) -> String {
        DeveloperNetworkTimingPopover.seconds(max(0, (frame.time - origin) * 1_000))
    }

    private func thumbnail(_ frame: DeveloperNetworkFilmstrip.Frame) -> some View {
        let chosen = selected == frame.time
        return VStack(spacing: 2) {
            Image(nsImage: frame.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: Self.height - 26)
                .overlay {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(chosen ? DeveloperToolsStyle.tint : DeveloperToolsStyle.rule.opacity(0.6),
                                      lineWidth: chosen ? 2 : 1)
                }
            Text(label(frame))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(chosen ? DeveloperToolsStyle.tint : Color.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { selected = chosen ? nil : frame.time }
        .onHover { inside in
            if inside { hovered = frame.id } else if hovered == frame.id { hovered = nil }
        }
        .popover(isPresented: Binding(get: { hovered == frame.id }, set: { shown in
            if !shown && hovered == frame.id { hovered = nil }
        }), arrowEdge: .bottom) {
            VStack(spacing: 4) {
                Image(nsImage: frame.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 420)
                Text(label(frame)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .accessibilityElement()
        .accessibilityLabel("Screenshot at " + label(frame))
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { selected = chosen ? nil : frame.time }
        .help(chosen ? "Show all requests" : "Show requests finished by " + label(frame))
    }
}
