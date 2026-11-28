import AppKit
import SwiftUI

/// One frame of Performance's screenshots filmstrip.
struct DeveloperPerformanceScreenshot: Equatable {
    /// ms from the recording's start.
    let time: Double
    /// A data: URL, or bare base64, as WebKit's Screenshot record carries it.
    let imageData: String

    @MainActor var image: NSImage? { DeveloperPerformanceScreenshots.image(imageData) }
}

/// Performance's Memory checkbox: a recording also tracks the JS heap.
/// Read when recording starts, by Record, ⌘E and the command menu alike.
enum DeveloperPerformanceMemory {
    static let key = "developerTools.performance.memory"

    static var enabled: Bool {
        get { DevDefaults.store.bool(forKey: key) }
        set { DevDefaults.store.set(newValue, forKey: key) }
    }
}

/// The recording's opt-out from WebKit's sampling profiler.
enum DeveloperPerformanceCapture {
    static let samplesKey = "developerTools.performance.disableJavaScriptSamples"

    static var jsSamplesDisabled: Bool {
        get { DevDefaults.store.bool(forKey: samplesKey) }
        set { DevDefaults.store.set(newValue, forKey: samplesKey) }
    }
}

@MainActor
enum DeveloperPerformanceScreenshots {
    static let key = "developerPerformanceScreenshots"

    /// The Screenshots checkbox, on by default as in Chrome.
    static var enabled: Bool {
        get { DevDefaults.store.object(forKey: key) as? Bool ?? true }
        set { DevDefaults.store.set(newValue, forKey: key) }
    }

    private static var cache: [Int: NSImage] = [:]

    nonisolated static func decode(_ data: String) -> Data? {
        let base64 = data.range(of: "base64,").map { String(data[$0.upperBound...]) } ?? data
        return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
    }

    static func image(_ data: String) -> NSImage? {
        let key = data.hashValue
        if let image = cache[key] { return image }
        guard let bytes = decode(data), let image = NSImage(data: bytes) else { return nil }
        if cache.count > 300 { cache.removeAll() }
        cache[key] = image
        return image
    }

    /// The frames to draw along a strip `width` points wide, each `slot`
    /// points apart: for each slot, the last frame taken by its time.
    nonisolated static func strip(_ shots: [DeveloperPerformanceScreenshot], duration: Double, width: Double,
                                  slot: Double) -> [(x: Double, shot: DeveloperPerformanceScreenshot)] {
        guard !shots.isEmpty, duration > 0, width > 0, slot > 0 else { return [] }
        var result: [(Double, DeveloperPerformanceScreenshot)] = []
        var x = 0.0
        var index = 0
        while x < width {
            let time = (x + slot) / width * duration
            while index + 1 < shots.count, shots[index + 1].time <= time { index += 1 }
            if shots[index].time <= time { result.append((x, shots[index])) }
            x += slot
        }
        return result
    }
}

/// The filmstrip over Performance's overview.
struct DeveloperPerformanceFilmstrip: View, Equatable {
    let profile: DeveloperPerformanceProfile

    static func == (a: Self, b: Self) -> Bool { a.profile == b.profile }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let first = profile.screenshots.first?.image
            let aspect = first.map { $0.size.width / max($0.size.height, 1) } ?? 1.6
            let slot = max(12, Double(height * aspect) + 2)
            let frames = DeveloperPerformanceScreenshots.strip(profile.screenshots, duration: profile.bounds.upperBound,
                                                                width: Double(geometry.size.width), slot: slot)
            ZStack(alignment: .topLeading) {
                ForEach(frames.indices, id: \.self) { index in
                    if let image = frames[index].shot.image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: slot - 2, height: height)
                            .border(Color.secondary.opacity(0.3), width: 0.5)
                            .offset(x: frames[index].x)
                    }
                }
            }
        }
        .clipped()
        .accessibilityElement()
        .accessibilityLabel("Screenshots")
        .accessibilityValue("\(profile.screenshots.count) screenshots")
    }
}
