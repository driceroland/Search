import Foundation

// Chrome DevTools' CSS overview (More tools › CSS overview): a capture of
// the page's colours, fonts, unused declarations, media queries and
// contrast problems. The page script (DeveloperCSSOverview-collect.js)
// only reads computed styles and style sheets; everything here is the
// arithmetic on what it sends: colour parsing and normalisation, WCAG
// contrast, selector classification and the counting.

/// A colour in sRGB: channels 0…255, alpha 0…1.
struct DeveloperCSSColor: Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red, 255)
        self.green = Self.clamp(green, 255)
        self.blue = Self.clamp(blue, 255)
        self.alpha = Self.clamp(alpha, 1)
    }

    static let white = DeveloperCSSColor(red: 255, green: 255, blue: 255)
    static let black = DeveloperCSSColor(red: 0, green: 0, blue: 0)

    private static func clamp(_ value: Double, _ upper: Double) -> Double {
        value.isFinite ? min(upper, max(0, value)) : 0
    }

    var isTransparent: Bool { alpha <= 0 }
    var isOpaque: Bool { alpha >= 1 }

    /// `#1a2b3c`, or `#1a2b3c80` when not opaque: how Chrome's overview
    /// writes a colour, and the key colours are counted under.
    var hex: String {
        func byte(_ value: Double) -> String {
            let number = Int(value.rounded())
            return (number < 16 ? "0" : "") + String(number, radix: 16)
        }
        let rgb = "#" + byte(red) + byte(green) + byte(blue)
        return isOpaque ? rgb : rgb + byte(alpha * 255)
    }

    /// This colour drawn over `background` (source-over).
    func over(_ background: DeveloperCSSColor) -> DeveloperCSSColor {
        let alpha = self.alpha + background.alpha * (1 - self.alpha)
        guard alpha > 0 else { return DeveloperCSSColor(red: 0, green: 0, blue: 0, alpha: 0) }
        func channel(_ top: Double, _ bottom: Double) -> Double {
            (top * self.alpha + bottom * background.alpha * (1 - self.alpha)) / alpha
        }
        return DeveloperCSSColor(red: channel(red, background.red), green: channel(green, background.green),
                                 blue: channel(blue, background.blue), alpha: alpha)
    }

    /// WCAG 2's relative luminance, of the colour as if opaque.
    var luminance: Double {
        func linear(_ channel: Double) -> Double {
            let value = channel / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2's contrast ratio, 1…21. A translucent foreground is first
    /// drawn over the background.
    static func contrast(_ foreground: DeveloperCSSColor, _ background: DeveloperCSSColor) -> Double {
        let back = background.isOpaque ? background : background.over(.white)
        let fore = foreground.isOpaque ? foreground : foreground.over(back)
        let lighter = max(fore.luminance, back.luminance)
        let darker = min(fore.luminance, back.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    // MARK: Parsing

    private static let named: [String: DeveloperCSSColor] = [
        "black": .black, "white": .white,
        "red": .init(red: 255, green: 0, blue: 0), "green": .init(red: 0, green: 128, blue: 0),
        "blue": .init(red: 0, green: 0, blue: 255), "yellow": .init(red: 255, green: 255, blue: 0),
        "gray": .init(red: 128, green: 128, blue: 128), "grey": .init(red: 128, green: 128, blue: 128),
        "silver": .init(red: 192, green: 192, blue: 192), "orange": .init(red: 255, green: 165, blue: 0),
        "purple": .init(red: 128, green: 0, blue: 128), "navy": .init(red: 0, green: 0, blue: 128),
        "transparent": .init(red: 0, green: 0, blue: 0, alpha: 0),
    ]

    /// A colour as a computed style writes one: `rgb(…)`/`rgba(…)` (comma
    /// or space syntax, numbers or percentages), `#hex`, a few names,
    /// `transparent`, `color(srgb r g b / a)`. Nil for what isn't one
    /// (`currentcolor`, other colour spaces, `none`).
    static func parse(_ text: String) -> DeveloperCSSColor? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        if let color = named[value] { return color }
        if value.hasPrefix("#") { return hex(String(value.dropFirst())) }
        guard let open = value.firstIndex(of: "("), value.hasSuffix(")") else { return nil }
        let function = String(value[..<open]).trimmingCharacters(in: .whitespaces)
        let inner = String(value[value.index(after: open)..<value.index(before: value.endIndex)])
        switch function {
        case "rgb", "rgba":
            let (channels, alpha) = arguments(inner)
            guard channels.count == 3 || (channels.count == 4 && alpha == nil) else { return nil }
            let rgb = channels.prefix(3).map { component($0, scale: 255) }
            guard rgb.allSatisfy({ $0 != nil }) else { return nil }
            let alphaText = channels.count == 4 ? channels[3] : alpha
            var a = 1.0
            if let alphaText {
                guard let parsed = component(alphaText, scale: 1) else { return nil }
                a = parsed
            }
            return DeveloperCSSColor(red: rgb[0]!, green: rgb[1]!, blue: rgb[2]!, alpha: a)
        case "color":
            let (parts, alpha) = arguments(inner)
            guard parts.first == "srgb" else { return nil }
            let channels = Array(parts.dropFirst())
            guard channels.count == 3 else { return nil }
            let rgb = channels.map { component($0, scale: 1) }
            guard rgb.allSatisfy({ $0 != nil }) else { return nil }
            var a = 1.0
            if let alpha {
                guard let parsed = component(alpha, scale: 1) else { return nil }
                a = parsed
            }
            return DeveloperCSSColor(red: rgb[0]! * 255, green: rgb[1]! * 255, blue: rgb[2]! * 255, alpha: a)
        default:
            return nil
        }
    }

    private static func hex(_ digits: String) -> DeveloperCSSColor? {
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        let expanded = digits.count <= 4 ? digits.map { "\($0)\($0)" }.joined() : digits
        var bytes: [Double] = []
        var index = expanded.startIndex
        while index < expanded.endIndex {
            let next = expanded.index(index, offsetBy: 2)
            bytes.append(Double(Int(expanded[index..<next], radix: 16) ?? 0))
            index = next
        }
        return DeveloperCSSColor(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes.count == 4 ? bytes[3] / 255 : 1)
    }

    /// The parts of `rgb(…)`: split on commas, or on spaces with an
    /// optional `/ alpha`.
    private static func arguments(_ inner: String) -> (channels: [String], alpha: String?) {
        var main = inner
        var alpha: String?
        if let slash = inner.firstIndex(of: "/") {
            main = String(inner[..<slash])
            alpha = inner[inner.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        }
        let separators = CharacterSet(charactersIn: ", ").union(.whitespacesAndNewlines)
        let channels = main.components(separatedBy: separators).filter { !$0.isEmpty }
        return (channels, alpha)
    }

    /// A number, or a percentage of `scale`; `none` is 0.
    private static func component(_ text: String, scale: Double) -> Double? {
        if text == "none" { return 0 }
        if text.hasSuffix("%") {
            return Double(text.dropLast()).map { $0 / 100 * scale }
        }
        return Double(text)
    }
}

/// The backdrop and text metrics that a Styles color swatch is measured against.
struct DeveloperStyleContrast: Equatable {
    let background: DeveloperCSSColor
    let largeText: Bool

    struct Result {
        let ratio: Double
        let aa: Bool
        let aaa: Bool
    }

    func measure(_ foreground: DeveloperCSSColor) -> Result {
        let ratio = DeveloperCSSColor.contrast(foreground, background)
        return Result(ratio: ratio, aa: ratio >= DeveloperCSSOverview.threshold(large: largeText),
                      aaa: ratio >= (largeText ? 4.5 : 7))
    }
}

enum DeveloperCSSOverview {
    // MARK: The page's answer

    /// One element as the page script describes it.
    struct Element: Equatable {
        /// Its index in the page script's list, to ask for it again.
        var index: Int
        var parent: Int?
        var label: String
        var hasText: Bool
        var rendered: Bool
        var backgroundImage: Bool
        var svgShape: Bool
        var values: [String: String]

        init(index: Int, parent: Int? = nil, label: String, hasText: Bool = false, rendered: Bool = true,
             backgroundImage: Bool = false, svgShape: Bool = false, values: [String: String] = [:]) {
            self.index = index
            self.parent = parent
            self.label = label
            self.hasText = hasText
            self.rendered = rendered
            self.backgroundImage = backgroundImage
            self.svgShape = svgShape
            self.values = values
        }

        subscript(_ field: String) -> String { values[field] ?? "" }

        /// The tag name a label starts with: `div` of `div#main.card`.
        var tag: String {
            String(label.prefix { $0 != "#" && $0 != "." }).lowercased()
        }
    }

    /// The page script's rows, interned strings looked up, by field name.
    static func elements(_ data: [String: Any]) -> [Element] {
        let fields = data["fields"] as? [String] ?? []
        let strings = data["strings"] as? [String] ?? []
        let rows = data["rows"] as? [[Any]] ?? []
        func string(_ value: Any?) -> String {
            guard let index = (value as? NSNumber)?.intValue, index >= 0, index < strings.count else { return "" }
            return strings[index]
        }
        return rows.enumerated().map { index, row -> Element in
            let parent = (row.first as? NSNumber)?.intValue
            let flags = row.count > 1 ? (row[1] as? NSNumber)?.intValue ?? 0 : 0
            var values: [String: String] = [:]
            for (offset, field) in fields.enumerated() where offset + 3 < row.count {
                let value = string(row[offset + 3])
                if !value.isEmpty { values[field] = value }
            }
            return Element(index: index, parent: parent.flatMap { $0 >= 0 && $0 < rows.count ? $0 : nil },
                           label: row.count > 2 ? string(row[2]) : "",
                           hasText: flags & 1 != 0, rendered: flags & 2 != 0,
                           backgroundImage: flags & 4 != 0, svgShape: flags & 8 != 0, values: values)
        }
    }

    // MARK: Summary

    struct SelectorCounts: Equatable {
        var type = 0
        var id = 0
        var classes = 0
        var universal = 0
        var attribute = 0
        var nonSimple = 0
    }

    /// The selectors of a rule's selector text, split at its top-level
    /// commas (not those inside `:is(…)` or `[a="x,y"]`).
    static func splitSelectorList(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in text {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { current.append(character); escaped = true; continue }
            if let open = quote {
                if character == open { quote = nil }
                current.append(character)
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "(", "[": depth += 1
            case ")", "]": depth = max(0, depth - 1)
            case "," where depth == 0:
                parts.append(current)
                current = ""
                continue
            default: break
            }
            current.append(character)
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The compound selectors of one selector, split at its top-level
    /// combinators (descendant space, `>`, `+`, `~`).
    static func compounds(_ selector: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var escaped = false
        func flush() {
            let part = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { parts.append(part) }
            current = ""
        }
        for character in selector {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { current.append(character); escaped = true; continue }
            if let open = quote {
                if character == open { quote = nil }
                current.append(character)
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "(", "[": depth += 1
            case ")", "]": depth = max(0, depth - 1)
            case " ", "\t", "\n", ">", "+", "~":
                if depth == 0 { flush(); continue }
            default: break
            }
            current.append(character)
        }
        flush()
        return parts
    }

    /// What kinds of simple selector `compound` has, at its top level.
    static func kinds(of compound: String) -> (type: Bool, id: Bool, classes: Bool, universal: Bool, attribute: Bool) {
        var type = false, id = false, classes = false, universal = false, attribute = false
        var depth = 0
        var quote: Character?
        var escaped = false
        var previous: Character?
        for (offset, character) in compound.enumerated() {
            defer { previous = character }
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let open = quote {
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "(": depth += 1
            case ")": depth = max(0, depth - 1)
            case "[":
                if depth == 0 { attribute = true }
                depth += 1
            case "]": depth = max(0, depth - 1)
            case "#" where depth == 0: id = true
            case "." where depth == 0: classes = true
            case "*" where depth == 0: universal = true
            default:
                if offset == 0, character.isLetter || character == "-" || character == "_" { type = true }
                if previous == "|", depth == 0, character.isLetter { type = true }
            }
        }
        return (type, id, classes, universal, attribute)
    }

    /// Chrome's selector counts: each selector of each rule counted under
    /// every kind of simple selector its key (rightmost) compound has, and
    /// as non-simple when it has a combinator.
    static func selectorCounts(_ selectorTexts: [String]) -> SelectorCounts {
        var counts = SelectorCounts()
        for text in selectorTexts {
            for selector in splitSelectorList(text) {
                let parts = compounds(selector)
                guard let key = parts.last else { continue }
                if parts.count > 1 { counts.nonSimple += 1 }
                let found = kinds(of: key)
                if found.type { counts.type += 1 }
                if found.id { counts.id += 1 }
                if found.classes { counts.classes += 1 }
                if found.universal { counts.universal += 1 }
                if found.attribute { counts.attribute += 1 }
            }
        }
        return counts
    }

    struct Summary: Equatable {
        var elements = 0
        var truncated = false
        var externalSheets = 0
        var inlineSheets = 0
        var unreadableSheets = 0
        var styleRules = 0
        var mediaQueries = 0
        var selectors = SelectorCounts()
    }

    // MARK: Media queries

    struct MediaQuery: Equatable, Identifiable {
        var text: String
        var count: Int
        var id: String { text }
    }

    /// Each distinct media query and how many @media rules use it, most first.
    static func mediaQueries(_ texts: [String]) -> [MediaQuery] {
        var counts: [String: Int] = [:]
        for text in texts {
            let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !normalized.isEmpty else { continue }
            counts[normalized, default: 0] += 1
        }
        return counts.map { MediaQuery(text: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.text < $1.text }
    }

    // MARK: Colours

    /// A colour the page uses and the elements using it.
    struct ColorUse: Equatable, Identifiable {
        var key: String
        var color: DeveloperCSSColor?
        var elements: [Int]
        var id: String { key }
        var count: Int { elements.count }
    }

    struct Colors: Equatable {
        var background: [ColorUse] = []
        var text: [ColorUse] = []
        var fill: [ColorUse] = []
        var border: [ColorUse] = []
        /// Every distinct colour in any of them.
        var unique: Int {
            Set((background + text + fill + border).map(\.key)).count
        }
    }

    /// A colour's key: its hex, or the text itself for one that doesn't
    /// parse. Nil for none at all (empty, transparent, currentcolor).
    static func colorKey(_ text: String) -> (key: String, color: DeveloperCSSColor?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !["none", "currentcolor", "inherit", "initial", "unset"].contains(trimmed.lowercased()) else { return nil }
        if let color = DeveloperCSSColor.parse(trimmed) {
            if color.isTransparent { return nil }
            return (key: color.hex, color: color)
        }
        // A url(…) fill or a paint server isn't a colour.
        if trimmed.lowercased().hasPrefix("url(") { return nil }
        return (trimmed, nil)
    }

    /// Colours by where they're used, most used first. Only rendered
    /// elements count; text colour only where an element has text of its
    /// own, fill only on SVG shapes, a border colour once per element.
    static func colors(_ elements: [Element]) -> Colors {
        var background = Tally(), text = Tally(), fill = Tally(), border = Tally()
        for element in elements where element.rendered {
            if let found = colorKey(element["backgroundColor"]) { background.add(found, element.index) }
            if element.hasText, let found = colorKey(element["color"]) { text.add(found, element.index) }
            if element.svgShape, let found = colorKey(element["fill"]) { fill.add(found, element.index) }
            var sides = Set<String>()
            for side in ["borderTopColor", "borderRightColor", "borderBottomColor", "borderLeftColor"] {
                if let found = colorKey(element[side]), sides.insert(found.key).inserted { border.add(found, element.index) }
            }
        }
        return Colors(background: background.uses, text: text.uses, fill: fill.uses, border: border.uses)
    }

    private struct Tally {
        private var order: [String] = []
        private var byKey: [String: ColorUse] = [:]

        mutating func add(_ found: (key: String, color: DeveloperCSSColor?), _ element: Int) {
            if byKey[found.key] == nil {
                order.append(found.key)
                byKey[found.key] = ColorUse(key: found.key, color: found.color, elements: [])
            }
            byKey[found.key]?.elements.append(element)
        }

        var uses: [ColorUse] {
            order.compactMap { byKey[$0] }.enumerated()
                .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
                .map(\.element)
        }
    }

    // MARK: Fonts

    struct FontUse: Equatable, Identifiable {
        var size: String
        var weight: String
        var lineHeight: String
        var elements: [Int]
        var id: String { size + "|" + weight + "|" + lineHeight }
        var count: Int { elements.count }
    }

    struct FontFamily: Equatable, Identifiable {
        var family: String
        var uses: [FontUse]
        var id: String { family }
        var count: Int { uses.reduce(0) { $0 + $1.count } }
    }

    /// Each font family set on text, and under it each size, weight and
    /// line-height used together, most used first.
    static func fonts(_ elements: [Element]) -> [FontFamily] {
        var families: [String: [String: FontUse]] = [:]
        for element in elements where element.rendered && element.hasText && !element.svgShape {
            let family = element["fontFamily"].isEmpty ? "(default)" : element["fontFamily"]
            let use = FontUse(size: element["fontSize"], weight: element["fontWeight"], lineHeight: element["lineHeight"], elements: [])
            families[family, default: [:]][use.id, default: use].elements.append(element.index)
        }
        return families.map { family, uses in
            FontFamily(family: family, uses: uses.values.sorted {
                $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id
            })
        }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.family < $1.family }
    }

    // MARK: Unused declarations

    struct Unused: Equatable {
        var property: String
        var value: String
        var reason: String
    }

    /// The computed values the overview's page script reads, by field,
    /// that DeveloperInactiveCSS judges with, by CSS name.
    private static let contextFields: [(field: String, name: String)] = [
        ("display", "display"), ("position", "position"),
    ]

    /// The declarations checked, by field and CSS name.
    private static let checked: [(field: String, name: String)] = [
        ("top", "top"), ("right", "right"), ("bottom", "bottom"), ("left", "left"),
        ("width", "width"), ("height", "height"), ("verticalAlign", "vertical-align"),
        ("marginTop", "margin-top"), ("marginRight", "margin-right"),
        ("marginBottom", "margin-bottom"), ("marginLeft", "margin-left"),
    ]

    /// What a computed style sets that its element ignores, as Chrome's
    /// overview checks: offsets on a statically positioned element, a
    /// size on a non-replaced inline one, vertical-align on a block-level
    /// one, margins on a table cell. The rules are Elements › Styles'
    /// (DeveloperInactiveCSS); a computed value left at its initial one
    /// isn't counted.
    static func unused(_ element: Element) -> [Unused] {
        var computed: [String: String] = [:]
        for (field, name) in contextFields { computed[name] = element[field] }
        let context = DeveloperInactiveCSS.Context(tag: element.tag, svgShape: element.svgShape, computed: computed)
        var found: [Unused] = []
        for (field, name) in checked {
            let value = element[field]
            if value.isEmpty || value == "auto" { continue }
            if name == "vertical-align", value == "baseline" { continue }
            if name.hasPrefix("margin"), isZero(value) { continue }
            if let reason = DeveloperInactiveCSS.reason(property: name, value: value, in: context) {
                found.append(Unused(property: name, value: value, reason: reason))
            }
        }
        return found
    }

    private static func isZero(_ value: String) -> Bool {
        let number = value.trimmingCharacters(in: .letters.union(.whitespaces).union(CharacterSet(charactersIn: "%")))
        return Double(number) == 0
    }

    struct UnusedGroup: Equatable, Identifiable {
        var reason: String
        var property: String
        var elements: [Int]
        /// The values found, most common first.
        var values: [String]
        var id: String { reason }
        var count: Int { elements.count }
    }

    /// Unused declarations grouped by why, most elements first.
    static func unusedGroups(_ elements: [Element]) -> [UnusedGroup] {
        var order: [String] = []
        var groups: [String: UnusedGroup] = [:]
        var values: [String: [String: Int]] = [:]
        for element in elements where element.rendered {
            for item in unused(element) {
                if groups[item.reason] == nil {
                    order.append(item.reason)
                    groups[item.reason] = UnusedGroup(reason: item.reason, property: item.property, elements: [], values: [])
                }
                groups[item.reason]?.elements.append(element.index)
                values[item.reason, default: [:]][item.value, default: 0] += 1
            }
        }
        return order.compactMap { reason -> UnusedGroup? in
            guard var group = groups[reason] else { return nil }
            group.values = (values[reason] ?? [:]).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
            return group
        }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.reason < $1.reason }
    }

    // MARK: Contrast

    /// What's behind an element's text: its own and its ancestors'
    /// backgrounds, composited down to the first opaque one (over white
    /// when none is). Nil when a background image is in the way, which
    /// can't be judged from colours alone.
    static func effectiveBackground(of index: Int, in elements: [Element]) -> DeveloperCSSColor? {
        var layers: [DeveloperCSSColor] = []
        var current: Int? = index
        var steps = 0
        while let at = current, at >= 0, at < elements.count, steps < 10_000 {
            let element = elements[at]
            if element.backgroundImage { return nil }
            if let color = DeveloperCSSColor.parse(element["backgroundColor"]), !color.isTransparent {
                layers.append(color)
                if color.isOpaque { break }
            }
            current = element.parent
            steps += 1
        }
        var result = DeveloperCSSColor.white
        for color in layers.reversed() { result = color.over(result) }
        return result
    }

    /// Large text by WCAG: 24px, or 18.66px (14pt) bold.
    static func isLargeText(fontSize: String, fontWeight: String) -> Bool {
        let size = Double(fontSize.lowercased().replacingOccurrences(of: "px", with: "").trimmingCharacters(in: .whitespaces)) ?? 16
        let weight: Double
        switch fontWeight.lowercased() {
        case "bold", "bolder": weight = 700
        case "normal", "": weight = 400
        default: weight = Double(fontWeight) ?? 400
        }
        return size >= 24 || (size >= 18.66 && weight >= 700)
    }

    /// WCAG AA: 4.5 for text, 3 for large text.
    static func threshold(large: Bool) -> Double { large ? 3 : 4.5 }

    struct ContrastIssue: Equatable, Identifiable {
        var text: DeveloperCSSColor
        var background: DeveloperCSSColor
        var ratio: Double
        var threshold: Double
        var elements: [Int]
        var id: String { text.hex + "/" + background.hex + "/" + String(threshold) }
        var count: Int { elements.count }
    }

    /// Text whose colour falls short of AA against what's behind it,
    /// grouped by the pair of colours (and the bar it misses), worst first.
    static func contrastIssues(_ elements: [Element]) -> [ContrastIssue] {
        var order: [String] = []
        var issues: [String: ContrastIssue] = [:]
        for element in elements where element.rendered && element.hasText && !element.svgShape {
            guard let text = DeveloperCSSColor.parse(element["color"]), !text.isTransparent,
                  let background = effectiveBackground(of: element.index, in: elements) else { continue }
            let ratio = DeveloperCSSColor.contrast(text, background)
            let bar = threshold(large: isLargeText(fontSize: element["fontSize"], fontWeight: element["fontWeight"]))
            guard ratio < bar else { continue }
            let issue = ContrastIssue(text: text, background: background, ratio: ratio, threshold: bar, elements: [])
            if issues[issue.id] == nil { order.append(issue.id); issues[issue.id] = issue }
            issues[issue.id]?.elements.append(element.index)
        }
        return order.compactMap { issues[$0] }.sorted {
            $0.ratio != $1.ratio ? $0.ratio < $1.ratio : $0.count > $1.count
        }
    }

    /// `3.42`, as a ratio is shown.
    static func ratioLabel(_ ratio: Double) -> String {
        String(format: "%.2f", (ratio * 100).rounded(.down) / 100)
    }

    // MARK: The report

    struct Report: Equatable {
        var summary = Summary()
        var elements: [Element] = []
        var colors = Colors()
        var fonts: [FontFamily] = []
        var unused: [UnusedGroup] = []
        var media: [MediaQuery] = []
        var contrast: [ContrastIssue] = []

        func label(_ index: Int) -> String {
            index >= 0 && index < elements.count ? elements[index].label : "element"
        }
    }

    static func report(_ data: [String: Any]) -> Report {
        let elements = Self.elements(data)
        let int = { (key: String) in (data[key] as? NSNumber)?.intValue ?? 0 }
        let mediaTexts = data["media"] as? [String] ?? []
        var summary = Summary()
        summary.elements = max(int("total"), elements.count)
        summary.truncated = data["truncated"] as? Bool ?? false
        summary.externalSheets = int("externalSheets")
        summary.inlineSheets = int("inlineSheets")
        summary.unreadableSheets = int("unreadableSheets")
        summary.styleRules = int("styleRules")
        summary.mediaQueries = mediaTexts.count
        summary.selectors = Self.selectorCounts(data["selectors"] as? [String] ?? [])
        return Report(summary: summary, elements: elements, colors: Self.colors(elements), fonts: Self.fonts(elements),
                      unused: Self.unusedGroups(elements), media: Self.mediaQueries(mediaTexts),
                      contrast: Self.contrastIssues(elements))
    }
}
