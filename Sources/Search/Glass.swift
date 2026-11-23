import AppKit
import SwiftUI

// The window as glass, as Arc and Zen have it: the ground the page's card
// and the column sit on lets what is behind the window through, blurred,
// under a tint and a grain. Only for whoever turns it on (Settings ›
// Appearance › Window › Glass); off, nothing here is drawn and the window
// is as opaque as it always was.
//
// In either layout. The glass is laid once, under everything, as the
// window's ground; the column and the bookmarks bar, which paint a ground
// of their own, leave it out while there is glass, and the page stays as
// opaque as it always is. Not in full screen, where there is nothing
// behind the window to see, and not for a folded column (see glassUnder),
// which is out over the page when it shows at all, where the desktop would
// show through the page.
//
// The layers, bottom up: the Mac's own blur of what is behind the window,
// the tint and the grain. The tint is the space's own colour or gradient:
// the wash the column, the strip and the bars lay over a solid ground is
// far too faint to read on glass, so on glass they leave it out and the
// glass wears the colour instead, once, under all of them. Transparency
// takes the colour off, down to the glass alone; the blur is always whole.
// Transparency and Grain are chosen where the colour is, in the space's
// Colour… (see SpaceLookPicker), and hold for every space; with spaces off,
// where there is no Colour…, in Settings under Glass.

extension Browser {
    /// Whether this window is glass right now.
    var glassy: Bool { prefs.glass && !fullScreen }

    /// Whether the column lies on the glass, and so leaves out a ground of
    /// its own: not while it is folded, when it is out over the page
    /// whenever it shows, sliding out or back in included.
    var glassUnder: Bool { glassy && !folded }

    /// The window under the views: clear for glass, otherwise the colour of
    /// the ground, so a resize or a slide never shows another colour at the
    /// edge for a frame.
    func paintGround(_ window: NSWindow?) {
        guard let window else { return }
        if glassy {
            window.isOpaque = false
            window.backgroundColor = .clear
        } else {
            window.isOpaque = true
            window.backgroundColor = asCards ? Palette.NS.frame : Palette.NS.ground
        }
    }
}

/// The glass the card and the column sit on, tinted with the space's
/// colour or gradient (its menu › Colour…), or the plain ground for a space
/// with none, as much as Transparency leaves, under the Grain.
struct GlassGround: View {
    @ObservedObject var prefs: Preferences
    let look: SpaceLook?
    /// Whether the spaces wear their colours at all (Browser.wash).
    let on: Bool
    let spaces: [Space]
    /// The two spaces a swipe has in sight, the one fading into the other
    /// (SwipeBlend), as SpaceWash has them.
    @ObservedObject var blend: SwipeBlend
    let toward: SwipeToward
    @Environment(\.washStrength) private var strength
    @Environment(\.washRoom) private var room
    @Environment(\.colorScheme) private var scheme

    /// The colour at Transparency nought: as much as there can be and the
    /// window still reads as glass rather than as a painted one.
    static let mostTint = 0.31
    /// Grain at one: past the gradient's faint grain, and no further than
    /// still reads as glass rather than as noise.
    static let mostGrain = 0.113

    init(_ browser: Browser) {
        prefs = browser.prefs
        look = browser.wash
        on = browser.prefs.usesSpaces && !browser.makingSpace
        spaces = browser.spaces
        blend = browser.swipeBlend
        toward = browser.swipeToward
    }

    var body: some View {
        ZStack {
            // The blur is always whole; Transparency takes the colour off it,
            // down to the glass alone.
            material
            let ends = on ? blend.ends : nil
            let clear = (1 - prefs.glassClear) * Self.mostTint
            tint(ends.map { SwipeBlend.look(of: $0.near, in: spaces) } ?? (look, strength))
                .opacity(clear)
                .modifier(SwipeWeight(toward: toward, side: ends == nil ? nil : .near))
            if let ends {
                tint(SwipeBlend.look(of: ends.far, in: spaces))
                    .opacity(clear)
                    .modifier(SwipeWeight(toward: toward, side: .far))
            }
            if prefs.glassGrain > 0 {
                Image(nsImage: Grain.tile)
                    .resizable(resizingMode: .tile)
                    .opacity(prefs.glassGrain * Self.mostGrain)
            }
        }
        .allowsHitTesting(false)
        // From one pair of spaces to the next with the rows, as SpaceWash.
        .transaction(value: on ? blend.ends : nil) { $0.animation = nil }
        .animation(Motion.quick, value: look)
    }

    @ViewBuilder private var material: some View {
        if prefs.glassStyle == .liquid, #available(macOS 26, *) {
            LiquidGlass()
        } else {
            BehindWindow()
        }
    }

    /// The colour itself, at its full strength: Transparency says how much
    /// of it lies on the glass.
    /// Toned as the wash tones it (Subtle, Rich or Vivid), so a space keeps
    /// the hue it has without glass.
    @ViewBuilder private func tint(_ worn: (look: SpaceLook?, strength: SpaceStrength)) -> some View {
        let dark = scheme == .dark
        switch worn.look {
        case .colour(let colour)? where Spaces.wash(colour, dark: dark) != nil:
            Spaces.toned(colour, worn.strength, dark: dark)
        case .gradient(let gradient)?:
            GeometryReader { geo in
                let ends = gradient.points(frame: geo.frame(in: .global), room: room)
                LinearGradient(stops: gradient.stops(strength: worn.strength, dark: dark), startPoint: ends.start, endPoint: ends.end)
            }
            .id(gradient)
            .transition(.opacity)
        default:
            Palette.frame
        }
    }
}

/// What is behind the window, blurred by the Mac. Kept active when the
/// window isn't key, as Arc keeps it: glass that turned grey whenever
/// another app came forward would be a different window each time.
private struct BehindWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The glass's kind: the Mac's frosted blur, or Liquid Glass.
enum GlassStyle: String, CaseIterable, Identifiable {
    case frosted, liquid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frosted: return "Frosted"
        case .liquid: return "Liquid"
        }
    }

    /// Liquid Glass is the Mac's from macOS 26; before that there is only
    /// frosted, and the choice isn't offered.
    static var liquidAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}

/// Liquid Glass, macOS 26's: one pane of it under the whole window, square
/// at its edges, which the window's own corners round.
@available(macOS 26, *)
private struct LiquidGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = 0
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {}
}
