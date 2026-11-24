import SwiftUI

/// Chrome's CSS overview drawer tool: Capture overview, then the page's
/// summary, colours, fonts, unused declarations, media queries and
/// contrast problems, a section at a time. Clicking a colour, a font or a
/// group lists the elements behind it; hovering one draws it on the page,
/// clicking it reveals it in Elements.
struct DeveloperCSSOverviewView: View {
    let session: DeveloperToolsSession
    @ObservedObject private var model: DeveloperCSSOverviewModel
    @State private var section = Section.summary
    @State private var detail: Detail?

    init(session: DeveloperToolsSession) {
        self.session = session
        model = DeveloperCSSOverviewModel.model(for: session)
    }

    enum Section: String, CaseIterable, Identifiable {
        case summary = "Overview summary"
        case colors = "Colors"
        case fonts = "Font info"
        case unused = "Unused declarations"
        case media = "Media queries"
        case contrast = "Contrast issues"
        var id: Self { self }
    }

    /// What the elements pane lists.
    struct Detail: Equatable {
        var title: String
        var elements: [Int]
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let problem = model.problem {
                DeveloperProblemNote(text: problem, font: nil)
            }
            if let report = model.report {
                HStack(spacing: 0) {
                    sidebar(report).frame(width: 180)
                    Divider()
                    ScrollView {
                        content(report)
                            .padding(DeveloperToolsStyle.gutter + 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let detail {
                        Divider()
                        DeveloperCSSOverviewElements(model: model, report: report, detail: detail) { self.detail = nil }
                            .frame(width: 280)
                    }
                }
            } else {
                start
            }
        }
        .font(.system(size: 11))
        .onDisappear { model.hover(nil) }
        .onChange(of: section) { _, _ in detail = nil }
        .accessibilityIdentifier("developer-css-overview")
    }

    private var toolbar: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            Button("Capture overview") { detail = nil; model.capture() }
                .controlSize(.small)
                .disabled(!session.ready || model.capturing)
            DeveloperPanelIcon(symbol: "nosign", title: "Clear overview") { detail = nil; model.clear() }
                .disabled(model.report == nil)
            if model.capturing { ProgressView().controlSize(.mini) }
            if model.stale {
                Text("The page has changed since this capture.").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.toolbarHeight)
        .background(DeveloperToolsStyle.chrome)
    }

    private var start: some View {
        VStack(spacing: 10) {
            Image(systemName: "paintpalette").font(.system(size: 26)).foregroundStyle(.secondary)
            Text("CSS overview").font(.system(size: 13, weight: .semibold))
            Text("Capture an overview of the page’s CSS: colours, fonts, unused declarations, media queries and contrast issues.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Capture overview") { model.capture() }
                .disabled(!session.ready || model.capturing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Sidebar

    private func sidebar(_ report: DeveloperCSSOverview.Report) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Section.allCases) { item in
                    let selected = section == item
                    Button { section = item } label: {
                        HStack {
                            Text(item.rawValue).fontWeight(selected ? .semibold : .regular)
                            Spacer(minLength: 4)
                            if let total = count(item, report) {
                                Text("\(total)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .padding(.horizontal, DeveloperToolsStyle.gutter)
                        .frame(height: DeveloperToolsStyle.rowHeight)
                        .background(selected ? DeveloperToolsStyle.selected : .clear,
                                    in: RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selected ? Palette.ink : .secondary)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(DeveloperToolsStyle.controlSpacing)
        }
        .background(DeveloperToolsStyle.chrome)
    }

    private func count(_ section: Section, _ report: DeveloperCSSOverview.Report) -> Int? {
        switch section {
        case .summary: nil
        case .colors: report.colors.unique
        case .fonts: report.fonts.count
        case .unused: report.unused.reduce(0) { $0 + $1.count }
        case .media: report.media.count
        case .contrast: report.contrast.reduce(0) { $0 + $1.count }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func content(_ report: DeveloperCSSOverview.Report) -> some View {
        switch section {
        case .summary: summary(report.summary)
        case .colors: colors(report.colors)
        case .fonts: fonts(report.fonts)
        case .unused: unused(report.unused)
        case .media: media(report.media)
        case .contrast: contrast(report.contrast)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold))
    }

    private func empty(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    private func summary(_ summary: DeveloperCSSOverview.Summary) -> some View {
        let rows: [(String, Int)] = [
            ("Elements", summary.elements),
            ("External stylesheets", summary.externalSheets),
            ("Inline style elements", summary.inlineSheets),
            ("Style rules", summary.styleRules),
            ("Media queries", summary.mediaQueries),
            ("Type selectors", summary.selectors.type),
            ("ID selectors", summary.selectors.id),
            ("Class selectors", summary.selectors.classes),
            ("Universal selectors", summary.selectors.universal),
            ("Attribute selectors", summary.selectors.attribute),
            ("Non-simple selectors", summary.selectors.nonSimple),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            heading("Overview summary")
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.0).foregroundStyle(.secondary)
                        Text(row.1.formatted()).monospacedDigit().gridColumnAlignment(.trailing)
                    }
                }
            }
            if summary.truncated {
                Text("Only the first elements were looked at for colours, fonts and contrast; the page has more.")
                    .foregroundStyle(.secondary)
            }
            if summary.unreadableSheets > 0 {
                Text("\(summary.unreadableSheets) style sheet\(summary.unreadableSheets == 1 ? "" : "s") from other origins couldn’t be read; their rules, selectors and media queries aren’t counted.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
    }

    private func colors(_ colors: DeveloperCSSOverview.Colors) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Colors")
            colorGroup("Background colors", colors.background)
            colorGroup("Text colors", colors.text)
            colorGroup("Fill colors", colors.fill)
            colorGroup("Border colors", colors.border)
        }
    }

    @ViewBuilder
    private func colorGroup(_ title: String, _ uses: [DeveloperCSSOverview.ColorUse]) -> some View {
        if !uses.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(title): \(uses.count)").fontWeight(.medium)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(uses) { use in
                        let shown = Detail(title: "\(title) · \(use.key)", elements: use.elements)
                        Button { detail = shown } label: {
                            HStack(spacing: 6) {
                                DeveloperCSSSwatch(color: use.color)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(use.key).font(DeveloperToolsStyle.code).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                                    Text("\(use.count)").foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            .padding(3)
                            .background(detail == shown ? DeveloperToolsStyle.selected : .clear,
                                        in: RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(use.count) element\(use.count == 1 ? "" : "s") use \(use.key)")
                    }
                }
            }
        }
    }

    private func fonts(_ families: [DeveloperCSSOverview.FontFamily]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Font info")
            if families.isEmpty { empty("No text found.") }
            ForEach(families) { family in
                VStack(alignment: .leading, spacing: 4) {
                    Text(family.family).font(.system(size: 12, weight: .medium)).lineLimit(2).textSelection(.enabled)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 2) {
                        GridRow {
                            Text("Size"); Text("Weight"); Text("Line height"); Text("Occurrences")
                        }
                        .foregroundStyle(.secondary)
                        ForEach(family.uses) { use in
                            GridRow {
                                Text(use.size); Text(use.weight); Text(use.lineHeight)
                                link("\(use.count)", Detail(title: "\(family.family) · \(use.size) \(use.weight) / \(use.lineHeight)",
                                                            elements: use.elements))
                            }
                            .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func unused(_ groups: [DeveloperCSSOverview.UnusedGroup]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Unused declarations")
            if groups.isEmpty { empty("No unused declarations found.") }
            ForEach(groups) { group in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.reason).fixedSize(horizontal: false, vertical: true)
                        Text(group.values.prefix(6).map { group.property + ": " + $0 }.joined(separator: ", "))
                            .font(DeveloperToolsStyle.code)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    link("\(group.count) element\(group.count == 1 ? "" : "s")", Detail(title: group.reason, elements: group.elements))
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func media(_ queries: [DeveloperCSSOverview.MediaQuery]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Media queries")
            if queries.isEmpty { empty("No media queries in the style sheets that could be read.") }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                ForEach(queries) { query in
                    GridRow {
                        Text(query.text).font(DeveloperToolsStyle.code).textSelection(.enabled)
                        Text("\(query.count) occurrence\(query.count == 1 ? "" : "s")").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }

    private func contrast(_ issues: [DeveloperCSSOverview.ContrastIssue]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Contrast issues")
            Text("Text below WCAG AA: a ratio of 4.5, or 3 for large text. Text over background images isn’t judged.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if issues.isEmpty { empty("No contrast issues found.") }
            ForEach(issues) { issue in
                let shown = Detail(title: "Contrast \(DeveloperCSSOverview.ratioLabel(issue.ratio)) · \(issue.text.hex) on \(issue.background.hex)",
                                   elements: issue.elements)
                Button { detail = shown } label: {
                    HStack(spacing: 10) {
                        Text("Aa")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DeveloperCSSSwatch.swiftUI(issue.text))
                            .frame(width: 40, height: 28)
                            .background(DeveloperCSSSwatch.swiftUI(issue.background), in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DeveloperToolsStyle.rule))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(issue.text.hex) on \(issue.background.hex)").font(DeveloperToolsStyle.code)
                            Text("Ratio \(DeveloperCSSOverview.ratioLabel(issue.ratio)), needs \(issue.threshold.formatted())")
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Text("\(issue.count) element\(issue.count == 1 ? "" : "s")").foregroundStyle(DeveloperToolsStyle.tint)
                    }
                    .padding(4)
                    .background(detail == shown ? DeveloperToolsStyle.selected : .clear,
                                in: RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func link(_ text: String, _ shown: Detail) -> some View {
        Button { detail = shown } label: {
            Text(text)
                .foregroundStyle(DeveloperToolsStyle.tint)
                .fontWeight(detail == shown ? .semibold : .regular)
        }
        .buttonStyle(.plain)
        .help("List these elements")
    }
}

/// A colour's swatch; a checkerboard shows through a translucent one, a
/// question mark stands for one that couldn't be read.
struct DeveloperCSSSwatch: View {
    let color: DeveloperCSSColor?

    static func swiftUI(_ color: DeveloperCSSColor) -> Color {
        Color(.sRGB, red: color.red / 255, green: color.green / 255, blue: color.blue / 255, opacity: color.alpha)
    }

    var body: some View {
        ZStack {
            if let color {
                if !color.isOpaque {
                    Canvas { context, size in
                        let cell: CGFloat = 5
                        for row in 0..<Int(ceil(size.height / cell)) {
                            for column in 0..<Int(ceil(size.width / cell)) where (row + column) % 2 == 0 {
                                context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                             with: .color(.gray.opacity(0.35)))
                            }
                        }
                    }
                }
                Self.swiftUI(color)
            } else {
                Text("?").foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DeveloperToolsStyle.rule))
    }
}

/// The elements behind a colour, a font or a group: hovering one draws it
/// on the page, clicking it reveals it in Elements.
private struct DeveloperCSSOverviewElements: View {
    @ObservedObject var model: DeveloperCSSOverviewModel
    let report: DeveloperCSSOverview.Report
    let detail: DeveloperCSSOverviewView.Detail
    let close: () -> Void
    @State private var hovered: Int?

    /// Lists longer than this show their first ones.
    private static let shownLimit = 500

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                Text(detail.title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                DeveloperPanelIcon(symbol: "xmark", title: "Close", action: close)
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.toolbarHeight)
            .background(DeveloperToolsStyle.chrome)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(detail.elements.prefix(Self.shownLimit).enumerated()), id: \.offset) { _, index in
                        Button { model.reveal(index) } label: {
                            Text(report.label(index))
                                .font(DeveloperToolsStyle.code)
                                .foregroundStyle(DeveloperToolsStyle.tint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, DeveloperToolsStyle.gutter)
                                .frame(maxWidth: .infinity, minHeight: DeveloperToolsStyle.rowHeight, alignment: .leading)
                                .background(hovered == index ? DeveloperToolsStyle.raised : .clear)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in
                            if inside {
                                hovered = index
                                model.hover(index)
                            } else if hovered == index {
                                hovered = nil
                                model.hover(nil)
                            }
                        }
                        .help("Reveal in Elements panel")
                    }
                    if detail.elements.count > Self.shownLimit {
                        Text("and \(detail.elements.count - Self.shownLimit) more")
                            .foregroundStyle(.secondary)
                            .padding(DeveloperToolsStyle.gutter)
                    }
                }
            }
        }
        .background(DeveloperToolsStyle.surface)
    }
}
