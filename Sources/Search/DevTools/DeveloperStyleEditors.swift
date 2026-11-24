import AppKit
import SwiftUI

// Chromium's inline style editors, ported for the Styles pane: the colour
// format picker (Shift-click a swatch), the bezier editor beside timing
// functions, the shadow editor beside box-shadow and text-shadow, and the
// flexbox and grid editors beside display: flex and display: grid.

// MARK: Colour formats

/// One colour written in each of the notations Chromium's
/// FormatPickerContextMenu offers.
enum DeveloperColorFormats {
    struct Option: Hashable {
        let text: String
        let section: Int  // 0 legacy, 1 wide gamut, 2 color()
    }

    static func options(for color: NSColor, original: String) -> [Option] {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let r = Double(rgb.redComponent), g = Double(rgb.greenComponent), b = Double(rgb.blueComponent)
        let alpha = Double(rgb.alphaComponent)
        let opaque = alpha >= 0.999
        let lower = original.lowercased().trimmingCharacters(in: .whitespaces)
        var output: [Option] = []
        func add(_ text: String, _ section: Int) {
            if text.lowercased() != lower, !output.contains(where: { $0.text == text }) { output.append(.init(text: text, section: section)) }
        }
        let bytes = [r, g, b].map { Int(($0 * 255).rounded()).clamped(0, 255) }
        let alphaByte = Int((alpha * 255).rounded()).clamped(0, 255)
        if opaque, let name = DeveloperColor.names.first(where: { Int($0.value.0) == bytes[0] && Int($0.value.1) == bytes[1] && Int($0.value.2) == bytes[2] })?.key {
            add(name, 0)
        }
        let hexDigits = bytes.map { String(format: "%02x", $0) } + (opaque ? [] : [String(format: "%02x", alphaByte)])
        if hexDigits.allSatisfy({ $0.first == $0.last }) { add("#" + hexDigits.map { String($0.first!) }.joined(), 0) }
        add("#" + hexDigits.joined(), 0)
        let slash = opaque ? "" : " / " + number(alpha)
        add("rgb(\(bytes[0]) \(bytes[1]) \(bytes[2])\(slash))", 0)
        let (h, s, l) = hsl(r, g, b)
        add("hsl(\(number(h))deg \(number(s * 100))% \(number(l * 100))%\(slash))", 0)
        let white = min(r, g, b), black = 1 - max(r, g, b)
        add("hwb(\(number(h))deg \(number(white * 100))% \(number(black * 100))%\(slash))", 0)
        let linear = [r, g, b].map(linearize)
        let lab = cieLab(linear)
        let lch = polar(lab.1, lab.2)
        add("lch(\(number(lab.0)) \(number(lch.0)) \(number(lch.1))\(slash))", 1)
        let ok = okLab(linear)
        let okch = polar(ok.1, ok.2)
        add("oklch(\(number(ok.0)) \(number(okch.0)) \(number(okch.1))\(slash))", 1)
        add("lab(\(number(lab.0)) \(number(lab.1)) \(number(lab.2))\(slash))", 1)
        add("oklab(\(number(ok.0)) \(number(ok.1)) \(number(ok.2))\(slash))", 1)
        add("color(srgb \(number(r)) \(number(g)) \(number(b))\(slash))", 2)
        add("color(srgb-linear \(number(linear[0])) \(number(linear[1])) \(number(linear[2]))\(slash))", 2)
        let p3 = displayP3(linear)
        add("color(display-p3 \(number(p3[0])) \(number(p3[1])) \(number(p3[2]))\(slash))", 2)
        return output
    }

    /// The order Shift-click on a swatch walks the formats in, as Chrome
    /// DevTools cycles them; a named colour goes to hex first.
    static let cycle = ["hex", "rgb", "hsl", "hwb", "lch", "oklch", "lab", "oklab", "color"]

    /// A colour's notation: "hex", "rgb" (rgba too), "hsl", … or "name".
    static func format(of text: String) -> String {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.hasPrefix("#") { return "hex" }
        for format in cycle where lower.hasPrefix(format + "(") || lower.hasPrefix(format + "a(") { return format }
        return "name"
    }

    /// The colour written in the next format of the cycle that differs
    /// from how it is written now.
    static func next(after original: String, color: NSColor) -> String {
        let all = options(for: color, original: "")
        let start = cycle.firstIndex(of: format(of: original)).map { $0 + 1 } ?? 0
        for offset in 0..<cycle.count {
            let wanted = cycle[(start + offset) % cycle.count]
            if let found = all.first(where: { format(of: $0.text) == wanted && $0.text.lowercased() != original.lowercased() }) {
                return found.text
            }
        }
        return original
    }

    /// Chromium's stringifyWithPrecision: two decimals, trailing zeros gone.
    static func number(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    private static func hsl(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        let l = (high + low) / 2
        guard delta > 0 else { return (0, 0, l) }
        let s = delta / (1 - abs(2 * l - 1))
        var h: Double
        if high == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if high == g { h = (b - r) / delta + 2 }
        else { h = (r - g) / delta + 4 }
        h *= 60
        if h < 0 { h += 360 }
        return (h, s, l)
    }

    private static func linearize(_ c: Double) -> Double {
        abs(c) <= 0.04045 ? c / 12.92 : (c < 0 ? -1 : 1) * pow((abs(c) + 0.055) / 1.055, 2.4)
    }

    private static func gamma(_ c: Double) -> Double {
        abs(c) <= 0.0031308 ? c * 12.92 : (c < 0 ? -1 : 1) * (1.055 * pow(abs(c), 1 / 2.4) - 0.055)
    }

    private static func multiply(_ m: [[Double]], _ v: [Double]) -> [Double] {
        m.map { row in zip(row, v).map(*).reduce(0, +) }
    }

    private static let srgbToXYZ: [[Double]] = [
        [0.41239079926595934, 0.357584339383878, 0.1804807884018343],
        [0.21263900587151027, 0.715168678767756, 0.07219231536073371],
        [0.01933081871559182, 0.11919477979462598, 0.9505321522496607],
    ]

    private static func cieLab(_ linear: [Double]) -> (Double, Double, Double) {
        let d65 = multiply(srgbToXYZ, linear)
        let d50 = multiply([
            [1.0479298208405488, 0.022946793341019088, -0.05019222954313557],
            [0.029627815688159344, 0.990434484573249, -0.01707382502938514],
            [-0.009243058152591178, 0.015055144896577895, 0.7518742899580008],
        ], d65)
        let white = [0.3457 / 0.3585, 1, (1 - 0.3457 - 0.3585) / 0.3585]
        let f = zip(d50, white).map { value, w -> Double in
            let t = value / w
            return t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116
        }
        return (116 * f[1] - 16, 500 * (f[0] - f[1]), 200 * (f[1] - f[2]))
    }

    private static func okLab(_ linear: [Double]) -> (Double, Double, Double) {
        let lms = multiply([
            [0.4122214708, 0.5363325363, 0.0514459929],
            [0.2119034982, 0.6806995451, 0.1073969566],
            [0.0883024619, 0.2817188376, 0.6299787005],
        ], linear).map(cbrt)
        let lab = multiply([
            [0.2104542553, 0.7936177850, -0.0040720468],
            [1.9779984951, -2.4285922050, 0.4505937099],
            [0.0259040371, 0.7827717662, -0.8086757660],
        ], lms)
        return (lab[0], lab[1], lab[2])
    }

    private static func polar(_ a: Double, _ b: Double) -> (Double, Double) {
        let chroma = (a * a + b * b).squareRoot()
        var hue = atan2(b, a) * 180 / .pi
        if hue < 0 { hue += 360 }
        return (chroma, chroma < 0.0001 ? 0 : hue)
    }

    private static func displayP3(_ linear: [Double]) -> [Double] {
        multiply([
            [2.493496911941425, -0.9313836179191239, -0.40271078445071684],
            [-0.8294889695615747, 1.7626640603183463, 0.023624685841943577],
            [0.03584583024378447, -0.07617238926804182, 0.9568845240076872],
        ], multiply(srgbToXYZ, linear)).map(gamma)
    }
}

private extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), high) }
}

// MARK: Bezier editor

/// Chromium's BezierEditor presets, in its categories.
enum DeveloperEasing {
    static let presets: [[(name: String, value: String)]] = [
        [("linear", "linear")],
        [("ease-in-out", "ease-in-out"), ("In Out · Sine", "cubic-bezier(0.45, 0.05, 0.55, 0.95)"),
         ("In Out · Quadratic", "cubic-bezier(0.46, 0.03, 0.52, 0.96)"), ("In Out · Cubic", "cubic-bezier(0.65, 0.05, 0.36, 1)"),
         ("Fast Out, Slow In", "cubic-bezier(0.4, 0, 0.2, 1)"), ("In Out · Back", "cubic-bezier(0.68, -0.55, 0.27, 1.55)")],
        [("Fast Out, Linear In", "cubic-bezier(0.4, 0, 1, 1)"), ("ease-in", "ease-in"),
         ("In · Sine", "cubic-bezier(0.47, 0, 0.75, 0.72)"), ("In · Quadratic", "cubic-bezier(0.55, 0.09, 0.68, 0.53)"),
         ("In · Cubic", "cubic-bezier(0.55, 0.06, 0.68, 0.19)"), ("In · Back", "cubic-bezier(0.6, -0.28, 0.74, 0.05)")],
        [("ease-out", "ease-out"), ("Out · Sine", "cubic-bezier(0.39, 0.58, 0.57, 1)"),
         ("Out · Quadratic", "cubic-bezier(0.25, 0.46, 0.45, 0.94)"), ("Out · Cubic", "cubic-bezier(0.22, 0.61, 0.36, 1)"),
         ("Linear Out, Slow In", "cubic-bezier(0, 0, 0.2, 1)"), ("Out · Back", "cubic-bezier(0.18, 0.89, 0.32, 1.28)")],
    ]

    static let keywords: [String: [Double]] = [
        "linear": [0, 0, 1, 1], "ease": [0.25, 0.1, 0.25, 1], "ease-in": [0.42, 0, 1, 1],
        "ease-out": [0, 0, 0.58, 1], "ease-in-out": [0.42, 0, 0.58, 1],
    ]

    static func isTimingProperty(_ name: String) -> Bool {
        ["transition", "transition-timing-function", "animation", "animation-timing-function"].contains(name)
    }

    /// The first easing in a value: a keyword or a cubic-bezier().
    static func token(in value: String) -> String? {
        if let range = value.range(of: #"cubic-bezier\([^)]*\)"#, options: .regularExpression) { return String(value[range]) }
        let words = value.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        return words.first { keywords[$0] != nil }
    }

    static func points(_ token: String) -> [Double]? {
        if let known = keywords[token] { return known }
        guard token.hasPrefix("cubic-bezier(") else { return nil }
        let numbers = token.dropFirst("cubic-bezier(".count).dropLast().split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return numbers.count == 4 ? numbers : nil
    }

    static func css(_ p: [Double]) -> String {
        if let name = keywords.first(where: { $0.value == p })?.key { return name }
        return "cubic-bezier(" + p.map(DeveloperColorFormats.number).joined(separator: ", ") + ")"
    }
}

struct DeveloperEasingSwatch: View {
    let value: String
    let onChange: ((String) -> Void)?
    @State private var shown = false

    var body: some View {
        if let token = DeveloperEasing.token(in: value), let points = DeveloperEasing.points(token) {
            Button { if onChange != nil { shown = true } } label: {
                DeveloperBezierCurve(points: points).stroke(DeveloperToolsStyle.tint, lineWidth: 1.2)
                    .frame(width: 10, height: 10)
            }
            .buttonStyle(.plain)
            .help(onChange == nil ? token : "Open cubic bezier editor")
            .accessibilityLabel("Open cubic bezier editor")
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                DeveloperBezierEditor(points: points) { new in
                    onChange?(value.replacingOccurrences(of: token, with: new))
                }
            }
        }
    }
}

struct DeveloperBezierCurve: Shape {
    let points: [Double]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let low = min(0, points[1], points[3]), high = max(1, points[1], points[3])
        func y(_ value: Double) -> CGFloat { rect.maxY - CGFloat((value - low) / (high - low)) * rect.height }
        path.move(to: CGPoint(x: rect.minX, y: y(0)))
        path.addCurve(to: CGPoint(x: rect.maxX, y: y(1)),
                      control1: CGPoint(x: rect.minX + CGFloat(points[0]) * rect.width, y: y(points[1])),
                      control2: CGPoint(x: rect.minX + CGFloat(points[2]) * rect.width, y: y(points[3])))
        return path
    }
}

struct DeveloperBezierEditor: View {
    @State var points: [Double]
    let onChange: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(DeveloperEasing.presets.enumerated()), id: \.offset) { _, category in
                    Menu(category[0].name) {
                        ForEach(category, id: \.value) { preset in
                            Button(preset.name) { set(DeveloperEasing.points(preset.value) ?? points, text: preset.value) }
                        }
                    }
                    .fixedSize()
                }
            }
            VStack(spacing: 6) {
                ZStack {
                    Rectangle().strokeBorder(DeveloperToolsStyle.rule)
                    DeveloperBezierCurve(points: points).stroke(DeveloperToolsStyle.tint, lineWidth: 2)
                        .padding(8)
                }
                .frame(width: 130, height: 130)
                Text(DeveloperEasing.css(points)).font(DeveloperToolsStyle.code).textSelection(.enabled)
                Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 2) {
                    ForEach(0..<2, id: \.self) { pair in
                        GridRow {
                            ForEach(0..<2, id: \.self) { axis in
                                let index = pair * 2 + axis
                                Text(["x\(pair + 1)", "y\(pair + 1)"][axis]).foregroundStyle(.secondary)
                                DeveloperSlider(value: Binding(get: { points[index] }, set: { new in
                                    var copy = points
                                    copy[index] = axis == 0 ? min(max(new, 0), 1) : new
                                    set(copy, text: nil)
                                }), in: axis == 0 ? 0...1 : -1...2)
                                .frame(width: 60)
                            }
                        }
                    }
                }
                .font(.system(size: 10))
            }
        }
        .padding(10)
    }

    private func set(_ new: [Double], text: String?) {
        points = new.map { ($0 * 100).rounded() / 100 }
        onChange(text ?? DeveloperEasing.css(points))
    }
}

// MARK: Shadow editor

/// Chromium's CSSShadowEditor for one box-shadow or text-shadow layer.
struct DeveloperShadow: Equatable {
    var inset = false
    var x = "0px", y = "0px", blur = "0px", spread = "0px"
    var color = ""
    var hasSpread = false

    init?(_ text: String) {
        var lengths: [String] = []
        var depth = 0, current = "", colourParts: [String] = []
        for character in text + " " {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if character == " " && depth == 0 {
                if !current.isEmpty {
                    if current == "inset" { inset = true }
                    else if Double(current.replacingOccurrences(of: #"[a-z%]+$"#, with: "", options: .regularExpression)) != nil { lengths.append(current) }
                    else { colourParts.append(current) }
                }
                current = ""
            } else { current.append(character) }
        }
        guard lengths.count >= 2 else { return nil }
        x = lengths[0]; y = lengths[1]
        if lengths.count > 2 { blur = lengths[2] }
        if lengths.count > 3 { spread = lengths[3]; hasSpread = true }
        color = colourParts.joined(separator: " ")
    }

    func css(spread allowed: Bool) -> String {
        ([inset ? "inset" : nil, x, y, blur, allowed && (hasSpread || spread != "0px") ? spread : nil,
          color.isEmpty ? nil : color] as [String?]).compactMap { $0 }.joined(separator: " ")
    }
}

/// Top-level commas in a value (between shadow layers).
func developerSplitLayers(_ value: String) -> [String] {
    var output: [String] = [], depth = 0, current = ""
    for character in value {
        if character == "(" { depth += 1 }
        if character == ")" { depth -= 1 }
        if character == ",", depth == 0 { output.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
        else { current.append(character) }
    }
    output.append(current.trimmingCharacters(in: .whitespaces))
    return output
}

struct DeveloperShadowSwatch: View {
    let property: String
    let value: String
    let onChange: ((String) -> Void)?
    @State private var shown = false

    var body: some View {
        if ["box-shadow", "text-shadow"].contains(property), DeveloperShadow(developerSplitLayers(value)[0]) != nil {
            Button { if onChange != nil { shown = true } } label: {
                Image(systemName: "shadow").font(.system(size: 9)).foregroundStyle(DeveloperToolsStyle.tint)
            }
            .buttonStyle(.plain)
            .help(onChange == nil ? value : "Open shadow editor")
            .accessibilityLabel("Open shadow editor")
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                DeveloperShadowEditor(shadow: DeveloperShadow(developerSplitLayers(value)[0])!, spread: property == "box-shadow") { layer in
                    var layers = developerSplitLayers(value)
                    layers[0] = layer
                    onChange?(layers.joined(separator: ", "))
                }
            }
        }
    }
}

struct DeveloperShadowEditor: View {
    @State var shadow: DeveloperShadow
    let spread: Bool
    let onChange: (String) -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            if spread {
                GridRow {
                    Text("Type")
                    Picker("Type", selection: Binding(get: { shadow.inset }, set: { shadow.inset = $0; commit() })) {
                        Text("Outset").tag(false)
                        Text("Inset").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 140)
                }
            }
            length("X offset", \.x, range: -20...20)
            length("Y offset", \.y, range: -20...20)
            length("Blur", \.blur, range: 0...20)
            if spread { length("Spread", \.spread, range: -20...20) }
        }
        .font(.system(size: 11))
        .padding(10)
    }

    private func length(_ title: String, _ key: WritableKeyPath<DeveloperShadow, String>, range: ClosedRange<Double>) -> some View {
        GridRow {
            Text(title)
            HStack(spacing: 6) {
                TextField(title, text: Binding(get: { shadow[keyPath: key] }, set: { shadow[keyPath: key] = $0 }))
                    .developerToolsField().frame(width: 56).onSubmit(commit)
                DeveloperSlider(value: Binding(get: {
                    Double(shadow[keyPath: key].replacingOccurrences(of: #"[a-z%]+$"#, with: "", options: .regularExpression)) ?? 0
                }, set: { new in
                    let unit = shadow[keyPath: key].range(of: #"[a-z%]+$"#, options: .regularExpression).map { String(shadow[keyPath: key][$0]) } ?? "px"
                    shadow[keyPath: key] = DeveloperColorFormats.number(new.rounded()) + (new.rounded() == 0 && unit == "px" ? "px" : unit)
                    if key == \.spread { shadow.hasSpread = true }
                    commit()
                }), in: range, step: 1)
                .frame(width: 90)
            }
        }
    }

    private func commit() { onChange(shadow.css(spread: spread)) }
}

// MARK: Flexbox and grid editors

/// Chromium's StylePropertyEditor (FlexboxEditor and GridEditor).
enum DeveloperLayoutEditor {
    static let flexbox: [(String, [String])] = [
        ("flex-direction", ["row", "column", "row-reverse", "column-reverse"]),
        ("flex-wrap", ["nowrap", "wrap", "wrap-reverse"]),
        ("align-content", ["center", "flex-start", "flex-end", "space-around", "space-between", "stretch"]),
        ("justify-content", ["center", "flex-start", "flex-end", "space-between", "space-around", "space-evenly"]),
        ("align-items", ["center", "flex-start", "flex-end", "stretch", "baseline"]),
    ]
    static let grid: [(String, [String])] = [
        ("grid-auto-flow", ["row", "column"]),
        ("align-content", ["center", "start", "end", "space-between", "space-around", "space-evenly", "stretch"]),
        ("justify-content", ["center", "start", "end", "space-between", "space-around", "space-evenly", "stretch"]),
        ("align-items", ["center", "start", "end", "stretch", "baseline"]),
        ("justify-items", ["center", "start", "end", "stretch"]),
    ]

    /// grid-auto-flow's direction and whether it is dense: "column dense" → ("column", true).
    static func autoFlow(_ value: String?) -> (direction: String?, dense: Bool) {
        let words = (value ?? "").split(separator: " ").map(String.init)
        return (words.first { $0 != "dense" }, words.contains("dense"))
    }

    /// The two written back: "row dense", "dense", "column", or nil for none.
    static func autoFlow(direction: String?, dense: Bool) -> String? {
        let words = [direction, dense ? "dense" : nil].compactMap { $0 }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    static func kind(_ property: DeveloperToolsSession.Detail) -> String? {
        guard property.name == "display" else { return nil }
        switch property.value.trimmingCharacters(in: .whitespaces) {
        case "flex", "inline-flex": return "flex"
        case "grid", "inline-grid": return "grid"
        default: return nil
        }
    }
}

struct DeveloperLayoutEditorButton: View {
    let kind: String
    let rule: DeveloperToolsSession.StyleRule
    /// Sets (value) or removes (nil) a declaration in the rule.
    let onSet: (String, String?) -> Void
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            Image(systemName: kind == "flex" ? "rectangle.split.3x1" : "square.grid.3x3")
                .font(.system(size: 9)).foregroundStyle(DeveloperToolsStyle.tint)
        }
        .buttonStyle(.plain)
        .help(kind == "flex" ? "Open flexbox editor" : "Open grid editor")
        .accessibilityLabel(kind == "flex" ? "Open flexbox editor" : "Open grid editor")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(kind == "flex" ? DeveloperLayoutEditor.flexbox : DeveloperLayoutEditor.grid, id: \.0) { name, values in
                    let current = rule.properties.last { $0.name == name && $0.enabled }?.value
                    // grid-auto-flow's direction buttons keep its dense checkbox, as in Chrome.
                    let flow = name == "grid-auto-flow" ? DeveloperLayoutEditor.autoFlow(current) : nil
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name + ": " + (current ?? "")).font(DeveloperToolsStyle.code)
                        HStack(spacing: 3) {
                            ForEach(values, id: \.self) { value in
                                let on = flow.map { $0.direction == value } ?? (current == value)
                                Button(value) {
                                    onSet(name, flow.map { DeveloperLayoutEditor.autoFlow(direction: on ? nil : value, dense: $0.dense) }
                                        ?? (on ? nil : value))
                                }
                                    .buttonStyle(.plain).font(.system(size: 10))
                                    .padding(.horizontal, 5).frame(height: 18)
                                    .background(on ? DeveloperToolsStyle.selected : DeveloperToolsStyle.raised,
                                                in: RoundedRectangle(cornerRadius: 3))
                                    .help(on ? "Remove \(name): \(value)" : "Add \(name): \(value)")
                            }
                            if let flow {
                                Toggle("dense", isOn: Binding(get: { flow.dense }, set: {
                                    onSet(name, DeveloperLayoutEditor.autoFlow(direction: flow.direction, dense: $0))
                                }))
                                .toggleStyle(.developerCheckbox).font(.system(size: 10)).padding(.leading, 4)
                            }
                        }
                    }
                }
            }
            .padding(10)
        }
    }
}

// MARK: DOM Breakpoints, Properties, Accessibility

/// Chromium's DOMBreakpointsSidebarPane: each breakpoint with its node.
/// As in Chrome, the checkbox switches a breakpoint off and on (it stays
/// listed); the context menu removes it.
struct DeveloperDOMBreakpointsPane: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var debugger: DeveloperDebugger

    var body: some View {
        let items = debugger.domBreakpoints
        VStack(alignment: .leading, spacing: DeveloperToolsStyle.stackSpacing) {
            if items.isEmpty {
                Text("No DOM breakpoints").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 12)
                Text("DOM breakpoints pause on the code that changes a DOM node or its children")
                    .foregroundStyle(.secondary).font(.system(size: 10)).frame(maxWidth: .infinity)
            }
            ForEach(items) { item in
                HStack(spacing: 6) {
                    Toggle("", isOn: Binding(get: { item.enabled }, set: { debugger.setDOMBreakpointEnabled(item.id, $0) }))
                        .toggleStyle(.developerCheckbox).labelsHidden()
                        .help(item.enabled ? "Disable breakpoint" : "Enable breakpoint")
                    VStack(alignment: .leading, spacing: 0) {
                        Text(session.nodes[item.node].map(DeveloperToolsSession.label) ?? item.label)
                            .foregroundStyle(DeveloperToolsStyle.tint)
                        Text(item.type.title).foregroundStyle(.secondary)
                    }
                    .opacity(item.enabled ? 1 : 0.6)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { session.selectNode(item.node) }
                .contextMenu {
                    Button("Reveal DOM node in Elements panel") { session.selectNode(item.node) }
                    Button("Remove breakpoint") { debugger.removeDOMBreakpoint(item.id) }
                    Button("Remove all DOM breakpoints") {
                        for each in debugger.domBreakpoints { debugger.removeDOMBreakpoint(each.id) }
                    }
                }
            }
        }
        .padding(8)
    }
}

/// Chromium's PropertiesWidget: the node object's properties, expandable,
/// with "Show all" and a filter.
struct DeveloperPropertiesPane: View {
    @ObservedObject var session: DeveloperToolsSession
    let node: Int
    @AppStorage("developerTools.propertiesShowAll") private var showAll = false
    @State private var filter = ""
    @State private var items: [DeveloperToolsSession.PropertyItem] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                TextField("Filter", text: $filter).developerToolsField()
                Toggle("Show all", isOn: $showAll).toggleStyle(.developerCheckbox).controlSize(.small).fixedSize()
                    .help("When unchecked, only properties whose values are neither null nor undefined will be shown")
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter).frame(height: DeveloperToolsStyle.toolbarHeight)
            .background(DeveloperToolsStyle.chrome)
            Divider()
            ScrollView {
                let shown = visible(items)
                LazyVStack(alignment: .leading, spacing: 0) {
                    if shown.isEmpty, !items.isEmpty { Text("No matching property").foregroundStyle(.secondary) }
                    ForEach(shown) { item in DeveloperPropertyRow(session: session, node: node, item: item, showAll: showAll) }
                }
                .padding(8)
            }
        }
        .task(id: "\(node)-\(session.domRevision)") { items = await session.properties(of: node) }
    }

    private func visible(_ list: [DeveloperToolsSession.PropertyItem]) -> [DeveloperToolsSession.PropertyItem] {
        list.filter { showAll || ($0.type != "undefined" && $0.value != "null") }
            .filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.value.localizedCaseInsensitiveContains(filter) }
    }
}

struct DeveloperPropertyRow: View {
    @ObservedObject var session: DeveloperToolsSession
    let node: Int
    let item: DeveloperToolsSession.PropertyItem
    let showAll: Bool
    @State private var open = false
    @State private var children: [DeveloperToolsSession.PropertyItem]?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: open ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                    .font(.system(size: 7)).foregroundStyle(.secondary).opacity(item.objectID == nil ? 0 : 1)
                Text(item.name).foregroundStyle(item.own ? Color.purple : Color.purple.opacity(0.6))
                Text(": ")
                Text(item.value).foregroundStyle(item.type == "string" ? Color.red.opacity(0.8) : Palette.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 16)
            .contentShape(Rectangle())
            .onTapGesture {
                guard let object = item.objectID else { return }
                open.toggle()
                if open, children == nil { Task { children = await session.properties(of: node, object: object) } }
            }
            if open, let children {
                ForEach(children.filter { showAll || ($0.type != "undefined" && $0.value != "null") }) { child in
                    DeveloperPropertyRow(session: session, node: node, item: child, showAll: showAll).padding(.leading, 12)
                }
            }
        }
    }
}

/// The accessibility tree and properties for the selected element.
struct DeveloperAccessibilityPane: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var elements: DeveloperElementsState
    let node: Int
    @State private var details: DeveloperToolsSession.AccessibilityDetails?

    private var properties: [String: Any] { details?.properties ?? [:] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let details, let selected = details.selected, properties["ignored"] as? Bool != true {
                    section("Accessibility tree")
                    ForEach(Array((details.ancestors + [selected]).enumerated()), id: \.element.id) { depth, link in
                        nodeLink(link, selected: link.id == node)
                            .padding(.leading, indentation(depth))
                    }
                    ForEach(details.children) { link in
                        nodeLink(link).padding(.leading, indentation(details.ancestors.count + 1))
                    }
                }
                section("ARIA attributes")
                let aria = ariaAttributes
                if aria.isEmpty { Text("No ARIA attributes").foregroundStyle(.secondary).padding(.leading, 8) }
                ForEach(aria, id: \.0) { name, value in pair(name, value, nameColor: .purple) }
                section("Computed properties")
                if details != nil, properties["exists"] as? Bool != true {
                    Text("No accessibility node").foregroundStyle(.secondary).padding(.leading, 8)
                } else if properties["ignored"] as? Bool == true {
                    Text("Accessibility node not exposed").foregroundStyle(.secondary).padding(.leading, 8)
                    if properties["hidden"] as? Bool == true { Text("Element isn’t visible").foregroundStyle(.secondary).padding(.leading, 8) }
                } else {
                    ForEach(computed, id: \.0) { name, value in pair(name, value, nameColor: DeveloperToolsStyle.tint) }
                }
                if let details, !details.relations.isEmpty {
                    section("Relations")
                    ForEach(details.relations) { relation in
                        Text(relation.title).foregroundStyle(.secondary).padding(.leading, 8)
                        ForEach(relation.nodes) { link in
                            nodeLink(link).padding(.leading, 16)
                        }
                    }
                }
                sourceOrderViewer
            }
            .padding(8)
        }
        // The badges belong to the element they were drawn for: another
        // selection, or leaving the pane, takes them down, as in Chrome.
        .onChange(of: node) { session.showSourceOrder(nil) }
        .onDisappear { session.showSourceOrder(nil) }
        .task(id: "\(node)-\(session.domRevision)") {
            details = nil
            let result = await session.accessibility(of: node)
            guard !Task.isCancelled else { return }
            details = result
        }
    }

    @ViewBuilder
    private var sourceOrderViewer: some View {
        let shown = elements.sourceOrder?.node == node
        section("Source order viewer")
        Toggle("Show source order", isOn: Binding(get: { shown }, set: { session.showSourceOrder($0 ? node : nil) }))
            .toggleStyle(.developerCheckbox).controlSize(.small)
            .padding(.leading, 8)
            .accessibilityIdentifier("developer-source-order")
        if shown, let order = elements.sourceOrder, let count = order.shown,
           let summary = DeveloperSourceOrder.summary(shown: count, capped: order.capped) {
            Text(summary).foregroundStyle(.secondary).padding(.leading, 8)
        }
    }

    private func indentation(_ depth: Int) -> CGFloat { 8 + CGFloat(min(depth, 8)) * 8 }

    private func nodeLink(_ link: DeveloperToolsSession.AccessibilityDetails.NodeLink, selected: Bool = false) -> some View {
        Button {
            session.selectNode(link.id)
        } label: {
            Text(link.title)
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(selected ? Color.primary : DeveloperToolsStyle.tint)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help(link.title)
    }

    private func section(_ title: String) -> some View {
        Text(title).fontWeight(.semibold).padding(.top, 4)
    }

    private func pair(_ name: String, _ value: String, nameColor: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(name).foregroundStyle(nameColor)
            Text(": ")
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
    }

    private var ariaAttributes: [(String, String)] {
        guard let element = session.nodes[node] else { return [] }
        return stride(from: 0, to: max(0, element.attributes.count - 1), by: 2)
            .filter { element.attributes[$0].hasPrefix("aria-") || element.attributes[$0] == "role" }
            .map { (element.attributes[$0], element.attributes[$0 + 1]) }
    }

    /// WebKit's fields under Chromium's names (AccessibilityStrings).
    private var computed: [(String, String)] {
        let names: [(String, String)] = [
            ("label", "Name"), ("role", "Role"), ("headingLevel", "Level"), ("hierarchyLevel", "Level"),
            ("disabled", "Disabled"), ("focused", "Focused"), ("readonly", "Read-only"), ("required", "Required"),
            ("invalid", "Invalid user entry"), ("checked", "Checked"), ("expanded", "Expanded"), ("pressed", "Pressed"),
            ("selected", "Selected"), ("liveRegionStatus", "Live region"), ("liveRegionAtomic", "Atomic (live regions)"),
            ("liveRegionRelevant", "Relevant (live regions)"), ("busy", "Busy (live regions)"), ("current", "Current"),
            ("isPopUpButton", "Has popup"), ("switchState", "Switch state"),
        ]
        var seen = Set<String>()
        return names.compactMap { key, title in
            guard let raw = properties[key], seen.insert(title).inserted else { return nil }
            if let list = raw as? [Any] { return (title, list.map { "\($0)" }.joined(separator: " ")) }
            if let flag = raw as? Bool { return (title, flag ? "true" : "false") }
            let text = "\(raw)"
            return key == "label" ? (title, "\"\(text)\"") : (title, text)
        }
    }
}
