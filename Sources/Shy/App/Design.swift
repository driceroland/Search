import SwiftUI
import AppKit

// Lifted from Office Inspiration, with the ground turned white: there the work
// floats on an off-white canvas, here the page *is* the ground and everything
// the browser draws has to get out of its way.
//
// Every colour is a pair — one for a light window, one for a dark — and
// resolves itself against whatever appearance the window has. The window
// takes its appearance from the app, and the app from Settings › Appearance:
// light, dark, or whatever the Mac is doing. Nothing else in the code knows
// which it is.
enum Palette {
    static let ground = Color(nsColor: NS.ground)
    static let ink = Color(nsColor: NS.ink)             // neutral-900 · neutral-100
    static let muted = Color(nsColor: NS.muted)         // neutral-500
    static let faint = Color(nsColor: NS.faint)         // neutral-300 · neutral-700
    static let hairline = Color(nsColor: NS.hairline)   // neutral-200 · neutral-800
    static let wash = Color(nsColor: NS.wash)           // the live tab
    /// The live pin: among squares that already wear a faint grey, the one
    /// you are on stands out from them as a live row does from the white.
    static let pinLive = Color(nsColor: NS.pinLive)
    static let hover = Color(nsColor: NS.hover)         // the one under the pointer
    /// Around the page's card, with the tabs down the side: the column, the
    /// bookmarks bar and the gaps share it, a touch off the page's white, so
    /// the card reads as one (see CardEdge).
    static let frame = Color(nsColor: NS.frame)
    /// The column's own greys, on that ground: the live tab, the one under the
    /// pointer, the resting pin squares and the live pin. The white column's
    /// wash, hover and pinLive all but vanished on it (Drice: the pins' squares
    /// and the open tab no longer showed), so these keep the same steps of
    /// contrast from the frame that those kept from the white.
    static let sideWash = Color(nsColor: NS.sideWash)
    static let sideHover = Color(nsColor: NS.sideHover)
    static let sideTile = Color(nsColor: NS.sideTile)
    static let sidePinLive = Color(nsColor: NS.sidePinLive)
    /// The only two that aren't grey: a connection nobody can read on the
    /// way, and one anybody can (see SiteCard.swift).
    static let safe = Color(nsColor: NS.safe)           // green-700 · green-400
    static let unsafe = Color(nsColor: NS.unsafe)       // amber-700 · amber-400

    /// The same colours for the AppKit corners of the app — a text field's
    /// ink, a window's background — which want an NSColor and keep it.
    enum NS {
        static let ground = pair(1.0, 0.11)
        static let ink = pair(0.09, 0.93)
        static let muted = pair(0.55, 0.58)
        static let faint = pair(0.83, 0.32)
        static let hairline = pair(0.91, 0.20)
        static let wash = pair(0.937, 0.175)
        static let pinLive = pair(0.90, 0.21)
        static let hover = pair(0.965, 0.15)
        static let frame = pair(0.955, 0.075)
        static let sideWash = pair(0.895, 0.155)
        static let sideHover = pair(0.915, 0.13)
        static let sideTile = pair(0.925, 0.115)
        static let sidePinLive = pair(0.86, 0.19)
        /// The resting traffic lights, drawn by hand when the app is behind.
        static let resting = pair(0.80, 0.30)
        static let safe = tint(light: (0.08, 0.50, 0.24), dark: (0.29, 0.87, 0.50))
        static let unsafe = tint(light: (0.71, 0.33, 0.04), dark: (0.98, 0.75, 0.14))

        private static func tint(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
            NSColor(name: nil) { appearance in
                let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
            }
        }

        private static func pair(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
            NSColor(name: nil) { appearance in
                let dim = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(white: dim ? dark : light, alpha: 1)
            }
        }
    }
}

/// The greys of the column's rows, pins and buttons, for the ground they lie
/// on: the white's (the strip, a panel, the column with the page edge to
/// edge) or the window's beside the page's card, set by the column for
/// what is in it (see SideBar.onFrame). Read through the environment, so a
/// row, a pin or a door is the same view on either ground.
struct Greys {
    let wash: Color
    let hover: Color
    let tile: Color
    let pinLive: Color

    static let white = Greys(wash: Palette.wash, hover: Palette.hover,
                             tile: Palette.wash.opacity(0.55), pinLive: Palette.pinLive)
    static let frame = Greys(wash: Palette.sideWash, hover: Palette.sideHover,
                             tile: Palette.sideTile, pinLive: Palette.sidePinLive)
}

private struct GreysKey: EnvironmentKey {
    static let defaultValue = Greys.white
}

extension EnvironmentValues {
    var greys: Greys {
        get { self[GreysKey.self] }
        set { self[GreysKey.self] = newValue }
    }
}

/// Light, dark, or the Mac's own — the one choice that colours everything.
enum Look: String, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }

    /// What the app is told to be. Nothing, for "system": the app then
    /// follows the Mac, and changes with it.
    var appearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }

    /// Set on the app rather than on the window, so every panel, alert and
    /// sheet — and every page, which follows the window it is in — agrees.
    ///
    /// Never from inside whatever is happening when it is asked for: the
    /// switch in Settings changes it from within an animation, over a panel
    /// in transition, and re-skinning every window in the middle of that is
    /// how a window ends up with a layer that takes clicks and shows
    /// nothing. The next turn of the run loop is soon enough.
    func apply() {
        let wanted = appearance
        DispatchQueue.main.async {
            guard NSApp.appearance !== wanted, NSApp.appearance?.name != wanted?.name else { return }
            NSApp.appearance = wanted
        }
    }
}

enum Metrics {
    /// The tab strip. The window's title bar is grown to match it so the
    /// traffic lights come down with the tabs — otherwise giving the row room
    /// to breathe just leaves it sitting below three buttons it used to line
    /// up with.
    static let strip: CGFloat = 52
    /// With the tabs down the side the page is a card: this far from the
    /// window's edges (and from the column, folded away), and its corners
    /// this round.
    static let cardGap: CGFloat = 8
    static let cardRadius: CGFloat = 10
    /// Where the first tab starts. The traffic lights run from 19 to 79 —
    /// measured, not guessed — so this leaves them the same air on their right
    /// that the window gives them on their left.
    static let lights: CGFloat = 100
    /// Back, forward and reload, at the far end of the row beside the
    /// bookmarks: three doors and the air before the next one.
    static let helm: CGFloat = 3 * 26 + 2 * 2 + 8
    /// The same three doors again, in the sidebar, where they sit right of
    /// the lights instead. The column already has 10 of horizontal padding
    /// of its own before this even starts. 72 put the back door's box 3
    /// points from the zoom button and its chevron 12, "a little tight"
    /// (feedback, 22 Oct 2026): at 80 the chevron is 20 points clear of the
    /// lights, about the 19 the window leaves on their left, as a toolbar's
    /// first item sits in Safari. A column too narrow for that gives back
    /// what it must (SideBar.lights), down to where it was.
    static let sideLights: CGFloat = 80
    /// The three doors' own width, without the air after them.
    static let helmDoors: CGFloat = 3 * 26 + 2 * 4
    /// The band left at the top when there is no strip: just enough for the
    /// traffic lights to sit in, and nothing else.
    static let bare: CGFloat = 34
    /// Tabs are a fixed width rather than the width of their titles, so the
    /// cross always lands in the same place and the row never rearranges
    /// itself while you read it. They give way when there are too many:
    /// narrower than tabTitled they show their site's mark alone, and they
    /// stop at tabMinWidth, the mark and its air. Past that the row scrolls,
    /// inside its own edges.
    static let tabTitled: CGFloat = 80
    static let tabMinWidth: CGFloat = 36
    /// The address field, in both the places it shows up.
    static let fieldWidth: CGFloat = 560
    /// The column of titles down the left, in the way that has one.
    static let side: CGFloat = 232
    static let sideMin: CGFloat = 176
    static let sideMax: CGFloat = 440
}

// One spring for anything that moves between two places, one for anything that
// arrives or leaves. Using the same two everywhere is most of why a thing feels
// like a single piece of software rather than a pile of views.
// When macOS Reduce Motion is on in System Settings, transitions become
// immediate so the interface does not jump or slide.
enum Motion {
    /// Whether interface transitions should be immediate, following the
    /// Mac's own accessibility setting.
    static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Whether the Mac is short of power: Low Power Mode is on, or it is hot
    /// enough that macOS is holding its processors back. Then the two springs
    /// below become a short ease-out. A spring keeps moving long after it
    /// looks done: glide takes about 0.5 s to settle, 30 frames that SwiftUI
    /// works out one by one on the main thread, which is the thread a busy or
    /// slowed Mac takes time from first, and every frame it misses shows as a
    /// stutter. 0.16 s is 10 frames, and is over before a missed one shows.
    /// Read at the moment something moves, so it follows the switch at once.
    /// Only once it is turned on in Settings › General (Preferences.lightMotion).
    static var light: Bool {
        guard Store.settings.bool(forKey: lightKey) else { return false }
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled || info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    nonisolated static let lightKey = "motion.light"

    static var glide: Animation? {
        reduced ? nil : light ? .easeOut(duration: 0.16) : .spring(response: 0.34, dampingFraction: 0.82)
    }

    static var settle: Animation? {
        reduced ? nil : light ? .easeOut(duration: 0.16) : .spring(response: 0.30, dampingFraction: 0.86)
    }

    static var quick: Animation? {
        reduced ? nil : .easeOut(duration: 0.14)
    }

    /// The folded column or strip coming out over the page, and going back.
    /// On glide it was slow both ways, next to Arc and Dia timed frame by
    /// frame on the same Mac: each slides its sidebar 90% of the way out in
    /// about 95ms and back in about 70ms, where glide took over 200ms. These
    /// match them. Going in is damped all the way, since nothing is arriving
    /// to settle. Fold.slide moves the window's buttons on the same numbers,
    /// in Core Animation's terms.
    static func fold(out: Bool) -> (response: Double, damping: Double) {
        out ? (0.14, 0.86) : (0.13, 1)
    }

    static func folding(out: Bool) -> Animation? {
        let spring = fold(out: out)
        return reduced ? nil : .spring(response: spring.response, dampingFraction: spring.damping)
    }
}

/// Shy's mark — the word "shy", lowercase, in Times New Roman Bold: black
/// type the way a newspaper prints it. The letters are the font's own glyph
/// outlines written out as path data rather than set as text, so it stays a
/// crisp vector at any size and doesn't lean on the font being there. No
/// plate, no square behind it: the mark draws the word and nothing else, the way every other icon
/// in this app is a bare shape rather than a shape on a background. The one
/// exception is the macOS app icon (`Icon/icon.swift`), which needs an
/// opaque square whether the mark wants one or not — that's the Dock's
/// requirement, not the logo's.
struct Logomark: Shape {
    /// The word's own bounding box, set at 1000 to the em: nothing outside it.
    static let canvas = CGSize(width: 1396.5, height: 877.9)

    /// "shy" as three outlines, one per letter, y running down from the top
    /// of the h. The same path as Icon/icon.swift.
    private static let data = "M282.7 192.9L290 348.6L273.4 348.6C253.6 302.4 233 270.8 211.7 253.9C190.3 237 169.1 228.5 147.9 228.5C134.6 228.5 123.2 233 113.8 241.9C104.3 250.9 99.6 261.2 99.6 272.9C99.6 281.7 102.9 290.2 109.4 298.3C119.8 311.7 148.9 334.6 196.8 366.9C244.6 399.3 276.1 426.8 291.3 449.5C306.4 472.1 314 497.4 314 525.4C314 550.8 307.6 575.7 294.9 600.1C282.2 624.5 264.3 643.2 241.2 656.2C218.1 669.3 192.5 675.8 164.6 675.8C142.7 675.8 113.6 668.9 77.1 655.3C67.4 651.7 60.7 649.9 57.1 649.9C46.4 649.9 37.4 658 30.3 674.3L14.2 674.3L6.3 510.3L22.9 510.3C37.6 553.2 57.7 585.4 83.3 606.9C108.8 628.4 133 639.2 155.8 639.2C171.4 639.2 184.2 634.4 194.1 624.8C204 615.2 209 603.5 209 589.8C209 574.2 204.1 560.7 194.3 549.3C184.6 537.9 162.8 520.7 128.9 497.6C79.1 463.1 46.9 436.7 32.2 418.5C10.7 391.8 0 362.3 0 330.1C0 294.9 12.1 263.1 36.4 234.6C60.6 206.1 95.7 191.9 141.6 191.9C166.3 191.9 190.3 197.9 213.4 210C222.2 214.8 229.3 217.3 234.9 217.3C240.7 217.3 245.4 216.1 249 213.6C252.6 211.2 258.3 204.3 266.1 192.9ZM569.8 0L569.8 264.2C594.9 237.8 617.8 219.2 638.7 208.3C659.5 197.3 681.2 191.9 703.6 191.9C732.3 191.9 756.8 200 777.1 216.3C797.4 232.6 811 251.7 817.6 273.7C824.3 295.7 827.6 332.7 827.6 384.8L827.6 563C827.6 597.8 830.9 619.5 837.4 628.2C843.9 636.8 857.1 642.3 877 644.5L877 662.1L645.5 662.1L645.5 644.5C661.8 642.3 674 635.7 682.1 625C688 616.5 690.9 595.9 690.9 563L690.9 359.4C690.9 321.6 689.5 297.9 686.5 288.3C683.6 278.7 678.6 271.2 671.6 265.9C664.6 260.5 656.7 257.8 647.9 257.8C634.9 257.8 622.2 262.3 609.9 271.2C597.5 280.2 584.1 295.9 569.8 318.4L569.8 563C569.8 595.5 572.3 615.9 577.1 624C583.3 635.1 596 641.9 615.2 644.5L615.2 662.1L383.8 662.1L383.8 644.5C403 642.6 416.7 636.4 424.8 626C430.3 618.8 433.1 597.8 433.1 563L433.1 99.1C433.1 64.6 429.9 43.1 423.6 34.7C417.2 26.2 404 20.7 383.8 18.1L383.8 0ZM1148.9 680.7L1001.5 342.3C979.3 291.2 963 259.8 952.4 248C941.8 236.3 929 228.2 914.1 223.6L914.1 205.6L1156.7 205.6L1156.7 223.6C1140.8 224.3 1129.6 227.4 1123 232.9C1116.5 238.4 1113.3 245.1 1113.3 252.9C1113.3 265.3 1121.4 289.7 1137.7 326.2L1215.8 504.9L1269 366.7C1288.2 317.5 1297.9 283.4 1297.9 264.2C1297.9 252.1 1293.9 242.5 1285.9 235.4C1277.9 228.2 1263.8 224.3 1243.7 223.6L1243.7 205.6L1396.5 205.6L1396.5 223.6C1381.5 225.3 1369.3 231 1359.9 241C1350.4 250.9 1334.6 284.7 1312.5 342.3L1182.1 680.7C1149.3 765.3 1124.8 817.4 1108.9 836.9C1086.4 864.3 1058.3 877.9 1024.4 877.9C997.4 877.9 975.5 870.2 958.7 854.7C942 839.3 933.6 820.6 933.6 798.8C933.6 779.9 939.4 764.3 950.9 752C962.5 739.6 976.7 733.4 993.7 733.4C1009.9 733.4 1023 738.6 1033 749C1042.9 759.4 1048 775.6 1048.3 797.4C1048.7 809.7 1050.1 817.7 1052.7 821.3C1055.3 824.9 1059.1 826.7 1064 826.7C1071.8 826.7 1080.1 821.9 1088.9 812.5C1101.9 798.8 1117.2 767.6 1134.8 718.8Z"

    func path(in rect: CGRect) -> Path {
        // Fit the canvas into whatever frame this is given, centred, at the
        // larger scale that still keeps it inside — an SVG viewBox's "meet".
        let scale = min(rect.width / Logomark.canvas.width, rect.height / Logomark.canvas.height)
        let ox = rect.midX - Logomark.canvas.width * scale / 2
        let oy = rect.midY - Logomark.canvas.height * scale / 2
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * scale, y: oy + y * scale) }
        var path = Path()
        var last = CGPoint.zero
        var start = CGPoint.zero
        for (c, n) in Logomark.commands {
            switch c {
            case "M": last = CGPoint(x: n[0], y: n[1]); start = last; path.move(to: pt(n[0], n[1]))
            case "L": last = CGPoint(x: n[0], y: n[1]); path.addLine(to: pt(n[0], n[1]))
            case "H": last.x = n[0]; path.addLine(to: pt(last.x, last.y))
            case "V": last.y = n[0]; path.addLine(to: pt(last.x, last.y))
            case "C":
                var k = 0
                while k + 5 < n.count {
                    path.addCurve(to: pt(n[k + 4], n[k + 5]), control1: pt(n[k], n[k + 1]), control2: pt(n[k + 2], n[k + 3]))
                    last = CGPoint(x: n[k + 4], y: n[k + 5])
                    k += 6
                }
            case "Z": path.closeSubpath(); last = start
            default: break
            }
        }
        return path
    }

    /// Read once. Absolute M, L, H, V, C, Z — what Figma writes for a
    /// flattened shape, and nothing else is needed.
    private static let commands: [(Character, [CGFloat])] = {
        var out: [(Character, [CGFloat])] = []
        var current: Character?
        var numbers: [CGFloat] = []
        var token = ""
        func flush() {
            if !token.isEmpty, let v = Double(token) { numbers.append(CGFloat(v)) }
            token = ""
        }
        for ch in data {
            if "MLHVCZ".contains(ch) {
                flush()
                if let current { out.append((current, numbers)) }
                current = ch
                numbers = []
            } else if ch == " " || ch == "," {
                flush()
            } else if ch == "-" && !token.isEmpty {
                flush()
                token = "-"
            } else {
                token.append(ch)
            }
        }
        flush()
        if let current { out.append((current, numbers)) }
        return out
    }()
}

/// Wrong address, said without a dialog: the field shivers and stops.
struct Shake: GeometryEffect {
    var travel: CGFloat

    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        guard !Motion.reduced else { return ProjectionTransform(.identity) }
        // Three there-and-backs, tapering to nothing, so it settles rather than
        // stopping mid-swing.
        let decay = 1 - travel
        return ProjectionTransform(
            CGAffineTransform(translationX: sin(travel * .pi * 6) * 7 * decay, y: 0)
        )
    }
}

extension View {
    /// What a popover holds, on the ground colour. From macOS 26 a popover
    /// clips what it holds to its own rounded glass; before, an opaque
    /// background was drawn out to the content's square edges, past the
    /// popover's rounded corners (macOS 15, by email). There the popover is
    /// handed the colour and fills its own shape with it, arrow included.
    /// `card`: drawn as its own rounded card, with an edge, on macOS 26.
    func popoverGround(card: Bool = false) -> some View {
        modifier(PopoverGround(card: card))
    }
}

private struct PopoverGround: ViewModifier {
    let card: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if card {
                content
                    .background(Palette.ground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            } else {
                content.background(Palette.ground)
            }
        } else {
            content.presentationBackground(Palette.ground)
        }
    }
}

/// The page as a card in the window, with the tabs down the side: round
/// corners, a hairline edge and a soft shadow under it. The shadow is drawn
/// by a shape behind the page, never by the page's own layers, which would
/// make WebKit's drawing go through it; the page's view is rounded by its own
/// layer as well (see StageView), since a web view is AppKit's and a clip of
/// SwiftUI's is not always carried down to it. Two pages side by side are a
/// card each, drawn by the stage that holds them (see PaneStage).
struct CardEdge: ViewModifier {
    let on: Bool

    // One shape of view, on or off: a page whose view were rebuilt as the
    // card comes and goes (the tabs across the top, a video taking the
    // screen) would be handed to a new stage just as WebKit takes it to its
    // full screen window. Off, the clip reaches far past the page and cuts
    // nothing, and the edge and shadow are clear.
    func body(content: Content) -> some View {
        content
            .clipShape(CardShape(on: on))
            .background {
                CardShape(on: on)
                    .fill(on ? Palette.ground : .clear)
                    .shadow(color: .black.opacity(on ? CardEdge.shadow : 0), radius: 6, y: 1)
            }
            .overlay {
                CardShape(on: on)
                    .strokeBorder(Color.primary.opacity(on ? CardEdge.edge : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    /// How dark the shadow and the edge are, for the stage's own cards too.
    static let shadow: Double = 0.07
    static let edge: Double = 0.08
}

/// The card's outline: round at its corners, or, off, a rectangle reaching
/// far past the page on every side.
private struct CardShape: InsettableShape {
    let on: Bool
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        guard on else { return Path(rect.insetBy(dx: -10_000, dy: -10_000)) }
        return RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            .path(in: rect.insetBy(dx: inset, dy: inset))
    }

    func inset(by amount: CGFloat) -> CardShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}
