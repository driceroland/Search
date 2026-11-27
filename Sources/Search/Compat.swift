import AppKit
import SwiftUI
import WebKit

// macOS 12 and 13 compatibility.
//
// Search runs on macOS 12 and later. These stand in for APIs that arrived in
// macOS 13 or 14: each uses the system's own where it exists, and on an older
// Mac does the closest thing it can, so the call sites read the same on
// every macOS. Nothing here changes what a newer Mac does.

// MARK: - Sleeping

extension Task where Success == Never, Failure == Never {
    /// `Task.sleep(for: .seconds(x))`, which is macOS 13.
    static func sleep(seconds: Double) async throws {
        guard seconds > 0 else { return try checkCancellation() }
        try await sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func sleep(seconds: Int) async throws {
        try await sleep(seconds: Double(seconds))
    }

    /// `Task.sleep(for: .milliseconds(x))`, which is macOS 13.
    static func sleep(milliseconds: Int) async throws {
        try await sleep(seconds: Double(milliseconds) / 1000)
    }
}

// MARK: - onChange with the old and new value

extension View {
    /// `onChange(of:initial:_:)` with `{ old, new in }`, which is macOS 14.
    /// On 12 and 13 the old value is the one the view was last drawn with.
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, initial: Bool = false,
                                      _ action: @escaping (_ oldValue: V, _ newValue: V) -> Void) -> some View {
        if #available(macOS 14, *) {
            onChange(of: value, initial: initial, action)
        } else {
            modifier(OnChangeCompat(value: value, initial: initial, action: action))
        }
    }
}

private struct OnChangeCompat<V: Equatable>: ViewModifier {
    let value: V
    let initial: Bool
    let action: (V, V) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { if initial { action(value, value) } }
            // The capture list keeps the value this body was made with: the
            // old one, by the time the closure runs.
            .onChange(of: value) { [value] new in action(value, new) }
    }
}

// MARK: - onGeometryChange

extension View {
    /// `onGeometryChange(for:of:action:)`, which is macOS 13 (back-deployed
    /// from 15). On 12 a GeometryReader behind the view measures it.
    @ViewBuilder
    func onGeometryChangeCompat<T: Equatable>(for type: T.Type, of transform: @escaping (GeometryProxy) -> T,
                                              action: @escaping (_ newValue: T) -> Void) -> some View {
        if #available(macOS 13, *) {
            onGeometryChange(for: type, of: transform, action: action)
        } else {
            background(GeometryReader { proxy in
                let measured = transform(proxy)
                Color.clear
                    .onAppear { action(measured) }
                    .onChange(of: measured) { action($0) }
            })
        }
    }
}

// MARK: - Small SwiftUI modifiers

extension View {
    /// `scrollDisabled(_:)`, macOS 13. On 12 the scroll view stays scrollable.
    @ViewBuilder
    func scrollDisabledCompat(_ disabled: Bool) -> some View {
        if #available(macOS 13, *) { scrollDisabled(disabled) } else { self }
    }

    /// `scrollClipDisabled(_:)`, macOS 14. On older ones the content clips.
    @ViewBuilder
    func scrollClipDisabledCompat(_ disabled: Bool = true) -> some View {
        if #available(macOS 14, *) { scrollClipDisabled(disabled) } else { self }
    }

    /// `scrollBounceBehavior(.basedOnSize)`, macOS 13.3.
    @ViewBuilder
    func scrollBouncesOnlyWhenNeeded() -> some View {
        if #available(macOS 13.3, *) { scrollBounceBehavior(.basedOnSize) } else { self }
    }

    /// `scrollContentBackground(.hidden)`, macOS 13.
    @ViewBuilder
    func scrollContentBackgroundHidden() -> some View {
        if #available(macOS 13, *) { scrollContentBackground(.hidden) } else { self }
    }

    /// `focusEffectDisabled()`, macOS 14.
    @ViewBuilder
    func focusEffectDisabledCompat() -> some View {
        if #available(macOS 14, *) { focusEffectDisabled() } else { self }
    }

    /// `symbolEffect(.bounce, value:)`, macOS 14. Older ones don't bounce.
    @ViewBuilder
    func bounceCompat<V: Equatable>(value: V) -> some View {
        if #available(macOS 14, *) { symbolEffect(.bounce, value: value) } else { self }
    }

    /// `presentationBackground(_:)`, macOS 13.3. Older ones paint behind.
    @ViewBuilder
    func presentationBackgroundCompat<S: ShapeStyle>(_ style: S) -> some View {
        if #available(macOS 13.3, *) { presentationBackground(style) } else { background(style) }
    }
}

// MARK: - Shapes

/// `RectangleCornerRadii`, macOS 13.
struct CornerRadii: Equatable {
    var topLeading: CGFloat = 0
    var bottomLeading: CGFloat = 0
    var bottomTrailing: CGFloat = 0
    var topTrailing: CGFloat = 0

    init(topLeading: CGFloat = 0, bottomLeading: CGFloat = 0, bottomTrailing: CGFloat = 0, topTrailing: CGFloat = 0) {
        self.topLeading = topLeading
        self.bottomLeading = bottomLeading
        self.bottomTrailing = bottomTrailing
        self.topTrailing = topTrailing
    }
}

/// `UnevenRoundedRectangle`, macOS 13: the system's own where there is one
/// (its continuous corners), plain circular corners on 12.
struct UnevenRect: Shape {
    var radii: CornerRadii
    var style: RoundedCornerStyle

    init(cornerRadii: CornerRadii, style: RoundedCornerStyle = .continuous) {
        radii = cornerRadii
        self.style = style
    }

    init(topLeadingRadius: CGFloat = 0, bottomLeadingRadius: CGFloat = 0, bottomTrailingRadius: CGFloat = 0,
         topTrailingRadius: CGFloat = 0, style: RoundedCornerStyle = .continuous) {
        radii = CornerRadii(topLeading: topLeadingRadius, bottomLeading: bottomLeadingRadius,
                            bottomTrailing: bottomTrailingRadius, topTrailing: topTrailingRadius)
        self.style = style
    }

    func path(in rect: CGRect) -> Path {
        if #available(macOS 13, *) {
            return UnevenRoundedRectangle(topLeadingRadius: radii.topLeading, bottomLeadingRadius: radii.bottomLeading,
                                          bottomTrailingRadius: radii.bottomTrailing, topTrailingRadius: radii.topTrailing,
                                          style: style).path(in: rect)
        }
        // Left to right, as SwiftUI draws in a left-to-right layout.
        let most = min(rect.width, rect.height) / 2
        let tl = min(max(radii.topLeading, 0), most), tr = min(max(radii.topTrailing, 0), most)
        let bl = min(max(radii.bottomLeading, 0), most), br = min(max(radii.bottomTrailing, 0), most)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + tr), radius: tr)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - br, y: rect.maxY), radius: br)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bl), radius: bl)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + tl, y: rect.minY), radius: tl)
        path.closeSubpath()
        return path
    }
}

// MARK: - URL

extension URL {
    /// `path(percentEncoded:)`, macOS 13. Like it, keeps a trailing slash.
    func pathCompat(percentEncoded: Bool) -> String {
        if #available(macOS 13, *) { return path(percentEncoded: percentEncoded) }
        let parts = URLComponents(url: self, resolvingAgainstBaseURL: false)
        return (percentEncoded ? parts?.percentEncodedPath : parts?.path) ?? path
    }
}

// MARK: - A page in full screen

/// `WKWebView.FullscreenState`, macOS 13, with the same case names.
enum PageFullscreen: Equatable {
    case notInFullscreen
    case enteringFullscreen
    case inFullscreen
    case exitingFullscreen
}

extension WKWebView {
    /// `fullscreenState`, macOS 13. macOS 12 has no way to ask, so a page is
    /// never in full screen there as far as Search can tell; WebKit still
    /// takes the video full screen itself.
    var fullscreenPhase: PageFullscreen {
        guard #available(macOS 13, *) else { return .notInFullscreen }
        switch fullscreenState {
        case .notInFullscreen: return .notInFullscreen
        case .enteringFullscreen: return .enteringFullscreen
        case .inFullscreen: return .inFullscreen
        case .exitingFullscreen: return .exitingFullscreen
        @unknown default: return .notInFullscreen
        }
    }

    /// `observe(\.fullscreenState)`, macOS 13. Nil on 12, with nothing to
    /// observe.
    func observeFullscreen(_ changed: @escaping (WKWebView) -> Void) -> NSKeyValueObservation? {
        guard #available(macOS 13, *) else { return nil }
        return observe(\.fullscreenState, options: [.new]) { web, _ in changed(web) }
    }
}

extension URL {
    /// `host(percentEncoded:)`, macOS 13. On 12, the host as `host` gives it.
    func hostCompat(percentEncoded: Bool = true) -> String? {
        if #available(macOS 13, *) { return host(percentEncoded: percentEncoded) }
        return host
    }

    /// `path()`, macOS 13: percent-encoded, trailing slash kept.
    func pathCompat() -> String { pathCompat(percentEncoded: true) }

    /// `query(percentEncoded:)`, macOS 13.
    func queryCompat(percentEncoded: Bool = true) -> String? {
        if #available(macOS 13, *) { return query(percentEncoded: percentEncoded) }
        let parts = URLComponents(url: self, resolvingAgainstBaseURL: false)
        return percentEncoded ? parts?.percentEncodedQuery : parts?.query
    }

    /// `fragment(percentEncoded:)`, macOS 13.
    func fragmentCompat(percentEncoded: Bool = true) -> String? {
        if #available(macOS 13, *) { return fragment(percentEncoded: percentEncoded) }
        let parts = URLComponents(url: self, resolvingAgainstBaseURL: false)
        return percentEncoded ? parts?.percentEncodedFragment : parts?.fragment
    }
}

// MARK: - Regular expressions

/// Swift's Regex is macOS 13: these are the few things Search asks of one,
/// on NSRegularExpression, which every macOS has.
enum Pattern {
    /// Each match's groups: 0 the whole match, then each capture (nil where
    /// it took no part).
    static func matches(_ pattern: String, in text: String, ignoringCase: Bool = false) -> [[String?]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: ignoringCase ? [.caseInsensitive] : []) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: whole).map { match in
            (0..<match.numberOfRanges).map { group in
                Range(match.range(at: group), in: text).map { String(text[$0]) }
            }
        }
    }

    /// Whether the whole of the text matches.
    static func wholeMatch(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "^(?:\(pattern))$") else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Each match replaced by what `with` makes of its groups.
    static func replacing(_ pattern: String, in text: String, with: ([String?]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            out += text[last..<range.lowerBound]
            let groups = (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
            out += with(groups)
            last = range.upperBound
        }
        out += text[last...]
        return out
    }
}

// MARK: - Animation, hover, menus

extension View {
    /// `transaction(value:) { $0.animation = nil }`, macOS 14: no animation
    /// for what changes along with `value`. On older ones,
    /// `animation(nil, value:)`, which does the same for the view's own
    /// changes.
    @ViewBuilder
    func unanimated<V: Equatable>(when value: V, _ body: @escaping (inout Transaction) -> Void) -> some View {
        if #available(macOS 14, *) { transaction(value: value, body) } else { animation(nil, value: value) }
    }

    /// `onContinuousHover`, macOS 13. macOS 12 has no pointer location to
    /// follow, so nothing is said there; clicks and keys still work.
    @ViewBuilder
    func onPointerMoveCompat(in space: CoordinateSpace = .global, _ moved: @escaping (CGPoint?) -> Void) -> some View {
        if #available(macOS 13, *) {
            onContinuousHover(coordinateSpace: space) { phase in
                if case .active(let point) = phase { moved(point) } else { moved(nil) }
            }
        } else {
            self
        }
    }

    /// `menuStyle(.button)`, macOS 13; the borderless button before.
    @ViewBuilder
    func buttonMenuStyleCompat() -> some View {
        if #available(macOS 13, *) { menuStyle(.button) } else { menuStyle(.borderlessButton) }
    }
}

/// `withAnimation(_:completionCriteria:_:completion:)`, macOS 14: on older
/// ones `completion` comes once the animation's `duration` has passed.
@MainActor
func withAnimationCompat(_ animation: Animation, duration: TimeInterval, _ body: () -> Void,
                         completion: @escaping () -> Void) {
    if #available(macOS 14, *) {
        withAnimation(animation, completionCriteria: .removed, body, completion: completion)
    } else {
        withAnimation(animation, body)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: completion)
    }
}

extension NSApplication {
    /// `activate()`, macOS 14.
    func activateCompat() {
        if #available(macOS 14, *) { activate() } else { activate(ignoringOtherApps: true) }
    }
}

extension NSMenuItem {
    /// `sectionHeader(title:)`, macOS 14; a greyed title before.
    static func sectionHeaderCompat(title: String) -> NSMenuItem {
        if #available(macOS 14, *) { return .sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

// MARK: - ViewThatFits

/// `ViewThatFits`, macOS 13. macOS 12 can't measure before it chooses, so
/// it shows `older`: whichever of the choices always fits.
struct FitsCompat<Fits: View, Older: View>: View {
    let axes: Axis.Set
    let content: Fits
    let older: Older

    init(in axes: Axis.Set = [.horizontal, .vertical], @ViewBuilder _ content: () -> Fits,
         @ViewBuilder older: () -> Older) {
        self.axes = axes
        self.content = content()
        self.older = older()
    }

    var body: some View {
        if #available(macOS 13, *) {
            ViewThatFits(in: axes) { content }
        } else {
            older
        }
    }
}

// MARK: - A stack either way

/// `AnyLayout(vertical ? VStackLayout : HStackLayout)`, macOS 13, which keeps
/// the children's identity when it turns. On macOS 12 a VStack or an HStack.
struct StackCompat<Content: View>: View {
    let vertical: Bool
    let spacing: CGFloat?
    let content: Content

    init(vertical: Bool, spacing: CGFloat? = nil, @ViewBuilder _ content: () -> Content) {
        self.vertical = vertical
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 13, *) {
            let layout = vertical ? AnyLayout(VStackLayout(spacing: spacing)) : AnyLayout(HStackLayout(spacing: spacing))
            layout { content }
        } else if vertical {
            VStack(spacing: spacing) { content }
        } else {
            HStack(spacing: spacing) { content }
        }
    }
}

// MARK: - An offset from where a view is drawn

extension View {
    /// `visualEffect { content, proxy in content.offset(…) }`, macOS 14: an
    /// offset worked out from where the view is drawn this frame, in the
    /// coordinate space `space`. Older ones have no such reading, and take
    /// `fallback`, worked out from where it will be.
    @ViewBuilder
    func drawnOffsetCompat<N: Hashable & Sendable>(in space: N, fallback: CGSize,
                                                   _ offset: @escaping @Sendable (CGRect) -> CGSize) -> some View {
        if #available(macOS 14, *) {
            visualEffect { content, proxy in content.offset(offset(proxy.frame(in: .named(space)))) }
        } else {
            self.offset(fallback)
        }
    }
}

// MARK: - Keys

/// `KeyPress`, macOS 14, with the fields Search reads.
struct KeyPressCompat {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let characters: String

    enum Result { case handled, ignored }
}

extension View {
    /// `onKeyPress(phases: .down)`, macOS 14. On older ones the keys go on
    /// to whatever else takes them: these views are for the pointer there.
    @ViewBuilder
    func onKeyDownCompat(_ action: @escaping (KeyPressCompat) -> KeyPressCompat.Result) -> some View {
        if #available(macOS 14, *) {
            onKeyPress(phases: .down) { press in
                action(KeyPressCompat(key: press.key, modifiers: press.modifiers, characters: press.characters)) == .handled
                    ? .handled : .ignored
            }
        } else {
            self
        }
    }

    /// `onKeyPress(_ key:)`, macOS 14.
    @ViewBuilder
    func onKeyPressCompat(_ key: KeyEquivalent, _ action: @escaping () -> KeyPressCompat.Result) -> some View {
        if #available(macOS 14, *) {
            onKeyPress(key) { action() == .handled ? .handled : .ignored }
        } else {
            self
        }
    }
}

// MARK: - A view as a picture

/// `ImageRenderer`, macOS 13: the view drawn to a bitmap at `scale`. On 12
/// it is drawn by an off-screen hosting view instead.
@MainActor
func renderImageCompat<V: View>(_ view: V, scale: CGFloat) -> CGImage? {
    if #available(macOS 13, *) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.cgImage
    }
    let host = NSHostingView(rootView: view)
    let size = host.fittingSize
    guard size.width >= 1, size.height >= 1 else { return nil }
    host.frame = CGRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)),
                                     pixelsHigh: Int(ceil(size.height * scale)), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep.cgImage
}

// MARK: - Website data stores of their own

extension WKWebsiteDataStore {
    /// Whether this Mac can keep a store under an identifier of its own
    /// (macOS 14): what a profile other than Personal, and a space signed out
    /// of the others, need. Without it there is the one store, and Search
    /// offers neither.
    static var separateStoresSupported: Bool {
        if #available(macOS 14, *) { return true }
        return false
    }

    /// `WKWebsiteDataStore(forIdentifier:)`, macOS 14. Nil on older ones.
    static func identifiedCompat(_ id: UUID) -> WKWebsiteDataStore? {
        if #available(macOS 14, *) { return WKWebsiteDataStore(forIdentifier: id) }
        return nil
    }
}
