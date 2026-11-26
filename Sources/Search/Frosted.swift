import AppKit
import SwiftUI
import WebKit

// The tab strip as frosted glass, as an iOS header is when the page scrolls
// under it (Settings › Appearance › Window › Frosted tab bar). Off, nothing
// here is drawn and the page starts under the strip as it always did.
//
// On, the page runs up behind the strip (and the bookmarks bar, if it is
// showing) and is told that this much of its top is covered, so it still
// begins just below, and scrolls up under the strip rather than being cut
// off at its edge. The strip blurs what is behind it, under a veil of the
// window's ground in light or dark, so at the top of a page it reads as the
// ground it always was and, once the page moves under it, as frosted glass,
// as Finder's toolbar does. How much blur, how much veil, and the hairline
// under it are its own settings, under the switch.
//
// Only with the tabs across the top, and not where the strip has no page
// under it: folded away, in full screen, or while two pages share the
// window, which keep the room they have. On glass too: the page covers the
// glass under the strip, so the strip shows the page, blurred, rather than
// the desktop.

extension Browser {
    /// Whether the strip is frosted, and the page lies under it, right now.
    var frostsStrip: Bool {
        FrostedStrip.available && prefs.frostedStrip && !prefs.sidebar && activeSplit == nil && !folded && !fullScreen
    }
}

/// The blur of the page behind the strip, as Finder's toolbar has it: the
/// page shows through softened and faint under a veil of the window's own
/// ground, so the strip keeps the app's colour and the page is only just
/// there, with a hairline where the page goes on below.
struct FrostedStrip: View {
    /// WebKit's own top content inset, which starts the page below the strip
    /// and lets it scroll up under it, as Safari's does. It works on every
    /// macOS Search runs on, where the public obscuredContentInsets needs 26,
    /// but is not in the public interface: asked for by name, and left alone
    /// if a WebKit doesn't know it, when the setting isn't offered.
    static var available: Bool {
        WKWebView.instancesRespond(to: NSSelectorFromString("_setTopContentInset:"))
            && WKWebView.instancesRespond(to: NSSelectorFromString("_topContentInset"))
    }

    private typealias Getter = @convention(c) (AnyObject, Selector) -> CGFloat
    private typealias Setter = @convention(c) (AnyObject, Selector, CGFloat) -> Void

    static func inset(of web: WKWebView) -> CGFloat {
        let get = NSSelectorFromString("_topContentInset")
        guard let imp = web.method(for: get) else { return 0 }
        return unsafeBitCast(imp, to: Getter.self)(web, get)
    }

    private typealias ImmediateSetter = @convention(c) (AnyObject, Selector, CGFloat, Bool) -> Void

    /// Set at once, and the page already on show moved along with it, as
    /// Safari does: set the ordinary way, a page laid out before it came
    /// (one brought back at launch, or open as the switch is turned on) kept
    /// its first line under the strip until it was scrolled.
    private typealias Flag = @convention(c) (AnyObject, Selector, Bool) -> Void

    static func setInset(_ top: CGFloat, of web: WKWebView) {
        // WebKit works the inset out for itself from the window's title bar
        // unless told not to, and did so again at every page load and every
        // change to the window, a click on the tabs among them: the page went
        // back under the strip and stayed there. Its own again with no inset,
        // as before the strip was frosted.
        let auto = NSSelectorFromString("_setAutomaticallyAdjustsContentInsets:")
        if web.responds(to: auto), let imp = web.method(for: auto) {
            unsafeBitCast(imp, to: Flag.self)(web, auto, top == 0)
        }
        let now = NSSelectorFromString("_setTopContentInset:immediate:")
        if web.responds(to: now), let imp = web.method(for: now) {
            unsafeBitCast(imp, to: ImmediateSetter.self)(web, now, top, true)
            return
        }
        let set = NSSelectorFromString("_setTopContentInset:")
        guard let imp = web.method(for: set) else { return }
        unsafeBitCast(imp, to: Setter.self)(web, set, top)
    }

    static func canInset(_ web: WKWebView) -> Bool {
        web.responds(to: NSSelectorFromString("_setTopContentInset:")) && web.responds(to: NSSelectorFromString("_topContentInset"))
    }

    @ObservedObject var prefs: Preferences

    /// The blur's radius at the setting's two ends.
    static func radius(_ blur: Double) -> Double { 4 + 36 * min(1, max(0, blur)) }

    var body: some View {
        Frost(radius: Self.radius(prefs.frostedBlur), veil: prefs.frostedTint)
            .overlay(alignment: .bottom) {
                if prefs.frostedLine { Rectangle().fill(Palette.hairline).frame(height: 1) }
            }
    }
}

/// A blur of whatever is behind it in the window, under a veil of the
/// window's ground: the backdrop layer the Mac's own materials are made of,
/// where a material over a page came out as a flat panel. The veil is a
/// layer of this view's own, over the blur: drawn by SwiftUI beside it, it
/// went under the blur and was blurred into the page. Looked up by name;
/// without it, the veil alone.
private struct Frost: NSViewRepresentable {
    var radius: Double
    var veil: Double

    func makeNSView(context: Context) -> Blur { Blur() }
    func updateNSView(_ view: Blur, context: Context) { view.set(radius: radius, veil: veil) }

    final class Blur: NSView {
        private var backdrop: CALayer?
        private var filter: NSObject?
        private let tint = CALayer()
        private var radius = -1.0
        /// How much of the ground lies over the blurred page.
        private var veil = 0.35

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            if let backdrop = (NSClassFromString("CABackdropLayer") as? CALayer.Type)?.init(),
               let filter = (NSClassFromString("CAFilter") as? NSObject.Type)?
                .perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?.takeUnretainedValue() as? NSObject {
                filter.setValue(true, forKey: "inputNormalizeEdges")
                backdrop.setValue(true, forKey: "windowServerAware")
                backdrop.setValue("frosted-strip", forKey: "groupName")
                backdrop.frame = bounds
                backdrop.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                layer?.addSublayer(backdrop)
                self.backdrop = backdrop
                self.filter = filter
            }
            tint.frame = bounds
            tint.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(tint)
        }
        required init?(coder: NSCoder) { nil }

        func set(radius: Double, veil: Double) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if radius != self.radius, let filter, let backdrop {
                self.radius = radius
                filter.setValue(radius, forKey: "inputRadius")
                // Given again: the layer copies its filters as they are set.
                backdrop.setValue([filter], forKey: "filters")
            }
            CATransaction.commit()
            if veil != self.veil || tint.backgroundColor == nil {
                self.veil = veil
                paintTint()
            }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            paintTint()
        }

        /// The ground in this view's light or dark, as much as the veil takes.
        private func paintTint() {
            var colour = Palette.NS.ground.cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance {
                colour = Palette.NS.ground.withAlphaComponent(min(1, max(0, veil))).cgColor
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tint.backgroundColor = colour
            CATransaction.commit()
        }
    }
}
