import Foundation

/// Statistics' categories, as Chrome names them. JavaScriptCore's class
/// names say which an object is: "Function" and its executables and code
/// blocks are code, "string" a string, and so on.
enum DeveloperHeapCategory: String, CaseIterable, Identifiable, Sendable {
    case code = "Code"
    case strings = "Strings"
    case arrays = "JS arrays"
    case typedArrays = "Typed arrays"
    case system = "System objects"
    case dom = "DOM nodes"
    case other = "Other JS objects"

    var id: String { rawValue }

    private static let typedArrayNames: Set<String> = [
        "Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array", "Int32Array",
        "Uint32Array", "Float16Array", "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array",
        "ArrayBuffer", "SharedArrayBuffer", "DataView",
    ]

    private static let systemNames: Set<String> = [
        "Structure", "StructureChain", "StructureRareData", "SymbolTable", "PropertyTable",
        "JSPropertyNameEnumerator", "SparseArrayValueMap", "GetterSetter", "CustomGetterSetter",
        "JSLexicalEnvironment", "LexicalEnvironment", "JSGlobalLexicalEnvironment", "JSSourceCode",
        "JSScriptFetcher", "JSScriptFetchParameters", "InferredValue", "JSTemplateObjectDescriptor",
        "WeakMapImpl", "HashMapImpl", "JSCallee", "Exception", "JSModuleRecord", "JSWebAssemblyModule",
    ]

    /// Which category an object of `className` falls in; `isInternal` is
    /// JavaScriptCore's internal flag and `domNode` whether it's a DOM node.
    static func of(className: String, isInternal: Bool, domNode: Bool) -> DeveloperHeapCategory {
        let name = className.hasPrefix("JS") && className.count > 2 ? String(className.dropFirst(2)) : className
        if name == "Function" || name.hasSuffix("Function") || name.hasSuffix("Executable")
            || name.contains("CodeBlock") { return .code }
        if name == "string" || name == "String" || name == "RopeString" { return .strings }
        if typedArrayNames.contains(name) { return .typedArrays }
        if name == "Array" || name == "ArrayStorage" { return .arrays }
        if domNode { return .dom }
        if isInternal || systemNames.contains(className) || systemNames.contains(name) { return .system }
        return .other
    }
}

/// Statistics: the heap's shallow sizes added up per category.
struct DeveloperHeapStatistics: Equatable, Sendable {
    struct Bucket: Identifiable, Equatable, Sendable {
        let category: DeveloperHeapCategory
        var count = 0
        var size = 0
        var id: DeveloperHeapCategory { category }
    }

    /// Every category, in Chrome's order, empty ones included.
    let buckets: [Bucket]
    let total: Int

    subscript(_ category: DeveloperHeapCategory) -> Bucket {
        buckets.first { $0.category == category } ?? Bucket(category: category)
    }
}

extension DeveloperHeapSnapshot {
    func category(of node: Int) -> DeveloperHeapCategory {
        DeveloperHeapCategory.of(className: classNames[classIndexes[node]], isInternal: isInternal(node),
                                 domNode: suggestsDOMNode(node))
    }

    /// Statistics for the whole snapshot, the GC roots left out.
    func statistics() -> DeveloperHeapStatistics {
        var buckets = DeveloperHeapCategory.allCases.map { DeveloperHeapStatistics.Bucket(category: $0) }
        let position = Dictionary(uniqueKeysWithValues: DeveloperHeapCategory.allCases.enumerated().map { ($1, $0) })
        var total = 0
        for node in 0..<nodeCount where node != root {
            let index = position[category(of: node)] ?? buckets.count - 1
            buckets[index].count += 1
            buckets[index].size += sizes[node]
            total += sizes[node]
        }
        return DeveloperHeapStatistics(buckets: buckets, total: total)
    }
}
