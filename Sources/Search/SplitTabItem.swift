import SwiftUI

/// A pair's one place in the row. In the column its pages are two lines, one
/// under the other, joined by a hairline: halves side by side in 232 points
/// would cut most titles to a dozen letters. Across the top they sit side by
/// side, with a single cross at the end for the half under the pointer — two
/// crosses next to each other are two chances to close the wrong page.
///
/// The page the keys go to wears the live grey, the same one that glides
/// from tab to tab, so it glides from one half to the other too.
struct SplitTabItem: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var left: Tab
    @ObservedObject var right: Tab
    /// Across the top: the item's width. Nil in the column, which is as wide
    /// as the column.
    let width: CGFloat?
    /// One line's height in the column; the whole strip's across the top.
    let height: CGFloat
    let live: Bool
    var focusedID: Tab.ID? = nil
    let interactive: Bool
    let pill: Namespace.ID

    @State private var hovered: Tab.ID?

    private var stacked: Bool { width == nil }
    private var focused: Tab.ID? { live ? (focusedID ?? browser.activeID) : nil }

    var body: some View {
        Group {
            if stacked {
                VStack(spacing: 0) {
                    half(left)
                    half(right)
                }
            } else {
                HStack(spacing: 0) {
                    half(left)
                    Rectangle()
                        .fill(Palette.hairline)
                        .frame(width: 1)
                        .padding(.vertical, 12)
                    half(right)
                }
                .frame(width: width, height: height)
                .overlay(alignment: .trailing) { cross }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
                .padding(.vertical, stacked ? 0 : 6)
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split tabs")
        .animation(Motion.quick, value: hovered)
    }

    private func half(_ tab: Tab) -> some View {
        SplitTabHalf(
            browser: browser,
            prefs: prefs,
            tab: tab,
            focused: focused == tab.id,
            stacked: stacked,
            height: height,
            narrow: width.map { ($0 - 1) / 2 < 64 } ?? false,
            interactive: interactive,
            pill: pill,
            hovered: $hovered
        )
        .frame(maxWidth: .infinity, maxHeight: stacked ? height : .infinity)
    }

    /// Across the top: one cross, at the end of the item, for whichever half
    /// the pointer is over.
    @ViewBuilder
    private var cross: some View {
        if interactive, let id = hovered, let tab = [left, right].first(where: { $0.id == id }),
           browser.editingTab == nil {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(width: 15, height: 15)
                .background(Palette.ink.opacity(0.07), in: Circle())
                .overlay {
                    CloseClick(armed: true) { browser.close(tab) }
                        .frame(width: 30, height: 28)
                }
                .padding(.trailing, 7)
                .transition(.opacity)
                .help(tab.id == left.id ? "Close the left page" : "Close the right page")
        }
    }
}

private struct SplitTabHalf: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let focused: Bool
    let stacked: Bool
    let height: CGFloat
    /// Too narrow for a title: the mark alone, as a narrow tab has.
    let narrow: Bool
    let interactive: Bool
    let pill: Namespace.ID
    @Binding var hovered: Tab.ID?

    private var hovering: Bool { hovered == tab.id }
    private var title: String { tab.label.isEmpty ? "New Tab" : tab.label }
    private var playing: Bool { !tab.loading && (tab.noisy || tab.muted) }
    private var editing: Bool { browser.editingTab == tab.id }

    private var laidOut: some View {
        row
            .padding(.leading, stacked ? 10 : 9)
            .padding(.trailing, stacked ? 7 : 4)
            .frame(height: stacked ? height : 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { ground }
            .frame(height: height)
            .contentShape(Rectangle())
    }

    private var handled: some View {
        laidOut
            .modifier(OneClick(double: false) {
                guard interactive, NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty else { return }
                browser.clearTabSelection()
                if focused { browser.beginTabEdit(tab) }
                else { browser.focusPane(tab) }
            })
            .modifier(ModifiedTabClick {
                if interactive && !editing { browser.extendTabSelection(to: tab, modifiers: $0) }
            })
            .overlay {
                if browser.selectedTabIDs.contains(tab.id) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if interactive { MiddleClick { browser.close(tab) } }
            }
            .onHover { over in
                if over { hovered = tab.id } else if hovered == tab.id { hovered = nil }
            }
            .contextMenu {
                if interactive { TabMenu(browser: browser, tab: tab, close: { browser.close(tab) }) }
            }
            .background {
                if interactive && browser.prefs.splitView {
                    SplitDropZone(browser: browser, tab: tab, kind: .strip)
                }
            }
    }

    var body: some View {
        handled
            .accessibilityElement(children: editing ? .contain : .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(focused ? "Focused page" : "")
            .accessibilityHint(interactive ? "Click to focus this page; right-click for tab actions" : "")
            .accessibilityAction(named: "Focus page") { browser.focusPane(tab) }
            .accessibilityAction(named: "Close tab") { if interactive { browser.close(tab) } }
            .help(title)
    }

    @ViewBuilder
    private var ground: some View {
        if focused {
            ZStack(alignment: .leading) {
                Rectangle().fill(Palette.wash)
                if prefs.showsReading, !narrow {
                    GeometryReader { geo in
                        ReadingFill(meter: tab.meter, width: geo.size.width)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .matchedGeometryEffect(id: "live", in: pill)
        } else if browser.selectedTabIDs.contains(tab.id) {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.wash)
        } else if hovering {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Palette.hover)
        }
    }

    private var row: some View {
        HStack(spacing: stacked ? 8 : 5) {
            titleContent
            Spacer(minLength: 0)
            if !editing {
                status
                // In the column each line has its own cross at its own end,
                // one under the other; across the top the item has one.
                if interactive && stacked { closeButton }
            }
        }
    }

    @ViewBuilder
    private var titleContent: some View {
        if editing {
            TabAddressField(browser: browser)
                .frame(height: 16)
        } else {
            HStack(spacing: stacked ? 8 : 5) {
                if prefs.glyph == .icons || narrow {
                    Mark(icon: tab.icon, letter: tab.monogram, size: stacked ? 15 : 13, dim: tab.asleep)
                        .frame(width: stacked ? 15 : 13, height: stacked ? 15 : 13)
                }
                if tab.shy {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.muted)
                }
                // The page is asking something, over its half of the stage.
                if browser.paneQuestions.contains(where: { $0.tab == tab.id }) {
                    Circle()
                        .fill(Palette.muted)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("Asking a question")
                }
                if !narrow {
                    Text(title)
                        .font(.system(size: stacked ? 12.5 : 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(focused ? Palette.ink : hovering ? Palette.ink.opacity(0.7) : Palette.muted)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if playing {
            Speaker(tab: tab)
                .padding(.trailing, stacked && hovering ? 3 : 0)
        } else if tab.loading && !(stacked && hovering) {
            Ring(size: 10)
                .padding(.trailing, 3)
        }
    }

    private var closeButton: some View {
        Image(systemName: "xmark")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Palette.muted)
            .frame(width: 15, height: 15)
            .background(hovering ? Palette.ink.opacity(0.07) : .clear, in: Circle())
            .opacity(hovering ? 1 : 0)
            .overlay {
                CloseClick(armed: hovering) { browser.close(tab) }
                    .frame(width: 26, height: height)
            }
    }
}
