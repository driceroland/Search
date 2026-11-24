import Foundation
import SwiftUI

struct DeveloperViewportSettings: Equatable, Codable {
    /// Chrome's zoom menu: Fit to window, or a fixed preview scale.
    enum Zoom: Hashable, Codable {
        case fit
        case fixed(Double)

        static let presets: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    }

    /// `nil` is Chrome's "Responsive".
    private(set) var device: DeveloperEmulatedDevice?
    private(set) var landscape = false
    private(set) var responsiveWidth = 390
    private(set) var responsiveHeight = 844
    /// Chrome's default for Responsive is the Mobile device type.
    var responsiveType = DeveloperEmulatedDevice.DeviceType.mobile
    /// `nil` uses the device type's default ratio.
    var responsiveScaleFactor: Double?
    var zoom = Zoom.fit

    // The device toolbar's ⋮ menu. As in Chrome DevTools these are off at
    // first, and Reset to defaults leaves them as they are.
    var showMediaQueries = false
    var showRulers = false
    var showDevicePixelRatio = false
    var showDeviceType = false

    init() {}

    var isResponsive: Bool { device == nil }

    var width: Int {
        guard let device else { return responsiveWidth }
        return landscape ? device.height : device.width
    }

    var height: Int {
        guard let device else { return responsiveHeight }
        return landscape ? device.width : device.height
    }

    /// The user agent the tab presents while device mode is on, or `nil` for the browser's own.
    var userAgent: String? {
        if let device { return device.userAgent.isEmpty ? nil : device.userAgent }
        return responsiveType == .mobile ? DeveloperDevices.responsiveMobileUserAgent : nil
    }

    /// The device pixel ratio to emulate, or `nil` for the screen's own.
    var deviceScaleFactor: Double? {
        if let device { return device.deviceScaleFactor }
        return responsiveScaleFactor ?? (responsiveType == .mobile ? DeveloperDevices.responsiveMobileScaleFactor : nil)
    }

    var touch: Bool { device?.touch ?? (responsiveType == .mobile) }

    func presentation(in room: CGSize, pageZoom: CGFloat) -> DeveloperViewportPresentation {
        let layout = CGSize(width: CGFloat(width) * pageZoom, height: CGFloat(height) * pageZoom)
        switch zoom {
        case .fit: return DeveloperViewportPresentation(layout: layout, room: room)
        case .fixed(let scale): return DeveloperViewportPresentation(layout: layout, scale: CGFloat(scale))
        }
    }

    mutating func select(_ device: DeveloperEmulatedDevice?) {
        self.device = device
        landscape = false
    }

    mutating func set(width: Int? = nil, height: Int? = nil) {
        guard device == nil else { return }
        if let width { responsiveWidth = Self.valid(width) }
        if let height { responsiveHeight = Self.valid(height) }
    }

    /// Dragging the viewport's edge. As in Chrome DevTools, a device preset
    /// becomes Responsive at the size, type and pixel ratio it had, and the
    /// drag goes on from there.
    mutating func resize(width: Int? = nil, height: Int? = nil) {
        if let device {
            responsiveWidth = self.width
            responsiveHeight = self.height
            responsiveType = device.type
            responsiveScaleFactor = device.deviceScaleFactor
            self.device = nil
            landscape = false
        }
        set(width: width, height: height)
    }

    mutating func rotate() {
        if device != nil { landscape.toggle() }
        else { (responsiveWidth, responsiveHeight) = (responsiveHeight, responsiveWidth) }
    }

    /// Chrome's "Reset to defaults": the size, zoom, type and ratio, not what the ⋮ menu shows.
    mutating func reset() {
        var fresh = DeveloperViewportSettings()
        fresh.showMediaQueries = showMediaQueries
        fresh.showRulers = showRulers
        fresh.showDevicePixelRatio = showDevicePixelRatio
        fresh.showDeviceType = showDeviceType
        self = fresh
    }

    /// A device saved before its definition changed, or a custom device since
    /// removed, is looked up again by name; a missing one falls back to Responsive.
    mutating func refreshDevice() {
        guard let device else { return }
        self.device = DeveloperDevices.device(id: device.id)
        if self.device == nil { landscape = false }
    }

    static func valid(_ value: Int) -> Int { min(9_999, max(50, value)) }

    /// The dimension fields' arrow keys, as in Chrome DevTools: one pixel, ten with Shift.
    static func stepped(_ value: Int, up: Bool, shift: Bool) -> Int {
        valid(value + (up ? 1 : -1) * (shift ? 10 : 1))
    }

    // Saved with whatever keys it has, so a setting added later reads an
    // older save as its default rather than discarding it.
    private enum CodingKeys: String, CodingKey {
        case device, landscape, responsiveWidth, responsiveHeight, responsiveType, responsiveScaleFactor, zoom
        case showMediaQueries, showRulers, showDevicePixelRatio, showDeviceType
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        device = try? values.decodeIfPresent(DeveloperEmulatedDevice.self, forKey: .device)
        landscape = (try? values.decodeIfPresent(Bool.self, forKey: .landscape)) ?? false
        responsiveWidth = Self.valid((try? values.decodeIfPresent(Int.self, forKey: .responsiveWidth)) ?? 390)
        responsiveHeight = Self.valid((try? values.decodeIfPresent(Int.self, forKey: .responsiveHeight)) ?? 844)
        responsiveType = (try? values.decodeIfPresent(DeveloperEmulatedDevice.DeviceType.self, forKey: .responsiveType))
            ?? .mobile
        responsiveScaleFactor = try? values.decodeIfPresent(Double.self, forKey: .responsiveScaleFactor)
        zoom = (try? values.decodeIfPresent(Zoom.self, forKey: .zoom)) ?? .fit
        showMediaQueries = (try? values.decodeIfPresent(Bool.self, forKey: .showMediaQueries)) ?? false
        showRulers = (try? values.decodeIfPresent(Bool.self, forKey: .showRulers)) ?? false
        showDevicePixelRatio = (try? values.decodeIfPresent(Bool.self, forKey: .showDevicePixelRatio)) ?? false
        showDeviceType = (try? values.decodeIfPresent(Bool.self, forKey: .showDeviceType)) ?? false
    }
    // encode(to:) is synthesized from CodingKeys.
}

struct DeveloperViewportPresentation {
    let layout: CGSize
    let scale: CGFloat

    init(layout: CGSize, room: CGSize) {
        self.layout = layout
        scale = max(0, min(1, room.width / layout.width, room.height / layout.height))
    }

    init(layout: CGSize, scale: CGFloat) {
        self.layout = layout
        self.scale = max(0.05, scale)
    }

    var displayed: CGSize {
        CGSize(width: layout.width * scale, height: layout.height * scale)
    }
}

/// Device mode, on or off, and its toolbar's settings. As in Chrome DevTools
/// (the `emulation.showDeviceMode` setting and the device-mode settings
/// beside it) both outlast closing DevTools and quitting.
@MainActor
final class DeveloperDeviceMode: ObservableObject {
    static let shared = DeveloperDeviceMode()
    private static let onKey = "developerTools.deviceMode.on"
    private static let settingsKey = "developerTools.deviceMode.settings"

    @Published var on: Bool {
        didSet { if on != oldValue { Store.settings.set(on, forKey: Self.onKey) } }
    }

    @Published var settings: DeveloperViewportSettings {
        didSet {
            guard settings != oldValue, let data = try? JSONEncoder().encode(settings) else { return }
            Store.settings.set(data, forKey: Self.settingsKey)
        }
    }

    init() {
        on = Store.settings.bool(forKey: Self.onKey)
        var saved = Store.settings.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(DeveloperViewportSettings.self, from: $0) } ?? DeveloperViewportSettings()
        saved.refreshDevice()
        settings = saved
    }

    /// The device toolbar button and ⇧⌘M.
    func toggle() { on.toggle() }
}

/// The edges of the emulated viewport that can be dragged, and what a drag
/// does to its size.
enum DeveloperViewportResize {
    struct Edges: OptionSet, Hashable {
        let rawValue: Int
        static let right = Edges(rawValue: 1)
        static let bottom = Edges(rawValue: 2)
        static let corner: Edges = [.right, .bottom]
    }

    struct Size: Equatable {
        var width: Int
        var height: Int
    }

    /// The size after the pointer has moved `translation` points from where
    /// the drag began. As in Chrome DevTools, the viewport is centred across
    /// and pinned at the top, so the right edge moves half as far as the
    /// width changes while the bottom edge follows the pointer; `scale` is
    /// points per CSS pixel when the drag began.
    static func size(from start: Size, translation: CGSize, scale: CGFloat, edges: Edges, centred: Bool = true) -> Size {
        let points = max(0.01, scale)
        var size = start
        if edges.contains(.right) {
            let change = translation.width * (centred ? 2 : 1) / points
            size.width = DeveloperViewportSettings.valid(start.width + Int(change.rounded()))
        }
        if edges.contains(.bottom) {
            size.height = DeveloperViewportSettings.valid(start.height + Int((translation.height / points).rounded()))
        }
        return size
    }
}

/// The rulers along the emulated viewport's top and left, as Chrome's
/// device mode draws them: ticks in CSS pixels, a label on the long ones.
enum DeveloperViewportRuler {
    struct Tick: Equatable {
        /// CSS pixels from the viewport's edge.
        let position: Int
        let kind: Kind
    }

    enum Kind: Equatable { case minor, medium, major }

    static let steps = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1_000, 2_000, 5_000]

    /// The spacing of the small ticks and of the labelled ones, in CSS
    /// pixels, for `scale` points a CSS pixel: small ticks at least 5 points
    /// apart, labels at least 50.
    static func spacing(scale: CGFloat) -> (minor: Int, major: Int) {
        let points = max(0.001, scale)
        let minor = steps.first { CGFloat($0) * points >= 5 } ?? steps[steps.count - 1]
        let major = steps.first { $0 >= minor && $0.isMultiple(of: minor) && CGFloat($0) * points >= 50 }
            ?? minor * 10
        return (minor, major)
    }

    static func ticks(length: Int, scale: CGFloat) -> [Tick] {
        guard length > 0 else { return [] }
        let (minor, major) = spacing(scale: scale)
        let half = major.isMultiple(of: 2) && (major / 2).isMultiple(of: minor) ? major / 2 : nil
        return stride(from: 0, through: length, by: minor).map { position in
            if position.isMultiple(of: major) { return Tick(position: position, kind: .major) }
            if let half, position.isMultiple(of: half) { return Tick(position: position, kind: .medium) }
            return Tick(position: position, kind: .minor)
        }
    }
}

/// A width breakpoint from the page's style sheets, for the media query bar.
struct DeveloperMediaQuery: Hashable, Comparable {
    /// Chrome's three rows: max-width (blue), min-width and max-width (green), min-width (orange).
    enum Kind: Int, Hashable { case max, range, min }

    let kind: Kind
    let min: Int?
    let max: Int?

    /// Where clicking the bar puts the viewport's width: the breakpoint itself.
    var width: Int { kind == .min ? (min ?? 0) : (max ?? min ?? 0) }

    var title: String {
        switch kind {
        case .max: "max-width: \(max ?? 0)px"
        case .min: "min-width: \(min ?? 0)px"
        case .range: "min-width: \(min ?? 0)px and max-width: \(max ?? 0)px"
        }
    }

    static func < (a: Self, b: Self) -> Bool {
        if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
        // Chrome draws the widest first, so the narrower sit on top.
        switch a.kind {
        case .max: return (a.max ?? 0) > (b.max ?? 0)
        case .min: return (a.min ?? 0) < (b.min ?? 0)
        case .range: return ((a.max ?? 0) - (a.min ?? 0)) > ((b.max ?? 0) - (b.min ?? 0))
        }
    }

    /// The width conditions in the `mediaText`s style sheets report: each
    /// comma-separated query gives one entry. Units are px, em and rem (16
    /// pixels to an em, as for the initial font size); the range syntax
    /// (`width >= 600px`, `600px <= width <= 900px`) counts too. Anything
    /// that isn't about the viewport's width is left out.
    static func parse(_ texts: [String]) -> [DeveloperMediaQuery] {
        var found = Set<DeveloperMediaQuery>()
        for text in texts {
            for query in text.lowercased().split(separator: ",") {
                var low: Int?
                var high: Int?
                let source = String(query)
                for (name, value) in features(in: source) {
                    if name == "min-width" { low = Swift.max(low ?? 0, value) }
                    if name == "max-width" { high = Swift.min(high ?? Int.max, value) }
                }
                for (isLow, value) in ranges(in: source) {
                    if isLow { low = Swift.max(low ?? 0, value) } else { high = Swift.min(high ?? Int.max, value) }
                }
                switch (low, high) {
                case let (low?, high?) where low <= high: found.insert(.init(kind: .range, min: low, max: high))
                case let (low?, nil): found.insert(.init(kind: .min, min: low, max: nil))
                case let (nil, high?): found.insert(.init(kind: .max, min: nil, max: high))
                default: break
                }
            }
        }
        return found.sorted()
    }

    /// `(min-width: 40em)` and the like, in CSS pixels.
    private static func features(in query: String) -> [(String, Int)] {
        let pattern = #"\(\s*(min-width|max-width)\s*:\s*([0-9]*\.?[0-9]+)\s*(px|em|rem)?\s*\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(query.startIndex..., in: query)
        return expression.matches(in: query, range: range).compactMap { match in
            guard let name = Range(match.range(at: 1), in: query), let number = Range(match.range(at: 2), in: query),
                  let value = Double(query[number]) else { return nil }
            let unit = Range(match.range(at: 3), in: query).map { String(query[$0]) } ?? "px"
            return (String(query[name]), pixels(value, unit))
        }
    }

    /// Range syntax: `width >= 600px`, `width < 40em`, `600px <= width`.
    /// True for a lower bound. A strict bound is one pixel inside, as
    /// Chrome's inspector rounds it.
    private static func ranges(in query: String) -> [(Bool, Int)] {
        let number = #"([0-9]*\.?[0-9]+)\s*(px|em|rem)?"#
        let patterns = [#"width\s*(>=|<=|>|<)\s*"# + number, number + #"\s*(>=|<=|>|<)\s*width"#]
        var out: [(Bool, Int)] = []
        for (index, pattern) in patterns.enumerated() {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(query.startIndex..., in: query)
            for match in expression.matches(in: query, range: range) {
                // Before or after the word "width", the groups come in a different order.
                let groups = index == 0 ? (op: 1, value: 2, unit: 3) : (op: 3, value: 1, unit: 2)
                guard let opRange = Range(match.range(at: groups.op), in: query),
                      let valueRange = Range(match.range(at: groups.value), in: query),
                      let value = Double(query[valueRange]) else { continue }
                // "width >= 600px" is preceded by "min-" in the feature syntax: skip those.
                if index == 0, let whole = Range(match.range, in: query), whole.lowerBound > query.startIndex,
                   query[query.index(before: whole.lowerBound)] == "-" { continue }
                let unit = Range(match.range(at: groups.unit), in: query).map { String(query[$0]) } ?? "px"
                var op = String(query[opRange])
                if index == 1 {
                    // "600px <= width" reads as "width >= 600px".
                    op = op.replacingOccurrences(of: "<", with: "≶").replacingOccurrences(of: ">", with: "<")
                        .replacingOccurrences(of: "≶", with: ">")
                }
                let amount = pixels(value, unit)
                switch op {
                case ">=": out.append((true, amount))
                case ">": out.append((true, amount + 1))
                case "<=": out.append((false, amount))
                case "<": out.append((false, amount - 1))
                default: break
                }
            }
        }
        return out
    }

    private static func pixels(_ value: Double, _ unit: String) -> Int {
        Int((unit == "px" ? value : value * 16).rounded())
    }

    /// Run in the inspected page's isolated world: every media condition its
    /// style sheets can be read for. Sheets from another origin can't be
    /// read from a page, so their breakpoints are missing, as they would be
    /// to the page's own scripts.
    static let script = #"""
    const texts = new Set();
    const visit = (rules, depth) => {
        for (const rule of rules) {
            if (texts.size >= 500) return;
            if (rule.type === 4 && rule.media) texts.add(String(rule.media.mediaText).slice(0, 512));
            if (rule.type === 3 && rule.media?.mediaText) texts.add(String(rule.media.mediaText).slice(0, 512));
            if (depth < 8 && rule.cssRules) { try { visit(rule.cssRules, depth + 1); } catch {} }
        }
    };
    for (const sheet of Array.from(document.styleSheets).slice(0, 300)) {
        try {
            if (sheet.media?.mediaText) texts.add(String(sheet.media.mediaText).slice(0, 512));
            visit(sheet.cssRules, 0);
        } catch {}
    }
    return Array.from(texts);
    """#
}
