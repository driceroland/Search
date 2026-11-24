import CoreGraphics
import Foundation

// Chrome DevTools' Layers tool (More tools › Layers), over WebKit's
// LayerTree domain: every composited layer of the page, from
// LayerTree.layersForNode on the document, with its size, memory and
// paint count; why WebKit composited it (reasonsForCompositingLayer); and
// a picture of the layers stacked in paint order. This file is the
// arithmetic, apart from the page: parsing, labels, the tree, the
// compositing reasons in words and the diagram's geometry.

/// A rectangle as the protocol sends it, in page coordinates.
struct DeveloperLayerRect: Equatable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 0
    var height: Double = 0

    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var isEmpty: Bool { width <= 0 || height <= 0 }

    func union(_ other: DeveloperLayerRect) -> DeveloperLayerRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let minX = min(x, other.x), minY = min(y, other.y)
        return DeveloperLayerRect(x: minX, y: minY, width: max(maxX, other.maxX) - minX, height: max(maxY, other.maxY) - minY)
    }

    /// `1280 × 720`, as the list shows a layer's size.
    var sizeLabel: String { "\(Self.integer(width)) × \(Self.integer(height))" }
    /// `(0, 64) 1280 × 720`.
    var label: String { "(\(Self.integer(x)), \(Self.integer(y))) " + sizeLabel }

    private static func integer(_ value: Double) -> String {
        value.isFinite ? String(Int(value.rounded())) : "0"
    }
}

extension DeveloperLayerRect {
    init?(raw: Any?) {
        guard let raw = raw as? [String: Any] else { return nil }
        let number = DeveloperLayerTree.number
        self.init(x: number(raw["x"]) ?? 0, y: number(raw["y"]) ?? 0,
                  width: max(0, number(raw["width"]) ?? 0), height: max(0, number(raw["height"]) ?? 0))
    }
}

/// One composited layer, as WebKit's LayerTree.Layer describes it.
struct DeveloperLayer: Identifiable, Equatable {
    let id: String
    /// The node the layer belongs to (its renderer's, or its nearest
    /// node's for an anonymous one).
    var nodeId: Int
    /// Where the layer is, in page coordinates.
    var bounds: DeveloperLayerRect
    /// What the layer's backing store covers, in page coordinates. WebKit
    /// sends it relative to `bounds`; its own frontend adds the origin, so
    /// does this.
    var compositedBounds: DeveloperLayerRect
    var paintCount: Int
    /// The backing store's estimate, in bytes.
    var memory: Double
    var isInShadowTree = false
    var isReflection = false
    var isGeneratedContent = false
    var isAnonymous = false
    var pseudoElementId: String?
    var pseudoElement: String?
    /// Its place in WebKit's list, which is paint order (back to front).
    var order: Int

    init(id: String, nodeId: Int = 0, bounds: DeveloperLayerRect = .init(), compositedBounds: DeveloperLayerRect? = nil,
         paintCount: Int = 0, memory: Double = 0, order: Int = 0) {
        self.id = id
        self.nodeId = nodeId
        self.bounds = bounds
        self.compositedBounds = compositedBounds ?? bounds
        self.paintCount = paintCount
        self.memory = memory
        self.order = order
    }

    init?(raw: [String: Any], order: Int) {
        let number = DeveloperLayerTree.number
        guard let layerID = Self.identifier(raw["layerId"]) else { return nil }
        let bounds = DeveloperLayerRect(raw: raw["bounds"]) ?? .init()
        var composited = DeveloperLayerRect(raw: raw["compositedBounds"]) ?? DeveloperLayerRect(width: bounds.width, height: bounds.height)
        composited.x += bounds.x
        composited.y += bounds.y
        self.init(id: layerID, nodeId: Int(number(raw["nodeId"]) ?? 0), bounds: bounds, compositedBounds: composited,
                  paintCount: max(0, Int(number(raw["paintCount"]) ?? 0)), memory: max(0, number(raw["memory"]) ?? 0),
                  order: order)
        isInShadowTree = raw["isInShadowTree"] as? Bool ?? false
        isReflection = raw["isReflection"] as? Bool ?? false
        isGeneratedContent = raw["isGeneratedContent"] as? Bool ?? false
        isAnonymous = raw["isAnonymous"] as? Bool ?? false
        pseudoElementId = Self.identifier(raw["pseudoElementId"])
        pseudoElement = (raw["pseudoElement"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// An id the protocol sends as a string or a number.
    private static func identifier(_ value: Any?) -> String? {
        switch value {
        case let text as String where !text.isEmpty: text
        case let value as NSNumber: value.stringValue
        default: nil
        }
    }

    /// The node's own layer, not one of the extra ones a node can have
    /// (a ::before's, a reflection's, an anonymous renderer's).
    var isPrimary: Bool { !isGeneratedContent && !isReflection && !isAnonymous }
}

/// The page's answer to labelling the layers' nodes: a node's label and
/// its nearest ancestor among them (by index), or nil.
struct DeveloperLayerNodeInfo: Equatable {
    var label: String
    var parent: Int?
}

/// Labels, the tree, sorting and the summary line.
enum DeveloperLayerTree {
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    /// A layer list from LayersForNode's reply, in WebKit's order; a layer
    /// sent twice is kept once.
    static func layers(_ raw: [[String: Any]]) -> [DeveloperLayer] {
        var seen = Set<String>()
        var layers: [DeveloperLayer] = []
        for (index, item) in raw.enumerated() {
            guard let layer = DeveloperLayer(raw: item, order: index), seen.insert(layer.id).inserted else { continue }
            layers.append(layer)
        }
        return layers
    }

    /// The row's name: its node's label, with what kind of extra layer it
    /// is when it isn't the node's own.
    static func label(_ layer: DeveloperLayer, node: String?) -> String {
        var base = node.flatMap { $0.isEmpty ? nil : $0 } ?? (layer.nodeId > 0 ? "node \(layer.nodeId)" : "layer")
        if layer.isGeneratedContent {
            let pseudo = layer.pseudoElement ?? "pseudo"
            base += pseudo.hasPrefix(":") ? pseudo : "::" + pseudo
        }
        if layer.isReflection { base += " (reflection)" }
        if layer.isAnonymous { base = "anonymous in " + base }
        return base
    }

    /// Each layer's parent layer: a node's extra layers go under its own
    /// layer, and a node's layer under the layer of its nearest ancestor
    /// that has one. `nodes` maps a node id to its info; `parent` there
    /// is an index into `order`, the node ids the info was asked for in.
    static func parents(_ layers: [DeveloperLayer], nodes: [Int: DeveloperLayerNodeInfo], order: [Int]) -> [String: String] {
        var primary: [Int: String] = [:]
        var first: [Int: String] = [:]
        for layer in layers {
            if layer.isPrimary, primary[layer.nodeId] == nil { primary[layer.nodeId] = layer.id }
            if first[layer.nodeId] == nil { first[layer.nodeId] = layer.id }
        }
        func layerOfAncestor(of node: Int) -> String? {
            var current = nodes[node]?.parent
            var steps = 0
            while let index = current, index >= 0, index < order.count, steps < 10_000 {
                let ancestor = order[index]
                if let found = primary[ancestor] ?? first[ancestor] { return found }
                current = nodes[ancestor]?.parent
                steps += 1
            }
            return nil
        }
        var result: [String: String] = [:]
        for layer in layers {
            if !layer.isPrimary, let own = primary[layer.nodeId], own != layer.id {
                result[layer.id] = own
            } else if let parent = layerOfAncestor(of: layer.nodeId), parent != layer.id {
                result[layer.id] = parent
            }
        }
        // A cycle (bad info) would hide layers: break it at the layer that closes it.
        for layer in layers {
            var seen: Set<String> = [layer.id]
            var current = result[layer.id]
            while let id = current {
                if !seen.insert(id).inserted { result[layer.id] = nil; break }
                current = result[id]
            }
        }
        return result
    }

    struct Row: Equatable, Identifiable {
        var layer: DeveloperLayer
        var depth: Int
        var id: String { layer.id }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case tree = "DOM tree"
        case paintCount = "Paint count"
        case memory = "Memory"
        var id: Self { self }
    }

    /// The list's rows: nested by DOM (depth-first, siblings in paint
    /// order), or flat, most painted or most memory first.
    static func rows(_ layers: [DeveloperLayer], parents: [String: String], sort: Sort) -> [Row] {
        switch sort {
        case .paintCount:
            return layers.sorted {
                $0.paintCount != $1.paintCount ? $0.paintCount > $1.paintCount : $0.order < $1.order
            }.map { Row(layer: $0, depth: 0) }
        case .memory:
            return layers.sorted {
                $0.memory != $1.memory ? $0.memory > $1.memory : $0.order < $1.order
            }.map { Row(layer: $0, depth: 0) }
        case .tree:
            let known = Set(layers.map(\.id))
            var children: [String: [DeveloperLayer]] = [:]
            var roots: [DeveloperLayer] = []
            for layer in layers.sorted(by: { $0.order < $1.order }) {
                if let parent = parents[layer.id], known.contains(parent) {
                    children[parent, default: []].append(layer)
                } else {
                    roots.append(layer)
                }
            }
            var rows: [Row] = []
            var visited = Set<String>()
            func visit(_ layer: DeveloperLayer, depth: Int) {
                guard visited.insert(layer.id).inserted else { return }
                rows.append(Row(layer: layer, depth: depth))
                for child in children[layer.id] ?? [] { visit(child, depth: depth + 1) }
            }
            for root in roots { visit(root, depth: 0) }
            // Anything left (it can't be, after parents' cycle check) still shows.
            for layer in layers where !visited.contains(layer.id) { visit(layer, depth: 0) }
            return rows
        }
    }

    static func totalMemory(_ layers: [DeveloperLayer]) -> Double { layers.reduce(0) { $0 + $1.memory } }

    /// `12 layers · 34.5 MB`, the summary line.
    static func summary(_ layers: [DeveloperLayer]) -> String {
        let count = layers.count
        return "\(count) layer\(count == 1 ? "" : "s") · " + bytes(totalMemory(layers))
    }

    /// `0 B`, `812 B`, `4.1 kB`, `12.3 MB`, as Chrome writes sizes (1000s).
    static func bytes(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0 B" }
        if value < 1000 { return "\(Int(value.rounded())) B" }
        let units = ["kB", "MB", "GB", "TB"]
        var amount = value / 1000
        var unit = 0
        while amount >= 999.95, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        let text = amount < 99.95 ? String(format: "%.1f", amount) : String(Int(amount.rounded()))
        return text + " " + units[unit]
    }
}

/// Why WebKit composited a layer, in words: WebKit's own frontend's
/// sentences, in its order, and any reason newer than these spelled out
/// from its name.
enum DeveloperLayerReasons {
    static let known: [(key: String, label: String)] = [
        ("transform3D", "Element has a 3D transform"),
        ("video", "Element is <video>"),
        ("canvas", "Element is <canvas>"),
        ("plugin", "Element is a plug-in"),
        ("iFrame", "Element is <iframe>"),
        ("model", "Element is <model>"),
        ("backfaceVisibilityHidden", "Element has “backface-visibility: hidden” style"),
        ("clipsCompositingDescendants", "Element clips compositing descendants"),
        ("animation", "Element is animated"),
        ("filters", "Element has CSS filters applied"),
        ("positionFixed", "Element has “position: fixed” style"),
        ("positionSticky", "Element has “position: sticky” style"),
        ("overflowScrollingTouch", "Element has “-webkit-overflow-scrolling: touch” style"),
        ("stacking", "Element may overlap another compositing element"),
        ("overlap", "Element overlaps other compositing element"),
        ("negativeZIndexChildren", "Element has children with a negative z-index"),
        ("transformWithCompositedDescendants", "Element has a 2D transform and composited descendants"),
        ("opacityWithCompositedDescendants", "Element has opacity applied and composited descendants"),
        ("maskWithCompositedDescendants", "Element is masked and has composited descendants"),
        ("reflectionWithCompositedDescendants", "Element has a reflection and composited descendants"),
        ("filterWithCompositedDescendants", "Element has CSS filters applied and composited descendants"),
        ("blendingWithCompositedDescendants", "Element has CSS blending applied and composited descendants"),
        ("isolatesCompositedBlendingDescendants",
         "Element is a stacking context and has composited descendants with CSS blending applied"),
        ("perspective", "Element has perspective applied"),
        ("preserve3D", "Element has “transform-style: preserve-3d” style"),
        ("willChange",
         "Element has “will-change” style which includes opacity, transform, transform-style, perspective, filter or backdrop-filter"),
        ("root", "Element is the root element"),
        ("blending", "Element has “blend-mode” style"),
        ("backdropRoot", "Element is a backdrop root"),
    ]

    /// The reasons set in `raw` (reasonsForCompositingLayer's
    /// compositingReasons), known ones first in WebKit's order, then the
    /// rest alphabetically.
    static func labels(_ raw: [String: Any]) -> [String] {
        func isSet(_ value: Any?) -> Bool {
            switch value {
            case let flag as Bool: return flag
            case let number as NSNumber: return number.boolValue
            default: return false
            }
        }
        let knownKeys = Set(known.map(\.key))
        var labels = known.filter { isSet(raw[$0.key]) }.map(\.label)
        labels += raw.keys.filter { !knownKeys.contains($0) && isSet(raw[$0]) }.sorted().map(spelled)
        return labels
    }

    /// `someNewReason` → `Some new reason`; `transform3D` → `Transform 3D`.
    static func spelled(_ key: String) -> String {
        var words: [String] = []
        var current = ""
        let characters = Array(key)
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let previous = current.last
            // A capital after a small letter starts a word, as does the
            // last capital of an acronym followed by a small letter
            // (HTMLThing); digits start one after a letter (transform3D).
            let startsWord = previous.map { previous in
                character.isUppercase ? previous.isLowercase || (previous.isUppercase && (next?.isLowercase ?? false))
                    : character.isNumber && previous.isLetter
            } ?? false
            if startsWord {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        let joined = words.enumerated().map { index, word in
            // Acronyms (3D, CSS) keep their case.
            word.count > 1 && word == word.uppercased() ? word : index == 0 ? word : word.lowercased()
        }.joined(separator: " ")
        guard let first = joined.first else { return key }
        return first.uppercased() + joined.dropFirst()
    }
}

/// The diagram: each layer a rectangle, stacked in paint order and seen
/// from an angle (yaw about the vertical axis, pitch about the horizontal),
/// projected flat. At yaw and pitch 0 it is the page seen straight on.
enum DeveloperLayerGeometry {
    struct Point3: Equatable {
        var x: Double
        var y: Double
        var z: Double
    }

    /// A layer's drawn outline: four corners on screen, and its depth after
    /// the turn (larger is nearer the viewer) to draw back to front.
    struct Quad: Equatable {
        var id: String
        var corners: [CGPoint]
        var depth: Double
    }

    struct Fit: Equatable {
        var scale: Double
        var dx: Double
        var dy: Double

        func apply(_ point: CGPoint) -> CGPoint {
            CGPoint(x: Double(point.x) * scale + dx, y: Double(point.y) * scale + dy)
        }
    }

    /// Everything the layers cover, in page coordinates.
    static func extent(_ layers: [DeveloperLayer]) -> DeveloperLayerRect {
        layers.reduce(DeveloperLayerRect()) { $0.union($1.bounds).union($1.compositedBounds) }
    }

    /// How far apart the layers are stacked, in page units: the stack about
    /// half as deep as the page is large, no gap wider than a tenth of it.
    static func spacing(extent: DeveloperLayerRect, count: Int) -> Double {
        let size = max(extent.width, extent.height, 1)
        guard count > 1 else { return 0 }
        return min(size * 0.1, size * 0.5 / Double(count - 1))
    }

    /// A point turned by `yaw` then `pitch` (radians) about `center`, and
    /// its depth toward the viewer.
    static func project(_ point: Point3, center: Point3, yaw: Double, pitch: Double) -> (point: CGPoint, depth: Double) {
        let x = point.x - center.x, y = point.y - center.y, z = point.z - center.z
        let x1 = x * cos(yaw) + z * sin(yaw)
        let z1 = -x * sin(yaw) + z * cos(yaw)
        let y2 = y * cos(pitch) - z1 * sin(pitch)
        let z2 = y * sin(pitch) + z1 * cos(pitch)
        return (CGPoint(x: x1, y: y2), z2)
    }

    /// Every layer's outline, back to front, before fitting to the view.
    static func quads(_ layers: [DeveloperLayer], yaw: Double, pitch: Double) -> [Quad] {
        let area = Self.extent(layers)
        let gap = spacing(extent: area, count: layers.count)
        let ordered = layers.sorted { $0.order < $1.order }
        let depthCenter = gap * Double(max(0, ordered.count - 1)) / 2
        let center = Point3(x: area.x + area.width / 2, y: area.y + area.height / 2, z: depthCenter)
        let outlines = ordered.enumerated().map { index, layer -> Quad in
            let rect = layer.bounds
            let z = gap * Double(index)
            let corners = [(rect.x, rect.y), (rect.maxX, rect.y), (rect.maxX, rect.maxY), (rect.x, rect.maxY)].map {
                project(Point3(x: $0.0, y: $0.1, z: z), center: center, yaw: yaw, pitch: pitch)
            }
            let depth = project(Point3(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2, z: z),
                                center: center, yaw: yaw, pitch: pitch).depth
            return Quad(id: layer.id, corners: corners.map { $0.point }, depth: depth)
        }
        // Stable: equal depths keep paint order.
        return outlines.enumerated().sorted {
            $0.element.depth != $1.element.depth ? $0.element.depth < $1.element.depth : $0.offset < $1.offset
        }.map(\.element)
    }

    /// The scale and offset that fit `points` into `size`, centred, with
    /// `padding` all round.
    static func fit(_ points: [CGPoint], into size: CGSize, padding: Double = 12) -> Fit {
        guard let first = points.first else { return Fit(scale: 1, dx: 0, dy: 0) }
        var minX = Double(first.x), maxX = minX, minY = Double(first.y), maxY = minY
        for point in points {
            minX = min(minX, Double(point.x)); maxX = max(maxX, Double(point.x))
            minY = min(minY, Double(point.y)); maxY = max(maxY, Double(point.y))
        }
        let width = max(maxX - minX, 1), height = max(maxY - minY, 1)
        let availableWidth = max(Double(size.width) - padding * 2, 1)
        let availableHeight = max(Double(size.height) - padding * 2, 1)
        let scale = min(availableWidth / width, availableHeight / height)
        let dx = (Double(size.width) - width * scale) / 2 - minX * scale
        let dy = (Double(size.height) - height * scale) / 2 - minY * scale
        return Fit(scale: scale, dx: dx, dy: dy)
    }

    /// Whether `point` is inside the polygon (even-odd rule).
    static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            if (current.y > point.y) != (previous.y > point.y) {
                let crossing = (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x
                if point.x < crossing { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    /// The front-most layer under `point`; `quads` back to front, already fitted.
    static func hit(_ quads: [Quad], at point: CGPoint) -> String? {
        quads.reversed().first { contains($0.corners, point) }?.id
    }
}
