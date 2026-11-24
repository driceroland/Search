import SwiftUI

/// Chrome's Layers drawer tool: the page's composited layers as a list
/// (nested by the DOM, or flat by paint count or memory), a diagram of
/// them stacked in paint order that turns when dragged, and the selected
/// layer's details with why WebKit composited it. Hovering a layer in
/// either draws its node on the page, as hovering in Elements does.
struct DeveloperLayersView: View {
    let session: DeveloperToolsSession
    @ObservedObject private var layers: DeveloperLayers
    @State private var sort = DeveloperLayerTree.Sort.tree

    init(session: DeveloperToolsSession) {
        self.session = session
        layers = DeveloperLayers.model(for: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let problem = layers.problem {
                DeveloperProblemNote(text: problem)
            }
            if layers.layers.isEmpty {
                Text(layers.loaded ? "This page has no composited layers." : "Reading the page’s layers…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Narrower than the three columns need, the details go
                // under the list and view, as Chrome's Layers does; the
                // drawer never asks for more width than it has, which would
                // push the whole DevTools column off its edges.
                GeometryReader { space in
                    if space.size.width >= 640 {
                        HStack(spacing: 0) {
                            list.frame(minWidth: 220, idealWidth: 320, maxWidth: 380)
                            Divider()
                            DeveloperLayersDiagram(layers: layers)
                                .frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
                            Divider()
                            details.frame(width: 260)
                        }
                    } else {
                        VStack(spacing: 0) {
                            HStack(spacing: 0) {
                                list.frame(width: max(140, min(320, space.size.width * 0.55)))
                                Divider()
                                DeveloperLayersDiagram(layers: layers)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            Divider()
                            details.frame(maxWidth: .infinity, maxHeight: max(80, space.size.height * 0.4))
                        }
                    }
                }
            }
        }
        .font(.system(size: 11))
        .onAppear { layers.start() }
        .onDisappear { layers.stop() }
        .accessibilityIdentifier("developer-layers")
    }

    private var toolbar: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            DeveloperPanelIcon(symbol: "arrow.clockwise", title: "Refresh layers") { layers.refresh() }
                .disabled(!session.ready)
            Divider().frame(height: 14)
            Picker("Sort", selection: $sort) {
                ForEach(DeveloperLayerTree.Sort.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .help("Show the layers nested as the DOM nests them, or sorted")
            Spacer(minLength: 0)
            if layers.loading { ProgressView().controlSize(.mini) }
            Text(DeveloperLayerTree.summary(layers.layers))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.toolbarHeight)
        .background(DeveloperToolsStyle.chrome)
    }

    // MARK: List

    private enum Column {
        static let size: CGFloat = 78
        static let memory: CGFloat = 60
        static let paints: CGFloat = 40
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.gutter) {
                Text("Layer").frame(maxWidth: .infinity, alignment: .leading)
                Text("Size").frame(width: Column.size, alignment: .trailing)
                Text("Memory").frame(width: Column.memory, alignment: .trailing)
                Text("Paints").frame(width: Column.paints, alignment: .trailing)
            }
            .developerColumnTitles()
            Divider()
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(DeveloperLayerTree.rows(layers.layers, parents: layers.parents, sort: sort)) { row in
                            rowView(row).id(row.id)
                        }
                    }
                }
                .onChange(of: layers.selection) { _, selection in
                    if let selection { withAnimation { reader.scrollTo(selection) } }
                }
            }
        }
        .onHover { if !$0 { layers.hover(nil) } }
    }

    private func rowView(_ row: DeveloperLayerTree.Row) -> some View {
        let layer = row.layer
        let selected = layers.selection == layer.id
        let hovered = layers.hovered == layer.id
        return HStack(spacing: DeveloperToolsStyle.gutter) {
            Text(layers.label(layer))
                .font(DeveloperToolsStyle.code)
                .foregroundStyle(layer.isPrimary ? Palette.ink : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, CGFloat(min(row.depth, 16)) * 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(layer.bounds.sizeLabel).frame(width: Column.size, alignment: .trailing)
            Text(DeveloperLayerTree.bytes(layer.memory)).frame(width: Column.memory, alignment: .trailing)
            Text("\(layer.paintCount)").frame(width: Column.paints, alignment: .trailing)
        }
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.rowHeight)
        .background(selected ? DeveloperToolsStyle.selected : hovered ? DeveloperToolsStyle.raised : .clear)
        .contentShape(Rectangle())
        .onTapGesture { layers.selection = layer.id }
        .onHover { inside in
            if inside { layers.hover(layer.id) } else if layers.hovered == layer.id { layers.hover(nil) }
        }
        .contextMenu {
            if layer.nodeId > 0 {
                Button("Reveal in Elements panel") { layers.reveal(layer) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Details

    private var details: some View {
        ScrollView {
            if let layer = layers.selectedLayer {
                VStack(alignment: .leading, spacing: 10) {
                    if layer.nodeId > 0 {
                        Button { layers.reveal(layer) } label: {
                            Text(layers.label(layer))
                                .font(DeveloperToolsStyle.code)
                                .foregroundStyle(DeveloperToolsStyle.tint)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                        .onHover { layers.hover($0 ? layer.id : nil) }
                        .help("Reveal in Elements panel")
                    } else {
                        Text(layers.label(layer)).font(DeveloperToolsStyle.code)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        detail("Size", layer.bounds.sizeLabel)
                        detail("Position", "(\(Int(layer.bounds.x.rounded())), \(Int(layer.bounds.y.rounded())))")
                        detail("Composited bounds", layer.compositedBounds.label)
                        detail("Memory estimate", DeveloperLayerTree.bytes(layer.memory))
                        detail("Paint count", "\(layer.paintCount)")
                        if layer.isInShadowTree { detail("In shadow tree", "Yes") }
                        if layer.isGeneratedContent { detail("Generated content", layer.pseudoElement ?? "Yes") }
                        if layer.isReflection { detail("Reflection", "Yes") }
                        if layer.isAnonymous { detail("Anonymous", "Yes") }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Compositing reasons").fontWeight(.semibold)
                        if let reasons = layers.reasons[layer.id] {
                            if reasons.isEmpty {
                                Text("None given").foregroundStyle(.secondary)
                            } else {
                                ForEach(reasons, id: \.self) { reason in
                                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                                        Text("•").foregroundStyle(.secondary)
                                        Text(reason).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(DeveloperToolsStyle.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Select a layer to see its details.")
                    .foregroundStyle(.secondary)
                    .padding(DeveloperToolsStyle.gutter)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func detail(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(name).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).monospacedDigit()
        }
    }
}

/// The layers as rectangles stacked back to front. Straight on to start
/// with; dragging turns the stack to see the layers apart, double-click
/// faces it again.
private struct DeveloperLayersDiagram: View {
    @ObservedObject var layers: DeveloperLayers
    @State private var yaw = 0.0
    @State private var pitch = 0.0
    @State private var dragStart: (yaw: Double, pitch: Double)?

    private static let limit = Double.pi / 2.2

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let fitted = fittedQuads(size)
            ZStack(alignment: .topTrailing) {
                Canvas { context, _ in
                    for quad in fitted {
                        var path = Path()
                        path.addLines(quad.corners)
                        path.closeSubpath()
                        let selected = layers.selection == quad.id
                        let hovered = layers.hovered == quad.id
                        let tint = DeveloperToolsStyle.tint
                        context.fill(path, with: .color(tint.opacity(selected ? 0.32 : hovered ? 0.24 : 0.07)))
                        context.stroke(path, with: .color(selected ? DeveloperToolsStyle.tint : tint.opacity(hovered ? 1 : 0.55)),
                                       lineWidth: selected ? 2 : hovered ? 1.5 : 1)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): layers.hover(DeveloperLayerGeometry.hit(fitted, at: point))
                    case .ended: layers.hover(nil)
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { drag in
                            let start = dragStart ?? (yaw, pitch)
                            if dragStart == nil { dragStart = start }
                            yaw = min(Self.limit, max(-Self.limit, start.yaw + Double(drag.translation.width) / 200))
                            pitch = min(Self.limit, max(-Self.limit, start.pitch - Double(drag.translation.height) / 200))
                        }
                        .onEnded { _ in dragStart = nil }
                )
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    withAnimation(.easeInOut(duration: 0.25)) { yaw = 0; pitch = 0 }
                })
                .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                    if let id = DeveloperLayerGeometry.hit(fitted, at: tap.location) { layers.selection = id }
                })
                DeveloperPanelIcon(symbol: "rotate.3d", title: "Turn to see the layers apart", active: yaw != 0 || pitch != 0) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if yaw == 0 && pitch == 0 { yaw = -0.6; pitch = 0.45 } else { yaw = 0; pitch = 0 }
                    }
                }
                .padding(DeveloperToolsStyle.controlSpacing)
            }
            .help("Drag to turn the layers; double-click to face them again")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Layer diagram")
        }
        .background(DeveloperToolsStyle.surface)
        .clipped()
    }

    private func fittedQuads(_ size: CGSize) -> [DeveloperLayerGeometry.Quad] {
        let quads = DeveloperLayerGeometry.quads(layers.layers, yaw: yaw, pitch: pitch)
        let fit = DeveloperLayerGeometry.fit(quads.flatMap(\.corners), into: size, padding: 16)
        return quads.map { quad in
            var fitted = quad
            fitted.corners = quad.corners.map(fit.apply)
            return fitted
        }
    }
}
