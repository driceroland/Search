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
// The inspector's page is WebKit's. With Chrome's colors on, a stylesheet on
// that page retints it: a flat tab strip, the open tab underlined. The
// panels, the icons and the tools stay Web Inspector's. Light or dark follows
// the page, and Keep the Web Inspector dark holds the page dark. Both are
// off unless asked for. The names are asked for first, the same as the rest
// of this file, and a WebKit that does not answer keeps the inspector as it
// came.

extension Browser {
    /// ⌥⌘I: the inspector, or put away if it is up.
    func toggleInspector() {
        if prefs.devTools {
            if let tab = active, DeveloperTools.isOpen(for: tab) {
                DeveloperTools.shared.close()
                return
            }
            if showDeveloperPanel(.elements) { return }
        }
        withNativeInspector { inspector in
            if self.asks(inspector, "isVisible") {
                self.send(inspector, "close")
            } else {
                self.send(inspector, "show")
                self.watch(inspector, tries: 12)
            }
        }
    }

    /// ⌥⌘J: the inspector, at its console.
    func showConsole() {
        if prefs.devTools {
            if let tab = active, let session = DeveloperTools.shared.session,
               session.tab === tab, session.panel == .console {
                DeveloperTools.shared.close()
                return
            }
            if showDeveloperPanel(.console) { return }
        }
        withNativeInspector { inspector in
            self.send(inspector, "showConsole")
            self.watch(inspector, tries: 12)
        }
    }

    /// ⌥⌘C: the inspector, and the next click on the page picks what it
    /// shows. Again, and the picking stops.
    func inspectElement() {
        if prefs.devTools && showDeveloperPanel(.elements) {
            DeveloperTools.shared.session?.togglePicker()
            return
        }
        withNativeInspector { inspector in
            if !self.asks(inspector, "isVisible") { self.send(inspector, "show") }
            self.send(inspector, "toggleElementSelection")
            self.watch(inspector, tries: 12)
        }
    }

    func developerPanelTarget(for tab: Tab) -> WKWebView? {
        // Console history and Recorder captures can outlive their session.
        guard prefs.devTools, !isPopup, tab.isWeb, !tab.shy, !tab.floating, !tab.immersed,
              let target = tab.built else { return nil }
        // Extension-owned pages share a script controller. Use Web Inspector there.
        if #available(macOS 15.4, *), let pages = Extensions.pages,
           target.configuration.userContentController === pages { return nil }
        return target
    }

    @discardableResult
    func showDeveloperPanel(_ panel: DeveloperPanel, web: WKWebView? = nil, point: NSPoint? = nil) -> Bool {
        guard let tab = active, let target = developerPanelTarget(for: tab),
              web == nil || web === target else { return false }
        return DeveloperTools.shared.open(in: self, panel: panel, web: target, point: point)
    }

    /// The page's own Inspect Element. WebKit opens the inspector itself;
    /// this only puts the coat on, the same as the View menu. The inspector
    /// can arrive a moment after the menu item runs.
    func dressInspector(of web: WKWebView, tries: Int = 12) {
        guard Shared.prefs.inspectorChrome || Shared.prefs.inspectorDark || Self.touched else { return }
        if let inspector = inspector(of: web) {
            watch(inspector, tries: tries)
            return
        }
        guard tries > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak web] in
            guard let self, let web else { return }
            self.dressInspector(of: web, tries: tries - 1)
        }
    }

    /// The inspector of the tab in front — none for a blank tab, which has
    /// no page to look at.
    private func withNativeInspector(_ action: @escaping (NSObject) -> Void) {
        guard let tab = active, tab.isWeb else { return }
        let enabled = prefs.devTools
        NativeInspectorHandoff.whenReady {
            guard self.active === tab, self.prefs.devTools == enabled,
                  let inspector = self.inspector(of: tab.web) else { return }
            action(inspector)
        }
    }

    private func inspector(of web: WKWebView) -> NSObject? {
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

    /// A change of either switch, on every inspector already open. A tab
    /// with no page yet is left alone: asking for its page would build it.
    static func coatOpenInspectors() {
        for browser in Browsers.all { browser.coatInspectors() }
    }

    private func coatInspectors() {
        for tab in tabs {
            guard let web = tab.built, let inspector = inspector(of: web) else { continue }
            if inspectorPage(inspector) != nil || asks(inspector, "isVisible") {
                watch(inspector, tries: 12)
            }
        }
    }

    /// Dark when asked. Otherwise the page follows its window.
    private static var inspectorAppearance: NSAppearance? {
        Shared.prefs.inspectorDark ? NSAppearance(named: .darkAqua) : nil
    }

    /// The inspector's own page, once WebKit has made it. Nil until then.
    private func inspectorPage(_ inspector: NSObject) -> WKWebView? {
        let get = NSSelectorFromString("inspectorWebView")
        guard inspector.responds(to: get) else { return nil }
        return inspector.perform(get)?.takeUnretainedValue() as? WKWebView
    }

    /// Whether a coat was put on this launch. Until then an open does
    /// nothing; after, an open with both switches off takes the coat off a
    /// page WebKit kept.
    private static var touched = false

    /// The page arrives after show, so this asks a few times. With both
    /// switches off, and nothing put on yet, it does not ask at all.
    private func watch(_ inspector: NSObject, tries: Int) {
        let on = Shared.prefs.inspectorChrome || Shared.prefs.inspectorDark
        guard on || Self.touched else { return }
        if on { Self.touched = true }
        if let page = inspectorPage(inspector) {
            apply(page, inspector: inspector, tries: tries)
            return
        }
        later(inspector, tries: tries)
    }

    private func later(_ inspector: NSObject, tries: Int) {
        guard tries > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak inspector] in
            guard let self, let inspector else { return }
            self.watch(inspector, tries: tries - 1)
        }
    }

    private func apply(_ page: WKWebView, inspector: NSObject, tries: Int) {
        page.appearance = Self.inspectorAppearance
        let script = Shared.prefs.inspectorChrome ? Self.paintScript : Self.clearScript
        page.evaluateJavaScript(script) { [weak self, weak inspector] result, _ in
            guard let self, let inspector, (result as? String) != "ok" else { return }
            self.later(inspector, tries: tries)
        }
    }

    /// Takes the stylesheet off. Waits until the page is there, so a page
    /// still loading is not told it is done.
    private static let clearScript = """
    (function(){
      if (!document.documentElement) return "wait";
      var node = document.getElementById("search-inspector-skin");
      if (node) node.remove();
      return "ok";
    })()
    """

    /// One stylesheet, light or dark with the page. Appended once and
    /// replaced in place: the page's own rules follow the variables.
    private static let paintScript: String = {
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
