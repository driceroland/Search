import SwiftUI
import AppKit

/// Heading positions in the tab row's own coordinate space, so its existing
/// reorder drag can also land a tab on a group without a second drag gesture.
struct GroupDropFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// A quiet name above the tabs it contains, in either layout.
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

    /// Its height in the column, a little under a tab's.
    static let height: CGFloat = 24

    static func width(for name: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        return ceil((name as NSString).size(withAttributes: [.font: font]).width) + 20
    }

    var body: some View {
        HStack(spacing: 8) {
            if editing {
                TextField(L("Group name"), text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: horizontal ? max(60, Self.width(for: group.name) - 20) : nil)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { browser.editingGroupID = nil }
            } else {
                Text(group.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if !horizontal { Spacer(minLength: 0) }
            if !editing && !horizontal {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .rotationEffect(.degrees(group.collapsed ? -90 : 0))
                    .opacity(hovering ? 1 : 0)
            }
        }
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 10)
        .frame(height: horizontal ? 28 : Self.height)
        .frame(maxWidth: horizontal ? nil : .infinity, alignment: .leading)
        .fixedSize(horizontal: horizontal, vertical: false)
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
            Button(L("Rename Group")) { browser.editingGroupID = group.id }
            Button(group.collapsed ? L("Expand Group") : L("Collapse Group")) { browser.toggleTabGroup(group.id) }
            Divider()
            Button(L("Ungroup Tabs")) { browser.removeTabGroup(group.id) }
            Button(L("Close Group")) { browser.closeTabGroup(group.id) }
        }
    }

    private func commit() {
        browser.renameTabGroup(group.id, to: draft)
        browser.editingGroupID = nil
    }
}
