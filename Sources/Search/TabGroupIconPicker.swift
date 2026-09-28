import SwiftUI
import AppKit

/// The same mark in a heading or a menu, with emoji left in their own colors.
struct GroupIconArt: View {
    let icon: TabGroupIcon?
    let size: CGFloat

    var body: some View {
        switch icon {
        case .some(.symbol(let name)):
            Image(systemName: name)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(Palette.muted)
        case .some(.emoji(let value)):
            Text(value)
                .font(.system(size: size))
        case nil:
            Image(systemName: "plus")
                .font(.system(size: size - 2, weight: .medium))
                .foregroundStyle(Palette.muted)
        }
    }
}

/// A menu image needs real pixels for emoji; a Text-based SwiftUI menu label
/// can silently omit its icon when AppKit builds the native menu.
enum GroupMenuIcon {
    static func image(for icon: TabGroupIcon) -> NSImage? {
        switch icon {
        case .symbol(let name):
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .emoji(let value):
            let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                let font = NSFont.systemFont(ofSize: 15)
                let text = value as NSString
                let size = text.size(withAttributes: [.font: font])
                text.draw(at: NSPoint(x: (rect.width - size.width) / 2,
                                      y: (rect.height - size.height) / 2),
                          withAttributes: [.font: font])
                return true
            }
            image.isTemplate = false
            return image
        }
    }
}

struct TabGroupIconPicker: View {
    let icon: TabGroupIcon?
    let onChoose: (TabGroupIcon?) -> Void
    let onEmoji: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 6), spacing: 4) {
                ForEach(Array(zip(Spaces.icons, Spaces.iconNames)), id: \.0) { symbol, name in
                    Button { onChoose(.symbol(symbol)) } label: {
                        GroupIconArt(icon: .symbol(symbol), size: 13)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(icon == .symbol(symbol) ? Palette.wash : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(name)
                    .accessibilityLabel(name)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Button("No Icon") { onChoose(nil) }
                    .disabled(icon == nil)
                Spacer(minLength: 0)
                Button("Emoji…", action: onEmoji)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
        }
        .padding(10)
        .frame(width: 208)
    }
}

/// Character Viewer inserts into the first responder. Give it a persistent,
/// visible native field so it cannot insert into a tab's page or a name draft.
@MainActor
final class GroupEmojiCapture: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private static var active: GroupEmojiCapture?

    private let panel: NSPanel
    private let field: NSTextField
    private let useButton: NSButton
    private let onChoose: (TabGroupIcon) -> Void
    private let onClose: () -> Void

    private init(current: TabGroupIcon?, onChoose: @escaping (TabGroupIcon) -> Void,
                 onClose: @escaping () -> Void) {
        self.onChoose = onChoose
        self.onClose = onClose
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 282, height: 96),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        field = NSTextField(frame: NSRect(x: 12, y: 52, width: 258, height: 26))
        useButton = NSButton(title: "Use Emoji", target: nil, action: nil)
        super.init()

        panel.title = "Choose Emoji"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.delegate = self
        field.placeholderString = "Choose an emoji in the macOS viewer"
        if case .some(.emoji(let value)) = current?.validated { field.stringValue = value }
        field.delegate = self
        panel.contentView?.addSubview(field)

        let reopen = NSButton(title: "Emoji…", target: self, action: #selector(openViewer))
        reopen.bezelStyle = .rounded
        reopen.frame = NSRect(x: 12, y: 10, width: 78, height: 28)
        panel.contentView?.addSubview(reopen)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSelection))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 104, y: 10, width: 78, height: 28)
        panel.contentView?.addSubview(cancel)
        useButton.target = self
        useButton.action = #selector(useSelection)
        useButton.bezelStyle = .rounded
        useButton.keyEquivalent = "\r"
        useButton.frame = NSRect(x: 188, y: 10, width: 82, height: 28)
        useButton.isEnabled = TabGroupIcon.emoji(from: field.stringValue) != nil
        panel.contentView?.addSubview(useButton)
    }

    static func show(current: TabGroupIcon?, onChoose: @escaping (TabGroupIcon) -> Void,
                     onClose: @escaping () -> Void) {
        active?.panel.close()
        let capture = GroupEmojiCapture(current: current, onChoose: onChoose, onClose: onClose)
        active = capture
        if let parent = Links.window {
            capture.panel.setFrameOrigin(NSPoint(x: parent.frame.midX - 141,
                                                 y: parent.frame.midY - 48))
        } else {
            capture.panel.center()
        }
        capture.panel.makeKeyAndOrderFront(nil)
        capture.panel.makeFirstResponder(capture.field)
        DispatchQueue.main.async { [weak capture] in capture?.openViewer() }
    }

    @objc private func openViewer() {
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        NSApp.orderFrontCharacterPalette(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        useButton.isEnabled = TabGroupIcon.emoji(from: field.stringValue) != nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelSelection()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            useSelection()
            return true
        }
        return false
    }

    @objc private func useSelection() {
        guard let icon = TabGroupIcon.emoji(from: field.stringValue) else { return }
        onChoose(icon)
        panel.close()
    }

    @objc private func cancelSelection() {
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        if Self.active === self { Self.active = nil }
        onClose()
    }
}
