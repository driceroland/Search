import SwiftUI

/// One tab, as a line in the column.
struct SideRow: View {
    @Environment(\.greys) private var greys
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab
    let live: Bool
    let pill: Namespace.ID
    let close: () -> Void
    var interactive = true

    @State private var hovering = false
    @State private var selectedOnPress = false
    @State private var shake: CGFloat = 0
    @State private var pressed = false

    private var editing: Bool { browser.editingTab == tab.id }

    /// The ring or the speaker, which stay for as long as the page loads or
    /// plays (or is muted) and so keep a place of their own at the end of the
    /// row. The cross is only there under the pointer, and takes none.
    private var status: Bool { !editing && (tab.loading || speaker) }
    /// The speaker, which can be pressed, and so steps in beside the cross
    /// under the pointer rather than hiding beneath it as the ring does.
    private var speaker: Bool { !tab.loading && (tab.noisy || tab.muted) }
    /// A pinned row with a peek opened from it: the peek's icon at its end,
    /// as on a square's corner.
    private var peeking: Bool { !editing && tab.pin != nil && browser.peekFrom == tab.id && browser.peekTab != nil }
    /// Where the page is, said on the row you're on (Settings › Tabs › Show
    /// the address on the tab you're on).
    private var rest: AtRest? { live && !editing ? AtRest.said(tab.restAddress, always: prefs.showsAddress) : nil }
    private var atRest: Bool { rest != nil }

    var body: some View {
        #if DEBUG
        let _ = Bench.count("row")
        #endif
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                if editing {
                    TabAddressField(browser: browser)
                        .frame(height: 16)
                } else {
                    if !tab.isBlank {
                        Mark(icon: tab.icon, size: prefs.roomyTabs ? 17 : 15)
                    }
                    if tab.bench {
                        // A script's tab, not yours.
                        Image(systemName: "flask")
                            .font(.system(size: 9))
                            .foregroundStyle(colour.opacity(0.7))
                    }
                    if tab.shy {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 9))
                            .foregroundStyle(colour.opacity(0.7))
                    }
                    if tab.recording {
                        // An extension recording from this page (RecordingIndicator).
                        Image(systemName: "record.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(colour.opacity(0.8))
                            .help("Recording")
                    }
                    // A window the page asked for was refused (BlockedPopups).
                    PopupSign(browser: browser, tab: tab, colour: colour)
                    // The page is translated (Translate.swift).
                    TranslateSign(tab: tab, colour: colour)
                    TitleAtRest(label: tab.label, rest: rest, shown: atRest, hovering: hovering,
                                size: prefs.sideTitle, colour: colour, roomy: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .padding(.trailing, status || peeking ? 0 : 10)
            .frame(height: prefs.sideRow)
            .contentShape(Rectangle())
            .modifier(TabPress(enabled: interactive && !editing, active: live, selected: $selectedOnPress, pressing: $pressed) {
                browser.clearTabSelection()
                browser.select(tab)
            })

            if peeking, let page = browser.peekTab {
                // Under the pointer the cross takes its place, unless the
                // ring or the speaker already holds the end of the row.
                PeekBadge(page: page, size: 16)
                    .opacity(hovering && !status ? 0 : 1)
            }

            if status {
                ZStack {
                    if tab.loading {
                        Ring().transition(.opacity)
                    } else {
                        Speaker(tab: tab).transition(.opacity)
                    }
                }
                .frame(width: 15, height: 15)
                // The cross takes this place while the pointer is here; the
                // speaker moves one place in, clear of the cross's reach.
                .opacity(hovering && !speaker ? 0 : 1)
                .padding(.trailing, hovering && speaker ? 23 : 0)
            }
        }
        .padding(.trailing, status || peeking ? 7 : 0)
        .frame(height: prefs.sideRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The title keeps its length under the pointer and fades out
        // beneath the cross, rather than being cut shorter, so its end
        // doesn't jump on each row the pointer passes.
        .mask {
            ZStack {
                Rectangle().opacity(hovering && !editing && !status ? 0 : 1)
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 16)
                    Color.clear.frame(width: 26)
                }
            }
        }
        .overlay(alignment: .trailing) {
            if !editing {
                ZStack {
                    if hovering, tab.pin == nil || browser.wandered(tab) {
                        // A pinned row isn't closed (see Browser.close): one
                        // that has wandered goes back to its pinned page.
                        Image(systemName: tab.pin != nil ? "arrow.uturn.backward" : "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                            .frame(width: 15, height: 15)
                            .background(Palette.ink.opacity(0.07), in: Circle())
                            .transition(.opacity)
                    }
                }
                .frame(width: 15, height: 15)
                .overlay {
                    Color.clear
                        .frame(width: 30, height: prefs.sideRow)
                        .contentShape(Rectangle())
                        .onTapGesture { if hovering, tab.pin == nil || browser.wandered(tab) { close() } }
                }
                .help(tab.pin != nil ? "Back to Pinned Page" : "")
                .padding(.trailing, 7)
            }
        }
        .animation(Motion.quick, value: tab.loading)
        .animation(Motion.quick, value: speaker)
        .animation(Motion.quick, value: tab.blockedPopups.isEmpty)
        .animation(Motion.quick, value: tab.translation == nil)
        .animation(Motion.quick, value: peeking)
        .background { ground.animation(Motion.quick, value: live) }
        .overlay {
            if browser.selectedTabIDs.contains(tab.id) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .modifier(Shake(travel: shake))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .modifier(OneClick(double: false) {
            guard interactive, !selectedOnPress, NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty else { return }
            browser.clearTabSelection()
            if live { browser.beginTabEdit(tab) } else { browser.select(tab) }
        })
        .modifier(ModifiedTabClick { if interactive && !editing { browser.extendTabSelection(to: tab, modifiers: $0) } })
        .overlay { if interactive { MiddleClick(act: close) } }
        .onHover(perform: hover)
        #if DEBUG
        .onAppear { if interactive { Bench.rowAppeared(tab.id, hover: hover) } }
        .onDisappear { if interactive { Bench.rowDisappeared(tab.id) } }
        #endif
        .contextMenu { if interactive { TabMenu(browser: browser, tab: tab, close: close) } }
        .background {
            if interactive {
                SplitDropZone(browser: browser, tab: tab, kind: .strip)
            }
        }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.glide, value: editing)
        .onChange(of: browser.refusals) { _, _ in
            guard editing else { return }
            shake = 0
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
        .transition(.scale(scale: 0.94, anchor: .leading).combined(with: .opacity))
    }

    private func hover(_ over: Bool) { hovering = over }

    @ViewBuilder
    private var ground: some View {
        if live {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(greys.wash)
                .matchedGeometryEffect(id: "live", in: pill)
        } else if browser.selectedTabIDs.contains(tab.id) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(greys.wash)
        } else if hovering {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(greys.hover)
        }
    }

    private var colour: Color {
        if live { return Palette.ink }
        return hovering ? Palette.ink.opacity(0.7) : Palette.muted
    }
}
