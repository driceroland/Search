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
    @State private var choosingIcon = false
    @FocusState private var focused: Bool

    private var editing: Bool { browser.editingGroupID == group.id }

    /// Its height in the column, a little under a tab's.
    static let height: CGFloat = 24

    static func width(for group: TabGroup, editing: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let name = ceil((group.name as NSString).size(withAttributes: [.font: font]).width)
        return (editing ? max(60, name) : name) + 20 + ((group.icon?.validated != nil || editing) ? 20 : 0)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let icon = group.icon?.validated {
                iconButton(icon)
            } else if editing {
                iconButton(nil)
            }
            if editing {
                TextField("Group name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: horizontal ? max(60, Self.nameWidth(group.name)) : nil)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { browser.editingGroupID = nil }
            } else {
                HStack(spacing: 8) {
                    Text(group.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !horizontal { Spacer(minLength: 0) }
                    if !horizontal {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .medium))
                            .rotationEffect(.degrees(group.collapsed ? -90 : 0))
                            .opacity(hovering ? 1 : 0)
                    }
                }
                .frame(maxWidth: horizontal ? nil : .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { browser.toggleTabGroup(group.id) }
                .onDrag { NSItemProvider(object: "search-group:\(group.id.uuidString)" as NSString) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { browser.toggleTabGroup(group.id) }
            }
            if editing && !horizontal { Spacer(minLength: 0) }
        }
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 10)
        .frame(height: horizontal ? 28 : Self.height)
        .frame(maxWidth: horizontal ? nil : .infinity, alignment: .leading)
        .fixedSize(horizontal: horizontal, vertical: false)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(dropping ? Palette.wash : (hovering ? Palette.hover : .clear)))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
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
        .onChange(of: choosingIcon) { _, now in
            if !now { restoreNameFocus() }
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
        .contextMenu {
            Button("Rename Group") { browser.editingGroupID = group.id }
            Button("Change Icon…") { choosingIcon = true }
            Button(group.collapsed ? "Expand Group" : "Collapse Group") { browser.toggleTabGroup(group.id) }
            Divider()
            Button("Ungroup Tabs") { browser.removeTabGroup(group.id) }
        }
        .popover(isPresented: $choosingIcon, arrowEdge: .bottom) {
            TabGroupIconPicker(icon: group.icon, onChoose: { selected in
                browser.setTabGroupIcon(group.id, to: selected)
                choosingIcon = false
            }, onEmoji: {
                let id = group.id
                let current = group.icon
                choosingIcon = false
                DispatchQueue.main.async {
                    GroupEmojiCapture.show(current: current, onChoose: { selected in
                        browser.setTabGroupIcon(id, to: selected)
                    }, onClose: restoreNameFocus)
                }
            })
        }
    }

    private static func nameWidth(_ name: String) -> CGFloat {
        ceil((name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium)]).width)
    }

    private func iconButton(_ icon: TabGroupIcon?) -> some View {
        Button { choosingIcon = true } label: {
            GroupIconArt(icon: icon, size: 12)
                .frame(width: 14, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Change group icon")
        .accessibilityLabel("Change icon for \(group.name)")
    }

    private func commit() {
        browser.renameTabGroup(group.id, to: draft)
        browser.editingGroupID = nil
    }

    private func restoreNameFocus() {
        guard editing else { return }
        DispatchQueue.main.async { focused = true }
    }
}
