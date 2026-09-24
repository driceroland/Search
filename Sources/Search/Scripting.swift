import AppKit

@MainActor
@objc(ScriptTab)
final class ScriptTab: NSObject {
    private let tab: Tab
    private let index: Int
    private weak var window: NSWindow?

    init(_ tab: Tab, index: Int, in window: NSWindow) {
        self.tab = tab
        self.index = index
        self.window = window
    }

    @objc var url: String { tab.address?.absoluteString ?? "" }
    @objc var name: String { tab.title }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let window, let container = window.objectSpecifier,
              let description = container.keyClassDescription
        else { return nil }
        return NSIndexSpecifier(
            containerClassDescription: description,
            containerSpecifier: container, key: "scriptTabs", index: index
        )
    }
}

extension NSWindow {
    @objc var scriptTabs: [ScriptTab] {
        guard self === Links.window, let browser = Links.browser else { return [] }
        return browser.tabs.enumerated().map { ScriptTab($0.element, index: $0.offset, in: self) }
    }

    @objc var scriptCurrentTab: ScriptTab? {
        guard self === Links.window, let browser = Links.browser, let active = browser.active,
              let index = browser.tabs.firstIndex(where: { $0 === active })
        else { return nil }
        return ScriptTab(active, index: index, in: self)
    }
}
