import SwiftUI

/// A persistent, narrow alternative to the titled column. The page gets the
/// saved wide column's space back without forgetting that column's width.
struct IconSideBar: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @Namespace private var pill
    @State private var landing = false
    @State private var groupFrames: [UUID: GroupDropFrame] = [:]

    static let tile: CGFloat = 30
    static let gap: CGFloat = 2
    private var edge: Edge { prefs.sidePosition == .left ? .trailing : .leading }
    private var loose: [Tab] {
        browser.displayedTabs.filter { $0.pin == nil && (!prefs.usesTabGroups || browser.group(of: $0) == nil) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 6)
                .background { DragStrip() }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: Self.gap) {
                        rows(browser.squarePins, space: "icon-pins") { tab, index in
                            browser.moveDisplayedTab(tab, to: index)
                        }
                        rows(browser.listedPins, space: "icon-listed") { tab, index in
                            browser.moveDisplayedTab(tab, to: browser.squarePins.count + index)
                        }
                        if browser.pinnedCount > 0 && browser.displayedTabs.contains(where: { $0.pin == nil }) {
                            separator
                        }
                        if prefs.usesTabGroups {
                            ForEach(browser.tabGroups) { group in
                                IconGroupHeading(browser: browser, group: group, edge: edge)
                                rows(browser.visibleTabs(in: group), space: "icon-group-\(group.id)") { tab, index in
                                    browser.move(tab, within: group.id, to: index)
                                }
                            }
                        }
                        rows(loose, space: "icon-loose") { tab, index in
                            if prefs.usesTabGroups { browser.move(tab, within: nil, to: index) }
                            else { browser.moveDisplayedTab(tab, to: browser.pinnedCount + index) }
                        }
                        newTab
                    }
                    .padding(.horizontal, (Metrics.iconSide - Self.tile) / 2)
                    .padding(.vertical, Self.gap)
                    .coordinateSpace(name: "icon-rows")
                    .offset(x: browser.spaceSwipe)
                }
                .scrollIndicators(.hidden)
                .onChange(of: browser.activeID) { _, id in
                    if let id {
                        withAnimation(Motion.glide) { proxy.scrollTo(browser.activeSplit?.left ?? id, anchor: .center) }
                    }
                }
                .onAppear {
                    if let id = browser.activeID { proxy.scrollTo(browser.activeSplit?.left ?? id, anchor: .center) }
                }
            }
            SidebarFooter(browser: browser, prefs: prefs, compact: true)
        }
        .frame(width: prefs.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(landing ? Palette.hover : Palette.ground)
        .overlay(alignment: prefs.sidePosition == .left ? .trailing : .leading) {
            Rectangle().fill(Palette.hairline).frame(width: 1)
        }
        .clipped()
        .coordinateSpace(name: "icon-rail")
        .onAppear { SpaceSwipe.shared.start(for: browser) }
        .onPreferenceChange(GroupDropFrames.self) { groupFrames = $0 }
        .onDrop(of: [.url, .text], isTargeted: $landing) { browser.take($0) }
        .animation(Motion.quick, value: landing)
        .animation(IconRailInteraction.movement, value: browser.activeID)
        .animation(IconRailInteraction.movement, value: browser.tabs.map(\.id))
        .popover(isPresented: Binding(get: { browser.makingSpace }, set: { if !$0 { browser.cancelSpaceCreation() } }), arrowEdge: edge) {
            NewSpaceCard(browser: browser).frame(width: 280).padding(16)
        }
    }

    private var separator: some View {
        Rectangle().fill(Palette.hairline).frame(width: 28, height: 1).padding(.vertical, 4)
    }

    private func rows(_ tabs: [Tab], space: String, move: @escaping (Tab, Int) -> Void) -> some View {
        VStack(spacing: Self.gap) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                item(tab)
                    .modifier(SidebarRailFrame(key: "tab-\(tab.id.uuidString)"))
                    .id(tab.id)
                    .modifier(Carried(index: index, count: tabs.count, step: Self.tile + Self.gap,
                                      vertical: true, space: "icon-rows",
                                      onDropTab: { source, point in
                                          if let id = groupFrames.values.first(where: { $0.rect.contains(point) })?.group {
                                              browser.move(source, toGroup: id)
                                          }
                                      }, outside: { browser.dragOut(tab) }, browser: browser, tab: tab) {
                        move(tab, $0)
                    })
            }
        }
        .coordinateSpace(name: space)
    }

    @ViewBuilder
    private func item(_ tab: Tab) -> some View {
        if let pair = browser.split(for: tab), prefs.splitView,
           let right = browser.tabs.first(where: { $0.id == pair.right }), pair.left == tab.id {
            VStack(spacing: 0) {
                IconTab(browser: browser, prefs: prefs, tab: tab, pill: pill, height: Self.tile / 2, iconSize: 12)
                IconTab(browser: browser, prefs: prefs, tab: right, pill: pill, height: Self.tile / 2, iconSize: 12)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1).allowsHitTesting(false)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Split tabs")
        } else {
            IconTab(browser: browser, prefs: prefs, tab: tab, pill: pill)
        }
    }

    private var newTab: some View {
        Button(action: browser.newTab) {
            Image(systemName: "plus").font(.system(size: 16, weight: .regular))
                .foregroundStyle(Palette.muted)
                .frame(width: Self.tile, height: Self.tile)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(RailButtonStyle())
        .modifier(SidebarRailFrame(key: "new-tab"))
        .help("New tab   ⌘T")
        .accessibilityLabel("New tab")
        .contextMenu {
            Button("New Tab") { browser.newTab() }
            Button("New Private Tab") { browser.newShyTab() }
        }
    }

}

private struct IconTab: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let pill: Namespace.ID
    var height: CGFloat = IconSideBar.tile
    var iconSize: CGFloat = 16
    @State private var hovering = false

    private var live: Bool { browser.activeID == tab.id }
    private var editing: Bool { browser.editingTab == tab.id || browser.editingPin == tab.id }
    private var showsClose: Bool { IconRailInteraction.showsClose(active: live, hovering: hovering, pinned: tab.pin != nil, editing: editing, dragging: false) }
    private var title: String { tab.label.isEmpty ? "New Tab" : tab.label }
    private var status: String {
        [live ? "Selected" : nil, tab.shy ? "Private tab" : nil,
         tab.loading ? "Loading" : nil, tab.asleep ? "Sleeping" : nil,
         tab.recording ? "Recording" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        Button {
            if browser.split(for: tab) != nil && prefs.splitView { browser.focusPane(tab) }
            else { browser.select(tab) }
        } label: {
            ZStack {
                if showsClose {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.muted).transition(.opacity)
                } else if tab.loading {
                    Ring(size: iconSize * 0.75)
                } else if let icon = tab.icon {
                    Mark(icon: icon, letter: tab.monogram, size: iconSize, dim: tab.asleep)
                } else {
                    Image(systemName: tab.isBlank ? "square" : "globe")
                        .font(.system(size: iconSize, weight: .regular))
                        .foregroundStyle(Palette.muted.opacity(tab.asleep ? 0.45 : 1))
                }
            }
            .frame(width: IconSideBar.tile, height: height)
            .background { ground }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(RailButtonStyle())
        .overlay {
            if showsClose {
                RailCloseClick(audio: tab.noisy || tab.muted) { browser.close(tab) }
                    .frame(width: IconSideBar.tile, height: height)
                    .help("Close tab   ⌘W")
            }
        }
        .overlay(alignment: .topTrailing) {
            if tab.recording || tab.shy || tab.bench {
                Image(systemName: tab.recording ? "record.circle" : (tab.shy ? "eye.slash" : "flask"))
                    .font(.system(size: 6)).foregroundStyle(Palette.muted)
                    .padding(1).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !tab.loading && (tab.noisy || tab.muted) { Speaker(tab: tab).scaleEffect(0.7).frame(width: 12, height: 12).padding(1) }
        }
        .overlay { MiddleClick { browser.close(tab) } }
        .background {
            if prefs.splitView { SplitDropZone(browser: browser, tab: tab, kind: .strip) }
        }
        .onHover { hovering = $0 }
        .modifier(TabHoverDetails(browser: browser, tab: tab))
        .contextMenu { TabMenu(browser: browser, tab: tab, close: { browser.close(tab) }) }
        .help(title + (tab.shy ? " — Private tab" : ""))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(status)
        .accessibilityAction(named: "Close tab") { browser.close(tab) }
        .popover(isPresented: Binding(get: { editing }, set: { if !$0 { browser.finishTabEdit(); browser.editingPin = nil } }),
                 arrowEdge: prefs.sidePosition == .left ? .trailing : .leading) {
            Group {
                if browser.editingPin == tab.id { PinField(browser: browser, tab: tab) }
                else { TabAddressField(browser: browser) }
            }
            .frame(width: 280, height: 24).padding(12)
        }
        .animation(IconRailInteraction.hover, value: hovering)
        .animation(IconRailInteraction.hover, value: showsClose)
        .animation(Motion.quick, value: tab.loading)
    }

    @ViewBuilder private var ground: some View {
        if live {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.wash)
                .matchedGeometryEffect(id: "live", in: pill)
        }
    }
}

private struct IconGroupHeading: View {
    @ObservedObject var browser: Browser
    let group: TabGroup
    let edge: Edge
    @State private var renaming = false
    @State private var draft = ""

    @State private var dropping = false
    var body: some View {
        Button { browser.toggleTabGroup(group.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Image(systemName: group.collapsed ? "chevron.right" : "chevron.down").font(.system(size: 8))
            }
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
            .frame(width: IconSideBar.tile, height: 24)
        }
        .buttonStyle(.plain)
        .help(group.name)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: GroupDropFrames.self,
                                       value: [group.id: GroupDropFrame(group: group.id, rect: geometry.frame(in: .named("icon-rows")))])
            }
        }
        .onDrag { NSItemProvider(object: "search-group:\(group.id.uuidString)" as NSString) }
        .onDrop(of: [.text], isTargeted: $dropping) { providers in
            guard let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return false }
            _ = provider.loadObject(ofClass: String.self) { value, _ in
                guard let value, value.hasPrefix("search-group:"),
                      let id = UUID(uuidString: String(value.dropFirst("search-group:".count))) else { return }
                DispatchQueue.main.async {
                    if let index = browser.tabGroups.firstIndex(where: { $0.id == group.id }) { browser.moveTabGroup(id, to: index) }
                }
            }
            return true
        }
        .onAppear {
            if browser.editingGroupID == group.id { draft = group.name; renaming = true }
        }
        .onChange(of: browser.editingGroupID) { _, id in
            if id == group.id { draft = group.name; renaming = true }
        }
        .onChange(of: renaming) { _, on in
            if !on, browser.editingGroupID == group.id { browser.editingGroupID = nil }
        }
        .accessibilityLabel(group.name)
        .accessibilityValue(group.collapsed ? "Collapsed" : "Expanded")
        .contextMenu {
            Button("Rename Group") { draft = group.name; renaming = true }
            Button(group.collapsed ? "Expand Group" : "Collapse Group") { browser.toggleTabGroup(group.id) }
            Divider()
            Button("Ungroup Tabs") { browser.removeTabGroup(group.id) }
            Button("Close Group") { browser.closeTabGroup(group.id) }
        }
        .popover(isPresented: $renaming, arrowEdge: edge) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Group name", text: $draft).onSubmit(rename)
                Button("Save", action: rename).keyboardShortcut(.defaultAction)
            }.frame(width: 220).padding(16)
        }
    }

    private func rename() {
        browser.renameTabGroup(group.id, to: draft)
        renaming = false
    }
}
