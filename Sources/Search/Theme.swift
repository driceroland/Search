import SwiftUI
import AppKit

// A colour for the frame around the page, the way Arc does it: one to three
// colours run together as a gradient, laid over the desktop behind the window
// — faint enough to see through, or strong enough to hide it — with a little
// grain if you like. Each space keeps its own, so the frame says where you are.
//
// Only the frame is coloured: the column, the strip, the room around them.
// Pages are never touched.

struct Theme: Codable, Equatable {
    /// Where each colour sits on the pad: across is the hue, down is how
    /// deep it is — pale at the top, rich at the bottom.
    struct Dot: Codable, Equatable {
        var x: Double
        var y: Double

        var color: Color {
            Color(hue: x, saturation: 0.12 + 0.8 * y, brightness: 1 - 0.28 * y)
        }
    }

    var dots: [Dot]
    /// 0 is the desktop through frosted glass, 1 the colours at full strength.
    var strength: Double
    var grain: Double
    /// How much of the desktop shows through, sharp rather than frosted: 0
    /// is frosted glass, 1 clear.
    var clarity: Double = 0

    var colors: [Color] {
        let all = dots.map(\.color)
        return all.count == 1 ? [all[0], all[0]] : all
    }

    static let presets: [Theme] = [
        Theme(dots: [Dot(x: 0.58, y: 0.55)], strength: 0.55, grain: 0),
        Theme(dots: [Dot(x: 0.75, y: 0.45), Dot(x: 0.93, y: 0.5)], strength: 0.6, grain: 0.3),
        Theme(dots: [Dot(x: 0.05, y: 0.55), Dot(x: 0.12, y: 0.45)], strength: 0.6, grain: 0.3),
        Theme(dots: [Dot(x: 0.33, y: 0.5), Dot(x: 0.5, y: 0.45)], strength: 0.5, grain: 0),
        Theme(dots: [Dot(x: 0.55, y: 0.3), Dot(x: 0.8, y: 0.35), Dot(x: 0.95, y: 0.3)], strength: 0.7, grain: 0.4),
        Theme(dots: [Dot(x: 0.62, y: 0.9)], strength: 0.9, grain: 0.2),
        Theme(dots: [Dot(x: 0.1, y: 0.15)], strength: 0.35, grain: 0),
    ]
}

extension Browser {
    /// The space's colour, live while the pad is dragged; written down once
    /// the drag lets go.
    func setTheme(_ theme: Theme?, keep: Bool = true) {
        guard let at = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        spaces[at].theme = theme
        if keep { Spaces.write(spaces) }
    }
}

/// What the frame is painted with: the plain ground with no theme, and with
/// one the desktop, frosted, under the colours and the grain.
struct ThemeGround: View {
    let theme: Theme?

    var body: some View {
        if let theme {
            ZStack {
                // Never quite nothing: a pixel with no colour at all lets
                // clicks fall through the window to whatever is behind it.
                Color.white.opacity(0.02)
                Frost().opacity(1 - theme.clarity)
                LinearGradient(colors: theme.colors, startPoint: .topLeading, endPoint: .bottom)
                    .opacity(theme.strength)
                if theme.grain > 0, let tile = Grain.tile {
                    Image(decorative: tile, scale: 2)
                        .resizable(resizingMode: .tile)
                        .blendMode(.overlay)
                        .opacity(theme.grain * 0.5)
                }
            }
            .allowsHitTesting(false)
        } else {
            Palette.ground
        }
    }
}

/// What sits on a coloured frame, as in Arc: white laid over the colour
/// rather than grey, so the frame's colour comes through everything on it.
/// The live tab nearly solid, a pinned tile or a row under the pointer faint.
enum Tint {
    static let live = pair(0.88, 0.16)
    static let hover = pair(0.30, 0.08)
    /// Arc's pinned tiles and address well sit a shade darker than the
    /// colour in light, a shade lighter in dark.
    static let well = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.055)
    })
    static let tile = well

    private static func pair(_ light: CGFloat, _ dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dim = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: 1, alpha: dim ? dark : light)
        })
    }
}


/// The desktop behind the window, blurred, in the window's light or dark.
private struct Frost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Grey noise, drawn once, tiled.
private enum Grain {
    static let tile: CGImage? = {
        let side = 128
        var bytes = [UInt8](repeating: 0, count: side * side)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        guard let context = CGContext(
            data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        return context.makeImage()
    }()
}

/// The picker, over the page's corner with nothing dimmed, so the frame can
/// be watched changing: light or dark, the pad, how strong, how grainy, and
/// a few to start from.
struct ThemePanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    private var theme: Theme? { browser.space.theme }

    var body: some View {
        Plate("Colour", width: 320, close: { browser.theming = false }) {
            VStack(alignment: .leading, spacing: 14) {
                Segmented(options: Look.allCases.map { ($0, $0.title) }, selection: $prefs.look)

                Pad(theme: theme ?? Theme.presets[0]) { changed, keep in browser.setTheme(changed, keep: keep) }
                    .frame(height: 170)

                HStack(spacing: 8) {
                    Pill("Add colour") {
                        var next = theme ?? Theme.presets[0]
                        let last = next.dots.last ?? Theme.Dot(x: 0.5, y: 0.5)
                        next.dots.append(Theme.Dot(x: (last.x + 0.15).truncatingRemainder(dividingBy: 1), y: last.y))
                        browser.setTheme(next)
                    }
                    .disabled((theme?.dots.count ?? 1) >= 3)
                    Pill("Remove") {
                        guard var next = theme else { return }
                        next.dots.removeLast()
                        browser.setTheme(next)
                    }
                    .disabled((theme?.dots.count ?? 1) <= 1)
                    Spacer(minLength: 0)
                    Pill("None") { browser.setTheme(nil) }
                        .disabled(theme == nil)
                }

                dial("Strength", \.strength)
                dial("Grain", \.grain)
                dial("Clear", \.clarity)

                HStack(spacing: 8) {
                    ForEach(Array(Theme.presets.enumerated()), id: \.offset) { _, preset in
                        Circle()
                            .fill(LinearGradient(colors: preset.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                            .overlay(Circle().strokeBorder(Palette.ink, lineWidth: 2).opacity(theme == preset ? 1 : 0))
                            .onTapGesture { browser.setTheme(preset) }
                    }
                }
            }
        } foot: {
            EmptyView()
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
    }

    private func dial(_ name: String, _ key: WritableKeyPath<Theme, Double>) -> some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .frame(width: 58, alignment: .leading)
            Slider(
                value: Binding(
                    get: { (theme ?? Theme.presets[0])[keyPath: key] },
                    set: { value in
                        var next = theme ?? Theme.presets[0]
                        next[keyPath: key] = value
                        browser.setTheme(next, keep: false)
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in if !editing { browser.setTheme(theme) } }
            )
            .controlSize(.small)
        }
    }
}

/// Every hue across, pale to rich down, and a dot for each colour, dragged
/// where you want it.
private struct Pad: View {
    let theme: Theme
    let change: (Theme, _ keep: Bool) -> Void

    var body: some View {
        GeometryReader { room in
            let size = room.size
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: stride(from: 0.0, through: 1.0, by: 1 / 12).map { Color(hue: $0, saturation: 0.55, brightness: 0.95) },
                    startPoint: .leading, endPoint: .trailing
                )
                LinearGradient(colors: [.white.opacity(0.65), .clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                ForEach(Array(theme.dots.enumerated()), id: \.offset) { index, dot in
                    Circle()
                        .fill(dot.color)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                        .position(x: dot.x * size.width, y: dot.y * size.height)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { drag in change(moved(index, to: drag.location, in: size), false) }
                                .onEnded { drag in change(moved(index, to: drag.location, in: size), true) }
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func moved(_ index: Int, to point: CGPoint, in size: CGSize) -> Theme {
        var next = theme
        next.dots[index] = Theme.Dot(
            x: min(max(point.x / size.width, 0), 1),
            y: min(max(point.y / size.height, 0), 1)
        )
        return next
    }
}
