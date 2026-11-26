import AppKit
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
    /// The tab it is on, for a row drawn for the bench (RecordsTitle).
    var record: UUID? = nil

    /// What the line takes beside the name across the top: the open lock
    /// and its space, the port. Measured once a port.
    static func besideName(_ rest: AtRest, size: CGFloat) -> CGFloat {
        var beside: CGFloat = rest.kind == .notSecure ? size + 2 : 0
        guard !rest.tail.isEmpty else { return beside }
        let key = "\(size) \(rest.tail)"
        if let known = measured[key] { return beside + known }
        let width = ceil((rest.tail as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width)
        if measured.count > 200 { measured.removeAll() }
        measured[key] = width
        beside += width
        return beside
    }
    private static var measured: [String: CGFloat] = [:]

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
                .modifier(RecordsTitle(key: record.map { "\($0.uuidString.prefix(8).lowercased())/rest" },
                                       title: .init(text: rest.name, size: size,
                                                    medium: !(rest.kind == .file || rest.kind == .other), middle: true)))
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
/// the two swap in the same place, so the row doesn't move and nothing
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
    var dim = false
    /// The tab it is on, for a row drawn for the bench (RecordsTitle).
    var record: UUID? = nil
    var tidy: String? = nil

    private var on: Bool { shown && rest != nil }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(label)
                .font(.system(size: size))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(colour)
                .modifier(TidyGlint(tidy: tidy == label ? tidy : nil))
                .modifier(RecordsTitle(key: record.map { "\($0.uuidString.prefix(8).lowercased())/title" },
                                       title: .init(text: label, size: size, shown: !(on && !hovering))))
                .opacity(on && !hovering ? 0 : 1)
            if let rest, on {
                AtRestLine(rest: rest, size: size, compact: !roomy, record: record)
                    .opacity(hovering ? 0 : 1)
                    .transition(.opacity)
            }
        }
        .opacity(dim ? 0.45 : 1)
        .animation(Motion.reduced ? nil : .easeInOut(duration: 0.22), value: on)
        .animation(Motion.quick, value: dim)
        .animation(nil, value: hovering)
    }
}

/// On a row drawn off screen for the bench (Environment.recordsBands), a
/// title says what it holds and how wide it was laid out (TabBar.drawnTitles),
/// so a probe can tell what is left of it once cut. Nothing anywhere else.
struct RecordsTitle: ViewModifier {
    @Environment(\.recordsBands) private var records
    let key: String?
    let title: TabBar.DrawnTitle

    func body(content: Content) -> some View {
        if records, let key {
            content.onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                var drawn = title
                drawn.width = width
                TabBar.drawnTitles[key] = drawn
            }
        } else {
            content
        }
    }
}
