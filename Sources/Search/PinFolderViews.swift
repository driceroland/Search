import SwiftUI

// A pin folder's heading among the pinned rows (see PinFolders.swift): a
// fold mark, a folder and its name, set in by how deep it is. A click folds
// or opens it; its menu renames, nests, makes one inside, or deletes it.
// With icons only, the name's first letter and the fold mark, the name in
// its tooltip, as a group's heading has it.

struct PinFolderHeading: View {
    @Environment(\.greys) private var greys
    @ObservedObject var browser: Browser
    /// For the row's size: a tab's own.
    @ObservedObject var prefs: Preferences
    let folder: PinFolder
    let depth: Int
    var compact = false
    /// Not to be pressed: a copy drawn for a picture.
    var interactive = true
    /// A pin carried over it would go in.
    var target = false

    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    /// Set in by each level, as a group's tabs are under its name.
    static let indent: CGFloat = 14

    /// A heading's height: a tab row's, so a folder sits among the pins as
    /// one more of them; with icons only, a group heading's.
    static func height(_ prefs: Preferences, compact: Bool) -> CGFloat {
        compact ? GroupHeading.compactHeight : prefs.sideRow
    }

    /// The width a tab row gives its site's icon (SideRow's Mark).
    private var mark: CGFloat { 15 }

    private var editing: Bool { interactive && browser.editingPinFolder == folder.id }

    var body: some View {
        Group {
            if compact { short } else { long }
        }
        .background(RoundedRectangle(cornerRadius: compact ? 6 : 9, style: .continuous)
            .fill(target ? greys.wash : (hovering ? greys.hover : (compact ? greys.tile : .clear))))
        .contentShape(RoundedRectangle(cornerRadius: compact ? 6 : 9, style: .continuous))
        .onTapGesture { if interactive && !editing { browser.togglePinFolder(folder.id) } }
        .onHover { hovering = interactive && $0 }
        .contextMenu { if interactive { menu } }
        .accessibilityLabel(folder.name)
        .accessibilityHint(folder.collapsed ? "Folded folder" : "Folder")
    }

    private var short: some View {
        HStack(spacing: 2) {
            Text(folder.name.first.map { String($0).uppercased() } ?? "•")
                .font(.system(size: 9.5, weight: .semibold))
            Image(systemName: "chevron.down")
                .font(.system(size: 6.5, weight: .bold))
                .rotationEffect(.degrees(folder.collapsed ? -90 : 0))
        }
        .foregroundStyle(titleColour(hovering: hovering))
        .frame(maxWidth: .infinity)
        .frame(height: GroupHeading.compactHeight)
        .help(folder.collapsed ? "\(folder.name) — folded" : folder.name)
        .popover(isPresented: Binding(get: { editing }, set: { if !$0 { browser.editingPinFolder = nil } }),
                 hangingFrom: browser.prefs.sidePosition == .right ? .leading : .trailing) {
            field
                .frame(width: 160)
                .padding(10)
                .onAppear {
                    draft = folder.name
                    DispatchQueue.main.async { focused = true }
                }
        }
    }

    private var long: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8.5, weight: .semibold))
                .rotationEffect(.degrees(folder.collapsed ? 0 : 90))
                .frame(width: 10)
            HStack(spacing: 8) {
                // The folder where a tab's icon is, as large; its name as a tab's title.
                Image(systemName: glyph)
                    .font(.system(size: mark * 0.8))
                    .frame(width: mark, height: mark)
                if editing {
                    field
                } else {
                    Text(folder.name)
                        .font(.system(size: prefs.sideTitle, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(titleColour(hovering: false))
        .padding(.horizontal, 10)
        .padding(.leading, CGFloat(depth) * Self.indent)
        .frame(height: Self.height(prefs, compact: false))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: editing) { _, now in
            if now {
                draft = folder.name
                DispatchQueue.main.async { focused = true }
            }
        }
        .onAppear {
            if editing {
                draft = folder.name
                DispatchQueue.main.async { focused = true }
            }
        }
    }

    private var glyph: String {
        return folder.collapsed ? "folder" : "folder.fill"
    }

    /// Soft grey by default; full ink with Settings › Appearance › Tabs ›
    /// High contrast text, as a tab's title is.
    private func titleColour(hovering: Bool) -> Color {
        if prefs.highContrastText { return Palette.ink }
        return hovering ? Palette.ink.opacity(0.7) : Palette.muted
    }

    private var field: some View {
        TextField("Folder name", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: prefs.sideTitle, weight: .medium))
            .focused($focused)
            .onSubmit(commit)
            .onExitCommand { browser.editingPinFolder = nil }
    }

    private func commit() {
        browser.renamePinFolder(folder.id, to: draft)
        browser.editingPinFolder = nil
    }

    @ViewBuilder
    private var menu: some View {
        let folders = browser.pinFolders
        Button("Rename Folder") { browser.editingPinFolder = folder.id }
        Button(folder.collapsed ? "Expand Folder" : "Collapse Folder") { browser.togglePinFolder(folder.id) }
        Button("New Folder Inside") { browser.newPinFolder(in: folder.id) }
            .disabled(!PinTree.canMake(in: folder.id, in: folders))
        Menu("Move Folder To") {
            Button("Top of Pinned Rows") { browser.movePinFolder(folder.id, into: nil) }
                .disabled(folder.parent == nil)
            let others = PinFolderMenu.entries(folders).filter { $0.folder.id != folder.id }
            if !others.isEmpty { Divider() }
            ForEach(others, id: \.folder.id) { entry in
                Button(entry.title) { browser.movePinFolder(folder.id, into: entry.folder.id) }
                    .disabled(folder.parent == entry.folder.id || !PinTree.canMove(folder.id, into: entry.folder.id, in: folders))
            }
        }
        Divider()
        Button("Delete Folder") { browser.deletePinFolder(folder.id) }
    }
}

/// The folders as a menu lists them: in drawn order, each set in under the
/// one that holds it.
enum PinFolderMenu {
    struct Entry { let folder: PinFolder; let title: String }

    static func entries(_ folders: [PinFolder]) -> [Entry] {
        let open = folders.map { folder -> PinFolder in
            var folder = folder
            folder.collapsed = false
            return folder
        }
        return PinTree.lines(pins: [], folders: open).compactMap { line in
            guard case .folder(let folder, let depth) = line else { return nil }
            return Entry(folder: folder, title: String(repeating: "    ", count: depth) + folder.name)
        }
    }
}

/// Where a carried pin would go beside another: a thin line over or under
/// that row.
struct PinFolderMark: View {
    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 6)
            .allowsHitTesting(false)
    }
}

/// Where each line of the pinned rows was drawn, for where a pin let go
/// among them goes. Kept outside SwiftUI's state: measuring redraws nothing.
final class PinLineFrames {
    var rects: [UUID: CGRect] = [:]
}
