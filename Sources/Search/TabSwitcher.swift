import SwiftUI
import AppKit

/// Arc-style floating HUD modal for Control + Tab tab switching.
/// Displays tabs in most-recently-used (LRU) order with real-time keyboard and mouse navigation.
struct TabSwitcherModal: View {
    @ObservedObject var browser: Browser
    @State private var hoveredIndex: Int?

    var body: some View {
        ZStack {
            // Subtle dimmed background over the entire window
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture {
                    browser.cancelTabSwitcher()
                }

            VStack(spacing: 0) {
                header
                Divider()
                    .background(Palette.hairline)
                tabList
            }
            .frame(width: 390)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Palette.ground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color.black.opacity(0.25), radius: 24, x: 0, y: 10)
            .padding(.bottom, 40)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        .transition(.opacity)
    }

    private var header: some View {
        let profile = browser.activeProfile
        return HStack(spacing: 7) {
            Image(systemName: profile.symbol)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(profile.color)

            Text(profile.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.ink)

            Text("•")
                .font(.system(size: 10))
                .foregroundStyle(Palette.muted)

            let openCount = browser.tabSwitcherIDs.count
            Text("\(openCount) \(openCount == 1 ? "pestaña" : "pestañas")")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)

            Spacer()

            Text("⌃Tab")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Palette.ink.opacity(0.06))
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var tabList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(Array(browser.tabSwitcherIDs.enumerated()), id: \.element) { index, id in
                        if let tab = browser.tabs.first(where: { $0.id == id }) {
                            TabSwitcherRow(
                                browser: browser,
                                tab: tab,
                                index: index,
                                isSelected: index == browser.tabSwitcherIndex,
                                isHovered: hoveredIndex == index
                            )
                            .id(id)
                            .onHover { hovering in
                                if hovering {
                                    hoveredIndex = index
                                    browser.tabSwitcherIndex = index
                                } else if hoveredIndex == index {
                                    hoveredIndex = nil
                                }
                            }
                            .onTapGesture {
                                browser.pickFromSwitcher(at: index)
                            }
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: min(CGFloat(browser.tabSwitcherIDs.count * 44 + 12), 360))
            .onChange(of: browser.tabSwitcherIndex) { _, newIndex in
                if newIndex >= 0 && newIndex < browser.tabSwitcherIDs.count {
                    withAnimation(Motion.quick) {
                        proxy.scrollTo(browser.tabSwitcherIDs[newIndex], anchor: .center)
                    }
                }
            }
        }
    }
}

/// A single tab row inside the TabSwitcherModal.
private struct TabSwitcherRow: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let index: Int
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        let profile = browser.activeProfile
        HStack(spacing: 10) {
            Mark(icon: tab.icon, letter: tab.monogram, size: 20)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(tab.label.isEmpty ? "New tab" : tab.label)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)

                let host = tab.address?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
                if !host.isEmpty {
                    Text(host)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if tab.pin != nil {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Palette.muted)
            }

            if tab.id == browser.activeID {
                Text("Actual")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(Palette.ink.opacity(0.05))
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? profile.color.opacity(0.18)
                        : (isHovered ? Palette.hover : .clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected ? profile.color.opacity(0.35) : .clear,
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
