import SwiftUI

/// Heading positions in the tab row's own coordinate space, so its existing
/// reorder drag can also land a tab on a group without a second drag gesture.
struct GroupDropFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// The group heading has the same icon, title and chevron in either tab
/// layout. Its children live in that layout's own row or column.
struct GroupHeading: View {
    @ObservedObject var browser: Browser
    let group: TabGroup
    var horizontal = false
    var dragSpace: String? = nil

    @State private var draft = ""
    @State private var hovering = false
    @State private var dropping = false
    @FocusState private var focused: Bool

    private var editing: Bool { browser.editingGroupID == group.id }

    var body: some View {
        HStack(spacing: 8) {
            if let tab = browser.tabs(in: group.id).first {
                GroupMark(tab: tab)
            } else {
                Image(systemName: "square.stack")
                    .font(.system(size: 12))
                    .frame(width: 15)
            }
            if editing {
                TextField("Group name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { browser.editingGroupID = nil }
            } else {
                Text(group.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if !editing {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .rotationEffect(.degrees(group.collapsed ? -90 : 0))
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 10)
        .frame(width: horizontal ? 126 : nil, height: 28)
        .frame(maxWidth: horizontal ? nil : .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(dropping ? Palette.wash : (hovering ? Palette.hover : .clear)))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture { if !editing { browser.toggleTabGroup(group.id) } }
        .background {
            if let dragSpace {
                GeometryReader { geometry in
                    Color.clear.preference(key: GroupDropFrames.self,
                                           value: [group.id: geometry.frame(in: .named(dragSpace))])
                }
            }
        }
        .onHover { hovering = $0 }
        .onChange(of: editing) { _, now in
            if now {
                draft = group.name
                DispatchQueue.main.async { focused = true }
            }
        }
        .onAppear {
            if editing {
                draft = group.name
                DispatchQueue.main.async { focused = true }
            }
        }
        .onDrop(of: [.text], isTargeted: $dropping) { providers in
            guard let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return false }
            _ = provider.loadObject(ofClass: String.self) { value, _ in
                guard let value else { return }
                DispatchQueue.main.async {
                    if value.hasPrefix("search-group:"),
                       let id = UUID(uuidString: String(value.dropFirst("search-group:".count))),
                       let index = browser.tabGroups.firstIndex(where: { $0.id == group.id }) {
                        browser.moveTabGroup(id, to: index)
                    }
                }
            }
            return true
        }
        .onDrag { NSItemProvider(object: "search-group:\(group.id.uuidString)" as NSString) }
        .contextMenu {
            Button("Rename Group") { browser.editingGroupID = group.id }
            Button(group.collapsed ? "Expand Group" : "Collapse Group") { browser.toggleTabGroup(group.id) }
            Divider()
            Button("Remove Group") { browser.removeTabGroup(group.id) }
        }
    }

    private func commit() {
        browser.renameTabGroup(group.id, to: draft)
        browser.editingGroupID = nil
    }
}

private struct GroupMark: View {
    @ObservedObject var tab: Tab

    var body: some View {
        Mark(icon: tab.icon, letter: tab.monogram, size: 15)
    }
}
