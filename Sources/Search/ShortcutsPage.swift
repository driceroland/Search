import SwiftUI
import AppKit

/// Settings › Shortcuts: every command, the key it's on, and who gets that
/// key when a website wants it too. A list to find it in on the left, the
/// one you picked on the right.
struct ShortcutsPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var store: ShortcutStore

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All Shortcuts", changed = "Changed", disabled = "Disabled"
        var id: String { rawValue }
    }

    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var selected = Command.all[0].id
    @FocusState private var hunting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Hunt(text: $query, prompt: "Search shortcuts", focus: $hunting)
                Menu {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Palette.muted)
                .help("Show all, changed or disabled shortcuts")
                Menu {
                    Button("Reset All Shortcuts") { store.resetAll() }
                        .disabled(!store.anyModified)
                    Divider()
                    Section("When any shortcut conflicts") {
                        ForEach(Conflict.allCases) { conflict in
                            Button(conflict.title) { store.setAllConflicts(conflict) }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Palette.muted)
            }

            HStack(alignment: .top, spacing: 16) {
                list
                    .frame(width: 310)
                if let command = Command.named(selected) {
                    ShortcutDetail(browser: browser, store: store, command: command)
                        .id(command.id)
                }
            }
        }
    }

    private var shown: [Command] {
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        return Command.all.filter { command in
            switch filter {
            case .all: break
            case .changed: guard store.isModified(command.id) else { return false }
            case .disabled: guard store.isDisabled(command.id) else { return false }
            }
            guard !words.isEmpty else { return true }
            let keys = store.key(for: command.id)?.display.lowercased() ?? ""
            return command.title.lowercased().contains(words) || command.section.rawValue.lowercased().contains(words) || keys.contains(words)
        }
    }

    private var list: some View {
        let commands = shown
        return ScrollView(showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Command.Section.allCases, id: \.self) { section in
                    let rows = commands.filter { $0.section == section }
                    if !rows.isEmpty {
                        Text(section.rawValue)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                        ForEach(rows) { command in
                            Row(command: command, store: store, on: command.id == selected) { selected = command.id }
                        }
                    }
                }
                if commands.isEmpty {
                    Nothing(filter == .all ? "No shortcut matches" : "No \(filter.rawValue.lowercased()) shortcuts")
                }
            }
            .padding(.bottom, 8)
        }
        .frame(maxHeight: .infinity)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private struct Row: View {
        let command: Command
        @ObservedObject var store: ShortcutStore
        let on: Bool
        let pick: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: pick) {
                HStack(spacing: 6) {
                    Text(command.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if store.isModified(command.id) {
                        Circle().fill(Palette.muted).frame(width: 5, height: 5)
                            .help("Changed from the default")
                    }
                    Spacer(minLength: 8)
                    Text(store.isDisabled(command.id) ? "Off" : (store.key(for: command.id)?.display ?? ""))
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(on ? Palette.wash : (hovering ? Palette.hover : .clear))
                )
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Reset to Default") { store.reset(command.id) }
                    .disabled(!store.isModified(command.id))
                Button("Disable Shortcut") { store.disable(command.id) }
                    .disabled(store.key(for: command.id) == nil)
            }
        }
    }
}

/// The command you picked: what it does, its key, and what happens when a
/// website wants the key too.
private struct ShortcutDetail: View {
    @ObservedObject var browser: Browser
    @ObservedObject var store: ShortcutStore
    let command: Command

    @State private var armed = false
    @State private var note: String?
    /// A key another command has, waiting for "Replace".
    @State private var taking: (combo: KeyCombo, from: Command)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(command.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Menu {
                    Picker("When shortcut conflicts", selection: Binding(
                        get: { store.conflict(for: command.id) },
                        set: { store.setConflict($0, for: command.id) }
                    )) {
                        ForEach(Conflict.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("Reset to Default") { reset() }
                        .disabled(!store.isModified(command.id))
                    Button("Disable Shortcut") { disable() }
                        .disabled(store.key(for: command.id) == nil)
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Palette.muted)
                .help("When a website uses this shortcut too")
            }
            Text(command.detail)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            KeyRecorder(combo: store.key(for: command.id), disabled: store.isDisabled(command.id), armed: $armed) { event in
                record(event)
            }
            .onChange(of: armed) { _, on in
                browser.recordingShortcut = on
                if on { note = nil; taking = nil }
            }
            .onDisappear { browser.recordingShortcut = false }

            if let taking {
                HStack(spacing: 8) {
                    Text("\(taking.combo.display) is on \(taking.from.title).")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink)
                    Spacer(minLength: 0)
                    Pill("Replace", filled: true) {
                        store.assign(taking.combo, to: command.id)
                        self.taking = nil
                    }
                    Pill("Cancel") { self.taking = nil }
                }
            } else if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }

            HStack(spacing: 8) {
                Pill("Reset to Default") { reset() }
                    .disabled(!store.isModified(command.id))
                    .opacity(store.isModified(command.id) ? 1 : 0.4)
                Pill("Disable Shortcut") { disable() }
                    .disabled(store.key(for: command.id) == nil)
                    .opacity(store.key(for: command.id) == nil ? 0.4 : 1)
            }

            Text("When a website uses it too: \(store.conflict(for: command.id).title)")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func reset() {
        store.reset(command.id)
        note = nil
        taking = nil
    }

    private func disable() {
        store.disable(command.id)
        note = nil
        taking = nil
    }

    /// The key pressed while the recorder was listening.
    private func record(_ event: NSEvent) {
        armed = false
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Delete alone: no key for this command.
        if flags.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            disable()
            return
        }
        guard let combo = KeyCombo(event: event) else { return }
        guard combo.isUsable else {
            note = "Hold ⌘, ⌥ or ⌃ with it — a key on its own is for typing."
            return
        }
        guard !KeyCombo.reserved.contains(combo) else {
            note = "\(combo.display) belongs to macOS."
            return
        }
        if let other = store.owner(of: combo, except: command.id) {
            taking = (combo, other)
            return
        }
        store.assign(combo, to: command.id)
    }
}

/// A box that shows the key, and listens for a new one when clicked.
private struct KeyRecorder: View {
    let combo: KeyCombo?
    let disabled: Bool
    @Binding var armed: Bool
    let pressed: (NSEvent) -> Void

    @State private var monitor: Any?

    var body: some View {
        Button { armed.toggle() } label: {
            Text(label)
                .font(.system(size: armed || combo == nil ? 13 : 16, weight: .medium, design: .rounded))
                .foregroundStyle(combo == nil || armed ? Palette.muted : Palette.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(armed ? Palette.ink.opacity(0.5) : Palette.hairline, lineWidth: armed ? 1.5 : 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(armed ? "Press the new shortcut — esc to cancel, delete for none" : "Click to record a new shortcut")
        .onChange(of: armed) { _, on in on ? listen() : stop() }
        .onDisappear { stop() }
    }

    private var label: String {
        if armed { return "Press a shortcut…" }
        if let combo { return combo.display }
        return disabled ? "Disabled — click to record" : "None — click to record"
    }

    private func listen() {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53, flags.isEmpty {
                armed = false
            } else {
                pressed(event)
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
