import AppKit
import SwiftUI

private func shortcutTitle(_ command: Command) -> String {
    if command.section == .spaces, let number = Int(command.id.dropFirst("spaces.".count)) {
        return Interface.format("Space %@", String(number))
    }
    return Interface.text(command.title)
}

/// Settings › Keyboard & Mouse › Shortcuts: every menu command with its key, a card to a menu,
/// narrowed by name or key. Click a key and press the new one; right-click
/// to clear it or put the default back.
struct ShortcutsPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var store: ShortcutStore
    @ObservedObject var prefs: Preferences

    @State private var hunt = ""
    @FocusState private var hunting: Bool

    /// By name, or by key as the menus write it: "tab" and "⌘T" both find New Tab.
    private func shown(_ command: Command) -> Bool {
        if command.section == .spaces, !prefs.usesSpaces { return false }
        if Command.ai.contains(command.id), !browser.prefs.ai { return false }
        if Command.dusk.contains(command.id), !browser.prefs.darkensPages { return false }
        if Command.archive.contains(command.id), prefs.tabLife == .never { return false }
        if Command.capture.contains(command.id), !prefs.capturesPages { return false }
        if Command.styles.contains(command.id), !prefs.sitesStyles { return false }
        let words = hunt.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return true }
        let key = store.key(for: command.id)?.display ?? ""
        return command.title.localizedCaseInsensitiveContains(words) || shortcutTitle(command).localizedCaseInsensitiveContains(words)
            || key.localizedCaseInsensitiveContains(words.replacingOccurrences(of: " ", with: ""))
    }

    /// The keys that pick a tab by its place: not a menu command, and not
    /// yours to move one by one, but listed so they can be found, with the
    /// switch that hands ⌘1–⌘9 to the spaces.
    private var numbersShown: Bool {
        let words = hunt.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return true }
        let key = words.replacingOccurrences(of: " ", with: "")
        return ["Tab 1 to 9", "numbers"].contains { $0.localizedCaseInsensitiveContains(words) || Interface.text($0).localizedCaseInsensitiveContains(words) }
            || KeyCombo.tabNumbers.localizedCaseInsensitiveContains(key)
            || (1...9).contains { KeyCombo.tabNumber($0).display.localizedCaseInsensitiveContains(key) }
    }

    private var numbersNote: String {
        if prefs.usesSpaces && prefs.spacesOnCommand {
            return Interface.text("The ninth is the last. ⌘1–⌘9 switch spaces: Settings › Spaces & Pins")
        }
        return prefs.usesSpaces
            ? Interface.text("The ninth is the last. To switch spaces with them instead: Settings › Spaces & Pins")
            : Interface.text("The ninth is the last. With spaces on, they can switch spaces instead")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Hunt(text: $hunt, prompt: Interface.text("Search commands or keys"), focus: $hunting)
            let found = Command.all.filter(shown)
            let numbers = numbersShown
            if found.isEmpty, !numbers { Nothing(Interface.text("No command called that, or on that key")) }
            ForEach(Command.Section.allCases, id: \.self) { section in
                let commands = found.filter { $0.section == section }
                let numbered = section == .tabs && numbers
                if !commands.isEmpty || numbered {
                VStack(alignment: .leading, spacing: 6) {
                    Caption(section == .app ? section.rawValue : Interface.text(section.rawValue))
                    Card {
                        ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                            if index > 0 { Rule() }
                            Line(shortcutTitle(command)) {
                                KeyBox(browser: browser, store: store, id: command.id)
                            }
                            .contextMenu {
                                Button(Interface.text("Clear Shortcut")) { store.clear(command.id) }
                                    .disabled(store.key(for: command.id) == nil)
                                Button(Interface.text("Reset to Default")) { store.reset(command.id) }
                                    .disabled(!store.isChanged(command.id))
                            }
                        }
                        if numbered {
                            if !commands.isEmpty { Rule() }
                            Line(Interface.text("Tab 1 to 9"), numbersNote) {
                                FixedKey(text: KeyCombo.tabNumbers)
                            }
                        }
                    }
                }
                }
            }
            if #available(macOS 15.4, *) { extensionCommands }
            if store.anyChanged || prefs.peekClick != .shift, hunt.isEmpty {
                Pill(Interface.text("Reset All to Defaults")) {
                    store.resetAll()
                    prefs.peekClick = .shift
                }
            }
        }
    }
}

extension ShortcutsPage {
    /// The commands extensions bring, with the keys their manifests ask for
    /// unless you gave them others (#189).
    @available(macOS 15.4, *)
    @ViewBuilder private var extensionCommands: some View {
        let words = hunt.trimmingCharacters(in: .whitespaces)
        let commands = store.extensionCommands().filter { item in
            words.isEmpty || item.command.title.localizedCaseInsensitiveContains(words)
                || item.extensionName.localizedCaseInsensitiveContains(words)
                || (store.key(for: item.id)?.display ?? "").localizedCaseInsensitiveContains(words.replacingOccurrences(of: " ", with: ""))
        }
        if !commands.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Caption(Interface.text("Extensions"))
                Card {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Rule() }
                        Line(item.command.title, item.extensionName) {
                            KeyBox(browser: browser, store: store, id: item.id)
                        }
                        .contextMenu {
                            Button(Interface.text("Clear Shortcut")) { store.clear(item.id) }
                                .disabled(store.key(for: item.id) == nil)
                            Button(Interface.text("Reset to Default")) { store.reset(item.id) }
                                .disabled(!store.isChanged(item.id))
                        }
                    }
                }
            }
        }
    }
}

/// Keys that are listed but not moved here, drawn as a KeyBox at rest.
private struct FixedKey: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Palette.muted)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minWidth: 64, minHeight: 24)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
            .help(Interface.text("Set in Settings › Spaces & Pins"))
    }
}

/// The key a command is on. Click it and press another: that key moves
/// here, from whichever command had it. Esc stops without changing it,
/// ⌫ takes it off.
private struct KeyBox: View {
    let browser: Browser
    @ObservedObject var store: ShortcutStore
    /// A menu command's id, or an extension command's ("ext:…").
    let id: String

    @State private var listening = false
    @State private var monitor: Any?
    @State private var note: String?
    @State private var hovering = false
    /// A key another command has, pressed once: pressed again, it moves here.
    @State private var taking: KeyCombo?

    var body: some View {
        Button(action: listen) {
            Text(label)
                .font(.system(size: 12, weight: store.isChanged(id) ? .semibold : .regular))
                .foregroundStyle(listening || store.key(for: id) != nil ? Palette.ink : Palette.muted)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minWidth: 64, minHeight: 24)
                .background(listening ? Palette.hover : (hovering ? Palette.hover : Palette.ground),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(listening ? Palette.ink.opacity(0.4) : Palette.hairline, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // What the Shortcuts group's line under its title used to say.
        .help(Interface.text("Click, then press the new shortcut"))
        .onHover { hovering = $0 }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if let taking, let other = store.owner(of: taking, except: id) {
            return Interface.format("Used by %@ — press again", Command.named(other.id).map(shortcutTitle) ?? other.title)
        }
        if let note { return note }
        if listening { return Interface.text("Type a shortcut") }
        return store.key(for: id)?.display ?? Interface.text("None")
    }

    private func listen() {
        guard !listening else { return stop() }
        listening = true
        note = nil
        taking = nil
        store.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            take(event)
            return nil
        }
    }

    private func take(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53, flags.isEmpty { return stop() }
        if [51, 117].contains(event.keyCode), flags.isEmpty {
            store.clear(id)
            return stop()
        }
        guard let combo = KeyCombo(event: event) else { return }
        guard combo.isUsable else { return say(Interface.text("Add ⌘, ⌥ or ⌃")) }
        // ⌘1–⌘9 (or ⌃1–⌃9) pick tabs: the whole set moves, with its switch.
        guard !combo.isTabNumber else {
            return say(browser.prefs.usesSpaces ? Interface.text("Picks a tab — see Spaces & Pins") : Interface.text("Picks a tab"))
        }
        guard !KeyCombo.isReserved(combo) else { return say(Interface.text("Can’t be changed")) }
        // The switcher stays up while its key's ⌃, ⌥ or ⌘ is held, and
        // takes the tab picked when it is let go of: a key needs one.
        guard id != Command.recentTabs || combo.control || combo.option || combo.command
        else { return say(Interface.text("Hold ⌃, ⌥ or ⌘ with it")) }
        // An extension's command takes a key as its manifest would: one
        // that types a character, not an arrow or a function key.
        guard !id.hasPrefix("ext:") || combo.key.count == 1 else { return say(Interface.text("Not for an extension")) }
        guard !id.hasPrefix("ext:") || !KeyCombo.isBrowserOnly(combo) else { return say(Interface.text("Not for an extension")) }
        if store.owner(of: combo, except: id) != nil, taking != combo {
            taking = combo
            return
        }
        let other = store.owner(of: combo, except: id)
        store.assign(combo, to: id)
        stop()
        if let other { browser.announce(Interface.format("%@ moved from %@", combo.display, Command.named(other.id).map(shortcutTitle) ?? other.title)) }
    }

    /// Why that key won't do, for a moment, still listening.
    private func say(_ text: String) {
        note = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if note == text { note = nil } }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = false
        note = nil
        taking = nil
        store.recording = false
    }
}
