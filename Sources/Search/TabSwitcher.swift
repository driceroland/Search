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

    /// A pair's other page, by its first: the pair is one card, with both
    /// pages pictured side by side (see Browser.switchTabs).
    var partners: [Tab.ID: Tab.ID] = [:]

    /// Where the panel and each card are in the window, for the pointer to be
    /// matched against (see `hover(at:)` and Browser.clickTabSwitcher). From
    /// #358, by oddharsh.
    var panelFrame: CGRect = .zero
    var cardFrames: [Tab.ID: CGRect] = [:]
    /// Where the pointer was when the panel first felt it, and whether it has
    /// gone anywhere since.
    private var rest: CGPoint?
    private var moved = false

    /// The pointer over the panel picks the card under it, once it has moved.
    /// The panel comes up wherever the pointer happens to be, and a card that
    /// lands under a still pointer would otherwise take the pick from the keys
    /// before anyone reached for the mouse.
    func hover(at point: CGPoint) {
        guard visible else { return }
        if !moved {
            guard let rest else { return self.rest = point }
            guard abs(point.x - rest.x) + abs(point.y - rest.y) > 2 else { return }
            moved = true
        }
        if let id = card(at: point), id != selectedID { selectedID = id }
    }

    /// The card at a point in the window, if any.
    func card(at point: CGPoint) -> Tab.ID? {
        cardFrames.first { $0.value.contains(point) && candidates.contains($0.key) }?.key
    }

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
    func step(row: [Tab.ID], current: Tab.ID, backwards: Bool) {
        if candidates.isEmpty {
            let valid = Set(row)
            guard valid.contains(current) else { return }
            var seen: Set<Tab.ID> = []
            candidates = Array(([current] + recentIDs + row)
                .filter { valid.contains($0) && seen.insert($0).inserted }
                .prefix(10))
            guard candidates.count > 1 else {
                candidates = []
                return
            }
            selectedID = backwards ? candidates.last : candidates[1]
            let work = DispatchWorkItem { [weak self] in self?.show() }
            reveal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            return
        }

        guard let selectedID, let index = candidates.firstIndex(of: selectedID) else { return }
        let next = (index + (backwards ? -1 : 1) + candidates.count) % candidates.count
        self.selectedID = candidates[next]
        show()
    }

    func move(_ direction: Direction) {
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

    func finish(picking id: Tab.ID? = nil) -> Tab.ID? {
        let target = id ?? selectedID
        let valid = target.flatMap { candidates.contains($0) ? $0 : nil }
        cancel()
        return valid
    }

    func cancel() {
        guard active || reveal != nil || visible else { return }
        reveal?.cancel()
        reveal = nil
        generation = UUID()
        candidates = []
        selectedID = nil
        visible = false
        panelFrame = .zero
        cardFrames = [:]
        rest = nil
        moved = false
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
        partners = [:]
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
        let shown = candidates.contains(id) || candidates.contains { partners[$0] == id }
        guard kept(id) || (visible && shown) else { return }
        previews[id] = (address, image)
    }

    func capturePreviews(from tabs: [Tab], current: Tab.ID?) {
        guard visible, !previewRequested else { return }
        previewRequested = true
        let token = generation
        let firsts = [selectedID].compactMap { $0 } + candidates.filter { $0 != selectedID }
        let orderedIDs = firsts.flatMap { id in [id] + [partners[id]].compactMap { $0 } }
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
        let seconds = Set(candidates.compactMap { partners[$0] })
        previews = previews.filter { key, _ in candidates.contains(key) || seconds.contains(key) }
        visible = true
    }
}

/// The switcher stays in the browser window, above its page and address field.
struct TabSwitcherOverlay: View {
    @ObservedObject var browser: Browser
    @ObservedObject var switcher: TabSwitcher

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
                    .padding(12)
                    .background(Palette.ground, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline))
                    .background(GeometryReader { box in
                        Color.clear.preference(key: PanelFrame.self, value: box.frame(in: .global))
                    })
                    .onPreferenceChange(PanelFrame.self) { frame in
                        MainActor.assumeIsolated { switcher.panelFrame = frame }
                    }
                    .onPreferenceChange(CardFrames.self) { frames in
                        MainActor.assumeIsolated { switcher.cardFrames = frames }
                    }
                    .onContinuousHover(coordinateSpace: .global) { phase in
                        if case .active(let point) = phase { switcher.hover(at: point) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .task(id: switcher.selectedID) {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                switcher.capturePreviews(from: browser.tabs, current: browser.activeID)
            }
        }
    }

    /// Where the panel is, and each card by its tab, in the window's own
    /// top-left coordinates, the ones a click is turned into.
    private struct PanelFrame: PreferenceKey {
        static let defaultValue: CGRect = .zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            let next = nextValue()
            if next != .zero { value = next }
        }
    }

    private struct CardFrames: PreferenceKey {
        static let defaultValue: [Tab.ID: CGRect] = [:]
        static func reduce(value: inout [Tab.ID: CGRect], nextValue: () -> [Tab.ID: CGRect]) {
            value.merge(nextValue()) { $1 }
        }
    }

    private func picture(_ tab: Tab, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Palette.hover
            if let preview = switcher.preview(for: tab.id, address: tab.address) {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                Mark(icon: browser.prefs.glyph == .icons ? tab.icon : nil, letter: tab.monogram, size: 26)
            }
        }
        .frame(width: width, height: height)
    }

    private func card(_ tab: Tab, width: CGFloat, previewHeight: CGFloat, height: CGFloat) -> some View {
        let partner: Tab? = switcher.partners[tab.id].flatMap { id in browser.tabs.first { $0.id == id } }
        let caption: String = partner.map { tab.label + " · " + $0.label } ?? tab.label
        let side: CGFloat = partner == nil ? width - 16 : (width - 18) / 2
        return Button { browser.commitTabSwitch(picking: tab.id) } label: {
            VStack(spacing: 7) {
                // A pair: its two pages side by side, as on screen.
                HStack(spacing: 2) {
                    picture(tab, width: side, height: previewHeight)
                    if let partner {
                        picture(partner, width: side, height: previewHeight)
                    }
                }
                .frame(width: width - 16, height: previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: 5))

                HStack(spacing: 6) {
                    if browser.prefs.glyph == .icons, !tab.isBlank {
                        Mark(icon: tab.icon, letter: tab.monogram, size: 13)
                    }
                    Text(caption)
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
        .background(GeometryReader { box in
            Color.clear.preference(key: CardFrames.self, value: [tab.id: box.frame(in: .global)])
        })
        .accessibilityLabel("Switch to \(tab.label)")
        .accessibilityValue(tab.id == switcher.selectedID ? "Selected" : "")
    }
}
