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
    static let hover = Color(nsColor: NS.hover)         // the one under the pointer
    /// Around the page's card, with the tabs down the side: the column, the
    /// bookmarks bar and the gaps share it, a touch off the page's white, so
    /// the card reads as one (see CardEdge).
    static let frame = Color(nsColor: NS.frame)
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
        static let hover = pair(0.965, 0.15)
        static let frame = pair(0.955, 0.075)
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
    /// The live and hovered greys for a row lying on a tile (a Split View
    /// tab's panes), so the two together land where the plain ones do.
    let washOnTile: Color
    let hoverOnTile: Color
    /// The quiet ink of a tab's title that isn't live, the same way: on
    /// the plain ground Palette.muted exactly, on a space's Rich or Vivid
    /// colour as far from it as Palette.muted is from the plain ground,
    /// where the opaque grey lost a third of its contrast.
    let muted: Color
    /// The faintest ink, New tab's, the same way: on Vivid the opaque grey
    /// all but vanished into the colour.
    let faint: Color
    /// The hover of something that rests on `tile` (a pinned square): a
    /// step above it, short of `pinLive`. The plain `hover` is no darker
    /// than `tile` on the white (0.035 against 0.035), so a pin under the
    /// pointer didn't change at all.
    var tileHover: Color { wash }

    // Black in a light window, white in a dark one, at the strength that
    // lands on the same grey as Palette's over the ground they lie on (the
    // white, or the frame beside the card). On that ground nothing changes;
    // on a space's colour or gradient they take its tint, where an opaque
    // grey sat on it as a grey patch (Drice, 18 Nov 2026).
    static let white = Greys(wash: shade(0.063, 0.073), hover: shade(0.035, 0.045),
                             tile: shade(0.063, 0.073).opacity(0.55), pinLive: shade(0.10, 0.112),
                             washOnTile: shade(0.0294, 0.0342), hoverOnTile: shade(0.004, 0.005),
                             muted: shade(0.45, 0.5281), faint: shade(0.17, 0.236))
    static let frame = Greys(wash: shade(0.0628, 0.0865), hover: shade(0.0419, 0.0595),
                             tile: shade(0.0314, 0.0432), pinLive: shade(0.0995, 0.1243),
                             washOnTile: shade(0.0324, 0.0452), hoverOnTile: shade(0.0108, 0.0169),
                             muted: shade(0.4241, 0.5459), faint: shade(0.1309, 0.2649))

    private static func shade(_ light: CGFloat, _ dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: dark) : NSColor(white: 0, alpha: light)
        })
    }
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
    /// up with. Shorter tab bar, with the tabs across the top, takes it down
    /// to a few points above and below the 28-point tabs: a strip, not a
    /// toolbar. The column keeps the full band, as its first row shares it.
    @MainActor static var strip: CGFloat {
        Shared.prefs.compactStrip && !Shared.prefs.sidebar ? 36 : 52
    }
    /// With the tabs down the side the page is a card: this far from the
    /// window's edges (and from the column, folded away), and its corners
    /// this round.
    static let cardGap: CGFloat = 8
    static let cardRadius: CGFloat = 10

    /// The page's outline on its card: round at all four corners, or at the
    /// bottom two only when the row above the page is inside the card with
    /// it (Toolbar), the page's top a straight line under the row.
    static func cardOutline(_ corner: CGFloat, squareTop: Bool = false) -> UnevenRoundedRectangle {
        let top = squareTop ? 0 : corner
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: corner,
                                      bottomTrailingRadius: corner, topTrailingRadius: top, style: .continuous)
    }
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
    /// The least of it the fold door may have: its box 3 points clear of
    /// the zoom button (SideBar.folds).
    static let sideLightsLeast: CGFloat = 72
    /// The three doors' own width, without the air after them.
    static let helmDoors: CGFloat = 3 * 26 + 2 * 4
    /// The same two, for the doors Settings leaves shown (idea 815): all
    /// three unless some are hidden, nothing when none is, or when they are
    /// in the row above the page (Toolbar).
    @MainActor static func helm(_ prefs: Preferences) -> CGFloat {
        let n = CGFloat(prefs.rowHelmDoors)
        return n == 0 ? 0 : n * 26 + (n - 1) * 2 + 8
    }
    @MainActor static func helmDoors(_ prefs: Preferences) -> CGFloat {
        let n = CGFloat(prefs.rowHelmDoors)
        return n == 0 ? 0 : n * 26 + (n - 1) * 4
    }
    /// Tabs are a fixed width rather than the width of their titles, so the
    /// cross always lands in the same place and the row never rearranges
    /// itself while you read it. They give way when there are too many:
    /// narrower than tabTitled they show their site's mark alone, and they
    /// stop at tabMinWidth, the mark and its air. Past that the row scrolls,
    /// inside its own edges.
    static let tabWidth: CGFloat = 186
    /// A titled tab's own parts, end to end (TabPill.titled): its air at
    /// the left, the mark, a gap, the title, a gap, the spring at its
    /// least, a gap, the slot the cross and the ring take (kept while
    /// empty, so the title doesn't move under the pointer), its air at the
    /// right. Everything but the title.
    static let tabLead: CGFloat = 11
    static let tabTrail: CGFloat = 7
    static let tabMark: CGFloat = 15
    static let tabSpacing: CGFloat = 6
    static let tabSpring: CGFloat = 2
    static let tabCloseSlot: CGFloat = 15
    static let tabFixed: CGFloat = tabLead + tabMark + tabSpacing + tabSpacing + tabSpring + tabSpacing + tabCloseSlot + tabTrail
    /// The least a title is given: three letters and the "…", as most
    /// titles' letters run at 12.5 points ("Rec…" is 32, "Wea…" 35). Less
    /// than that and a tab showed its mark and a lone "…", or a letter or
    /// two, which says nothing a mark alone doesn't; it shows the mark
    /// alone instead.
    static let tabTitleRoom: CGFloat = 36
    /// A sign before the title (a blocked window, a translation), framed
    /// this wide; the bare ones (a script's flask, a private eye, the
    /// recording dot) are a symbol of 9 or 10 points, about tabGlyph.
    static let tabSign: CGFloat = 17
    static let tabGlyph: CGFloat = 12
    /// 104: narrower than this a tab is its mark alone.
    static let tabTitled: CGFloat = tabFixed + tabTitleRoom
    static let tabMinWidth: CGFloat = 36
    static let tabGap: CGFloat = 2
    /// A pinned tab is a square the height of the row, holding one letter.
    static let pinWidth: CGFloat = 30
    /// The square at the end of the row that opens a new page.
    static let plusWidth: CGFloat = 30
    /// What a full row of tabs still leaves past the plus to take the window
    /// by, as Chrome's does: the tabs give way before it. Without it they ran
    /// up to the buttons at the far end, and the corner the lights sit in was
    /// all of the row that moved the window.
    static let tabRowHold: CGFloat = 40
    /// The address field, in both the places it shows up.
    static let fieldWidth: CGFloat = 560
    /// The column of titles down the left, in the way that has one.
    static let side: CGFloat = 232
    static let sideMin: CGFloat = 176
    /// Narrower than this, with Narrow to icons on, the column is the strip
    /// of icons (Preferences.narrowStrip).
    static let narrowLine: CGFloat = 200
    static let sideMax: CGFloat = 440
}

/// The handle on an edge that pulls: the column's, the side panel's and the
/// one between two pages in Split View. Not a line the edge's whole height —
/// a short pill in the middle of it, as macOS and iPadOS draw theirs, that
/// grows a little and darkens under the pointer and while it is held. What
/// takes the pointer is still the whole edge; only the drawing is small.
enum Grip {
    static let width: CGFloat = 4
    /// Its length at rest, and under the pointer or held.
    static let rest: CGFloat = 28
    static let lit: CGFloat = 40
}

/// The pill itself (see Grip). `resting`: drawn, faint, before the pointer
/// comes; otherwise it is only there once the pointer is on the edge.
struct EdgeGrip: View {
    let lit: Bool
    var resting = false

    var body: some View {
        Capsule(style: .continuous)
            .fill(lit ? Palette.muted : Palette.faint)
            .frame(width: Grip.width, height: lit ? Grip.lit : Grip.rest)
            .opacity(lit || resting ? 1 : 0)
            .animation(Motion.quick, value: lit)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// An edge that resizes: the left-right cursor and hover, kept by AppKit.
/// SwiftUI's onHover with NSCursor push and pop missed the edge when the
/// pointer came in fast or from a page, and the page's own cursor then won,
/// so the edge only sometimes took the pointer. A cursor rect, and a
/// tracking area that sets the cursor on every move, hold it the whole time
/// the pointer is over the edge, as the split divider does (PaneStage.swift).
/// The view lets clicks through to the SwiftUI drag under it.
struct ResizeEdgeCursor: NSViewRepresentable {
    let hover: (Bool) -> Void

    func makeNSView(context: Context) -> EdgeCursorView {
        let view = EdgeCursorView()
        view.hover = hover
        return view
    }

    func updateNSView(_ view: EdgeCursorView, context: Context) {
        view.hover = hover
    }

    final class EdgeCursorView: NSView {
        var hover: ((Bool) -> Void)?
        private var inside = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                owner: self, userInfo: nil))
            window?.invalidateCursorRects(for: self)
        }

        override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func mouseMoved(with event: NSEvent) { NSCursor.resizeLeftRight.set() }

        override func mouseEntered(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
            set(true)
        }

        override func mouseExited(with event: NSEvent) { set(false) }

        private func set(_ on: Bool) {
            guard on != inside else { return }
            inside = on
            hover?(on)
        }
    }
}

extension View {
    /// The left-right cursor over this view, and whether the pointer is on it.
    func resizeEdge(hover: @escaping (Bool) -> Void) -> some View {
        overlay(ResizeEdgeCursor(hover: hover))
    }
}

// One spring for anything that moves between two places, one for anything that
// arrives or leaves. Using the same two everywhere is most of why a thing feels
// like a single piece of software rather than a pile of views.
// When macOS Reduce Motion is on in System Settings, or Reduce animations in
// Search's own, transitions become immediate so the interface does not jump
// or slide.
enum Motion {
    /// Whether interface transitions should be immediate, following the
    /// Mac's own accessibility setting or Search's Reduce animations.
    static var reduced: Bool {
        instant || (testReduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// A test run's stand-in for the Mac's Reduce Motion, so what Reduce
    /// animations does alone can be seen on a Mac that has it on.
    nonisolated(unsafe) static var testReduceMotion: Bool?

    /// Settings › Appearance › Reduce animations, for Search alone: every
    /// transition is immediate, as under Reduce Motion, and so are the fades
    /// Reduce Motion keeps. The tab ⌘1–⌘9 picks is lit at once, the page
    /// shows at once, a panel is there or gone. Kept here rather than read
    /// from the settings each time, since quick is asked for in nearly every
    /// row's body; Preferences sets it as it reads and writes the switch.
    nonisolated(unsafe) static var instant = false

    nonisolated static let instantKey = "motion.instant"

    /// `seconds`, or none with Reduce animations on: for the fades that run
    /// on a length of their own rather than on the animations below.
    static func seconds(_ seconds: TimeInterval) -> TimeInterval {
        instant ? 0 : seconds
    }

    /// `animation`, or none with Reduce animations on, the same way.
    static func timed(_ animation: Animation) -> Animation? {
        instant ? nil : animation
    }

    /// Whether the Mac is short of power: Low Power Mode is on, or it is hot
    /// enough that macOS is holding its processors back. Then the two springs
    /// below become a short ease-out. A spring keeps moving long after it
    /// looks done: glide takes about 0.5 s to settle, 30 frames that SwiftUI
    /// works out one by one on the main thread, which is the thread a busy or
    /// slowed Mac takes time from first, and every frame it misses shows as a
    /// stutter. 0.16 s is 10 frames, and is over before a missed one shows.
    /// Read at the moment something moves, so it follows the switch at once.
    /// Unless it is turned off in Settings › General (Preferences.lightMotion).
    static var light: Bool {
        guard lightOn else { return false }
        return lowPowerMode || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    /// The same switch, with Low Power Mode on and nothing else: idle tabs
    /// sleep sooner then (see Browser.sleepAfter). Heat alone doesn't count,
    /// since what a sleeping tab gives back is mostly memory, and a hot Mac
    /// has enough of that.
    static var savingPower: Bool {
        lightOn && lowPowerMode
    }

    /// The switch itself: on for everyone who never touched it (Drice, 25
    /// Nov 2026), as Preferences reads it.
    private static var lightOn: Bool {
        Retired.on(lightKey)
    }

    nonisolated static let lightKey = "motion.light"

    /// Low Power Mode, from Battery in System Settings, or a test run's stand-in
    /// for it: only an admin can turn the real one on.
    nonisolated(unsafe) static var testLowPower: Bool?

    private static var lowPowerMode: Bool {
        testLowPower ?? ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    static var glide: Animation? {
        reduced ? nil : light ? .easeOut(duration: 0.16) : .spring(response: 0.34, dampingFraction: 0.82)
    }

    static var settle: Animation? {
        reduced ? nil : light ? .easeOut(duration: 0.16) : .spring(response: 0.30, dampingFraction: 0.86)
    }

    static var quick: Animation? {
        reduced ? nil : .easeOut(duration: 0.14)
    }

    /// How far a tab gives while it is pressed (see Give): enough to feel
    /// under the pointer, about 3 points on a pill and 7 on a column row.
    static let give: CGFloat = 0.97

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

    /// How long the folded column takes to slide back in, or fade, and
    /// is still over the page: the spring's response (Motion.fold) runs a
    /// little past it.
    static var columnAway: TimeInterval {
        if reduced { return 0 }
        if fadesColumn { return fade }
        return slide(out: false) ?? 0.2
    }

    static func folding(out: Bool) -> Animation? {
        if reduced { return nil }
        if let slide = slide(out: out) {
            return out ? .easeOut(duration: slide) : .easeIn(duration: slide)
        }
        let spring = fold(out: out)
        return .spring(response: spring.response, dampingFraction: spring.damping)
    }

    /// Settings › Appearance › Slide the column in and out: the column comes
    /// out on an ease-out and goes back on an ease-in, over this long, as
    /// Arc's does, rather than on the short springs above. Nil when off.
    /// Read at the moment it moves, as `light` is.
    static func slide(out: Bool) -> TimeInterval? {
        guard Store.settings.bool(forKey: slidesKey) else { return nil }
        return out ? 0.26 : 0.22
    }

    nonisolated static let slidesKey = "sidebar.slides"

    /// Slide the column in and out with the Mac's Reduce Motion on: the
    /// column fades in place where it would slide, as Apple's own sidebars
    /// do under Reduce Motion, rather than doing nothing at all, which read
    /// as a switch that does nothing. Search's own Reduce animations still
    /// means at once (see `instant`).
    static var fadesColumn: Bool {
        !instant && slide(out: true) != nil
            && (testReduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// That fade's length.
    static let fade: TimeInterval = 0.2
}

/// Search's mark — Drice's Subtract.svg, a pill with an S cut out of it,
/// read from its own path data rather than loaded from a file, so it stays a
/// crisp vector at any size. No plate, no square behind it: the mark draws exactly
/// what the source file has and nothing it doesn't, the way every other icon
/// in this app is a bare shape rather than a shape on a background. The one
/// exception is the macOS app icon (`Icon/icon.swift`), which needs an
/// opaque square whether the mark wants one or not — that's the Dock's
/// requirement, not the logo's.
struct Logomark: Shape {
    /// The source's own canvas: Subtract.svg, 608 × 276, nothing outside it.
    static let canvas = CGSize(width: 608, height: 276)

    /// A pill with an S cut out of it. The same path as Icon/icon.swift and
    /// the website's mark.
    private static let data = "M469.443 0C545.471 0.00013198 607.103 61.6325 607.104 137.66C607.104 213.688 545.471 275.321 469.443 275.321H137.66C61.6323 275.321 0 213.688 0 137.66C0.00016085 61.6325 61.6325 0.000140192 137.66 0H469.443ZM138.104 51.5977C127.234 51.5977 117.512 53.5115 108.938 57.3389C100.518 61.0132 93.8581 66.2188 88.959 72.9551C84.2132 79.5381 81.8398 87.3464 81.8398 96.3789C81.8399 105.258 83.6773 112.607 87.3516 118.425C91.0258 124.089 95.9251 128.682 102.049 132.203C108.173 135.571 114.833 138.327 122.028 140.471L151.652 149.197C158.389 151.188 163.9 154.249 168.187 158.383C172.473 162.516 174.617 168.028 174.617 174.917C174.617 182.572 171.402 188.849 164.972 193.748C158.695 198.494 150.122 200.867 139.252 200.867C132.21 200.867 125.702 199.413 119.731 196.504C113.914 193.442 109.091 189.308 105.264 184.103C101.436 178.744 99.2169 172.697 98.6045 165.961H97.6855L75.4102 171.013C76.3287 180.658 79.697 189.308 85.5146 196.963C91.3322 204.618 98.9103 210.665 108.249 215.104C117.741 219.544 128.076 221.765 139.252 221.765C151.193 221.765 161.68 219.774 170.713 215.794C179.746 211.813 186.711 206.225 191.61 199.029C196.662 191.834 199.188 183.414 199.188 173.769C199.188 164.124 197.352 156.239 193.678 150.115C190.003 143.838 185.104 138.863 178.98 135.188C172.857 131.514 166.044 128.605 158.542 126.462L128.229 117.735C121.799 115.898 116.516 113.219 112.383 109.698C108.402 106.177 106.412 101.354 106.412 95.2305C106.412 88.188 109.168 82.6758 114.68 78.6953C120.344 74.5619 128.152 72.4951 138.104 72.4951C147.901 72.4952 155.939 74.9448 162.216 79.8438C168.493 84.7428 172.397 91.1729 173.928 99.1338H174.847L196.663 93.8525C195.745 85.5853 192.605 78.3131 187.247 72.0361C181.889 65.6061 174.923 60.6306 166.35 57.1094C157.929 53.4351 148.514 51.5977 138.104 51.5977Z"

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
    /// clips what it holds to its own rounded glass, and the background
    /// fills its arrow too; before, an opaque background was drawn out to the
    /// content's square edges, past the popover's rounded corners (macOS 15,
    /// by email). There the popover is handed the colour and fills its own
    /// shape with it, arrow included. The bookmarks list and card were drawn
    /// as a rounded card of their own inside the popover, which left the
    /// arrow in the popover's lighter glass beside the darker card; they're
    /// on the ground as the rest are now.
    func popoverGround() -> some View {
        modifier(PopoverGround())
    }
}

private struct PopoverGround: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.background(Palette.ground)
        } else {
            content.presentationBackground(Palette.ground)
        }
    }
}

/// What a row above the page (Toolbar, BookmarksBar) is drawn on.
enum RowGround {
    /// Its own ground, a hairline under it: edge to edge, or with the tabs
    /// across the top.
    case own
    /// The window's ground beside the page's card, and no line of its own:
    /// the card's edge is the line.
    case frame
    /// Inside the page's card, over the page: the card's top (CardHead)
    /// draws the ground and the edge, and the page's own edge is the line
    /// under the rows, so the row draws neither.
    case card
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
    /// Where the card lies in the view, for a card drawn over a page laid
    /// out larger than it (the window's page as ⌘S moves the column): the
    /// clip, ground and edge follow these, animated, and the page doesn't.
    var insets = EdgeInsets()
    var corner: CGFloat = Metrics.cardRadius
    /// The screen's scale, for the window's page: its edges on whole
    /// pixels, a hairline one pixel wide and no soft shadow around it, so
    /// the white of the page meets the window's grey on a sharp line. Zero
    /// keeps the soft card other cards are (the side panel, downloads).
    var scale: CGFloat = 0

    // One shape of view, on or off: a page whose view were rebuilt as the
    // card comes and goes (the tabs across the top, a video taking the
    // screen) would be handed to a new stage just as WebKit takes it to its
    // full screen window. Off, the clip reaches far past the page and cuts
    // nothing, and the edge and shadow are clear.
    func body(content: Content) -> some View {
        let shape = CardShape(on: on, insets: insets, corner: corner, scale: scale)
        let crisp = scale > 0
        content
            .clipShape(shape)
            .background {
                if crisp {
                    shape.fill(on ? Palette.ground : .clear)
                } else {
                    shape
                        .fill(on ? Palette.ground : .clear)
                        .shadow(color: .black.opacity(on ? CardEdge.shadow : 0), radius: 6, y: 1)
                }
            }
            .overlay {
                shape
                    .strokeBorder(Color.primary.opacity(on && corner > 0 ? CardEdge.edge : 0),
                                  lineWidth: crisp ? 1 / scale : 1)
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
    var insets = EdgeInsets()
    var corner: CGFloat = Metrics.cardRadius
    var scale: CGFloat = 0
    var inset: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>> {
        get { .init(.init(insets.top, insets.leading), .init(.init(insets.bottom, insets.trailing), corner)) }
        set {
            insets = EdgeInsets(top: newValue.first.first, leading: newValue.first.second,
                                bottom: newValue.second.first.first, trailing: newValue.second.first.second)
            corner = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard on else { return Path(rect.insetBy(dx: -10_000, dy: -10_000)) }
        func pixel(_ x: CGFloat) -> CGFloat { scale > 0 ? (x * scale).rounded() / scale : x }
        let card = CGRect(x: pixel(rect.minX + insets.leading), y: pixel(rect.minY + insets.top),
                          width: pixel(rect.width - insets.leading - insets.trailing),
                          height: pixel(rect.height - insets.top - insets.bottom))
        return RoundedRectangle(cornerRadius: max(0, corner), style: .continuous)
            .path(in: card.insetBy(dx: inset, dy: inset))
    }

    func inset(by amount: CGFloat) -> CardShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}

/// An offset kept to the screen's pixels while it animates, so what it
/// moves is never drawn between two of them, resampled and soft.
struct PixelOffset: GeometryEffect {
    var offset: CGSize
    var scale: CGFloat

    var animatableData: CGSize.AnimatableData {
        get { offset.animatableData }
        set { offset.animatableData = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        func pixel(_ x: CGFloat) -> CGFloat { scale > 0 ? (x * scale).rounded() / scale : x }
        return ProjectionTransform(CGAffineTransform(translationX: pixel(offset.width), y: pixel(offset.height)))
    }
}

/// The window's page cut to its card on every frame the card moves (see
/// StageView.clip): what the card is short of the page laid out under it,
/// across and down, and its corners, handed on as SwiftUI works each frame
/// out, so the page's edge and the card's are one.
struct CardClip: ViewModifier, Animatable {
    var card: EdgeInsets
    var corner: CGFloat
    let scale: CGFloat
    let on: Bool
    /// The row above the page inside the card (Toolbar): the page's top
    /// corners square under it, the card rounding its own above the row.
    var squareTop = false

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>> {
        get { .init(.init(card.top, card.leading), .init(.init(card.bottom, card.trailing), corner)) }
        set {
            card = EdgeInsets(top: newValue.first.first, leading: newValue.first.second,
                              bottom: newValue.second.first.first, trailing: newValue.second.first.second)
            corner = newValue.second.second
        }
    }

    func body(content: Content) -> some View {
        func pixel(_ x: CGFloat) -> CGFloat { scale > 0 ? (x * scale).rounded() / scale : x }
        let across = CGSize(width: pixel(card.leading + card.trailing), height: pixel(card.top + card.bottom))
        return content.background(Rider(across: on ? across : nil, corner: on ? max(0, corner) : 0,
                                        squareTop: on && squareTop))
    }

    /// The card, measured in the window: the room it leaves across and
    /// down, inside this view's own size. Read as the stage lays itself
    /// out, so the two are always of the same moment: handed a size worked
    /// out before the stage had grown, the card was cut short for a frame.
    private struct Rider: NSViewRepresentable {
        let across: CGSize?
        let corner: CGFloat
        let squareTop: Bool

        func makeNSView(context: Context) -> NSView { Unseen() }

        func updateNSView(_ view: NSView, context: Context) {
            guard let unseen = view as? Unseen, let window = view.window else { return }
            // The window's stage: two pages' (PaneStage), or the one page's.
            if unseen.stage?.window !== window {
                unseen.stage = Self.find(in: window.contentView)
            }
            let card: (() -> CGSize)? = across.map { across in
                { [weak unseen] in
                    guard let unseen else { return .zero }
                    return CGSize(width: unseen.bounds.width - across.width, height: unseen.bounds.height - across.height)
                }
            }
            switch unseen.stage {
            case let panes as PaneStage: panes.clip(card: card, corner: corner)
            case let one as StageView: one.clip(card: card, corner: corner, squareTop: squareTop)
            default: break
            }
        }

        private static func find(in view: NSView?) -> NSView? {
            guard let view else { return nil }
            if view is PaneStage || view is StageView { return view }
            for sub in view.subviews { if let found = find(in: sub) { return found } }
            return nil
        }

        private final class Unseen: NSView {
            weak var stage: NSView?
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                // The first frame's update may come before the window does.
                needsLayout = true
            }
        }
    }
}
