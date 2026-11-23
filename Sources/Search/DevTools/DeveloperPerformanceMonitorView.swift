import SwiftUI

/// Chrome's Performance monitor drawer tool: the metrics on the left, each
/// with a checkbox, its colour and its reading now; on the right a strip
/// of small line charts, one per metric checked, scrolling over the last
/// minute. Reading stops while the tool is hidden.
struct DeveloperPerformanceMonitorView: View {
    let session: DeveloperToolsSession
    @ObservedObject private var monitor: DeveloperPerformanceMonitorModel

    init(session: DeveloperToolsSession) {
        self.session = session
        monitor = DeveloperPerformanceMonitorModel.model(for: session)
    }

    /// Chrome's metric colours, near enough, readable on light and dark.
    static func color(_ metric: DeveloperPerformanceMetric) -> Color {
        switch metric {
        case .cpu: Color(red: 0.85, green: 0.19, blue: 0.15)
        case .jsHeap: Color(red: 0.10, green: 0.45, blue: 0.91)
        case .domNodes: Color(red: 0.09, green: 0.55, blue: 0.24)
        case .eventListeners: Color(red: 0.89, green: 0.45, blue: 0.00)
        case .documents: Color(red: 0.58, green: 0.20, blue: 0.90)
        case .frames: Color(red: 0.07, green: 0.62, blue: 0.70)
        case .layouts: Color(red: 0.76, green: 0.10, blue: 0.47)
        case .styleRecalcs: Color(red: 0.55, green: 0.42, blue: 0.00)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            metricList
                .frame(width: 210)
            Divider()
            charts
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
        .accessibilityIdentifier("developer-performance-monitor")
    }

    // MARK: Metrics

    private var metricList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if let problem = monitor.problem {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                }
                ForEach(DeveloperPerformanceMetric.allCases) { metric in row(metric) }
            }
            .padding(DeveloperToolsStyle.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DeveloperToolsStyle.chrome)
    }

    private func row(_ metric: DeveloperPerformanceMetric) -> some View {
        let reason = monitor.unavailableReason(metric)
        let value = reason == nil ? monitor.latest(metric) : nil
        let color = Self.color(metric)
        return HStack(alignment: .top, spacing: 6) {
            Toggle(isOn: Binding(get: { monitor.enabled.contains(metric) && !metric.neverAvailable },
                                 set: { _ in monitor.toggle(metric) })) { EmptyView() }
                .toggleStyle(.developerCheckbox)
                .labelsHidden()
                .tint(color)
                .disabled(metric.neverAvailable)
            VStack(alignment: .leading, spacing: 0) {
                Text(metric.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(metric.format(value))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(value == nil ? AnyShapeStyle(HierarchicalShapeStyle.tertiary) : AnyShapeStyle(color))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .help(reason ?? metric.about)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(metric.title)
        .accessibilityValue(metric.format(value))
    }

    // MARK: Charts

    private var shown: [DeveloperPerformanceMetric] {
        DeveloperPerformanceMetric.allCases.filter { monitor.enabled.contains($0) && !$0.neverAvailable }
    }

    @ViewBuilder private var charts: some View {
        if shown.isEmpty {
            Text("Check a metric to chart it.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Scrolls smoothly while shown; still while hidden or stopped.
            TimelineView(.animation(minimumInterval: 0.2, paused: !monitor.running)) { _ in
                let now = DeveloperPerformanceMonitorModel.now()
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element) { index, metric in
                        if index > 0 { Divider() }
                        DeveloperPerformanceChart(metric: metric, samples: monitor.history.samples(metric), now: now,
                                                  reason: monitor.unavailableReason(metric), color: Self.color(metric))
                    }
                }
            }
        }
    }
}

/// One metric's chart: the last minute's line under its scale, with a grid
/// every ten seconds.
private struct DeveloperPerformanceChart: View {
    let metric: DeveloperPerformanceMetric
    let samples: [DeveloperMetricSample]
    let now: Double
    let reason: String?
    let color: Color

    var body: some View {
        let window = DeveloperChartScale.window
        let visible = samples.filter { $0.time >= now - window - 2 }
        let maximum = DeveloperChartScale.maximum(visible, metric: metric)
        GeometryReader { geometry in
            let size = CGSize(width: geometry.size.width, height: max(1, geometry.size.height - 14))
            let runs = DeveloperChartScale.segments(visible, now: now, maximum: maximum, size: size)
            let grid = DeveloperChartScale.gridTimes(now: now)
            Canvas { context, _ in
                let rule = Color.secondary.opacity(0.18)
                context.translateBy(x: 0, y: 14)
                for time in grid {
                    let x = size.width - CGFloat((now - time) / window) * size.width
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(rule), lineWidth: 1)
                }
                for fraction in [0.5, 1.0] {
                    var line = Path()
                    let y = size.height - CGFloat(fraction) * size.height + 0.5
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(rule), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                for run in runs {
                    guard let first = run.first else { continue }
                    var line = Path()
                    line.move(to: first)
                    for point in run.dropFirst() { line.addLine(to: point) }
                    var fill = line
                    if let last = run.last {
                        fill.addLine(to: CGPoint(x: last.x, y: size.height))
                        fill.addLine(to: CGPoint(x: first.x, y: size.height))
                        fill.closeSubpath()
                    }
                    context.fill(fill, with: .color(color.opacity(0.12)))
                    context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    Text(metric.title).foregroundStyle(color)
                    Spacer(minLength: 0)
                    Text(metric.format(maximum)).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.system(size: 10))
                .lineLimit(1)
                .padding(.horizontal, 4)
                .frame(height: 14)
            }
            .overlay {
                if let reason {
                    Text("n/a")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help(reason)
                }
            }
        }
        .frame(minHeight: 36, maxHeight: .infinity)
        .clipped()
        .accessibilityElement()
        .accessibilityLabel(metric.title + " chart")
    }
}
