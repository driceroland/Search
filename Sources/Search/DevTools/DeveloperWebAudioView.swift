import SwiftUI

/// Chrome's WebAudio drawer tool: a picker of the page's audio contexts
/// in the toolbar, the selected context's graph drawn as boxes and edges,
/// and its properties beside it.
struct DeveloperWebAudioView: View {
    let session: DeveloperToolsSession
    @ObservedObject private var audio: DeveloperWebAudioModel

    init(session: DeveloperToolsSession) {
        self.session = session
        audio = DeveloperWebAudioModel.model(for: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let problem = audio.problem {
                HStack {
                    Text(problem).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    DeveloperPanelIcon(symbol: "xmark", title: "Dismiss", size: 16) { audio.dismissProblem() }
                }
                .padding(.horizontal, DeveloperToolsStyle.gutter).padding(.vertical, 4)
                .background(DeveloperToolsStyle.raised)
                Divider()
            }
            if let context = audio.selected {
                HStack(spacing: 0) {
                    DeveloperWebAudioGraphView(graph: context.graph)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    properties(context).frame(width: 250)
                }
            } else {
                VStack(spacing: 6) {
                    Text("Open a page that uses Web Audio API to start monitoring.")
                        .foregroundStyle(.secondary)
                    Text("Contexts made before the WebAudio tool opened appear once they connect a node; reload the page to see them all.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(.system(size: 11))
        .onAppear { audio.start() }
        .accessibilityIdentifier("developer-web-audio")
    }

    private var toolbar: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            Menu(audio.selected?.title ?? "(no recordings)") {
                ForEach(audio.contexts) { context in
                    Button(context.title) { audio.selection = context.id }
                }
            }
            .fixedSize()
            .disabled(audio.contexts.isEmpty)
            .accessibilityLabel("Audio context")
            Spacer()
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.toolbarHeight)
        .background(DeveloperToolsStyle.chrome)
    }

    private func properties(_ context: DeveloperWebAudioContext) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(context.type == "offline" ? "OfflineAudioContext" : "AudioContext")
                    .fontWeight(.semibold)
                    .padding(.horizontal, DeveloperToolsStyle.gutter)
                    .frame(height: DeveloperToolsStyle.rowHeight)
                ForEach(Self.rows(for: context), id: \.name) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.name).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(row.value).font(DeveloperToolsStyle.code).textSelection(.enabled)
                    }
                    .padding(.horizontal, DeveloperToolsStyle.gutter)
                    .frame(minHeight: DeveloperToolsStyle.rowHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("developer-web-audio-properties")
    }

    /// The context's properties, as Chrome's WebAudio tool lists them.
    struct Row: Hashable {
        let name: String
        let value: String
    }

    static func rows(for context: DeveloperWebAudioContext) -> [Row] {
        func seconds(_ value: Double?) -> String {
            guard let value else { return "—" }
            return String(format: "%.3f s", value)
        }
        func milliseconds(_ value: Double?) -> String {
            guard let value else { return "—" }
            return String(format: "%.3f ms", value * 1000)
        }
        var rows = [
            Row(name: "Context type", value: context.type),
            Row(name: "State", value: context.state.isEmpty ? "—" : context.state),
            Row(name: "Sample rate", value: context.sampleRate.map { String(format: "%.0f Hz", $0) } ?? "—"),
            Row(name: "Max output channels", value: context.maxChannelCount.map { String($0) } ?? "—"),
            Row(name: "Current time", value: seconds(context.currentTime)),
        ]
        if context.type != "offline" {
            rows.append(Row(name: "Base latency", value: milliseconds(context.baseLatency)))
            rows.append(Row(name: "Output latency", value: milliseconds(context.outputLatency)))
        }
        rows.append(Row(name: "Nodes", value: String(context.graph.nodes.count)))
        rows.append(Row(name: "Connections", value: String(context.graph.edges.count)))
        return rows
    }
}

/// Where the graph view puts each node: a box with the node's type on top
/// and a row for each AudioParam, in columns from sources to destination.
struct DeveloperWebAudioLayout {
    static let width: CGFloat = 170
    static let header: CGFloat = 24
    static let paramRow: CGFloat = 15
    static let columnGap: CGFloat = 70
    static let rowGap: CGFloat = 18
    static let margin: CGFloat = 16

    private(set) var frames: [String: CGRect] = [:]
    private(set) var size: CGSize = .zero

    init(_ graph: DeveloperWebAudioGraph) {
        var width: CGFloat = Self.margin
        var height: CGFloat = 0
        for column in graph.columns() {
            var y = Self.margin
            for node in column {
                let frame = CGRect(x: width, y: y, width: Self.width, height: Self.height(of: node))
                frames[node.id] = frame
                y = frame.maxY + Self.rowGap
            }
            height = max(height, y - Self.rowGap + Self.margin)
            width += Self.width + Self.columnGap
        }
        size = CGSize(width: width - Self.columnGap + Self.margin, height: height)
    }

    static func height(of node: DeveloperWebAudioNode) -> CGFloat {
        header + CGFloat(node.params.count) * paramRow + (node.params.isEmpty ? 0 : 5)
    }

    func start(of edge: DeveloperWebAudioEdge) -> CGPoint? {
        guard let frame = frames[edge.source] else { return nil }
        return CGPoint(x: frame.maxX, y: frame.minY + Self.header / 2 + CGFloat(min(edge.output, 3)) * 4)
    }

    func end(of edge: DeveloperWebAudioEdge, in graph: DeveloperWebAudioGraph) -> CGPoint? {
        guard let frame = frames[edge.destination] else { return nil }
        if let param = edge.param, let row = graph.node(edge.destination)?.params.firstIndex(where: { $0.name == param }) {
            return CGPoint(x: frame.minX, y: frame.minY + Self.header + (CGFloat(row) + 0.5) * Self.paramRow)
        }
        return CGPoint(x: frame.minX, y: frame.minY + Self.header / 2 + CGFloat(min(edge.input, 3)) * 4)
    }
}

/// The graph itself: a box per node, an edge per connection, drawn on a
/// Canvas that scrolls when it's larger than the room.
struct DeveloperWebAudioGraphView: View {
    let graph: DeveloperWebAudioGraph

    var body: some View {
        let layout = DeveloperWebAudioLayout(graph)
        ScrollView([.horizontal, .vertical]) {
            Canvas { context, _ in draw(&context, layout) }
                .frame(width: max(layout.size.width, 1), height: max(layout.size.height, 1))
        }
        .background(DeveloperToolsStyle.surface)
        .accessibilityElement()
        .accessibilityLabel("Audio graph")
        .accessibilityValue("\(graph.nodes.count) nodes, \(graph.edges.count) connections")
        .accessibilityIdentifier("developer-web-audio-graph")
    }

    private func draw(_ context: inout GraphicsContext, _ layout: DeveloperWebAudioLayout) {
        for edge in graph.edges {
            guard let start = layout.start(of: edge), let end = layout.end(of: edge, in: graph) else { continue }
            let reach = max(abs(end.x - start.x) / 2, 30)
            var path = Path()
            path.move(to: start)
            path.addCurve(to: end, control1: CGPoint(x: start.x + reach, y: start.y),
                          control2: CGPoint(x: end.x - reach, y: end.y))
            context.stroke(path, with: .color(DeveloperToolsStyle.tint), lineWidth: 1.2)
            var arrow = Path()
            arrow.move(to: end)
            arrow.addLine(to: CGPoint(x: end.x - 6, y: end.y - 3.5))
            arrow.addLine(to: CGPoint(x: end.x - 6, y: end.y + 3.5))
            arrow.closeSubpath()
            context.fill(arrow, with: .color(DeveloperToolsStyle.tint))
        }
        for node in graph.nodes {
            guard let frame = layout.frames[node.id] else { continue }
            let box = Path(roundedRect: frame, cornerRadius: 4)
            context.fill(box, with: .color(Self.fill(for: node)))
            context.stroke(box, with: .color(Palette.faint), lineWidth: 1)
            let title = Text(node.type).font(.system(size: 11, weight: .semibold)).foregroundColor(Palette.ink)
            context.draw(title, in: CGRect(x: frame.minX + 8, y: frame.minY + 4, width: frame.width - 16,
                                           height: DeveloperWebAudioLayout.header - 8))
            for (row, param) in node.params.enumerated() {
                let y = frame.minY + DeveloperWebAudioLayout.header + CGFloat(row) * DeveloperWebAudioLayout.paramRow
                let dot = Path(ellipseIn: CGRect(x: frame.minX - 3, y: y + DeveloperWebAudioLayout.paramRow / 2 - 3,
                                                 width: 6, height: 6))
                context.fill(dot, with: .color(Palette.muted))
                let label = param.name + (param.value.map { " " + Self.format($0) } ?? "")
                context.draw(Text(label).font(.system(size: 10)).foregroundColor(Palette.muted),
                             in: CGRect(x: frame.minX + 8, y: y, width: frame.width - 16,
                                        height: DeveloperWebAudioLayout.paramRow))
            }
        }
    }

    /// Sources, processors and the destination tinted apart, as Chrome's
    /// graph does.
    private static func fill(for node: DeveloperWebAudioNode) -> Color {
        if node.inputs == 0 { return Palette.safe.opacity(0.14) }
        if node.outputs == 0 { return Palette.unsafe.opacity(0.14) }
        return DeveloperToolsStyle.raised
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e9 ? String(Int(value)) : String(format: "%.3g", value)
    }
}
