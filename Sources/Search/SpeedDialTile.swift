import SwiftUI

/// Native preview button with standard keyboard focus and a context menu.
final class SpeedDialTile: NSButton, NSMenuItemValidation {
    private let browser: Browser
    private let dial: SpeedDial
    private var site: Bookmark
    /// The address without its "www.", worked out once per update rather than per draw.
    private var host = ""
    override var isFlipped: Bool { true }

    init(browser: Browser, dial: SpeedDial, site: Bookmark) {
        self.browser = browser
        self.dial = dial
        self.site = site
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .exterior
        target = self
        action = #selector(openSite)
        let menu = NSMenu()
        // The arrows are shown, and a focused tile hears them itself (see
        // keyDown). As AppKit's own arrow keys, the menu draws ← and →.
        let left = "\u{F702}", right = "\u{F703}"
        for (index, row) in [("Rename…", ""), ("Move Earlier", left), ("Move Later", right),
                             ("Move to Start", left), ("Move to End", right),
                             ("Refresh Preview from Open Page", ""), ("Remove from Speed Dial", "")].enumerated() {
            if index == 1 || index == 5 || index == 6 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: row.0, action: #selector(choose(_:)), keyEquivalent: row.1)
            item.keyEquivalentModifierMask = index > 2 ? [.shift, .option, .command] : [.option, .command]
            item.tag = index
            item.target = self
            menu.addItem(item)
        }
        self.menu = menu
        update(site)
    }
    required init?(coder: NSCoder) { nil }

    func update(_ site: Bookmark) {
        self.site = site
        host = site.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
        title = site.title
        toolTip = site.url
        image = dial.image(site)
        setAccessibilityLabel(site.title)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: 0, y: 0, width: bounds.width, height: 116)
        let shape = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        NSColor(Palette.wash).setFill()
        shape.fill()
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = max(box.width / image.size.width, box.height / image.size.height)
            let crop = NSRect(x: (image.size.width - box.width / scale) / 2,
                              y: (image.size.height - box.height / scale) / 2,
                              width: box.width / scale, height: box.height / scale)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            image.draw(in: box, from: crop, operation: .sourceOver,
                       fraction: isHighlighted ? 0.7 : 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            text((host.isEmpty ? site.title : host).prefix(1).uppercased(), at: NSRect(x: 0, y: 39, width: box.width, height: 38),
                 font: .systemFont(ofSize: 30, weight: .light), color: NSColor(Palette.muted), centered: true)
        }
        text(site.title, at: NSRect(x: 0, y: 124, width: bounds.width, height: 18),
             font: .systemFont(ofSize: 13, weight: .medium), color: .labelColor)
        text(host, at: NSRect(x: 0, y: 147, width: bounds.width, height: 13),
             font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    }
    private func text(_ value: String, at rect: NSRect, font: NSFont, color: NSColor, centered: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = centered ? .center : .left
        (value as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
    /// ⌥⌘← and ⌥⌘→ move the focused tile a place; with ⇧, to either end.
    /// (⌘← alone is Back, everywhere.)
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags
        let arrow: Int? = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : nil
        guard let arrow, modifiers.contains([.command, .option]) else { return super.keyDown(with: event) }
        dial.move(site.id, by: modifiers.contains(.shift) ? arrow * SpeedDial.limit : arrow)
        // The page redraws on the move; keep the keyboard on this tile.
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self) }
    }
    /// A tile takes the keys once it is clicked, whatever the Mac's Keyboard
    /// navigation setting says — the arrows that move it need somewhere to go.
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill() }

    @objc private func openSite() {
        if let url = site.url.flatMap(URL.init(string:)), SpeedDial.isWebsite(url) { browser.visit(url) }
    }
    private var source: Tab? {
        browser.tabs.first { SpeedDial.matches(site, $0.address) && SpeedDial.canCapture($0) }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.tag {
        case 1, 3: return dial.entries.first?.id != site.id
        case 2, 4: return dial.entries.last?.id != site.id
        case 5: return source != nil
        default: return true
        }
    }
    @objc private func choose(_ item: NSMenuItem) {
        switch item.tag {
        case 0: rename()
        case 1, 2, 3, 4: dial.move(site.id, by: [-1, 1, -SpeedDial.limit, SpeedDial.limit][item.tag - 1])
        case 5: if let tab = source { dial.capture(site, from: tab) }
        case 6: dial.remove(site.id)
        default: break
        }
    }
    private func rename() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Bookmark"
        alert.informativeText = "The bookmark name changes everywhere."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: site.title)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let id = site.id
        alert.beginSheetModal(for: window) { [weak self] answer in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if answer == .alertFirstButtonReturn, !name.isEmpty {
                self?.browser.bookmarks.update(id, title: name, url: nil)
            }
        }
    }
}
