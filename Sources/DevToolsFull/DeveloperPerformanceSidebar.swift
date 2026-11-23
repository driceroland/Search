import SwiftUI

/// Performance's sidebar, as in Chrome DevTools: Insights, a card for
/// each check over the recording that highlights what it found on the
/// timeline when hovered or opened, and Annotations, the labels added to
/// the recording.
struct DeveloperPerformanceSidebar: View {
    typealias Insight = DeveloperPerformanceInsight

    let insights: [Insight]
    let annotations: [DeveloperPerformanceAnnotation]
    /// The card opened, and the one under the pointer, by id.
    @Binding var open: String?
    @Binding var hovered: String?
    let chooseInsight: (Insight) -> Void
    let chooseRow: (Insight, Insight.Row) -> Void
    let showAnnotation: (DeveloperPerformanceAnnotation) -> Void
    let deleteAnnotation: (UUID) -> Void
    /// Ask AI about an insight; nil while AI assistance is turned off.

    @State private var tab = Tab.insights

    enum Tab: String, CaseIterable, Identifiable {
        case insights = "Insights", annotations = "Annotations"
        var id: String { rawValue }
    }

    static let failColor = Color(red: 0.85, green: 0.19, blue: 0.15)
    static let passColor = Color(red: 0.12, green: 0.56, blue: 0.27)

    var body: some View {
        VStack(spacing: 0) {
            DeveloperTabBar(Tab.allCases, selection: $tab, title: { item in
                item == .annotations && !annotations.isEmpty ? "\(item.rawValue) (\(annotations.count))" : item.rawValue
            })
            Divider()
            switch tab {
            case .insights: insightList
            case .annotations: annotationList
            }
        }
        .font(.system(size: 11))
        .accessibilityIdentifier("developer-performance-sidebar")
    }

    // MARK: Insights

    private var insightList: some View {
        let failing = insights.filter { if case .pass = $0.verdict { return false } else { return true } }
        let passed = insights.filter { if case .pass = $0.verdict { return true } else { return false } }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if insights.isEmpty {
                    Text("No insights for this recording.").foregroundStyle(.secondary).padding(.vertical, 8)
                }
                if !failing.isEmpty {
                    ForEach(failing) { card($0) }
                }
                if !passed.isEmpty {
                    Text("Passed insights").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.top, failing.isEmpty ? 0 : 8)
                    ForEach(passed) { card($0) }
                }
            }
            .padding(8)
        }
    }

    private func color(_ verdict: Insight.Verdict) -> Color {
        switch verdict {
        case .fail: Self.failColor
        case .pass: Self.passColor
        case .info: Color.secondary
        }
    }

    private func card(_ insight: Insight) -> some View {
        let isOpen: Bool = open == insight.id
        let lit: Bool = isOpen || hovered == insight.id
        let fill: Color = lit ? DeveloperToolsStyle.selected : DeveloperToolsStyle.raised
        let edge: Color = lit ? DeveloperToolsStyle.tint : DeveloperToolsStyle.rule
        return VStack(alignment: .leading, spacing: 6) {
            cardHeader(insight, isOpen: isOpen)
            if isOpen { cardDetails(insight) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).stroke(edge, lineWidth: lit ? 1.5 : 0.5)
        }
        .onHover { (inside: Bool) in
            if inside { hovered = insight.id } else if hovered == insight.id { hovered = nil }
        }
        .accessibilityIdentifier("developer-performance-insight-\(insight.id)")
    }

    private func cardHeader(_ insight: Insight, isOpen: Bool) -> some View {
        Button { chooseInsight(insight) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(color(insight.verdict)).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(insight.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                    if let headline = insight.headline {
                        Text(headline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(insight.title), \(verdictName(insight.verdict))")
        .accessibilityValue(insight.headline ?? "")
    }

    @ViewBuilder
    private func cardDetails(_ insight: Insight) -> some View {
        Text(insight.explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if !insight.rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(insight.rows) { (row: Insight.Row) in rowView(insight, row) }
            }
        }
    }

    private func verdictName(_ verdict: Insight.Verdict) -> String {
        switch verdict {
        case .fail: "failed"
        case .pass: "passed"
        case .info: "for information"
        }
    }

    private func rowView(_ insight: Insight, _ row: Insight.Row) -> some View {
        Button { chooseRow(insight, row) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(row.failing ? Self.failColor : Color.clear).frame(width: 5, height: 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.label).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
                    if let detail = row.detail {
                        Text(detail).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                Text(row.value).monospacedDigit().foregroundStyle(row.failing ? Self.failColor : Palette.ink)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.detail ?? row.label)
    }

    // MARK: Annotations

    private var annotationList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if annotations.isEmpty {
                    Text("No annotations yet. Choose a range or an event and click Add annotation, or right-click an entry and choose Link entries.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
                }
                ForEach(annotations.sorted { $0.range.lowerBound < $1.range.lowerBound }) { annotation in
                    annotationRow(annotation)
                }
            }
            .padding(8)
        }
    }

    /// A label, or an entries link with its arrow.
    private func annotationRow(_ annotation: DeveloperPerformanceAnnotation) -> some View {
        let times = DeveloperPerformanceRuler.label(annotation.range.lowerBound) + " – "
            + DeveloperPerformanceRuler.label(annotation.range.upperBound)
        return Button { showAnnotation(annotation) } label: {
            VStack(alignment: .leading, spacing: 2) {
                if annotation.link != nil {
                    Label(annotation.label, systemImage: "arrow.right")
                        .foregroundStyle(Palette.ink).lineLimit(2)
                } else {
                    Text(annotation.label).foregroundStyle(Palette.ink).lineLimit(2)
                }
                Text(times).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DeveloperToolsStyle.raised, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete annotation") { deleteAnnotation(annotation.id) }
        }
        .accessibilityAction(named: "Delete annotation") { deleteAnnotation(annotation.id) }
    }
}
