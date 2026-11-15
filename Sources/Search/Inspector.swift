import AppKit
import WebKit

// The Web Inspector: WebKit's own, on the tab in front — from the View menu
// and its keys, as from Inspect Element in a page's right-click menu. The
// keys are Chrome's and Arc's: ⌥⌘I for the inspector, ⌥⌘J for the console,
// ⌥⌘C to pick an element on the page.
//
// WebKit answers for its inspector only through names outside the public
// framework, so each is asked for before it is used; a WebKit without them
// leaves the menu doing nothing rather than the app falling over.
//
// The inspector's page is WebKit's. Once it is up, a stylesheet on that page
// retints it: Chrome's colors, a flat tab strip, the open tab underlined.
// The panels, the icons and the tools stay Web Inspector's. Light or dark
// follows the page, and Settings can keep that page dark. The names are
// asked for first, the same as the rest of this file, and a WebKit that
// does not answer keeps the inspector as it came.

extension Browser {
    /// ⌥⌘I: the inspector, or put away if it is up.
    func toggleInspector() {
        guard let inspector = inspector() else { return }
        if asks(inspector, "isVisible") {
            send(inspector, "close")
        } else {
            send(inspector, "show")
            dress(inspector)
        }
    }

    /// ⌥⌘J: the inspector, at its console.
    func showConsole() {
        guard let inspector = inspector() else { return }
        send(inspector, "showConsole")
        dress(inspector)
    }

    /// ⌥⌘C: the inspector, and the next click on the page picks what it
    /// shows. Again, and the picking stops.
    func inspectElement() {
        guard let inspector = inspector() else { return }
        if !asks(inspector, "isVisible") { send(inspector, "show") }
        send(inspector, "toggleElementSelection")
        dress(inspector)
    }

    /// The inspector of the tab in front — none for a blank tab, which has
    /// no page to look at.
    private func inspector() -> NSObject? {
        guard let tab = active, tab.isWeb else { return nil }
        let web = tab.web
        let get = NSSelectorFromString("_inspector")
        guard web.responds(to: get) else { return nil }
        return web.perform(get)?.takeUnretainedValue() as? NSObject
    }

    private func send(_ inspector: NSObject, _ name: String) {
        let selector = NSSelectorFromString(name)
        guard inspector.responds(to: selector) else { return }
        inspector.perform(selector)
    }

    private func asks(_ inspector: NSObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard inspector.responds(to: selector) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(inspector.method(for: selector), to: Getter.self)(inspector, selector)
    }

    /// Dark when Settings asks the inspector to stay dark. Otherwise the
    /// page follows its window, so a change of the switch reaches one that
    /// is already open.
    static func coatOpenInspectors() {
        for browser in Browsers.all { browser.coatInspector() }
    }

    private func coatInspector() {
        guard let inspector = inspector(), let page = inspectorPage(inspector) else { return }
        page.appearance = Self.inspectorAppearance
    }

    private static var inspectorAppearance: NSAppearance? {
        Shared.prefs.inspectorDark ? NSAppearance(named: .darkAqua) : nil
    }

    /// The inspector's own page, once WebKit has made it. Nil until then.
    private func inspectorPage(_ inspector: NSObject) -> WKWebView? {
        let get = NSSelectorFromString("inspectorWebView")
        guard inspector.responds(to: get) else { return nil }
        return inspector.perform(get)?.takeUnretainedValue() as? WKWebView
    }

    /// Put the skin on the inspector's page. The page arrives after show,
    /// so this asks a few times, and stops once the page has taken it.
    /// Closing and opening again meets a new page and asks again.
    private func dress(_ inspector: NSObject) {
        paint(inspector, tries: 12)
    }

    private func paint(_ inspector: NSObject, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak inspector] in
            guard let self, let inspector else { return }
            guard let page = self.inspectorPage(inspector) else {
                if tries > 1 { self.paint(inspector, tries: tries - 1) }
                return
            }
            page.appearance = Self.inspectorAppearance
            page.evaluateJavaScript(Self.skinScript) { result, _ in
                if (result as? String) != "ok", tries > 1 {
                    self.paint(inspector, tries: tries - 1)
                }
            }
        }
    }

    /// One stylesheet, light or dark with the Mac. Appended to the
    /// inspector's page, and left there: the page's own rules follow the
    /// variables, and these replace the ones a coat of paint can.
    private static let skinScript: String = {
        let css = skin
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")
        return """
        (function(){
          if (!document.documentElement) return "wait";
          var node = document.getElementById("search-inspector-skin");
          if (!node) {
            node = document.createElement("style");
            node.id = "search-inspector-skin";
            document.documentElement.appendChild(node);
          }
          node.textContent = `\(css)`;
          return "ok";
        })()
        """
    }()

    private static let skin = """
    :root {
      --search-accent: #0b57d0;
      --search-on-accent: #fff;
      --search-tab: #f1f3f4;
      --search-line: #dadce0;
      --search-muted: #5f6368;
      --search-title: #202124;
      --search-hover: rgba(32, 33, 36, 0.06);
      --search-page: #fff;
      --search-panel: #f8f9fa;
      --search-input: #fff;
    }
    @media (prefers-color-scheme: dark) {
      :root, body {
        --search-accent: #a8c7fa;
        --search-on-accent: #062e6f;
        --search-tab: #262626;
        --search-line: #444746;
        --search-muted: #9aa0a6;
        --search-title: #e8eaed;
        --search-hover: rgba(255, 255, 255, 0.06);
        --search-page: #1f1f1f;
        --search-panel: #262626;
        --search-input: #1f1f1f;
        --foreground-lightness: 100% !important;
        --text-color: #e3e3e3 !important;
        --text-color-active: #fff !important;
        --text-color-secondary: #c4c7c5 !important;
        --text-color-tertiary: #8e918f !important;
        --text-color-quaternary: #5e615f !important;
        --separator-color: #444746 !important;
        --background-color: #1f1f1f !important;
        --background-color-content: #1f1f1f !important;
        --background-color-secondary: #262626 !important;
        --background-color-tertiary: #313131 !important;
        --background-color-intermediate: #262626 !important;
        --background-color-selected: #004a77 !important;
        --panel-background-color: #262626 !important;
        --panel-background-color-light: #2a2a2a !important;
        --link-text-color: #a8c7fa !important;
        --selected-foreground-color: #c2e7ff !important;
        --selected-background-color: #004a77 !important;
        --selected-background-color-unfocused: #004a77 !important;
        --selected-background-color-active: #005a92 !important;
        --selected-background-color-hover: rgba(168, 199, 250, 0.24) !important;
        --glyph-color: #c4c7c5 !important;
        --glyph-color-active: #a8c7fa !important;
        --glyph-color-disabled: rgba(196, 199, 197, 0.38) !important;
        --border-color: #444746 !important;
        --border-color-secondary: #333 !important;
        --button-background-color: #313131 !important;
        --button-background-color-hover: #3c4043 !important;
        --button-background-color-pressed: #444746 !important;
        --syntax-highlight-number-color: #b5cea8 !important;
        --syntax-highlight-bigint-color: #b5cea8 !important;
        --syntax-highlight-boolean-color: #9cdcfe !important;
        --syntax-highlight-string-color: #ce9178 !important;
        --syntax-highlight-link-color: #a8c7fa !important;
        --syntax-highlight-regexp-color: #d16969 !important;
        --syntax-highlight-symbol-color: #4ec9b0 !important;
        --syntax-highlight-comment-color: #6a9955 !important;
        --console-secondary-text-color: #9aa0a6 !important;
        --error-text-color: #f2b8b5 !important;
        --popover-background-color: #262626 !important;
        --popover-border-color: #444746 !important;
        --overlay-background: #262626 !important;
      }
    }
    @media (prefers-color-scheme: light) {
      :root, body {
        --text-color: #202124 !important;
        --text-color-active: #202124 !important;
        --text-color-secondary: #5f6368 !important;
        --text-color-tertiary: #80868b !important;
        --text-color-quaternary: #bdc1c6 !important;
        --separator-color: #dadce0 !important;
        --background-color: #fff !important;
        --background-color-content: #fff !important;
        --background-color-secondary: #f8f9fa !important;
        --background-color-tertiary: #f1f3f4 !important;
        --background-color-intermediate: #f8f9fa !important;
        --background-color-selected: #d3e3fd !important;
        --panel-background-color: #f8f9fa !important;
        --panel-background-color-light: #fff !important;
        --link-text-color: #0b57d0 !important;
        --selected-foreground-color: #041e49 !important;
        --selected-background-color: #d3e3fd !important;
        --selected-background-color-unfocused: #d3e3fd !important;
        --selected-background-color-active: #a8c7fa !important;
        --selected-background-color-hover: rgba(11, 87, 208, 0.12) !important;
        --glyph-color: #444746 !important;
        --glyph-color-active: #0b57d0 !important;
        --border-color: #dadce0 !important;
        --border-color-secondary: #e8eaed !important;
        --button-background-color: #fff !important;
        --button-background-color-hover: #f1f3f4 !important;
        --button-background-color-pressed: #e8eaed !important;
        --syntax-highlight-number-color: #098658 !important;
        --syntax-highlight-bigint-color: #098658 !important;
        --syntax-highlight-boolean-color: #0451a5 !important;
        --syntax-highlight-string-color: #a31515 !important;
        --syntax-highlight-link-color: #0b57d0 !important;
        --syntax-highlight-regexp-color: #811f3f !important;
        --syntax-highlight-symbol-color: #0070c1 !important;
        --syntax-highlight-comment-color: #008000 !important;
        --console-secondary-text-color: #5f6368 !important;
        --popover-background-color: #fff !important;
        --popover-border-color: #dadce0 !important;
      }
    }

    html, body, #main, #content, #tab-browser {
      background-color: var(--search-page) !important;
      color: var(--search-title) !important;
    }
    body { font-size: 12px !important; }
    .cm-s-default, .syntax-highlighted, .spreadsheet-css-declaration { font-size: 11px !important; }

    body.mac-platform .tab-bar, .tab-bar {
      --tab-bar-background: var(--search-tab);
      --tab-item-background: transparent;
      --tab-item-medium-border-color: transparent;
      --tab-item-light-border-color: transparent;
      --tab-item-dark-border-color: transparent;
      --tab-item-border-color: transparent;
      --tab-item-medium-border-style: none;
      background: var(--search-tab) !important;
      border-bottom: 1px solid var(--search-line) !important;
      height: 28px !important;
    }
    .tab-bar > .border { display: none !important; }
    .tab-bar > .tabs {
      flex-wrap: nowrap !important;
      justify-content: flex-start !important;
      align-items: stretch !important;
    }
    .tab-bar > .tabs > .item {
      flex: 0 0 auto !important;
      border: none !important;
      background: transparent !important;
      color: var(--search-muted) !important;
      font-size: 12px !important;
      font-weight: 500 !important;
      padding: 0 12px !important;
      box-shadow: none !important;
    }
    body.mac-platform .tab-bar > .tabs > .item:not(.disabled).selected,
    .tab-bar > .tabs > .item.selected {
      --tab-item-background: transparent;
      background: transparent !important;
      color: var(--search-title) !important;
      box-shadow: inset 0 -2px 0 var(--search-accent) !important;
    }
    .tab-bar > .tabs > .item:not(.selected):hover {
      --tab-item-background: transparent;
      background: var(--search-hover) !important;
      color: var(--search-title) !important;
    }

    .sidebar { background-color: var(--search-panel) !important; }
    .navigation-bar, .quick-console, #console-prompt, .console-drawer > .navigation-bar {
      background-color: var(--search-tab) !important;
      border-color: var(--search-line) !important;
    }
    .spreadsheet-css-declaration {
      background: var(--search-page) !important;
      border-bottom-color: var(--search-line) !important;
    }
    .details-section > .header {
      font-size: 11px !important;
      font-weight: 600 !important;
      color: var(--search-muted) !important;
    }
    .tree-outline.dom li.selected .selection-area {
      background-color: var(--selected-background-color) !important;
    }
    .tree-outline.dom li.selected, .tree-outline.dom li.selected * {
      color: var(--selected-foreground-color) !important;
    }
    .navigation-bar .item.radio.button.text-only.selected,
    .options-container > .toggle.selected {
      color: var(--search-on-accent) !important;
    }
    .navigation-bar .item.radio.button.text-only.selected::before,
    .options-container > .toggle.selected::before {
      background-color: var(--search-accent) !important;
      opacity: 1 !important;
    }
    input, input[type="search"], textarea {
      background-color: var(--search-input) !important;
      color: var(--search-title) !important;
      border-color: var(--search-line) !important;
    }
    """
}
