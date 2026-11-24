import SwiftUI

/// A row's place to drop a carried tab beside (SplitDropZone) and, when
/// `hint`, what dropping it onto the row would make (MergeHint).
struct SplitDropMarks: ViewModifier {
    let browser: Browser
    let tab: Tab
    let on: Bool
    var hint = true

    func body(content: Content) -> some View {
        content
            .background { if on { SplitDropZone(browser: browser, tab: tab, kind: .strip) } }
            .overlay { if on && hint { MergeHint(browser: browser, tab: tab) } }
    }
}

/// Over a tab in the column while another is held over its middle (see
/// TabMerge): the split letting go would make, drawn on the row itself. The
/// row is outlined as a pair is, and the half the carried tab would take,
/// left or right as the hand is, holds its mark and title. The hand moving
/// across the row moves that half with it, to the other side.
struct MergeHint: View {
    @ObservedObject var browser: Browser
    let tab: Tab
    @ObservedObject private var merge = TabMerge.shared
    @Environment(\.greys) private var greys

    private var shown: TabMerge.Shown? {
        guard let shown = merge.shown, shown.targetID == tab.id,
              shown.browserID == ObjectIdentifier(browser) else { return nil }
        return shown
    }

    var body: some View {
        GeometryReader { geometry in
            if let shown, let source = browser.tabs.first(where: { $0.id == shown.sourceID }) {
                let half = geometry.size.width / 2
                let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                // The row as the pair will be: the tab let go on keeps its
                // look, the one carried wears the live grey, as it will
                // have the keys.
                ZStack(alignment: .topLeading) {
                    Half(tab: tab, sideTitle: browser.prefs.sideTitle, carried: false)
                        .frame(width: half, height: geometry.size.height)
                        .offset(x: shown.onLeft ? half : 0)
                    Half(tab: source, sideTitle: browser.prefs.sideTitle, carried: true)
                        .frame(width: half, height: geometry.size.height)
                        .background(shape.fill(greys.wash))
                        .offset(x: shown.onLeft ? 0 : half)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .background(shape.fill(Palette.ground))
                .background(shape.fill(greys.tile))
                .overlay(shape.strokeBorder(Palette.ink.opacity(0.25), lineWidth: 1))
                .transition(.opacity)
                .animation(Motion.quick, value: shown.onLeft)
            }
        }
        .animation(Motion.quick, value: shown?.sourceID)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One tab, as it would stand in its half.
    private struct Half: View {
        @ObservedObject var tab: Tab
        let sideTitle: CGFloat
        let carried: Bool

        var body: some View {
            HStack(spacing: 8) {
                Mark(icon: tab.icon, letter: tab.monogram, size: 15, dim: tab.asleep)
                    .frame(width: 15, height: 15)
                Text(tab.label.isEmpty ? "New Tab" : tab.label)
                    .font(.system(size: sideTitle))
                    .foregroundStyle(carried ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
        }
    }
}
