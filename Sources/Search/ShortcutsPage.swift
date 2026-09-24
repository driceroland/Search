import AppKit
import SwiftUI

/// Settings › Shortcuts: every menu command with its key, a card to a menu,
/// narrowed by name or key. Click a key and press the new one; right-click
/// to clear it or put the default back.
struct ShortcutsPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var store: ShortcutStore

    @State private var hunt = ""
    @FocusState private var hunting: Bool

    /// By name, or by key as the menus write it: "tab" and "⌘T" both find New Tab.
    private func shown(_ command: Command) -> Bool {
        let words = hunt.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return true }
        let key = store.key(for: command.id)?.display ?? ""
        return command.title.localizedCaseInsensitiveContains(words)
            || key.localizedCaseInsensitiveContains(words.replacingOccurrences(of: " ", with: ""))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Hunt(text: $hunt, prompt: "Search commands or keys", focus: $hunting)
            let found = Command.all.filter(shown)
            if found.isEmpty { Nothing("No command called that, or on that key") }
            ForEach(Command.Section.allCases, id: \.self) { section in
                let commands = found.filter { $0.section == section }
                if !commands.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Caption(section.rawValue)
                    Card {
                        ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                            if index > 0 { Rule() }
                            Line(command.title) {
                                KeyBox(browser: browser, store: store, command: command)
                            }
                            .contextMenu {
                                Button("Clear Shortcut") { store.clear(command.id) }
                                    .disabled(store.key(for: command.id) == nil)
                                Button("Reset to Default") { store.reset(command.id) }
                                    .disabled(!store.isChanged(command.id))
                            }
                        }
                    }
                }
                }
            }
            if store.anyChanged, hunt.isEmpty {
                Pill("Reset All to Defaults") { store.resetAll() }
            }
        }
    }
}

/// The key a command is on. Click it and press another: that key moves
/// here, from whichever command had it. Esc stops without changing it,
/// ⌫ takes it off.
private struct KeyBox: View {
    let browser: Browser
    @ObservedObject var store: ShortcutStore
    let command: Command

    @State private var listening = false
    @State private var monitor: Any?
    @State private var note: String?
    @State private var hovering = false
    /// A key another command has, pressed once: pressed again, it moves here.
    @State private var taking: KeyCombo?

    var body: some View {
        Button(action: listen) {
            Text(label)
                .font(.system(size: 12, weight: store.isChanged(command.id) ? .semibold : .regular))
                .foregroundStyle(listening || store.key(for: command.id) != nil ? Palette.ink : Palette.muted)
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
        .onHover { hovering = $0 }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if let taking, let other = store.owner(of: taking, except: command.id) {
            return "Used by \(other.title) — press again"
        }
        if let note { return note }
        if listening { return "Type a shortcut" }
        return store.key(for: command.id)?.display ?? "None"
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
            store.clear(command.id)
            return stop()
        }
        guard let combo = KeyCombo(event: event) else { return }
        guard combo.isUsable else { return say("Add ⌘, ⌥ or ⌃") }
        guard !KeyCombo.isReserved(combo) else { return say("Can’t be changed") }
        if store.owner(of: combo, except: command.id) != nil, taking != combo {
            taking = combo
            return
        }
        let other = store.owner(of: combo, except: command.id)
        store.assign(combo, to: command.id)
        stop()
        if let other { browser.announce("\(combo.display) moved from \(other.title)") }
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
