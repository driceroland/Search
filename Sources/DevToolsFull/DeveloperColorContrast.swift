import AppKit
import SwiftUI

/// Chrome's contrast section: the AA and AAA lines, each with the nearest
/// colour that would pass, of the same hue with only its lightness moved.
enum DeveloperContrastFix {
    struct Line: Equatable {
        /// "AA" or "AAA".
        let level: String
        /// 4.5 or 7, or 3 and 4.5 for large text.
        let threshold: Double
        let passes: Bool
        /// The suggested colour, when the line fails and one exists.
        let fix: DeveloperCSSColor?
    }

    static func thresholds(large: Bool) -> (aa: Double, aaa: Double) {
        large ? (3, 4.5) : (4.5, 7)
    }

    static func lines(foreground: DeveloperCSSColor, background: DeveloperCSSColor, large: Bool) -> [Line] {
        let ratio = DeveloperCSSColor.contrast(foreground, background)
        let (aa, aaa) = thresholds(large: large)
        return [("AA", aa), ("AAA", aaa)].map { level, threshold in
            let passes = ratio >= threshold
            return Line(level: level, threshold: threshold, passes: passes,
                        fix: passes ? nil : suggestion(for: foreground, on: background, ratio: threshold))
        }
    }

    /// `4.5`, `7`, `3`: a threshold as Chrome labels it.
    static func label(_ threshold: Double) -> String {
        threshold == threshold.rounded() ? String(Int(threshold)) : String(threshold)
    }

    /// The colour of the same hue and saturation nearest in lightness to
    /// `foreground` whose contrast with `background` reaches `ratio`, its
    /// alpha kept; nil when neither lighter nor darker gets there. A
    /// foreground that already passes is its own answer.
    static func suggestion(for foreground: DeveloperCSSColor, on background: DeveloperCSSColor,
                           ratio: Double) -> DeveloperCSSColor? {
        if DeveloperCSSColor.contrast(foreground, background) >= ratio { return foreground }
        let (hue, saturation, lightness) = hsl(foreground)
        let back = background.isOpaque ? background : background.over(.white)
        func color(_ l: Double) -> DeveloperCSSColor {
            rgb(hue: hue, saturation: saturation, lightness: l, alpha: foreground.alpha)
        }
        func shown(_ color: DeveloperCSSColor) -> Double {
            (color.isOpaque ? color : color.over(back)).luminance
        }
        // Lightness moves every channel the same way, so luminance (and so
        // contrast on each side of the background's) is monotonic in it.
        func passes(_ l: Double, lighter: Bool) -> Bool {
            let candidate = color(l)
            let side = lighter ? shown(candidate) >= back.luminance : shown(candidate) <= back.luminance
            return side && DeveloperCSSColor.contrast(candidate, background) >= ratio
        }
        func search(lighter: Bool) -> Double? {
            let end = lighter ? 1.0 : 0.0
            guard passes(end, lighter: lighter) else { return nil }
            var near = lightness, far = end
            for _ in 0..<40 {
                let middle = (near + far) / 2
                if passes(middle, lighter: lighter) { far = middle } else { near = middle }
            }
            return far
        }
        let found = [search(lighter: true), search(lighter: false)].compactMap { $0 }
            .min { abs($0 - lightness) < abs($1 - lightness) }
        guard let found else { return nil }
        // Rounded to whole channels, as the colour is written; a channel
        // lost in rounding is made up one step further on.
        let lighter = found > lightness
        var l = found
        for _ in 0..<64 {
            let candidate = rounded(color(l))
            if DeveloperCSSColor.contrast(candidate, background) >= ratio { return candidate }
            l = lighter ? min(1, l + 1.0 / 512) : max(0, l - 1.0 / 512)
        }
        return nil
    }

    private static func rounded(_ color: DeveloperCSSColor) -> DeveloperCSSColor {
        DeveloperCSSColor(red: color.red.rounded(), green: color.green.rounded(), blue: color.blue.rounded(),
                          alpha: color.alpha)
    }

    /// Hue in degrees, saturation and lightness 0…1.
    static func hsl(_ color: DeveloperCSSColor) -> (Double, Double, Double) {
        let r = color.red / 255, g = color.green / 255, b = color.blue / 255
        let high = max(r, g, b), low = min(r, g, b)
        let l = (high + low) / 2
        guard high > low else { return (0, 0, l) }
        let d = high - low
        let s = l > 0.5 ? d / (2 - high - low) : d / (high + low)
        var h: Double
        if high == r { h = (g - b) / d + (g < b ? 6 : 0) } else if high == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h *= 60
        return (h, s, l)
    }

    static func rgb(hue: Double, saturation: Double, lightness: Double, alpha: Double = 1) -> DeveloperCSSColor {
        let l = min(1, max(0, lightness)), s = min(1, max(0, saturation))
        let c = (1 - abs(2 * l - 1)) * s
        let h = ((hue.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        var r = 0.0, g = 0.0, b = 0.0
        if h < 1 { (r, g, b) = (c, x, 0) }
        else if h < 2 { (r, g, b) = (x, c, 0) }
        else if h < 3 { (r, g, b) = (0, c, x) }
        else if h < 4 { (r, g, b) = (0, x, c) }
        else if h < 5 { (r, g, b) = (x, 0, c) }
        else { (r, g, b) = (c, 0, x) }
        let m = l - c / 2
        return DeveloperCSSColor(red: (r + m) * 255, green: (g + m) * 255, blue: (b + m) * 255, alpha: alpha)
    }

    static func nsColor(_ color: DeveloperCSSColor) -> NSColor {
        NSColor(srgbRed: color.red / 255, green: color.green / 255, blue: color.blue / 255, alpha: color.alpha)
    }
}

/// The popover the contrast ratio opens: the ratio, then Chrome's AA and
/// AAA lines, a failing one offering its suggested colour.
struct DeveloperContrastDetails: View {
    let foreground: DeveloperCSSColor
    let contrast: DeveloperStyleContrast
    let apply: ((DeveloperCSSColor) -> Void)?

    var body: some View {
        let ratio = DeveloperCSSColor.contrast(foreground, contrast.background)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Contrast ratio").fontWeight(.semibold)
                Text(DeveloperCSSOverview.ratioLabel(ratio)).monospacedDigit()
                sample
            }
            ForEach(DeveloperContrastFix.lines(foreground: foreground, background: contrast.background,
                                               large: contrast.largeText), id: \.level) { line in
                HStack(spacing: 6) {
                    Text("\(line.level): \(DeveloperContrastFix.label(line.threshold))").monospacedDigit()
                    Image(systemName: line.passes ? "checkmark" : "exclamationmark.triangle.fill")
                        .foregroundStyle(line.passes ? Color.green : Color.orange)
                        .accessibilityLabel(line.passes ? "Passes" : "Fails")
                    if let fix = line.fix {
                        Button {
                            apply?(fix)
                        } label: {
                            HStack(spacing: 4) {
                                Rectangle().fill(Color(nsColor: DeveloperContrastFix.nsColor(fix)))
                                    .frame(width: 10, height: 10)
                                    .overlay { Rectangle().strokeBorder(Palette.ink.opacity(0.3), lineWidth: 0.5) }
                                Text(fix.hex)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(apply == nil)
                        .help("Use suggested color \(fix.hex) to fix low contrast")
                    }
                }
            }
            if contrast.largeText {
                Text("Large text").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(10)
    }

    private var sample: some View {
        Text("Aa")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(nsColor: DeveloperContrastFix.nsColor(foreground)))
            .padding(.horizontal, 4)
            .background(Color(nsColor: DeveloperContrastFix.nsColor(contrast.background)),
                        in: RoundedRectangle(cornerRadius: 2))
    }
}
