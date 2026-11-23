import AppKit

/// How the Network toolbar and filter bar fit the dock's width. The rows
/// keep a fixed height: what does not fit folds into a menu, so dragging
/// the divider never reflows the panel onto more lines.
enum DeveloperNetworkToolbar {
    /// Toolbar groups after the always-shown record, clear, search and
    /// reload (and the settings gear at the far right), in the order they
    /// fold into » from the right, as Chrome's toolbar overflows.
    enum Item: CaseIterable {
        case keepLog, disableCache, conditions, files

        /// What a group takes, its label measured as drawn.
        func width(conditionLabel: String) -> CGFloat {
            let spacing = DeveloperToolsStyle.controlSpacing
            func text(_ string: String, size: CGFloat) -> CGFloat {
                ceil((string as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width)
            }
            switch self {
            case .keepLog: return text("Keep log", size: NSFont.smallSystemFontSize) + 24 + spacing
            case .disableCache: return text("Disable cache", size: NSFont.smallSystemFontSize) + 24 + spacing
            case .conditions: return text(conditionLabel, size: NSFont.systemFontSize) + 28 + spacing
            case .files: return DeveloperToolsStyle.controlHeight * 3 + spacing * 4 + 5
            }
        }
    }

    /// The groups that fit in a toolbar this wide; the rest go to ».
    static func shown(width: CGFloat, conditionLabel: String) -> [Item] {
        let spacing = DeveloperToolsStyle.controlSpacing
        // Record, clear, search, reload and the settings gear, with the rule.
        let fixed = DeveloperToolsStyle.gutter * 2 + DeveloperToolsStyle.controlHeight * 5 + spacing * 5 + 5
        let overflow = DeveloperToolsStyle.controlHeight + spacing
        let all = Item.allCases
        if all.reduce(fixed, { $0 + $1.width(conditionLabel: conditionLabel) }) <= width { return all }
        var shown: [Item] = []
        var used = fixed + overflow
        for item in all {
            let next = item.width(conditionLabel: conditionLabel)
            guard used + next <= width else { break }
            shown.append(item)
            used += next
        }
        return shown
    }

    /// Below this the Invert checkbox moves into More filters.
    static let compactFilterWidth: CGFloat = 420

    /// Wide enough for the filter box and the type chips on one line, as
    /// Chrome lays them out; narrower, the chips get a line of their own
    /// that scrolls sideways rather than wrapping.
    static func chipsShareFilterRow(width: CGFloat) -> Bool { width >= 1_000 }
}
