import AppKit
import SwiftUI

/// "Copy visible styled selection": messages as rich text, with the
/// colours, weights and decorations `%c` gave them and the value colours
/// the console draws, as RTF beside the plain text.
enum ConsoleStyledCopy {
    static let fontSize: CGFloat = 11

    static func attributed(_ rows: [ConsoleRow]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, row) in rows.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n", attributes: [.font: font(size: fontSize)])) }
            output.append(attributed(row.line))
        }
        return output
    }

    static func attributed(_ line: DeveloperToolsSession.ConsoleLine) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let level = levelColor(line.level)
        if line.details?.type == "clear" || line.details?.type == "navigation" {
            let run: [NSAttributedString.Key: Any] = [.font: font(size: fontSize, italic: true),
                                                      .foregroundColor: resolved(.secondaryLabelColor)]
            output.append(NSAttributedString(string: line.text, attributes: run))
            return output
        }
        for segment in ConsoleRowContent.segments(line) {
            switch segment {
            case .text(let text, let style):
                output.append(NSAttributedString(string: text, attributes: attributes(style, color: level)))
            case .object(let object, let style):
                var color = level
                if let value = ConsoleTheme.color(for: object), object.subtype != "error" { color = resolved(NSColor(value)) }
                var run = attributes(style, color: color)
                if style.isPlain, object.type == "function" { run[.font] = font(size: fontSize, italic: true) }
                output.append(NSAttributedString(string: ConsoleFormat.inline(object), attributes: run))
            }
        }
        return output
    }

    /// A `%c` style as AppKit attributes; `color` is what the text has
    /// when the style sets none.
    static func attributes(_ style: ConsoleStyle, color: NSColor?) -> [NSAttributedString.Key: Any] {
        var run: [NSAttributedString.Key: Any] = [
            .font: font(size: CGFloat(style.fontSize ?? Double(fontSize)), bold: style.bold, italic: style.italic,
                        monospaced: style.monospaced),
        ]
        if let value = style.color.map({ nsColor($0) }) ?? color { run[.foregroundColor] = value }
        if let background = style.background { run[.backgroundColor] = nsColor(background) }
        if style.underline { run[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strikethrough { run[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return run
    }

    static func font(size: CGFloat, bold: Bool = false, italic: Bool = false, monospaced: Bool = true) -> NSFont {
        let weight: NSFont.Weight = bold ? .bold : .regular
        let base = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        guard italic else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }

    static func nsColor(_ color: ConsoleColor) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    /// Errors, warnings and verbose messages keep their colour; other
    /// text takes the destination's own.
    private static func levelColor(_ level: String) -> NSColor? {
        switch level {
        case "error": return resolved(NSColor(ConsoleTheme.errorText))
        case "warning": return resolved(NSColor(ConsoleTheme.warningText))
        case "debug": return resolved(NSColor(ConsoleTheme.verbose))
        default: return nil
        }
    }

    /// A theme colour as it draws now, so RTF carries plain RGB.
    private static func resolved(_ color: NSColor) -> NSColor {
        var output = color
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)
        appearance?.performAsCurrentDrawingAppearance {
            output = color.usingColorSpace(.sRGB) ?? color
        }
        return output
    }

    static func rtf(_ text: NSAttributedString) -> Data? {
        text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:])
    }

    static func copy(_ rows: [ConsoleRow]) {
        let text = attributed(rows)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let rtf = rtf(text) { pasteboard.setData(rtf, forType: .rtf) }
        pasteboard.setString(text.string, forType: .string)
    }
}
