import AppKit
import WebKit

/// The Mac's text substitutions inside pages, as in Safari: your Text
/// Replacements ("omw" → "On my way!"), smart quotes and smart dashes, in
/// Edit › Substitutions. Text replacement follows the Mac's own setting
/// (System Settings › Keyboard › Text Input). Smart quotes and dashes start
/// off, as they always have in Search: in a browser they are wrong in every
/// code field and wanted in few. The menu turns any of them on or off.
///
/// WebKit's text checker reads its switches once, from the app's standard
/// defaults, and keeps them for every page of the app at once. Its own
/// action for each, the one Safari's menu sends, flips it everywhere and
/// writes the choice back to those defaults, where it outranks what is
/// registered here from then on.
enum Substitution: String, CaseIterable {
    case quotes, dashes, replacement

    var title: String {
        switch self {
        case .quotes: return "Smart Quotes"
        case .dashes: return "Smart Dashes"
        case .replacement: return "Text Replacement"
        }
    }

    /// Where WebKit keeps it.
    var key: String {
        switch self {
        case .quotes: return "WebAutomaticQuoteSubstitutionEnabled"
        case .dashes: return "WebAutomaticDashSubstitutionEnabled"
        case .replacement: return "WebAutomaticTextReplacementEnabled"
        }
    }

    /// WebKit's own action for it, as Safari's menu sends it.
    var action: Selector {
        switch self {
        case .quotes: return NSSelectorFromString("toggleAutomaticQuoteSubstitution:")
        case .dashes: return NSSelectorFromString("toggleAutomaticDashSubstitution:")
        case .replacement: return NSSelectorFromString("toggleAutomaticTextReplacement:")
        }
    }

    /// What the Mac says, for every app that hasn't been told otherwise.
    var mac: Bool {
        switch self {
        case .quotes: return NSSpellChecker.isAutomaticQuoteSubstitutionEnabled
        case .dashes: return NSSpellChecker.isAutomaticDashSubstitutionEnabled
        case .replacement: return NSSpellChecker.isAutomaticTextReplacementEnabled
        }
    }

    /// Where each starts when nothing was chosen in the menu: text
    /// replacement as the Mac has it, smart quotes and dashes off.
    var start: Bool { self == .replacement ? mac : false }

    /// Before the first web view: where each starts, as what WebKit reads
    /// when nothing was chosen here. Registered, so kept in memory only and
    /// never written: a choice made in the menu stays the one that counts,
    /// and the Mac's setting is read afresh at each launch. Smart quotes and
    /// dashes used to be written off at every launch, which undid the menu;
    /// what was written then is off too, and is left as it is.
    static func register() {
        var start: [String: Any] = [:]
        for kind in allCases { start[kind.key] = kind.start }
        UserDefaults.standard.register(defaults: start)
    }

    /// Whether it's on in pages, asked of WebKit the way it is asked for a
    /// menu's tick. Without a web view yet, what WebKit will read.
    func isOn(in web: WKWebView?) -> Bool {
        guard let web, web.responds(to: action) else { return UserDefaults.standard.bool(forKey: key) }
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        _ = web.validateUserInterfaceItem(item)
        return item.state == .on
    }

    /// Flipped for every page, through WebKit's own action; without a web
    /// view yet, written where WebKit will read it.
    func toggle(in web: WKWebView?) {
        if let web, web.responds(to: action) {
            web.perform(action, with: nil)
        } else {
            UserDefaults.standard.set(!isOn(in: nil), forKey: key)
        }
    }

    /// The Mac's own panel of them, as Show Substitutions opens it in Safari.
    static func showPanel() {
        NSSpellChecker.shared.substitutionsPanel.orderFront(nil)
    }
}
