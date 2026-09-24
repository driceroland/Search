import AppKit
import Combine

// The Touch Bar, on a Mac that has one: back and forward, reload and home as
// in Chrome, the tabs of this row by their icons to slide along and tap, and
// a new tab. A Mac without one never asks the bar for its items, so none of
// them is made and nothing here watches anything.
//
// The bar is the window's, the far end of the responder chain, so anything
// nearer the focus with a bar of its own wins: a field on a page gets
// WebKit's suggestions, a playing video its timeline, the address field its
// own. That is how Safari steps aside while you type.

@MainActor
final class TouchBar: NSObject {
    private let browser: Browser

    /// Tabs and the active one, from the first time the bar is shown.
    private var watch: Set<AnyCancellable> = []
    /// The active tab's back, forward and loading.
    private var watchTab: Set<AnyCancellable> = []
    private var watched: Tab.ID?

    private weak var steps: NSSegmentedControl?
    private weak var reload: NSButtonTouchBarItem?
    private weak var scrubber: NSScrubber?

    /// One tab in the row: a key's width, the bar's full height.
    private static let tile = NSSize(width: 44, height: 30)
    private static let tileID = NSUserInterfaceItemIdentifier("tab")

    init(browser: Browser) {
        self.browser = browser
    }

    func make() -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self
        // View › Customize Touch Bar, which AppKit shows only on a Mac with one.
        bar.customizationIdentifier = "com.officecommun.search.touchbar"
        bar.defaultItemIdentifiers = [.steps, .reload, .home, .tabs, .newTab]
        bar.customizationAllowedItemIdentifiers = [.steps, .reload, .home, .tabs, .newTab, .flexibleSpace]
        return bar
    }

    // MARK: - following the browser

    private func start() {
        guard watch.isEmpty else { return }
        // Published values are sent before they are set: a turn of the run
        // loop later, the browser says what they became.
        browser.$tabs.combineLatest(browser.$activeID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.follow() }
            .store(in: &watch)
    }

    private func follow() {
        let tab = browser.active
        if tab?.id != watched {
            watched = tab?.id
            watchTab = []
            if let tab {
                tab.$canGoBack.combineLatest(tab.$canGoForward, tab.$loading, tab.$icon)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in self?.refresh() }
                    .store(in: &watchTab)
            }
        }
        scrubber?.reloadData()
        showActive()
        refresh()
    }

    private func refresh() {
        let tab = browser.active
        let page = tab.map { !$0.isBlank } ?? false
        steps?.setEnabled(tab?.canGoBack == true, forSegment: 0)
        steps?.setEnabled(tab?.canGoForward == true, forSegment: 1)
        reload?.isEnabled = page
        reload?.image = Self.image(tab?.loading == true ? NSImage.stopProgressTemplateName : NSImage.touchBarRefreshTemplateName)
        // An icon that arrived late.
        if let index = activeIndex {
            scrubber?.reloadItems(at: [index])
            showActive()
        }
    }

    private var activeIndex: Int? {
        browser.tabs.firstIndex { $0.id == browser.activeID }
    }

    private func showActive() {
        guard let scrubber else { return }
        scrubber.selectedIndex = activeIndex ?? -1
        if let index = activeIndex { scrubber.scrollItem(at: index, to: .none) }
    }

    // MARK: - drawing a tab

    private func tile(for tab: Tab) -> NSImage {
        let icon = tab.icon
        let letter = tab.monogram
        return NSImage(size: Self.tile, flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            // The Touch Bar is black whatever the Mac's appearance.
            NSColor(white: 0.24, alpha: 1).setFill()
            shape.fill()
            shape.addClip()
            if let icon {
                icon.draw(in: NSRect(x: rect.midX - 9, y: rect.midY - 9, width: 18, height: 18))
            } else {
                let text = NSAttributedString(string: letter, attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: NSColor.white,
                ])
                let size = text.size()
                text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            }
            return true
        }
    }

    private static func image(_ name: NSImage.Name) -> NSImage {
        NSImage(named: name) ?? NSImage()
    }

    /// For what AppKit has no Touch Bar picture of: home.
    private static func symbol(_ name: String, _ label: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
    }

    // MARK: - actions

    @objc private func step(_ control: NSSegmentedControl) {
        control.selectedSegment == 0 ? browser.back() : browser.forward()
    }

    @objc private func reloadOrStop() {
        guard let tab = browser.active, !tab.isBlank else { return }
        tab.loading ? tab.stop() : tab.reload()
    }

    @objc private func home() { browser.goHome() }
    @objc private func newTab() { browser.newTab() }
}

// MARK: - the bar's items

extension TouchBar: NSTouchBarDelegate {
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        defer { start() }
        switch identifier {
        case .steps:
            let control = NSSegmentedControl(
                images: [Self.image(NSImage.touchBarGoBackTemplateName), Self.image(NSImage.touchBarGoForwardTemplateName)],
                trackingMode: .momentary, target: self, action: #selector(step(_:))
            )
            steps = control
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = control
            item.customizationLabel = "Back/Forward"
            return item
        case .reload:
            let item = NSButtonTouchBarItem(identifier: identifier, image: Self.image(NSImage.touchBarRefreshTemplateName), target: self, action: #selector(reloadOrStop))
            item.customizationLabel = "Reload"
            reload = item
            return item
        case .home:
            let item = NSButtonTouchBarItem(identifier: identifier, image: Self.symbol("house", "Home"), target: self, action: #selector(home))
            item.customizationLabel = "Home"
            return item
        case .newTab:
            let item = NSButtonTouchBarItem(identifier: identifier, image: Self.image(NSImage.touchBarAddTemplateName), target: self, action: #selector(newTab))
            item.customizationLabel = "New Tab"
            return item
        case .tabs:
            // A set width: a scrubber has no size of its own, and left to
            // constraints it came out with no height, and the buttons after
            // it with no size at all.
            let scrubber = NSScrubber(frame: NSRect(x: 0, y: 0, width: 300, height: Self.tile.height))
            scrubber.register(NSScrubberImageItemView.self, forItemIdentifier: Self.tileID)
            scrubber.mode = .free
            scrubber.selectionOverlayStyle = .outlineOverlay
            scrubber.showsAdditionalContentIndicators = true
            let layout = NSScrubberFlowLayout()
            layout.itemSize = Self.tile
            layout.itemSpacing = 6
            scrubber.scrubberLayout = layout
            scrubber.dataSource = self
            scrubber.delegate = self
            self.scrubber = scrubber
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = scrubber
            item.customizationLabel = "Tabs"
            return item
        default:
            return nil
        }
    }
}

extension TouchBar: NSScrubberDataSource, NSScrubberDelegate {
    func numberOfItems(for scrubber: NSScrubber) -> Int { browser.tabs.count }

    func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView {
        let view = scrubber.makeItem(withIdentifier: Self.tileID, owner: nil) as? NSScrubberImageItemView ?? NSScrubberImageItemView()
        if browser.tabs.indices.contains(index) { view.image = tile(for: browser.tabs[index]) }
        return view
    }

    func scrubber(_ scrubber: NSScrubber, didSelectItemAt index: Int) {
        guard browser.tabs.indices.contains(index) else { return }
        browser.select(browser.tabs[index])
    }
}

extension NSTouchBarItem.Identifier {
    fileprivate static let steps = Self("com.officecommun.search.steps")
    fileprivate static let reload = Self("com.officecommun.search.reload")
    fileprivate static let home = Self("com.officecommun.search.home")
    fileprivate static let tabs = Self("com.officecommun.search.tabs")
    fileprivate static let newTab = Self("com.officecommun.search.newtab")
}
