import SwiftUI

/// ⌃Tab: the tabs of the space on screen as pictures, the one you are on
/// first and then the ones you last left, latest first: the planet. The
/// small windows sit beside it as its moons. From a small window it is the
/// same picture, walked from the moon you are on. One gesture's order stays
/// fixed until ⌃ is let go of, so walking it does not rearrange what is
/// being walked.
@MainActor
final class TabSwitcher: ObservableObject {
    enum Direction { case left, right, up, down }

    /// A letter pressed with ⌃ still held, on the card picked: what its ⌘
    /// key does to the tab on screen, done to that card instead. Only with
    /// Settings › Tabs › Keys in the tab switcher on.
    enum Action {
        /// ⌃W: closed as ⌘W closes it (a pin is put down); a small window closed.
        case close
        /// ⌃R: its page loaded again.
        case reload
        /// ⌃M: its sound off, or on again.
        case mute
        /// ⌃O: a small window into the row, as its Open in Search.
        case keep

        init?(_ event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .control else { return nil }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w": self = .close
            case "r": self = .reload
            case "m": self = .mute
            case "o": self = .keep
            default: return nil
            }
        }
    }

    /// The tabs left, latest first, in every space: going back to a space
    /// finds its order where it was. Kept only while the switcher is on.
    private var recentIDs: [Tab.ID] = []
    @Published private(set) var candidates: [Tab.ID] = []
    /// The small windows (Little.swift), the one in front first: out of the
    /// grid, beside it, as a moon is beside its planet. They aren't the
    /// row's, and picking one brings its window forward and leaves the row
    /// as it was.
    @Published private(set) var moons: [Tab.ID] = []
    static let maxMoons = 9
    /// Up to three to a column, and the columns even: four moons are two
    /// and two, not three and one.
    var moonColumns: Int { (moons.count + 2) / 3 }
    var moonsPerColumn: Int { moonColumns == 0 ? 0 : (moons.count + moonColumns - 1) / moonColumns }
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
    var moonsFrame: CGRect = .zero
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
        cardFrames.first { $0.value.contains(point) && ring.contains($0.key) }?.key
    }

    /// A click while the panel is up, at a point in the window's top-left
    /// coordinates: on a card, that card is picked; outside the panel, the
    /// switcher goes. True when the click was the switcher's.
    func click(at point: CGPoint, pick: (Tab.ID) -> Void) -> Bool {
        guard visible else { return false }
        guard panelFrame.contains(point) || moonsFrame.contains(point) else {
            cancel()
            return true
        }
        // Between two cards: the switcher's, and nothing happens.
        if let id = card(at: point) { pick(id) }
        return true
    }

    /// The card the gesture started on: the tab on screen, or the small
    /// window the keys were in. The switcher shows over its window.
    private(set) var home: Tab.ID?
    /// Walked from a small window: its moons come first, then the planet.
    private var moonsLead = false

    /// Every card in the order ⌃Tab walks them: the grid, then its moons,
    /// or the moons first when the gesture started on one.
    private var ring: [Tab.ID] { moonsLead ? moons + candidates : candidates + moons }

    private var previewRequests: [Tab.ID: UUID] = [:]
    private var reveal: DispatchWorkItem?
    private var previewRequested = false
    private var generation = UUID()
    var active: Bool { home != nil }

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
    /// next comes back again. ⇧ starts from the far end, which is the last
    /// moon when there are any: the walk is one ring, grid then moons.
    func step(row: [Tab.ID], current: Tab.ID, backwards: Bool, moons: [Tab.ID] = []) {
        guard active else {
            guard row.contains(current) else { return }
            let planet = ordered(row: row, current: current)
            begin(home: current, planet: planet, moons: moons.filter { !planet.contains($0) },
                  moonsLead: false, backwards: backwards)
            return
        }
        walk(backwards: backwards)
    }

    /// ⌃Tab in a small window: the same planet and moons, the moons first,
    /// from the one the keys are in. A quick press goes back to the small
    /// window last left, and walking on goes out to the tabs. `planet` comes
    /// in its own order, the browser's (see `ordered`).
    func step(fromMoon moon: Tab.ID, moons: [Tab.ID], planet: [Tab.ID], backwards: Bool) {
        guard active else {
            guard moons.contains(moon) else { return }
            var seen: Set<Tab.ID> = []
            let latest = ([moon] + recentIDs + moons).filter { moons.contains($0) && seen.insert($0).inserted }
            begin(home: moon, planet: Array(planet.prefix(10)), moons: latest, moonsLead: true, backwards: backwards)
            return
        }
        walk(backwards: backwards)
    }

    /// A row's tabs as the grid shows them: the one on screen, the ones left
    /// latest first, then the rest in the row's order; ten at most.
    func ordered(row: [Tab.ID], current: Tab.ID?) -> [Tab.ID] {
        let valid = Set(row)
        var seen: Set<Tab.ID> = []
        return Array(([current].compactMap { $0 } + recentIDs + row)
            .filter { valid.contains($0) && seen.insert($0).inserted }
            .prefix(10))
    }

    private func begin(home: Tab.ID, planet: [Tab.ID], moons: [Tab.ID], moonsLead: Bool, backwards: Bool) {
        candidates = planet
        self.moons = Array(moons.prefix(Self.maxMoons))
        self.moonsLead = moonsLead
        // One tab and a small window is still somewhere to go.
        guard ring.count > 1, ring.first == home else {
            candidates = []
            self.moons = []
            self.moonsLead = false
            return
        }
        self.home = home
        selectedID = backwards ? ring.last : ring[1]
        let work = DispatchWorkItem { [weak self] in self?.show() }
        reveal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func walk(backwards: Bool) {
        let ring = ring
        guard let selectedID, let index = ring.firstIndex(of: selectedID) else { return }
        let next = (index + (backwards ? -1 : 1) + ring.count) % ring.count
        self.selectedID = ring[next]
        show()
    }

    /// Left and right go round the ring, grid and moons both; up and down
    /// stay in the grid's columns, or the moons' own.
    func move(_ direction: Direction) {
        let ring = ring
        guard let selectedID, let index = ring.firstIndex(of: selectedID) else { return }
        show()
        switch direction {
        case .left: self.selectedID = ring[(index - 1 + ring.count) % ring.count]
        case .right: self.selectedID = ring[(index + 1) % ring.count]
        case .up, .down:
            if let moon = moons.firstIndex(of: selectedID) {
                let per = moonsPerColumn
                let next = direction == .up ? moon - 1 : moon + 1
                // Within its own column.
                guard moons.indices.contains(next), next / per == moon / per else { return }
                self.selectedID = moons[next]
            } else if let card = candidates.firstIndex(of: selectedID) {
                if direction == .up {
                    guard card >= 5 else { return }
                    self.selectedID = candidates[card - 5]
                } else {
                    guard card < 5, candidates.count > 5 else { return }
                    self.selectedID = candidates[min(card + 5, candidates.count - 1)]
                }
            }
        }
    }

    /// A card closed from the switcher: out of the grid or the moons, and
    /// the pick on to the next one. The one the gesture started on closed
    /// ends it, as ⌘W there would; so does nowhere left to go.
    func remove(_ id: Tab.ID) {
        guard active else { return }
        guard id != home else { return cancel() }
        let before = ring
        guard let index = before.firstIndex(of: id) else { return }
        candidates.removeAll { $0 == id }
        moons.removeAll { $0 == id }
        cardFrames[id] = nil
        guard ring.count > 1 else { return cancel() }
        if selectedID == id { selectedID = before[(index + 1) % before.count] }
    }

    /// A card changed without the switcher's own lists changing (a tab
    /// muted from it): drawn again.
    func redraw() { objectWillChange.send() }

    func finish(picking id: Tab.ID? = nil) -> Tab.ID? {
        let target = id ?? selectedID
        let valid = target.flatMap { ring.contains($0) ? $0 : nil }
        cancel()
        return valid
    }

    func cancel() {
        guard active || reveal != nil || visible else { return }
        reveal?.cancel()
        reveal = nil
        generation = UUID()
        candidates = []
        moons = []
        home = nil
        moonsLead = false
        selectedID = nil
        visible = false
        panelFrame = .zero
        moonsFrame = .zero
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
        let shown = ring.contains(id) || candidates.contains { partners[$0] == id }
        guard kept(id) || (visible && shown) else { return }
        previews[id] = (address, image)
    }

    /// `tab`: a card's tab by its id, whether the row's or a small window's.
    func capturePreviews(of tab: (Tab.ID) -> Tab?, current: Tab.ID?) {
        guard visible, !previewRequested else { return }
        previewRequested = true
        let token = generation
        let firsts = [selectedID].compactMap { $0 } + ring.filter { $0 != selectedID }
        let orderedIDs = firsts.flatMap { id in [id] + [partners[id]].compactMap { $0 } }
        let ordered = orderedIDs.compactMap(tab)
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
        previews = previews.filter { key, _ in ring.contains(key) || seconds.contains(key) }
        visible = true
    }
}

/// The switcher stays in the window it came up in, above its page and
/// address field: a browser window, or a small window.
struct TabSwitcherOverlay: View {
    @ObservedObject var switcher: TabSwitcher
    @ObservedObject private var prefs = Shared.prefs
    /// A card's tab by its id: one of the row's, or a small window's.
    let tab: (Tab.ID) -> Tab?
    /// The tab on screen, whose picture is always taken fresh.
    let current: Tab.ID?
    /// Only over the window whose tab this is: the small windows share one
    /// switcher, and each has this over its page. None for a browser's,
    /// which has a switcher of its own.
    var host: Tab.ID?
    let pick: (Tab.ID) -> Void

    /// A moon's card beside a grid card, at its biggest: small, as the
    /// small window is.
    private static let moonScale: CGFloat = 0.62

    /// A moon's size by its page's length, as a moon's goes by its mass: a
    /// page one screen long is the smallest, sixteen screens or more fills
    /// the column, on a log scale between, so a 40-comment thread and a
    /// 400-comment one still differ. One whose page hasn't said is between.
    static func moonSize(screens: Double?) -> CGFloat {
        guard let screens else { return 0.8 }
        return 0.6 + 0.4 * CGFloat(min(1, max(0, log2(screens) / 4)))
    }

    var body: some View {
        if switcher.visible, host == nil || switcher.home == host {
            GeometryReader { geometry in
                let columns = min(5, switcher.candidates.count)
                let moonColumns = switcher.moonColumns
                // The moons' panel, its gap to the grid and its own padding,
                // come out of the room the grid's cards had.
                let moonRoom: CGFloat = moonColumns == 0 ? 0 : 14 + 16 + CGFloat(moonColumns - 1) * 6
                let width = min(176, (geometry.size.width - 64 - CGFloat(columns - 1) * 8 - moonRoom)
                    / (CGFloat(columns) + Self.moonScale * CGFloat(moonColumns)))
                let previewHeight = (width - 16) * 0.62
                let cardHeight = previewHeight + 39
                ZStack {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .onTapGesture { switcher.cancel() }

                    HStack(alignment: .center, spacing: 14) {
                        grid(width: width, previewHeight: previewHeight, cardHeight: cardHeight)
                        if moonColumns > 0 { moons(width: width * Self.moonScale, columns: moonColumns) }
                    }
                    // The grid's cards and the moons' both.
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
                switcher.capturePreviews(of: tab, current: current)
            }
        }
    }

    /// The planet: the tabs, five to a row.
    private func grid(width: CGFloat, previewHeight: CGFloat, cardHeight: CGFloat) -> some View {
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
                            if let tab = tab(id) {
                                card(tab, width: width, previewHeight: previewHeight, height: cardHeight)
                            }
                        }
                    }
                }
                if prefs.switcherKeys { legend }
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
    }

    /// The letters that act on the card picked while ⌃ is held (see
    /// TabSwitcher.Action), under the grid; Open in Search only on a moon.
    private var legend: some View {
        let moon = switcher.selectedID.map(switcher.moons.contains) == true
        let keys = [("W", "Close"), ("R", "Reload"), ("M", "Mute")] + (moon ? [("O", "Open in Search")] : [])
        return HStack(spacing: 14) {
            ForEach(keys, id: \.0) { key, name in
                HStack(spacing: 4) {
                    Text("⌃" + key).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.ink)
                    Text(name).font(.system(size: 10.5)).foregroundStyle(Palette.muted)
                }
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    /// The moons: the small windows, in a panel of their own beside the
    /// grid, in even columns, their cards smaller than a tab's and sized by
    /// their pages. `width` is a column's, the biggest a moon can be.
    private func moons(width: CGFloat, columns: Int) -> some View {
        let per = switcher.moonsPerColumn
        return HStack(alignment: .center, spacing: 6) {
            ForEach(0..<columns, id: \.self) { column in
                VStack(spacing: 6) {
                    ForEach(Array(switcher.moons.dropFirst(column * per).prefix(per)), id: \.self) { id in
                        if let tab = tab(id) {
                            let size = width * Self.moonSize(screens: tab.screens)
                            moon(tab, width: size, previewHeight: (size - 12) * 0.62)
                        }
                    }
                }
                .frame(width: width)
            }
        }
        .padding(8)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
        .background(GeometryReader { box in
            Color.clear.preference(key: MoonsFrame.self, value: box.frame(in: .global))
        })
        .onPreferenceChange(MoonsFrame.self) { frame in
            MainActor.assumeIsolated { switcher.moonsFrame = frame }
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

    private struct MoonsFrame: PreferenceKey {
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

    private func picture(_ tab: Tab, width: CGFloat, height: CGFloat, mark: CGFloat = 26) -> some View {
        ZStack {
            Palette.hover
            if let preview = switcher.preview(for: tab.id, address: tab.address) {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                Mark(icon: prefs.glyph == .icons ? tab.icon : nil, letter: tab.monogram, size: mark)
            }
        }
        .frame(width: width, height: height)
    }

    /// A card whose sound is off, as ⌃M leaves it.
    private var mutedMark: some View {
        Image(systemName: "speaker.slash.fill")
            .font(.system(size: 9.5))
            .foregroundStyle(Palette.muted)
            .accessibilityLabel("Muted")
    }

    private func card(_ tab: Tab, width: CGFloat, previewHeight: CGFloat, height: CGFloat) -> some View {
        let partner: Tab? = switcher.partners[tab.id].flatMap(self.tab)
        let caption: String = partner.map { tab.label + " · " + $0.label } ?? tab.label
        let side: CGFloat = partner == nil ? width - 16 : (width - 18) / 2
        return Button { pick(tab.id) } label: {
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
                    if prefs.glyph == .icons, !tab.isBlank {
                        Mark(icon: tab.icon, letter: tab.monogram, size: 13)
                    }
                    Text(caption)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if tab.muted || partner?.muted == true { mutedMark }
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

    /// A small window's card: its page under a thin line, as the window
    /// itself has one, and its title, which tells one thread of a site from
    /// the next where the site alone wouldn't.
    private func moon(_ tab: Tab, width: CGFloat, previewHeight: CGFloat) -> some View {
        let selected = tab.id == switcher.selectedID
        return Button { pick(tab.id) } label: {
            VStack(spacing: 5) {
                VStack(spacing: 0) {
                    Palette.hairline.frame(height: 5)
                    picture(tab, width: width - 12, height: previewHeight - 5, mark: 18)
                }
                .frame(width: width - 12, height: previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.hairline))

                HStack(spacing: 4) {
                    Text(tab.label)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    if tab.muted { mutedMark }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(6)
            .frame(width: width, alignment: .topLeading)
            .background(selected ? Palette.faint : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .animation(Motion.glide, value: selected)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background(GeometryReader { box in
            Color.clear.preference(key: CardFrames.self, value: [tab.id: box.frame(in: .global)])
        })
        .accessibilityLabel("Switch to the small window \(tab.label)")
        .accessibilityValue(selected ? "Selected" : "")
    }
}
