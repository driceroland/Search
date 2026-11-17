import AppKit
import Combine
import SwiftUI

// Search's mark in the menu bar, by the clock, for as long as Search runs
// (Settings › Keyboard & Mouse › From any app). Off unless asked for. It
// says Search is still there with every window closed — ready for the
// launcher's key — and its menu raises the address field, opens a window or
// Settings, or quits.

@MainActor
final class MenuBarItem: NSObject, NSMenuDelegate {
    static let shared = MenuBarItem()

    /// A line of its menu, worked out apart from AppKit for the tests.
    enum Line: Equatable {
        /// The launcher's field, with its key as the menu shows keys.
        case field(KeyCombo)
        case newWindow
        case settings
        case separator
        case quit
    }

    private var item: NSStatusItem?
    private var bag = Set<AnyCancellable>()
    private var started = false

    /// Once, at launch: the mark follows its switch from then on.
    func start() {
        guard !started else { return }
        started = true
        // Published as it is about to change: read once it has.
        Shared.prefs.$menuBarIcon.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.follow() }
        }.store(in: &bag)
        follow()
    }

    /// There while the switch is on. Never on a run the bench drives, which
    /// puts nothing on screen.
    private func follow() {
        let wanted = Shared.prefs.menuBarIcon && !Launcher.benchDriven
        if wanted, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = Self.mark
            item.button?.setAccessibilityLabel("Search")
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
        } else if !wanted, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    /// The field's line only while the launcher is on and has a key: with
    /// none, there is nothing to raise.
    nonisolated static func lines(launcher: Bool, key: KeyCombo?) -> [Line] {
        let field: [Line] = launcher ? key.map { [.field($0), .separator] } ?? [] : []
        return field + [.newWindow, .settings, .separator, .quit]
    }

    /// Made as it opens, so the field's line has the key as it is now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = Shared.prefs
        for line in Self.lines(launcher: prefs.launcher, key: prefs.launcherKey?.combo) {
            switch line {
            case .field(let key):
                let item = add("Open Address Field", #selector(openField), to: menu)
                // Shown, not taken: the key itself is the launcher's.
                if let character = Self.equivalent(key) {
                    item.keyEquivalent = character
                    item.keyEquivalentModifierMask = Self.flags(key)
                }
            case .newWindow: add("New Window", #selector(newWindow), to: menu)
            case .settings: add("Settings…", #selector(settings), to: menu)
            case .separator: menu.addItem(.separator())
            case .quit: add("Quit Search", #selector(quit), to: menu)
            }
        }
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    /// The character a menu draws for a key: a letter or a digit as it is,
    /// Space as a space. Any other key goes without one.
    private static func equivalent(_ key: KeyCombo) -> String? {
        if key.key == "space" { return " " }
        return key.key.count == 1 ? key.key : nil
    }

    private static func flags(_ key: KeyCombo) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if key.command { flags.insert(.command) }
        if key.shift { flags.insert(.shift) }
        if key.option { flags.insert(.option) }
        if key.control { flags.insert(.control) }
        return flags
    }

    // The menu closes before its line's action: the field comes up over the
    // app in front once it has.
    @objc private func openField() { DispatchQueue.main.async { Launcher.shared.show() } }

    @objc private func newWindow() {
        Browsers.newWindow()
        Links.comeForward(lookedAt: true)
    }

    @objc private func settings() {
        let browser = Browsers.ensureWindow()
        browser.tuning = true
        Launcher.bringUp(browser)
        Links.comeForward(lookedAt: true)
    }

    /// As Search › Quit does, asking first when Settings says to — in front,
    /// so the question isn't behind another app.
    @objc private func quit() {
        Links.comeForward(lookedAt: true)
        if Links.shouldQuit() { NSApp.terminate(nil) }
    }

    /// The pill with the S through it, as the app's icon has it, drawn as a
    /// template so the menu bar colours it as it does its own. The mark is
    /// 2.2 times as wide as it is tall.
    private static let mark: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 10), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(Logomark().path(in: rect).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Search"
        return image
    }()
}
