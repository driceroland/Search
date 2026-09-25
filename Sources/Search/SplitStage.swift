import SwiftUI

/// Two page hosts when there is room, or the focused page when there is not.
struct SplitStage: View {
    @ObservedObject var browser: Browser
    @State private var choosingTab = false

    static let minimumWidth: CGFloat = 560
    static let dividerWidth: CGFloat = 12

    var body: some View {
        GeometryReader { room in
            Group {
                if browser.prefs.splitViews, let pending = browser.pendingSplit,
                   let right = browser.tabs.first(where: { $0.id == pending }) {
                    HStack(spacing: 0) {
                        emptyPane(except: pending)
                            .frame(width: max(0, (room.size.width - Self.dividerWidth) / 2))
                        Rectangle().fill(Palette.hairline).frame(width: 4).frame(width: Self.dividerWidth)
                        Page(tab: right)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if room.size.width >= Self.minimumWidth,
                          let pair = browser.activePair,
                          let left = browser.tabs.first(where: { $0.id == pair.left }),
                          let right = browser.tabs.first(where: { $0.id == pair.right }) {
                    let fraction = shownFraction(pair.fraction, width: room.size.width)
                    HStack(spacing: 0) {
                        pane(left, side: .left)
                            .frame(width: max(0, (room.size.width - Self.dividerWidth) * fraction))
                        SplitDivider(browser: browser, pair: pair, width: room.size.width, shownFraction: fraction)
                        pane(right, side: .right)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if let tab = browser.active {
                    Page(tab: tab)
                } else {
                    Palette.ground
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { widthChanged(room.size.width) }
            .onChange(of: room.size.width) { _, width in widthChanged(width) }
        }
    }

    private func widthChanged(_ width: CGFloat) {
        let canShow = width >= Self.minimumWidth
        guard browser.splitCanShow != canShow else { return }
        browser.splitCanShow = canShow
        if canShow { browser.wakeSplitPartner() }
    }

    private func shownFraction(_ fraction: Double, width: CGFloat) -> Double {
        let floor = max(0.25, min(0.5, 260 / max(1, width - Self.dividerWidth)))
        return min(1 - floor, max(floor, fraction))
    }

    private func pane(_ tab: Tab, side: SplitSide) -> some View {
        Page(tab: tab)
            .overlay {
                Rectangle()
                    .strokeBorder(tab.id == browser.activeID ? Palette.ink.opacity(0.35) : Palette.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel("\(side == .left ? "Left" : "Right") split pane: \(tab.label)")
    }

    private func emptyPane(except right: Tab.ID) -> some View {
        ZStack(alignment: .bottom) {
            Button { choosingTab = true } label: {
                VStack(spacing: 12) {
                    Image(systemName: "square.split.2x1")
                        .font(.system(size: 24, weight: .ultraLight))
                    Text("Drag a tab here")
                        .font(.system(size: 13))
                    Text("Or click to choose a tab")
                        .font(.system(size: 12))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .popover(isPresented: $choosingTab, arrowEdge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(browser.tabs.filter { $0.id != right && !$0.bench }) { tab in
                            Button(tab.label) {
                                choosingTab = false
                                browser.finishSplit(with: tab.id)
                            }
                            .buttonStyle(.plain)
                            .padding(10)
                        }
                    }
                }
                .frame(minWidth: 180, maxHeight: 300)
                .padding(8)
            }
            .accessibilityLabel("Choose a tab for the left split pane")
            Button("Cancel") { browser.pendingSplit = nil }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .padding(.bottom, 22)
        }
        .foregroundStyle(Palette.muted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
        .contentShape(Rectangle())
        .onDrop(of: [SplitDrag.type], isTargeted: nil) { providers in
            return SplitDrag.receive(providers) { browser.finishSplit(with: $0) }
        }
    }
}

private struct SplitDivider: View {
    @ObservedObject var browser: Browser
    let pair: SplitPair
    let width: CGFloat
    let shownFraction: Double

    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(width: 4)
            .frame(width: SplitStage.dividerWidth)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if start == nil { start = shownFraction }
                    let floor = max(0.25, min(0.5, 260 / max(1, width - SplitStage.dividerWidth)))
                    let next = (start ?? shownFraction) + Double(value.translation.width / (width - SplitStage.dividerWidth))
                    browser.setSplitFraction(min(1 - floor, max(floor, next)), for: pair.id)
                }
                .onEnded { _ in
                    start = nil
                    let current = browser.splitPairs.first(where: { $0.id == pair.id })?.fraction ?? pair.fraction
                    browser.setSplitFraction(current, for: pair.id, save: true)
                })
            .help("Drag to resize split view")
            .onHover { over in
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .focusable()
            .accessibilityLabel("Split divider")
            .accessibilityValue("\(Int(shownFraction * 100)) percent left")
            .accessibilityAdjustableAction { direction in
                let floor = max(0.25, min(0.5, 260 / max(1, width - SplitStage.dividerWidth)))
                switch direction {
                case .increment: browser.setSplitFraction(min(1 - floor, shownFraction + 0.05), for: pair.id, save: true)
                case .decrement: browser.setSplitFraction(max(floor, shownFraction - 0.05), for: pair.id, save: true)
                @unknown default: break
                }
            }
    }
}
