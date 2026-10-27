import SwiftUI

/// A pair's one place in the row. In the column its pages are two lines, one
/// under the other, joined by a hairline: halves side by side in 232 points
/// would cut most titles to a dozen letters. Across the top they sit side by
/// side, with a single cross at the end for the half under the pointer — two
/// crosses next to each other are two chances to close the wrong page.
///
/// The page the keys go to wears the live grey, the same one that glides
/// from tab to tab, so it glides from one half to the other too.
///
/// The pair reads as one thing: a faint ground of its own under both halves
/// and an outline round them, with a fine line between the halves while
/// neither is lit. Two lit halves — the live one and the one under the
/// pointer — meet square where they touch, so the two greys join with no
/// notch between their corners.
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

    @Environment(\.greys) private var greys
    @State private var hovered: Tab.ID?

    private var stacked: Bool { width == nil }
    private var focused: Tab.ID? { live ? (focusedID ?? browser.activeID) : nil }

    var body: some View {
        Group {
            if stacked {
                VStack(spacing: 0) {
                    half(left, first: true)
                    half(right, first: false)
                }
                .overlay {
                    Rectangle()
                        .fill(Palette.hairline)
                        .frame(height: 1)
                        .padding(.horizontal, 10)
                        .opacity(lit(left) || lit(right) ? 0 : 1)
                        .allowsHitTesting(false)
                }
            } else {
                HStack(spacing: 0) {
                    half(left, first: true)
                    Rectangle()
                        .fill(Palette.hairline)
                        .frame(width: 1)
                        .padding(.vertical, 12)
                    half(right, first: false)
                }
                .frame(width: width, height: height)
                .overlay(alignment: .trailing) { cross }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(greys.tile)
                .padding(.vertical, stacked ? 0 : 6)
                .allowsHitTesting(false)
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

    /// A half wearing a grey: the live one, a selected one, the one under
    /// the pointer.
    private func lit(_ tab: Tab) -> Bool {
        focused == tab.id || hovered == tab.id || browser.selectedTabIDs.contains(tab.id)
    }

    private func half(_ tab: Tab, first: Bool) -> some View {
        SplitTabHalf(
            browser: browser,
            prefs: prefs,
            tab: tab,
            focused: focused == tab.id,
            stacked: stacked,
            first: first,
            joined: lit(first ? right : left),
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
                    CloseClick(armed: true) { browser.closeTab(tab) }
                        .frame(width: 30, height: 28)
                }
                .padding(.trailing, 7)
                .transition(.opacity)
                .help(tab.id == left.id ? "Close the left page" : "Close the right page")
        }
    }
}

private struct SplitTabHalf: View {
    @Environment(\.greys) private var greys
    @Environment(\.tabShortcutNumbers) private var shortcutNumbers
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let focused: Bool
    let stacked: Bool
    /// The top half in the column, the left one across the top.
    let first: Bool
    /// The other half is lit too: the corners where the two touch are square,
    /// so the greys meet without a notch.
    let joined: Bool
    let height: CGFloat
    /// Too narrow for a title: the mark alone, as a narrow tab has.
    let narrow: Bool
    let interactive: Bool
    let pill: Namespace.ID
    @Binding var hovered: Tab.ID?
    @State private var selectedOnPress = false

    private var hovering: Bool { hovered == tab.id }
    private var title: String { tab.label.isEmpty ? "New Tab" : tab.label }
    private var playing: Bool { !tab.loading && (tab.noisy || tab.muted) }
    private var editing: Bool { browser.editingTab == tab.id }
    /// Where the page is, said on the half you're on (Settings › Tabs › Show
    /// the address on the tab you're on).
    private var rest: AtRest? { focused && !editing && !narrow ? AtRest.said(tab.restAddress, always: prefs.showsAddress) : nil }
    private var atRest: Bool { rest != nil }

    private var laidOut: some View {
        row
            .padding(.leading, stacked ? 0 : 9)
            .padding(.trailing, stacked ? 7 : 4)
            .frame(height: stacked ? height : 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { ground.animation(Motion.quick, value: stacked && focused).animation(Motion.quick, value: joined) }
            .frame(height: height)
            .contentShape(Rectangle())
    }

    private var handled: some View {
        laidOut
            .modifier(OneClick(double: false) {
                guard interactive, !stacked || !selectedOnPress, NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty else { return }
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
                if interactive { MiddleClick { browser.closeTab(tab) } }
            }
            .onHover { over in
                if over { hovered = tab.id } else if hovered == tab.id { hovered = nil }
            }
            .contextMenu {
                if interactive { TabMenu(browser: browser, tab: tab, close: { browser.closeTab(tab) }) }
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
            .accessibilityAction(named: "Close tab") { if interactive { browser.closeTab(tab) } }
            .help(title)
    }

    /// The grey's shape: round, but square on the side it shares with the
    /// other half while that one is lit too.
    private var shape: UnevenRoundedRectangle {
        let round: CGFloat = 9
        let seam: CGFloat = joined ? 0 : round
        let radii: RectangleCornerRadii
        switch (stacked, first) {
        case (true, true): radii = .init(topLeading: round, bottomLeading: seam, bottomTrailing: seam, topTrailing: round)
        case (true, false): radii = .init(topLeading: seam, bottomLeading: round, bottomTrailing: round, topTrailing: seam)
        case (false, true): radii = .init(topLeading: round, bottomLeading: round, bottomTrailing: seam, topTrailing: seam)
        case (false, false): radii = .init(topLeading: seam, bottomLeading: seam, bottomTrailing: round, topTrailing: round)
        }
        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
    }

    @ViewBuilder
    private var ground: some View {
        if focused {
            ZStack(alignment: .leading) {
                Rectangle().fill(greys.wash)
                if prefs.showsReading, !narrow {
                    GeometryReader { geo in
                        ReadingFill(meter: tab.meter, width: geo.size.width)
                    }
                }
            }
            .clipShape(shape)
            .matchedGeometryEffect(id: "live", in: pill)
        } else if browser.selectedTabIDs.contains(tab.id) {
            shape.fill(greys.wash)
        } else if hovering {
            shape.fill(greys.hover)
        }
    }

    private var row: some View {
        HStack(spacing: stacked ? 8 : 5) {
            titleContent
                .padding(.leading, stacked ? 10 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: stacked ? height : 16)
                .contentShape(Rectangle())
                .modifier(TabPress(enabled: stacked && interactive && !editing, active: focused, selected: $selectedOnPress) {
                    browser.clearTabSelection()
                    browser.focusPane(tab)
                })
            if !editing {
                if interactive, let number = shortcutNumbers[tab.id] {
                    TabShortcutNumber(number: number)
                }
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
                if !narrow {
                    PopupSign(browser: browser, tab: tab)
                    TranslateSign(tab: tab)
                }
                // The page is asking something, over its half of the stage.
                if browser.paneQuestions.contains(where: { $0.tab == tab.id }) {
                    Circle()
                        .fill(Palette.muted)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("Asking a question")
                }
                if !narrow {
                    TitleAtRest(label: title, rest: rest, shown: atRest, hovering: hovering,
                                size: stacked ? prefs.sideTitle : 12,
                                colour: focused ? Palette.ink : hovering ? Palette.ink.opacity(0.7) : Palette.muted,
                                roomy: stacked)
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
                CloseClick(armed: hovering) { browser.closeTab(tab) }
                    .frame(width: 26, height: height)
            }
    }
}
