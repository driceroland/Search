import SwiftUI

/// What you have taken off this site, and the way back.
///
/// A list of selectors is not something anyone can read. So resting the pointer
/// on a row puts that one thing back on the page, outlined, and scrolls to it —
/// you decide what to restore by looking at it, not by decoding its name.
struct HiddenPanel: View {
    @ObservedObject var browser: Browser

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
