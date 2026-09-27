import SwiftUI

/// One tab-row position shared by both halves of a split pair.
struct SplitTabItem: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var left: Tab
    @ObservedObject var right: Tab
    let width: CGFloat?
    let height: CGFloat
    let live: Bool
    var focusedID: Tab.ID? = nil
    let interactive: Bool

    var body: some View {
        HStack(spacing: 0) {
            half(left)
            Rectangle()
                .fill(Palette.ink.opacity(0.14))
                .frame(width: 1)
                .padding(.vertical, 6)
            half(right)
        }
        .frame(width: width, height: height)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(live ? Palette.wash : Palette.ground.opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Palette.hairline.opacity(live ? 1 : 0.75), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split tabs")
    }

    private func half(_ tab: Tab) -> some View {
        SplitTabHalf(
            browser: browser,
            prefs: prefs,
            tab: tab,
            focused: live && (focusedID ?? browser.activeID) == tab.id,
            height: height,
            interactive: interactive
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SplitTabHalf: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let focused: Bool
    let height: CGFloat
    let interactive: Bool

    @State private var hovering = false

    private var title: String { tab.label.isEmpty ? "New Tab" : tab.label }
    private var playing: Bool { !tab.loading && (tab.noisy || tab.muted) }
    private var editing: Bool { browser.editingTab == tab.id }

    var body: some View {
        decoratedRow
            .modifier(OneClick(double: false) {
                guard interactive else { return }
                if focused { browser.beginTabEdit(tab) }
                else { browser.focusPane(tab) }
            })
            .overlay {
                if interactive { MiddleClick { browser.close(tab) } }
            }
            .onHover { hovering = $0 }
            .contextMenu {
                if interactive { TabMenu(browser: browser, tab: tab, close: { browser.close(tab) }) }
            }
            .background {
                if interactive && browser.prefs.splitView {
                    SplitDropZone(browser: browser, tab: tab, kind: .strip)
                }
            }
            .accessibilityElement(children: editing ? .contain : .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(focused ? "Focused pane" : "")
            .accessibilityHint(interactive ? "Click to focus this pane; right-click for tab actions" : "")
            .accessibilityAction(named: "Focus pane") { browser.focusPane(tab) }
            .accessibilityAction(named: "Close tab") { if interactive { browser.close(tab) } }
            .help(title)
    }

    private var decoratedRow: some View {
        row
            .padding(.leading, 7)
            .padding(.trailing, 4)
            .frame(height: height)
            .background {
                Rectangle().fill(focused ? Palette.ink.opacity(0.055) : .clear)
            }
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5)
                        .padding(1)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
    }

    private var row: some View {
        HStack(spacing: 4) {
            titleContent
            Spacer(minLength: 0)
            if !editing {
                status
                if interactive { closeButton }
            }
        }
    }

    @ViewBuilder
    private var titleContent: some View {
        if editing {
            TabAddressField(browser: browser)
                .frame(height: 16)
        } else {
            HStack(spacing: 4) {
                Mark(icon: prefs.glyph == .icons ? tab.icon : nil,
                     letter: tab.monogram, size: 13, dim: tab.asleep)
                    .frame(width: 13, height: 13)
                if tab.shy {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.muted)
                }
                Text(title)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(focused ? Palette.ink : Palette.muted)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if playing {
            Speaker(tab: tab)
                .padding(.trailing, hovering ? 3 : 0)
        } else if tab.loading {
            Ring(size: 10)
                .padding(.trailing, 3)
        }
    }

    private var closeButton: some View {
        Image(systemName: "xmark")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .frame(width: 14, height: 14)
            .background(hovering ? Palette.ink.opacity(0.07) : .clear, in: Circle())
            .opacity(hovering ? 1 : 0)
            .overlay {
                CloseClick(armed: hovering) { browser.close(tab) }
                    .frame(width: 26, height: height)
            }
    }
}
