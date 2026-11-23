import Foundation

/// Declarations that have no effect where they are, as Chrome DevTools
/// tells: a flex container's properties on an element that isn't one, a
/// flex item's when the parent isn't a flex container, offsets on a
/// statically positioned element and the like. Elements › Styles shows the
/// reason by the declaration's info icon; CSS Overview's "Unused
/// declarations" groups elements by it.
enum DeveloperInactiveCSS {
    /// What decides it: the element's computed style and its parent's, by
    /// CSS property name (`display`, `column-count`), and the element's tag.
    struct Context: Equatable {
        var tag: String
        var svgShape = false
        var computed: [String: String]
        var parent: [String: String] = [:]

        /// The computed properties the rules read, kept from a full
        /// computed style.
        static let fields: Set<String> = [
            "display", "position", "float", "overflow", "overflow-x", "column-count", "column-width",
        ]

        init(tag: String, svgShape: Bool = false, computed: [String: String], parent: [String: String] = [:]) {
            self.tag = tag.lowercased()
            self.svgShape = svgShape
            self.computed = computed.filter { Self.fields.contains($0.key) }
            self.parent = parent.filter { Self.fields.contains($0.key) }
        }

        func own(_ name: String) -> String { (computed[name] ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
        func ofParent(_ name: String) -> String { (parent[name] ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// Elements whose width and height apply while inline: replaced ones.
    static let replaced: Set<String> = [
        "img", "input", "video", "canvas", "iframe", "embed", "object", "select", "textarea", "button",
        "svg", "audio", "meter", "progress", "picture", "model",
    ]

    static let flexContainer: Set<String> = ["flex-direction", "flex-flow", "flex-wrap"]
    static let gridContainer: Set<String> = [
        "grid-template", "grid-template-columns", "grid-template-rows", "grid-template-areas",
        "grid-auto-columns", "grid-auto-rows", "grid-auto-flow",
    ]
    static let flexOrGridContainer: Set<String> = ["justify-content", "align-items"]
    static let gaps: Set<String> = ["gap", "row-gap", "column-gap", "grid-gap", "grid-row-gap", "grid-column-gap"]
    static let flexItem: Set<String> = ["flex", "flex-basis", "flex-grow", "flex-shrink"]
    static let gridItem: Set<String> = [
        "grid-area", "grid-column", "grid-row", "grid-column-start", "grid-column-end",
        "grid-row-start", "grid-row-end",
    ]
    static let flexOrGridItem: Set<String> = ["order", "align-self"]
    static let offsets: Set<String> = [
        "top", "right", "bottom", "left", "inset", "inset-block", "inset-inline",
        "inset-block-start", "inset-block-end", "inset-inline-start", "inset-inline-end",
    ]
    static let multicolContainer: Set<String> = [
        "column-fill", "column-rule", "column-rule-color", "column-rule-style", "column-rule-width",
    ]
    static let margins: Set<String> = ["margin", "margin-top", "margin-right", "margin-bottom", "margin-left"]
    static let paddings: Set<String> = ["padding", "padding-top", "padding-right", "padding-bottom", "padding-left"]
    static let tableParts: Set<String> = [
        "table-row", "table-row-group", "table-header-group", "table-footer-group", "table-column", "table-column-group",
    ]

    static func isFlex(_ display: String) -> Bool { display.contains("flex") }
    static func isGrid(_ display: String) -> Bool { display.contains("grid") }

    /// Why `property` has no effect on the element `context` describes,
    /// in Chrome's words; nil when it may have one (or the context is too
    /// thin to tell).
    static func reason(property: String, value: String, in context: Context) -> String? {
        let name = property.lowercased()
        let value = value.trimmingCharacters(in: .whitespaces).lowercased()
        let display = context.own("display")
        let position = context.own("position")
        let parentDisplay = context.ofParent("display")
        // A parent with display: contents passes its children to its own
        // parent, which isn't known here; nor is a missing one.
        let parentKnown = !parentDisplay.isEmpty && parentDisplay != "contents"
        let parentFlexOrGrid = parentKnown && (isFlex(parentDisplay) || isGrid(parentDisplay))

        if !display.isEmpty, display != "contents" {
            if flexContainer.contains(name), !isFlex(display) {
                return own("display", display, prevents: name, fix: "Try setting display to flex.")
            }
            if gridContainer.contains(name), !isGrid(display) {
                return own("display", display, prevents: name, fix: "Try setting display to grid.")
            }
            if flexOrGridContainer.contains(name), !isFlex(display), !isGrid(display) {
                return own("display", display, prevents: name, fix: "Try setting display to flex or grid.")
            }
            if gaps.contains(name), !isFlex(display), !isGrid(display), !isMulticol(context) {
                return own("display", display, prevents: name, fix: "Try setting display to flex or grid.")
            }
            if name == "width" || name == "height", display == "inline",
               !replaced.contains(context.tag), !context.svgShape {
                return own("display", display, prevents: name, fix: "Try setting display to something other than inline.")
            }
            if name == "vertical-align", !display.contains("inline"), display != "table-cell", display != "none" {
                return own("display", display, prevents: name,
                           fix: "Try setting display to something other than \(display).")
            }
            if margins.contains(name), display == "table-cell" {
                return own("display", display, prevents: name, fix: "Try setting display to something other than table-cell.")
            }
            if paddings.contains(name), tableParts.contains(display) {
                return own("display", display, prevents: name, fix: "Try setting display to something other than \(display).")
            }
            if name == "text-overflow" {
                let overflow = context.own("overflow-x").isEmpty ? context.own("overflow") : context.own("overflow-x")
                if overflow == "visible" {
                    return own("overflow", overflow, prevents: name, fix: "Try setting overflow to hidden.")
                }
            }
        }
        if multicolContainer.contains(name), context.computed["column-count"] != nil, !isMulticol(context) {
            return "The column-count: auto and column-width: auto properties prevent \(name) from having an effect. "
                + "Try setting column-count or column-width."
        }
        if position == "static" {
            if offsets.contains(name) {
                return own("position", position, prevents: name, fix: "Try setting position to something other than static.")
            }
            if name == "z-index", parentKnown, !parentFlexOrGrid {
                return own("position", position, prevents: name, fix: "Try setting position to something other than static.")
            }
        }
        if name == "float", value != "none" {
            if position == "absolute" || position == "fixed" {
                return own("position", position, prevents: name, fix: "Try setting position to something other than \(position).")
            }
            if parentFlexOrGrid {
                return parent("display", parentDisplay, prevents: name,
                              fix: "Try setting the display of the parent to something other than \(parentDisplay).")
            }
        }
        guard parentKnown else { return nil }
        if flexItem.contains(name), !isFlex(parentDisplay) {
            return parent("display", parentDisplay, prevents: name, fix: "Try setting the display of the parent to flex.")
        }
        if gridItem.contains(name), !isGrid(parentDisplay) {
            return parent("display", parentDisplay, prevents: name, fix: "Try setting the display of the parent to grid.")
        }
        if flexOrGridItem.contains(name), !parentFlexOrGrid,
           !(name == "align-self" && (position == "absolute" || position == "fixed")) {
            return parent("display", parentDisplay, prevents: name,
                          fix: "Try setting the display of the parent to flex or grid.")
        }
        return nil
    }

    private static func isMulticol(_ context: Context) -> Bool {
        let count = context.own("column-count")
        let width = context.own("column-width")
        return (!count.isEmpty && count != "auto") || (!width.isEmpty && width != "auto")
    }

    private static func own(_ reason: String, _ value: String, prevents property: String, fix: String) -> String {
        "The \(reason): \(value) property prevents \(property) from having an effect. \(fix)"
    }

    private static func parent(_ reason: String, _ value: String, prevents property: String, fix: String) -> String {
        "The \(reason): \(value) property of the parent element prevents \(property) from having an effect. \(fix)"
    }
}
