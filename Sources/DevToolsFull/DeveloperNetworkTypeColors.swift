import SwiftUI

/// Chrome's Settings › Preferences › Network › "Color-code resource types",
/// on by default: the download part of each waterfall bar takes its
/// resource type's colour, as Chrome draws it, instead of the phase colour.
enum DeveloperNetworkTypeColors {
    static let key = "developerTools.network.colorCodeResourceTypes"

    /// A colour as hue (degrees), saturation and lightness (0 to 1), the
    /// way Chrome's stylesheet writes its resource-type colours.
    struct HSL: Hashable {
        let hue: Double
        let saturation: Double
        let lightness: Double

        /// The same colour as red, green and blue, each 0 to 1.
        var rgb: (red: Double, green: Double, blue: Double) {
            let chroma = (1 - abs(2 * lightness - 1)) * saturation
            let sector = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
            let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
            let parts: [Double]
            switch Int(sector) {
            case 0: parts = [chroma, second, 0]
            case 1: parts = [second, chroma, 0]
            case 2: parts = [0, chroma, second]
            case 3: parts = [0, second, chroma]
            case 4: parts = [second, 0, chroma]
            default: parts = [chroma, 0, second]
            }
            let match = lightness - chroma / 2
            return (parts[0] + match, parts[1] + match, parts[2] + match)
        }
    }

    /// Chrome's colour for a kind of request: documents blue, stylesheets
    /// purple, scripts orange, fetch and XHR yellow, images and media
    /// green, fonts coral, Wasm teal, and everything else grey. Chrome's
    /// "other" is nearly white; it is a mid grey here so it shows on a
    /// white list.
    static func hsl(for kind: DeveloperRequestKind) -> HSL {
        switch kind {
        case .document: HSL(hue: 215, saturation: 1, lightness: 0.8)
        case .stylesheet: HSL(hue: 272, saturation: 0.64, lightness: 0.8)
        case .script: HSL(hue: 31, saturation: 1, lightness: 0.8)
        case .fetch: HSL(hue: 53, saturation: 1, lightness: 0.8)
        case .image, .media: HSL(hue: 90, saturation: 0.5, lightness: 0.8)
        case .font: HSL(hue: 8, saturation: 1, lightness: 0.8)
        case .wasm: HSL(hue: 175, saturation: 0.5, lightness: 0.7)
        case .manifest, .socket, .other: HSL(hue: 0, saturation: 0, lightness: 0.7)
        }
    }

    static func color(for kind: DeveloperRequestKind) -> Color {
        let rgb = hsl(for: kind).rgb
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
