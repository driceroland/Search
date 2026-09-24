import SwiftUI

// Folders in the column, as in Arc: a name with tabs under it, opened and shut
// with a click. A folder is its name on the tabs in it. It lives as long as
// one of them does and sits where its first tab sits in the row.
//
// ponytail: one level only and no empty folders. Nesting and a folder that
// outlives its tabs need folders of their own in the session.

extension Browser {
    private func folderKey(_ folder: String) -> String { "\(spaceID.uuidString)/\(folder)" }

    func isFolderShut(_ folder: String) -> Bool {
        shutFolders.contains(folderKey(folder))
    }

    func openFolder(containing tab: Tab) {
        guard let folder = tab.folder else { return }
        shutFolders.remove(folderKey(folder))
    }

    /// The folders in this space, in the order their first tabs come.
    var folders: [String] {
        var seen: [String] = []
        for tab in tabs where tab.pin == nil {
            if let name = tab.folder, !seen.contains(name) { seen.append(name) }
        }
        return seen
    }

    func tabs(in folder: String) -> [Tab] {
        tabs.filter { $0.pin == nil && $0.folder == folder }
    }

    func file(_ tab: Tab, in folder: String?) {
        guard tab.pin == nil else { return }
        tab.folder = folder
        objectWillChange.send()
        writeSession()
    }

    /// Asks for a name, then puts the tab in a new folder by it.
    func fileInNewFolder(_ tab: Tab) {
        Ask.name("New Folder", placeholder: "Name", confirm: "Create") { [weak self] name in
            guard let self else { return }
            let name = name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            shutFolders.remove(folderKey(name))
            file(tab, in: name)
        }
    }

    func renameFolder(_ folder: String) {
        Ask.name("Rename Folder", placeholder: "Name", initial: folder, confirm: "Rename") { [weak self] name in
            guard let self else { return }
            let name = name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != folder else { return }
            for tab in tabs(in: folder) { tab.folder = name }
            if shutFolders.remove(folderKey(folder)) != nil { shutFolders.insert(folderKey(name)) }
            objectWillChange.send()
            writeSession()
        }
    }

    /// The folder goes; its tabs stay, loose.
    func ungroup(_ folder: String) {
        for tab in tabs(in: folder) { tab.folder = nil }
        shutFolders.remove(folderKey(folder))
        objectWillChange.send()
        writeSession()
    }

    func toggleFolder(_ folder: String) {
        let key = folderKey(folder)
        if shutFolders.contains(key) { shutFolders.remove(key) } else { shutFolders.insert(key) }
    }
}

/// The folder part of a tab's right-click menu.
struct FolderMenu: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab

    var body: some View {
        let otherFolders = browser.folders.filter { $0 != tab.folder }
        if tab.pin == nil, !tab.shy {
            Menu("Add to Folder") {
                ForEach(otherFolders, id: \.self) { name in
                    Button(name) { browser.file(tab, in: name) }
                }
                if !otherFolders.isEmpty { Divider() }
                Button("New Folder…") { browser.fileInNewFolder(tab) }
            }
            if tab.folder != nil {
                Button("Remove from Folder") { browser.file(tab, in: nil) }
            }
        }
    }
}

/// A folder's own row: its icon, its name in bold, a click to open or shut.
struct FolderRow: View {
    @ObservedObject var browser: Browser
    let name: String
    let height: CGFloat

    @State private var hovering = false

    private var themed: Bool { browser.space.theme != nil }
    private var open: Bool { !browser.isFolderShut(name) }

    var body: some View {
        HStack(spacing: themed ? 10 : 8) {
            // Arc's folder: an outline with a pale inside.
            ZStack {
                Image(systemName: "folder.fill").foregroundStyle(Color.white.opacity(0.7))
                Image(systemName: "folder").foregroundStyle(Palette.ink.opacity(0.75))
            }
            .font(.system(size: themed ? 16 : 13, weight: .medium))
            .frame(width: themed ? 18 : 15)
            Text(name)
                .font(.system(size: themed ? 14.5 : 12.5, weight: .bold))
                .foregroundStyle(Palette.ink.opacity(themed ? 0.9 : 0.8))
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .rotationEffect(.degrees(open ? 90 : 0))
                .opacity(hovering ? 1 : 0)
        }
        .padding(.leading, themed ? 12 : 10)
        .padding(.trailing, 10)
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: themed ? 10 : 9, style: .continuous)
                .fill(hovering ? (themed ? Tint.hover : Palette.hover) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: themed ? 10 : 9, style: .continuous))
        .onTapGesture { withAnimation(Motion.settle) { browser.toggleFolder(name) } }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename Folder…") { browser.renameFolder(name) }
            Button("Ungroup") { browser.ungroup(name) }
            Divider()
            Button("Close Tabs in Folder") { browser.tabs(in: name).forEach { browser.close($0) } }
        }
        .animation(Motion.quick, value: hovering)
    }
}

/// The small heading over the folders on a coloured frame, as in Arc: the
/// space's name.
struct ColumnHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Palette.ink.opacity(0.5))
            .padding(.leading, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Arc's address at the head of the column, on a coloured frame: the page's
/// host in a well, a click to change it, its link to copy and the site's
/// hidden things beside it.
struct AddressWell: View {
    @ObservedObject var browser: Browser

    var body: some View {
        HStack(spacing: 4) {
            Text(browser.active?.address.map { Address.pretty($0) } ?? "")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Palette.ink.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { browser.edit() }
            Door(icon: "link", help: "Copy Address   ⇧⌘C") { browser.copyAddress() }
            Door(icon: "slider.horizontal.3", on: browser.reviewing, help: "Hidden on This Site   ⇧⌘U") { browser.reviewing.toggle() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Tint.well))
        .opacity(browser.active?.isBlank == false ? 1 : 0.6)
    }
}
