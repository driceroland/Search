import SwiftUI

/// ⌃Tab with the switcher on (Settings › Tabs): the tabs of the space on
/// screen as pictures, the one you are on first and then the ones you last
/// left, latest first. One gesture's order stays fixed until ⌃ is let go
/// of, so walking it does not rearrange what is being walked.
@MainActor
final class TabSwitcher: ObservableObject {
    enum Direction { case left, right, up, down }

    /// The tabs left, latest first, in every space: going back to a space
    /// finds its order where it was. Kept only while the switcher is on.
    private var recentIDs: [Tab.ID] = []
    @Published private(set) var candidates: [Tab.ID] = []
    @Published private(set) var selectedID: Tab.ID?
    @Published private(set) var visible = false
    @Published private var previews: [Tab.ID: (address: URL, image: NSImage)] = [:]

    /// With spaces, a row for each space, in the order ⌃1–⌃9 go: its five
    /// latest, in the same order the space on screen gets. Empty without
    /// spaces, and the switcher is the one grid it always was.
    struct Shelf: Identifiable {
        let space: Space
        let ids: [Tab.ID]
        var id: UUID { space.id }
    }
    @Published private(set) var shelves: [Shelf] = []

    /// Every tab on show: the space on screen's, or every space's.
    private var shown: [Tab.ID] { shelves.isEmpty ? candidates : shelves.flatMap(\.ids) }

    private var previewRequests: [Tab.ID: UUID] = [:]
    private var reveal: DispatchWorkItem?
    private var previewRequested = false
    private var generation = UUID()
    var active: Bool { !candidates.isEmpty }

    /// The tab just left goes to the front, with a picture of it as it was.
    /// Tabs that are gone fall out, and only the ten latest keep a picture.
    func left(_ tab: Tab, alive: Set<Tab.ID>) {
        recentIDs = [tab.id] + recentIDs.filter { $0 != tab.id && alive.contains($0) }
        prune { kept($0) }
        if !tab.isBlank { requestPreview(of: tab, gesture: nil) }
    }

    /// The first ⌃Tab of a gesture takes the space's tabs in that order, the
    /// ones never left after them in the row's order, and stops on the one
    /// before this one: a quick press goes back to the last tab, and the
    /// next comes back again. ⇧ starts from the far end.
    ///
    /// `spaces`, with spaces on: every space's row and the tab it was showing,
    /// each to be a row of the switcher. Once the pick is in another space's
    /// row, Tab walks that row.
    func step(row: [Tab.ID], current: Tab.ID, backwards: Bool,
              spaces: [(space: Space, row: [Tab.ID], showing: Tab.ID?)] = []) {
        if candidates.isEmpty {
            guard row.contains(current) else { return }
            // Five with spaces, so that each space is one row.
            candidates = order(row, first: current, limit: spaces.isEmpty ? 10 : 5)
            shelves = spaces
                .map { Shelf(space: $0.space, ids: $0.row.contains(current) ? candidates : order($0.row, first: $0.showing, limit: 5)) }
                .filter { !$0.ids.isEmpty }
            // Somewhere to go: another tab here, or another space.
            guard candidates.count > 1 || shelves.count > 1 else {
                candidates = []
                shelves = []
                return
            }
            selectedID = backwards ? candidates.last : candidates[min(1, candidates.count - 1)]
            let work = DispatchWorkItem { [weak self] in self?.show() }
            reveal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            return
        }

        let line = selectedID.flatMap { id in shelves.first { $0.ids.contains(id) }?.ids } ?? candidates
        guard let selectedID, let index = line.firstIndex(of: selectedID) else { return }
        let next = (index + (backwards ? -1 : 1) + line.count) % line.count
        self.selectedID = line[next]
        show()
    }

    /// A row's tabs: the one it was showing, then the ones last left, then the
    /// rest in the row's order.
    private func order(_ row: [Tab.ID], first: Tab.ID?, limit: Int) -> [Tab.ID] {
        let valid = Set(row)
        var seen: Set<Tab.ID> = []
        return Array(([first].compactMap { $0 } + recentIDs + row)
            .filter { valid.contains($0) && seen.insert($0).inserted }
            .prefix(limit))
    }

    func move(_ direction: Direction) {
        if !shelves.isEmpty { return moveAcross(direction) }
        guard let selectedID, let index = candidates.firstIndex(of: selectedID) else { return }
        show()
        let next: Int
        switch direction {
        case .left: next = (index - 1 + candidates.count) % candidates.count
        case .right: next = (index + 1) % candidates.count
        case .up:
            guard index >= 5 else { return }
            next = index - 5
        case .down:
            guard index < 5, candidates.count > 5 else { return }
            next = min(index + 5, candidates.count - 1)
        }
        self.selectedID = candidates[next]
    }

    /// With spaces: along the row and round, or up and down into the space
    /// above or below, at the same place in its row or its last card.
    private func moveAcross(_ direction: Direction) {
        guard let selectedID, let at = shelves.firstIndex(where: { $0.ids.contains(selectedID) }),
              let index = shelves[at].ids.firstIndex(of: selectedID)
        else { return }
        show()
        let ids = shelves[at].ids
        switch direction {
        case .left: self.selectedID = ids[(index - 1 + ids.count) % ids.count]
        case .right: self.selectedID = ids[(index + 1) % ids.count]
        case .up, .down:
            let to = at + (direction == .up ? -1 : 1)
            guard shelves.indices.contains(to) else { return }
            let there = shelves[to].ids
            self.selectedID = there[min(index, there.count - 1)]
        }
    }

    func finish(picking id: Tab.ID? = nil) -> Tab.ID? {
        let target = id ?? selectedID
        let valid = target.flatMap { shown.contains($0) ? $0 : nil }
        cancel()
        return valid
    }

    func cancel() {
        guard active || reveal != nil || visible else { return }
        reveal?.cancel()
        reveal = nil
        generation = UUID()
        candidates = []
        shelves = []
        selectedID = nil
        visible = false
        prune { kept($0) }
        previewRequested = false
    }

    /// Whether a tab's picture is kept between gestures: one of the ten tabs
    /// left last. Pictures are only ever kept in memory, never on disk.
    private func kept(_ id: Tab.ID) -> Bool {
        recentIDs.prefix(10).contains(id)
    }

    /// Turned off: nothing kept, not the order and not the pictures.
    func reset() {
        cancel()
        recentIDs = []
        previewRequests = [:]
        if !previews.isEmpty { previews = [:] }
    }

    /// Only the pictures of tabs in `keep`, and nothing published when
    /// nothing goes.
    private func prune(to keep: (Tab.ID) -> Bool) {
        previewRequests = previewRequests.filter { keep($0.key) }
        if previews.keys.contains(where: { !keep($0) }) { previews = previews.filter { keep($0.key) } }
    }

    func preview(for id: Tab.ID, address: URL?) -> NSImage? {
        guard let cached = previews[id], cached.address == address else { return nil }
        return cached.image
    }

    func cachePreview(_ image: NSImage, for id: Tab.ID, address: URL) {
        guard kept(id) || (visible && shown.contains(id)) else { return }
        previews[id] = (address, image)
    }

    func capturePreviews(from tabs: [Tab], current: Tab.ID?) {
        guard visible, !previewRequested else { return }
        previewRequested = true
        let token = generation
        let orderedIDs = [selectedID].compactMap { $0 } + shown.filter { $0 != selectedID }
        let ordered = orderedIDs.compactMap { id in tabs.first { $0.id == id } }
            .filter { $0.id == current || preview(for: $0.id, address: $0.address) == nil }
        for (index, tab) in ordered.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.04) { [weak self, weak tab] in
                guard let self, let tab, self.generation == token, self.visible else { return }
                guard tab.id == current || self.preview(for: tab.id, address: tab.address) == nil else { return }
                self.requestPreview(of: tab, gesture: token)
            }
        }
    }

    private func requestPreview(of tab: Tab, gesture: UUID?) {
        guard let address = tab.address else { return }
        let id = tab.id
        let request = UUID()
        previewRequests[id] = request
        tab.preview(width: 180) { [weak self, weak tab] image in
            guard let self, self.previewRequests[id] == request else { return }
            self.previewRequests[id] = nil
            guard let tab, let image, tab.address == address,
                  gesture == nil || (self.generation == gesture && self.visible)
            else { return }
            self.cachePreview(image, for: id, address: address)
        }
    }

    private func show() {
        guard active, !visible else { return }
        reveal?.cancel()
        reveal = nil
        previews = previews.filter { shown.contains($0.key) }
        visible = true
    }
}

/// The switcher stays in the browser window, above its page and address field.
struct TabSwitcherOverlay: View {
    @ObservedObject var browser: Browser
    @ObservedObject var switcher: TabSwitcher
    @Namespace private var pick

    var body: some View {
        if switcher.visible {
            GeometryReader { geometry in
                let columns = min(5, switcher.candidates.count)
                let width = min(176, (geometry.size.width - 64 - CGFloat(columns - 1) * 8) / CGFloat(columns))
                let previewHeight = (width - 16) * 0.62
                let cardHeight = previewHeight + 39
                ZStack {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .onTapGesture { switcher.cancel() }

                    Group {
                        if switcher.shelves.isEmpty {
                        ZStack(alignment: .topLeading) {
                            if let selected = switcher.selectedID,
                               let index = switcher.candidates.firstIndex(of: selected) {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Palette.faint)
                                    .frame(width: width, height: cardHeight)
                                    .offset(
                                        x: CGFloat(index % 5) * (width + 8),
                                        y: CGFloat(index / 5) * (cardHeight + 8)
                                    )
                                    .animation(Motion.glide, value: switcher.selectedID)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(0..<((switcher.candidates.count + 4) / 5), id: \.self) { row in
                                    HStack(spacing: 8) {
                                        ForEach(Array(switcher.candidates.dropFirst(row * 5).prefix(5)), id: \.self) { id in
                                            if let tab = browser.tabs.first(where: { $0.id == id }) {
                                                card(tab, width: width, previewHeight: previewHeight, height: cardHeight)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        } else {
                            shelved(in: geometry.size)
                        }
                    }
                    .padding(12)
                    .background(Palette.ground, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .task(id: switcher.selectedID) {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                switcher.capturePreviews(from: browser.tabs + browser.parkedTabs, current: browser.activeID)
            }
        }
    }

    /// With spaces: a row for each, under the space's icon and name, the
    /// name in full ink on the row the pick is in. Cards shrink to keep every
    /// row in the window rather than scrolling any out of it.
    private func shelved(in size: CGSize) -> some View {
        let rows = CGFloat(switcher.shelves.count)
        let across = (size.width - 64 - 4 * 8) / 5
        // Each row also carries its name, 24 points, and 10 between rows.
        let down = ((size.height - 88 - (rows - 1) * 10) / rows - 24 - 39) / 0.62 + 16
        let width = max(96, min(176, across, down))
        let previewHeight = (width - 16) * 0.62
        let cardHeight = previewHeight + 39
        let everyone = browser.tabs + browser.parkedTabs
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(switcher.shelves) { shelf in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: shelf.space.symbol)
                            .font(.system(size: 10, weight: .medium))
                        Text(shelf.space.name)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(switcher.selectedID.map(shelf.ids.contains) == true ? Palette.ink : Palette.muted)
                    .frame(height: 18)
                    .padding(.leading, 8)
                    HStack(spacing: 8) {
                        ForEach(shelf.ids, id: \.self) { id in
                            if let tab = everyone.first(where: { $0.id == id }) {
                                card(tab, width: width, previewHeight: previewHeight, height: cardHeight)
                                    .background {
                                        if id == switcher.selectedID {
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(Palette.faint)
                                                .matchedGeometryEffect(id: "pick", in: pick)
                                        }
                                    }
                            }
                        }
                    }
                }
            }
        }
        .animation(Motion.glide, value: switcher.selectedID)
    }

    private func card(_ tab: Tab, width: CGFloat, previewHeight: CGFloat, height: CGFloat) -> some View {
        Button { browser.commitTabSwitch(picking: tab.id) } label: {
            VStack(spacing: 7) {
                ZStack {
                    Palette.hover
                    if let preview = switcher.preview(for: tab.id, address: tab.address) {
                        Image(nsImage: preview)
                            .resizable()
                            .scaledToFill()
                            .frame(width: width - 16, height: previewHeight)
                            .clipped()
                    } else {
                        Mark(icon: browser.prefs.glyph == .icons ? tab.icon : nil, letter: tab.monogram, size: 26)
                    }
                }
                .frame(width: width - 16, height: previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: 5))

                HStack(spacing: 6) {
                    if browser.prefs.glyph == .icons, !tab.isBlank {
                        Mark(icon: tab.icon, letter: tab.monogram, size: 13)
                    }
                    Text(tab.label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(width: width, height: height, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Switch to \(tab.label)")
        .accessibilityValue(tab.id == switcher.selectedID ? "Selected" : "")
    }
}
