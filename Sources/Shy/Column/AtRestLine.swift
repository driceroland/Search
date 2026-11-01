import SwiftUI

/// The site, as the tab you're on says it at rest (AtRest.swift): the
/// subdomain dim and first to give way, the registrable domain in ink, a
/// port after it, and "Not secure" before a page that came over plain http.
struct AtRestLine: View {
    let rest: AtRest
    var size: CGFloat
    var ink: Color = Palette.ink
    var dim: Color = Palette.muted
    /// Across the top, where a tab is a few words wide: an open lock says
    /// "Not secure" in the room of one letter (the words are its tooltip),
    /// and the registrable domain alone stands for the host.
    var compact = false

    var body: some View {
        HStack(spacing: 0) {
            if rest.kind == .notSecure {
                if compact {
                    Image(systemName: "lock.open")
                        .font(.system(size: size - 2, weight: .medium))
                        .foregroundStyle(dim)
                        .help("Not secure")
                    Text(" ")
                } else {
                    Text("Not secure")
                        .foregroundStyle(dim)
                        .fixedSize()
                    Text("  ")
                }
            }
            if !rest.lead.isEmpty && !compact {
                Text(rest.lead)
                    .foregroundStyle(dim)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Text(rest.name)
                .foregroundStyle(ink)
                .fontWeight(rest.kind == .file || rest.kind == .other ? .regular : .medium)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if !rest.tail.isEmpty {
                Text(rest.tail)
                    .foregroundStyle(dim)
                    .fixedSize()
            }
        }
        .font(.system(size: size))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rest.text)
    }
}

/// A tab's title — or, on the tab you're on with the setting on, where its
/// page is, in the title's place. The title comes back under the pointer:
/// the two crossfade in the same place, so the row doesn't move and nothing
/// beside it does. The page's own title is on the page; what it can't say
/// about itself is where it came from.
struct TitleAtRest: View {
    let label: String
    let rest: AtRest?
    /// The setting is on, this is the tab you're on, and it isn't being edited.
    let shown: Bool
    let hovering: Bool
    let size: CGFloat
    let colour: Color
    /// In the column, with room for "Not secure" and the subdomain; across
    /// the top a lock says the first and the site alone stands for the host.
    let roomy: Bool

    private var on: Bool { shown && rest != nil }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(label)
                .font(.system(size: size))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(colour)
                .opacity(on && !hovering ? 0 : 1)
            if let rest, on {
                AtRestLine(rest: rest, size: size, compact: !roomy)
                    .opacity(hovering ? 0 : 1)
                    .transition(.opacity)
            }
        }
        .animation(Motion.reduced ? nil : .easeInOut(duration: 0.22), value: on)
        .animation(Motion.reduced ? nil : .easeInOut(duration: 0.22), value: hovering)
    }
}
