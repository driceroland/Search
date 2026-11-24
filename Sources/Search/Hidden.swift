import SwiftUI

/// What you have taken off this site, and the way back.
///
/// A list of selectors is not something anyone can read. So resting the pointer
/// on a row puts that one thing back on the page, outlined, and scrolls to it —
/// you decide what to restore by looking at it, not by decoding its name.
struct HiddenPanel: View {
    @ObservedObject var browser: Browser
    /// The list itself, watched too: a row restored leaves it at once rather
    /// than when the browser next changes (idea 1064).
    @ObservedObject private var curtain: Curtain

    init(browser: Browser) {
        self.browser = browser
        self.curtain = browser.curtain
    }

    /// Where the panel opens: the top left when more of what was hidden here
    /// sat on the right of the page, as noted when it was hidden, so the
    /// panel isn't over the very thing a row brings back; else the top right.
    static func leading(for veils: [Veil]) -> Bool {
        let sides = veils.compactMap { $0.note?.split(separator: " ").last }
        return sides.filter { $0 == "right" }.count > sides.filter { $0 == "left" }.count
    }

    var body: some View {
        Plate(browser.hereHost ?? "This page", width: 380, close: { browser.reviewing = false }) {
            if browser.hereVeils.isEmpty {
                Card { Nothing("Nothing is hidden here.") }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Caption("Hidden on this site — rest on a line to see it")
                    ScrollView(showsIndicators: false) {
                        Card {
                            ForEach(Array(browser.hereVeils.enumerated()), id: \.element.id) { index, veil in
                                if index > 0 { Rule() }
                                Row(
                                    veil: veil,
                                    peek: { browser.peek(veil) },
                                    restore: { browser.restore(veil) }
                                )
                            }
                        }
                        .padding(.bottom, 2)
                    }
                    .frame(maxHeight: 320)
                }
            }
        } foot: {
            HStack(spacing: 8) {
                Pill("Hide something…", filled: true) { browser.toggleHiding() }
                    .shortcutHelp("Hide Something", "view.hide")
                if !browser.hereVeils.isEmpty {
                    Pill("Restore all") { browser.restoreAll() }
                }
                Spacer()
            }
        }
        // Leaving the panel puts the page back the way it was.
        .onHover { inside in
            if !inside { browser.stopPeeking() }
        }
    }

    private struct Row: View {
        let veil: Veil
        let peek: () -> Void
        let restore: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(veil.label)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let note = veil.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)

                Quick("Restore", act: restore)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { peek() }
            }
            .animation(Motion.quick, value: hovering)
        }
    }
}

/// The panel in its place over the page: a top corner (see
/// HiddenPanel.leading), or wherever it was last dragged in this window.
/// A drag anywhere on it moves it, kept inside the window.
struct HiddenPanelPlace: View {
    @ObservedObject var browser: Browser
    /// The corner picked as it opened, kept while it is up: restoring rows
    /// mustn't send it across the window.
    @State private var opened: Bool
    @State private var drag: CGSize = .zero

    struct Spot { var leading: Bool; var offset: CGSize }

    private static let width: CGFloat = 380, margin: CGFloat = 14

    init(browser: Browser) {
        self.browser = browser
        _opened = State(initialValue: HiddenPanel.leading(for: browser.hereVeils))
    }

    var body: some View {
        GeometryReader { room in
            let spot = browser.hiddenPanelSpot ?? Spot(leading: opened, offset: .zero)
            HiddenPanel(browser: browser)
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .onChanged { drag = $0.translation }
                        .onEnded { end in
                            browser.hiddenPanelSpot = Spot(leading: spot.leading,
                                                           offset: Self.kept(spot, moved: end.translation, in: room.size))
                            drag = .zero
                        }
                )
                .offset(Self.kept(spot, moved: drag, in: room.size))
                .padding(.top, Metrics.strip + 8)
                .padding(spot.leading ? .leading : .trailing, Self.margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: spot.leading ? .topLeading : .topTrailing)
        }
    }

    /// The offset from its corner, moved, with the panel still in the room:
    /// across to the other edge at most, and its top never above the strip
    /// nor lower than a title's height from the bottom.
    static func kept(_ spot: Spot, moved: CGSize, in room: CGSize) -> CGSize {
        let across = max(0, room.width - width - 2 * margin)
        let x = spot.offset.width + moved.width, y = spot.offset.height + moved.height
        return CGSize(width: spot.leading ? min(max(x, 0), across) : min(max(x, -across), 0),
                      height: min(max(y, -Metrics.strip), max(0, room.height - Metrics.strip - 8 - 60)))
    }
}
