import SwiftUI
import AppKit
import CoreImage

enum ChromeAccent: String, CaseIterable, Identifiable {
    case page, graphite, blue, purple, pink, red, orange, green
    var id: String { rawValue }
    var title: String { self == .page ? "Match page" : rawValue.capitalized }
    var color: Color {
        switch self {
        case .page, .graphite: return Palette.ink
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .green: return .green
        }
    }
    func selection(for pageColor: NSColor?) -> Color {
        guard self == .page else { return self == .graphite ? Palette.wash : color.opacity(0.22) }
        guard let rgb = pageColor?.usingColorSpace(.deviceRGB), rgb.saturationComponent > 0.08
        else { return Palette.wash }
        return resolved(for: rgb).opacity(0.22)
    }

    func resolved(for pageColor: NSColor?) -> Color {
        self == .page ? pageColor.map { Color(nsColor: $0) } ?? Palette.ink : color
    }
}

/// Only the background blends with the live page; controls stay fully opaque.
struct ChromeBackground: View {
    @ObservedObject var prefs: Preferences
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Palette.ground.opacity(reduceTransparency ? 1 : 1 - prefs.chromeTransparency)
            .allowsHitTesting(false)
    }
}

struct PageChrome {
    var top: CGFloat = 0
    var side: CGFloat = 0
    var radius: Double = 0
}

/// Lives beside the WebKit view so its background contains the rendered page.
final class BackgroundBlurView: NSView {
    private var radius: Double = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        identifier = NSUserInterfaceItemIdentifier("page-chrome-backdrop")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setRadius(_ value: Double) {
        guard radius != value else { return }
        radius = value
        // Keep the backdrop opaque after the Gaussian samples beyond the page
        // edges. CIColorMatrix operates on unpremultiplied colors, so restoring
        // alpha preserves those colors and leaves transparency to its own layer.
        guard let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: value]),
              let opaque = CIFilter(name: "CIColorMatrix")
        else { backgroundFilters = []; return }
        opaque.setDefaults()
        opaque.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputAVector")
        opaque.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputBiasVector")
        backgroundFilters = [blur, opaque]
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
