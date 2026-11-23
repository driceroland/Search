import SwiftUI

/// Lighthouse's View Treemap: the page's JavaScript as nested rectangles,
/// each script sized by its bytes and, where DevTools loaded its source
/// map, split into the modules the map says it was built from (by the
/// bytes of the script each maps to, as the Duplicated JavaScript insight
/// counts them), with the bytes the load didn't run from coverage. As
/// Lighthouse's script-treemap-data builds it: a module's path becomes
/// folders, chains of single folders are collapsed into one, and what no
/// mapping reaches is "(unmapped)". Pure apart from the view, for the tests.
enum DeveloperLighthouseTreemap {
    struct Node: Equatable, Identifiable {
        /// The path from the root, unique in the tree.
        var id: String
        var name: String
        var resourceBytes: Double
        /// Bytes the load didn't run; nil when coverage didn't measure it
        /// (it is measured per script, not per module).
        var unusedBytes: Double?
        var children: [Node] = []
    }

    struct Script: Equatable {
        var url: String
        var text: String
        var map: DeveloperSourceMap?
    }

    /// A map's `sources` entry as folders: without webpack's scheme, a
    /// trailing ?, and the leading ./ and ../ that only say where the build ran.
    static func pathComponents(_ source: String) -> [String] {
        var source = source
        if source.hasSuffix("?") { source.removeLast() }
        for prefix in ["webpack:///", "webpack://", "file://"] where source.hasPrefix(prefix) {
            source.removeFirst(prefix.count)
            break
        }
        if let scheme = source.range(of: "://") {
            // Another scheme's address: the host is its first folder.
            source = String(source[scheme.upperBound...])
        }
        return source.split(separator: "/").map(String.init).filter { $0 != "." && $0 != ".." && !$0.isEmpty }
    }

    /// The tree, one root per script, largest first.
    static func nodes(_ scripts: [Script], coverage: [DeveloperCoverageMath.Entry]? = nil) -> [Node] {
        var unusedByURL: [String: Double] = [:]
        for entry in coverage ?? [] where entry.kind == .javaScript { unusedByURL[entry.url] = Double(entry.unused) }
        var roots: [Node] = []
        var seen = Set<String>()
        for script in scripts where seen.insert(script.url).inserted {
            let total = Double(script.text.utf16.count)
            guard total > 0 else { continue }
            var root = Node(id: script.url, name: script.url, resourceBytes: total, unusedBytes: unusedByURL[script.url])
            if let map = script.map, let sizes = DeveloperPerformanceInsights.generatedSizes(map, text: script.text) {
                var mapped = 0.0
                var tree = Folder()
                for (index, source) in map.sources.enumerated() {
                    guard let size = sizes[index], size > 0 else { continue }
                    let parts = pathComponents(source)
                    tree.add(parts.isEmpty ? [source] : parts, bytes: Double(size))
                    mapped += Double(size)
                }
                if total - mapped > 0 { tree.add(["(unmapped)"], bytes: total - mapped) }
                root.children = tree.nodes(under: script.url)
            }
            roots.append(root)
        }
        return roots.sorted { $0.resourceBytes > $1.resourceBytes }
    }

    /// Folders as the sources' paths are added.
    private struct Folder {
        var bytes = 0.0
        var children: [String: Folder] = [:]
        var order: [String] = []

        mutating func add(_ path: [String], bytes: Double) {
            self.bytes += bytes
            guard let first = path.first else { return }
            if children[first] == nil { order.append(first) }
            children[first, default: Folder()].add(Array(path.dropFirst()), bytes: bytes)
        }

        /// The folder's children as nodes, single-child chains collapsed
        /// ("src/components" rather than "src" holding "components").
        func nodes(under parent: String) -> [Node] {
            order.compactMap { name -> Node? in
                guard var folder = children[name] else { return nil }
                var label = name
                while folder.order.count == 1, let only = folder.order.first, let next = folder.children[only] {
                    label += "/" + only
                    folder = next
                }
                let id = parent + "|" + label
                return Node(id: id, name: label, resourceBytes: folder.bytes, children: folder.nodes(under: id))
            }
            .sorted { $0.resourceBytes > $1.resourceBytes }
        }
    }

    // MARK: Layout

    /// The squarified treemap (Bruls, Huizing and van Wijk) of `values` in
    /// `rect`: each value's rectangle, its area in proportion, as near
    /// square as rows allow. Values of zero get an empty rectangle.
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var out = Array(repeating: CGRect.zero, count: values.count)
        let total = values.reduce(0) { $0 + max(0, $1) }
        let width = Double(rect.width), height = Double(rect.height)
        guard total > 0, width > 0, height > 0 else { return out }
        let scale = width * height / total
        let areas = values.map { max(0, $0) * scale }
        var free = (x: Double(rect.minX), y: Double(rect.minY), width: width, height: height)

        func worst(_ row: [Int], side: Double) -> Double {
            let sum = row.reduce(0) { $0 + areas[$1] }
            guard sum > 0, side > 0, let largest = row.map({ areas[$0] }).max(),
                  let smallest = row.map({ areas[$0] }).min(), smallest > 0 else { return .infinity }
            return max(side * side * largest / (sum * sum), sum * sum / (side * side * smallest))
        }
        func place(_ row: [Int]) {
            let sum = row.reduce(0) { $0 + areas[$1] }
            guard sum > 0 else { return }
            if free.width >= free.height {
                // A column down the left.
                let columnWidth = free.height > 0 ? sum / free.height : 0
                var y = free.y
                for index in row {
                    let cell = columnWidth > 0 ? areas[index] / columnWidth : 0
                    out[index] = CGRect(x: free.x, y: y, width: columnWidth, height: cell)
                    y += cell
                }
                free = (x: free.x + columnWidth, y: free.y, width: max(0, free.width - columnWidth), height: free.height)
            } else {
                // A row across the top.
                let rowHeight = free.width > 0 ? sum / free.width : 0
                var x = free.x
                for index in row {
                    let cell = rowHeight > 0 ? areas[index] / rowHeight : 0
                    out[index] = CGRect(x: x, y: free.y, width: cell, height: rowHeight)
                    x += cell
                }
                free = (x: free.x, y: free.y + rowHeight, width: free.width, height: max(0, free.height - rowHeight))
            }
        }

        var row: [Int] = []
        for index in values.indices.sorted(by: { values[$0] > values[$1] }) where areas[index] > 0 {
            let side = min(free.width, free.height)
            if row.isEmpty || worst(row + [index], side: side) <= worst(row, side: side) {
                row.append(index)
            } else {
                place(row)
                row = [index]
            }
        }
        if !row.isEmpty { place(row) }
        return out
    }
}

// MARK: The view

/// View Treemap's sheet: the scripts' rectangles, a click on one with
/// modules opens it, the path above goes back up.
struct DeveloperLighthouseTreemapView: View {
    let roots: [DeveloperLighthouseTreemap.Node]
    let title: String
    let close: () -> Void
    /// The nodes opened, from a root down.
    @State private var path: [DeveloperLighthouseTreemap.Node] = []
    @State private var hovered: String?

    init(roots: [DeveloperLighthouseTreemap.Node], title: String, close: @escaping () -> Void) {
        self.roots = roots
        self.title = title
        self.close = close
    }

    private var shown: [DeveloperLighthouseTreemap.Node] { path.last?.children ?? roots }
    private var total: Double { path.last?.resourceBytes ?? roots.reduce(0) { $0 + $1.resourceBytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                Button("All scripts") { path = [] }
                    .buttonStyle(.plain)
                    .foregroundStyle(path.isEmpty ? Color.primary : DeveloperToolsStyle.tint)
                ForEach(Array(path.enumerated()), id: \.element.id) { offset, node in
                    Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.secondary)
                    Button(Self.short(node.name)) { path = Array(path.prefix(offset + 1)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(offset == path.count - 1 ? Color.primary : DeveloperToolsStyle.tint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(Self.size(total)).font(DeveloperToolsStyle.code).foregroundStyle(.secondary)
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter + 4)
            .frame(height: DeveloperToolsStyle.toolbarHeight + 6)
            .background(DeveloperToolsStyle.chrome)
            Divider()
            if shown.isEmpty {
                Text(roots.isEmpty ? "The page loaded no scripts whose text could be read." : "No modules.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let frames = DeveloperLighthouseTreemap.squarify(shown.map(\.resourceBytes),
                                                                     in: CGRect(origin: .zero, size: geometry.size))
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { offset, node in
                            cell(node, color: color(offset), frame: frames[offset])
                        }
                    }
                }
                .padding(DeveloperToolsStyle.gutter)
            }
            Divider()
            Text(footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DeveloperToolsStyle.gutter + 4).padding(.vertical, 6)
        }
        .font(.system(size: 11))
        .frame(minWidth: 640, idealWidth: 820, minHeight: 440, idealHeight: 560)
        .accessibilityIdentifier("developer-lighthouse-treemap")
    }

    private var footnote: String {
        "\(title). Sizes are of each script's text as the page has it; modules come from the scripts' source maps, and unused bytes from JavaScriptCore's coverage over the load (per script)."
    }

    private func color(_ offset: Int) -> Color {
        // A root keeps its hue as it is opened.
        let index = path.first.flatMap { first in roots.firstIndex { $0.id == first.id } } ?? offset
        let hue = Double((path.isEmpty ? offset : index) % 12) / 12
        return Color(hue: hue, saturation: 0.45, brightness: 0.85)
    }

    @ViewBuilder
    private func cell(_ node: DeveloperLighthouseTreemap.Node, color: Color, frame: CGRect) -> some View {
        let unused = node.unusedBytes.map { node.resourceBytes > 0 ? min(1, $0 / node.resourceBytes) : 0 }
        let fill = color.opacity(hovered == node.id ? 1 : (path.isEmpty ? 0.85 : 0.7))
        ZStack(alignment: .topLeading) {
            Rectangle().fill(fill)
            if let unused, unused > 0 {
                // The unused share, darker, along the bottom.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle().fill(Color.black.opacity(0.18)).frame(height: max(0, frame.height * CGFloat(unused)))
                }
            }
            if frame.width > 46, frame.height > 26 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.short(node.name)).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(label(node)).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                }
                .foregroundStyle(Color.black.opacity(0.8))
                .padding(4)
            }
        }
        .overlay(Rectangle().stroke(Color.white.opacity(0.9), lineWidth: 1))
        .frame(width: max(0, frame.width), height: max(0, frame.height))
        .offset(x: frame.minX, y: frame.minY)
        .help("\(node.name)\n\(label(node))" + (node.children.isEmpty ? "" : "\nClick to open"))
        .onHover { inside in hovered = inside ? node.id : (hovered == node.id ? nil : hovered) }
        .onTapGesture { if !node.children.isEmpty { path.append(node) } }
    }

    /// Bytes under 1 KiB, a tenth of a KiB under 10, whole KiB above, as
    /// Lighthouse's treemap: a small script must not read as 0 KiB.
    nonisolated static func size(_ bytes: Double) -> String {
        if bytes < 1024 { return Int(bytes.rounded()).formatted() + " B" }
        let kib = bytes / 1024
        return kib < 10 ? String(format: "%.1f KiB", kib) : Int(kib.rounded()).formatted() + " KiB"
    }

    private func label(_ node: DeveloperLighthouseTreemap.Node) -> String {
        var text = Self.size(node.resourceBytes)
        if let unused = node.unusedBytes, unused > 0 { text += " · " + Self.size(unused) + " unused" }
        return text
    }

    /// A script's file name rather than its whole address.
    static func short(_ name: String) -> String {
        guard name.contains("://"), let address = URL(string: name) else { return name }
        let file = address.lastPathComponent
        return file.isEmpty || file == "/" ? address.host() ?? name : file
    }
}
