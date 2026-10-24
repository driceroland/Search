import SwiftUI
import AppKit

/// Unshifted heading and member frames in the layout's named coordinate space.
struct GroupDropFrame: Equatable {
    let group: UUID
    var tab: UUID? = nil
    let rect: CGRect
}

struct GroupDropTarget: Equatable {
    let group: UUID
    var member: UUID? = nil
    var after = false
}

struct GroupDropFrames: PreferenceKey {
    static var defaultValue: [UUID: GroupDropFrame] = [:]

    static func reduce(value: inout [UUID: GroupDropFrame], nextValue: () -> [UUID: GroupDropFrame]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }

    static func resolve(_ point: CGPoint, frames: [UUID: GroupDropFrame],
                        groups: [TabGroup], excluding source: UUID, vertical: Bool) -> GroupDropTarget? {
        // Model group order gives overlapping regions a deterministic priority.
        for group in groups {
            let heading = frames[group.id]?.rect
            let members = frames.values.filter { $0.group == group.id && $0.tab != nil && $0.tab != source }
                .sorted { vertical ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
            let extent = members.reduce(heading ?? .null) { $0.union($1.rect) }
            guard extent.contains(point) else { continue }
            if heading?.contains(point) == true || group.collapsed || members.isEmpty {
                return GroupDropTarget(group: group.id)
            }
            let position = vertical ? point.y : point.x
            if let next = members.first(where: { position < (vertical ? $0.rect.midY : $0.rect.midX) }) {
                return GroupDropTarget(group: group.id, member: next.tab)
            }
            return GroupDropTarget(group: group.id, member: members.last?.tab, after: true)
        }
        return nil
    }
}

/// A quiet name above the tabs it contains, in either layout.
struct GroupHeading: View {
    @Environment(\.greys) private var greys
    @Environment(\.tabShortcutNumbers) private var shortcutNumbers
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

    static func width(for name: String, numbered: Bool = false) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        return ceil((name as NSString).size(withAttributes: [.font: font]).width) + 20 + (numbered ? 23 : 0)
    }

    var body: some View {
        HStack(spacing: 8) {
            if editing {
                TextField("Group name", text: $draft)
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
            if !editing, group.collapsed {
                if let number = shortcutNumbers[group.id] {
                    TabShortcutNumber(number: number)
                } else if horizontal, browser.prefs.showsTabShortcuts {
                    Color.clear.frame(width: 15, height: 15)
                }
            }
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
            .fill(dropping ? greys.wash : (hovering ? greys.hover : .clear)))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture { if !editing { browser.toggleTabGroup(group.id) } }
        .background {
            if let dragSpace {
                GeometryReader { geometry in
                    Color.clear.preference(key: GroupDropFrames.self,
                                           value: [group.id: GroupDropFrame(group: group.id, rect: geometry.frame(in: .named(dragSpace)))])
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
            // The whole group into another space, still a group there: Arc's
            // folders came in wherever Arc had them.
            if browser.prefs.usesSpaces, browser.spaces.count > 1 {
                Menu("Move Group to Space") {
                    ForEach(browser.spaces.filter { $0.id != browser.spaceID }) { space in
                        Button {
                            browser.move(group: group.id, toSpace: space.id)
                        } label: {
                            Label(space.name, systemImage: space.symbol)
                        }
                    }
                }
            }
            Divider()
            Button("Ungroup Tabs") { browser.removeTabGroup(group.id) }
            Button("Close Group") { browser.closeTabGroup(group.id) }
        }
    }

    private func commit() {
        browser.renameTabGroup(group.id, to: draft)
        browser.editingGroupID = nil
    }
}
