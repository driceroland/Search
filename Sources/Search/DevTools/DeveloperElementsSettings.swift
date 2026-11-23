import Foundation

/// Settings › Preferences › Elements, as Chrome DevTools has them. The
/// Settings view binds the keys with @AppStorage; the session and the tree
/// read them here.
enum DeveloperElementsSettings {
    static let userAgentShadowDOMKey = "developerTools.elements.showUserAgentShadowDOM"
    static let commentsKey = "developerTools.elements.showComments"
    static let rulersKey = "developerTools.elements.showRulersOnHover"
    static let detailedTooltipKey = "developerTools.elements.detailedInspectTooltip"
    /// Elements' "Word wrap" (the tree's long lines), kept by DeveloperElementsView.
    static let wordWrapKey = "developerTools.elements.wrapLines"

    private static func flag(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    /// The browser's own shadow roots (an <input type=range>'s track and
    /// thumb), off by default as in Chrome.
    static var showUserAgentShadowDOM: Bool { flag(userAgentShadowDOMKey, default: false) }
    static var showHTMLComments: Bool { flag(commentsKey, default: true) }
    static var showRulersOnHover: Bool { flag(rulersKey, default: true) }
    /// The tag, size and colour label beside a highlighted element.
    static var detailedInspectTooltip: Bool { flag(detailedTooltipKey, default: true) }
}
