import SwiftUI

/// One Control+Tab gesture. Its candidate order stays fixed until Control is
/// released, so stepping does not rearrange the list it is stepping through.
@MainActor
final class TabSwitcher: ObservableObject {
    enum Direction { case left, right, up, down }

    private(set) var recentIDs: [Tab.ID] = []
    @Published private(set) var candidates: [Tab.ID] = []
    @Published private(set) var selectedID: Tab.ID?
    @Published private(set) var visible = false
    @Published private var previews: [Tab.ID: (address: URL, image: NSImage)] = [:]

    private var previewRequests: [Tab.ID: UUID] = [:]
    private var reveal: DispatchWorkItem?
    private var previewRequested = false
    private var generation = UUID()
    var active: Bool { !candidates.isEmpty }

    func record(_ id: Tab.ID) {
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
        if recentIDs.count > 10 { recentIDs.removeLast() }
        prune { recentIDs.contains($0) }
    }

    func step(eligible: [Tab.ID], current: Tab.ID, backwards: Bool) {
        if candidates.isEmpty {
            let valid = Set(eligible)
            guard valid.contains(current) else { return }
            var seen: Set<Tab.ID> = []
            candidates = Array(([current] + recentIDs + eligible)
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
        prune { recentIDs.contains($0) }
        previewRequested = false
    }

    func tabsChanged(eligible: [Tab.ID]) {
        if active { cancel() }
        let valid = Set(eligible)
        recentIDs.removeAll { !valid.contains($0) }
        prune { valid.contains($0) }
    }

    /// Keep the last view of a recently used tab, without retaining its web view
    /// or writing private-page images to disk.
    func rememberPreview(of tab: Tab) {
        guard recentIDs.contains(tab.id), !tab.bench, !tab.isBlank else { return }
        requestPreview(of: tab, gesture: nil)
    }

    func forgetPreview(of id: Tab.ID) {
        previewRequests[id] = nil
        if previews[id] != nil { previews[id] = nil }
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
        guard recentIDs.contains(id) || (visible && candidates.contains(id)) else { return }
        previews[id] = (address, image)
    }

    func capturePreviews(from tabs: [Tab], current: Tab.ID?) {
        guard visible, !previewRequested else { return }
        previewRequested = true
        let token = generation
        let orderedIDs = [selectedID].compactMap { $0 } + candidates.filter { $0 != selectedID }
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
        previews = previews.filter { candidates.contains($0.key) }
        visible = true
    }
}

/// The switcher stays in the browser window, above its page and address field.
struct TabSwitcherOverlay: View {
    @ObservedObject var browser: Browser
    @ObservedObject var switcher: TabSwitcher
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                                .animation(reduceMotion ? nil : Motion.glide, value: switcher.selectedID)
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
