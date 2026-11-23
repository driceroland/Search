import Foundation

// The Memory inspector drawer tool's pure logic: which objects it opens,
// addresses typed in and written out, the hex view's rows and pages, the
// address history, byte editing, and a byte run read as integers, floats
// and pointers of each width in either byte order.

/// Which remote objects the inspector opens: ArrayBuffer, SharedArrayBuffer,
/// every TypedArray, DataView and WebAssembly.Memory, as Chrome offers
/// "Reveal in Memory inspector panel" on them.
enum DeveloperMemoryInspectable {
    static let typedArrays: Set<String> = [
        "Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array", "Int32Array", "Uint32Array",
        "Float16Array", "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array",
    ]
    static let buffers: Set<String> = ["ArrayBuffer", "SharedArrayBuffer"]
    static let memories: Set<String> = ["WebAssembly.Memory", "Memory"]

    enum Kind: String, Equatable {
        case buffer, typedArray, dataView, wasmMemory
    }

    static func kind(className: String?, type: String = "object") -> Kind? {
        guard type == "object", let className else { return nil }
        if buffers.contains(className) { return .buffer }
        if typedArrays.contains(className) { return .typedArray }
        if className == "DataView" { return .dataView }
        if memories.contains(className) { return .wasmMemory }
        return nil
    }

    static func inspectable(className: String?, type: String = "object", objectId: String?) -> Bool {
        objectId != nil && kind(className: className, type: type) != nil
    }
}

/// Addresses as typed in Chrome's address field and drawn in the address
/// column: "0x1A" or "1Ah" in hex, "26" in decimal.
enum DeveloperMemoryAddress {
    static func parse(_ text: String) -> Int? {
        var value = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "")
        guard !value.isEmpty else { return nil }
        var radix = 10
        if value.lowercased().hasPrefix("0x") {
            value = String(value.dropFirst(2))
            radix = 16
        } else if value.lowercased().hasSuffix("h") {
            value = String(value.dropLast())
            radix = 16
        } else if value.contains(where: { "abcdefABCDEF".contains($0) }) {
            radix = 16
        }
        guard !value.isEmpty, let parsed = Int(value, radix: radix), parsed >= 0 else { return nil }
        return parsed
    }

    /// "0x0000001A": eight hex digits, more when the buffer needs them.
    static func format(_ address: Int, length: Int = 0) -> String {
        "0x" + digits(address, length: length)
    }

    static func digits(_ address: Int, length: Int = 0) -> String {
        let width = max(8, String(max(0, length - 1), radix: 16).count)
        let hex = String(max(0, address), radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, width - hex.count)) + hex
    }
}

/// The hex view's geometry: rows of a fixed width, a page of rows read
/// at a time, and where each byte sits.
struct DeveloperMemoryLayout: Equatable {
    var bytesPerRow = 16
    var rows = 16

    var pageSize: Int { bytesPerRow * rows }

    /// The start of the page an address is on.
    func pageStart(_ address: Int) -> Int {
        guard pageSize > 0 else { return 0 }
        return max(0, address) / pageSize * pageSize
    }

    /// The row starts of a page, cut short at the buffer's end.
    func rowStarts(page: Int, length: Int) -> [Int] {
        guard length > 0 else { return [] }
        return stride(from: page, to: min(length, page + pageSize), by: bytesPerRow).map { $0 }
    }

    /// The address a step of pages away, kept in the buffer: Chrome's
    /// previous and next page buttons. The byte keeps its place on the page.
    func step(_ address: Int, pages: Int, length: Int) -> Int {
        guard length > 0 else { return 0 }
        let moved = address + pages * pageSize
        if moved < 0 {
            // Before the first page: the same column on the first page.
            return address - pageStart(address)
        }
        if moved >= length {
            // Past the end: the last byte, unless already on the last page.
            return pageStart(address) == pageStart(length - 1) ? address : length - 1
        }
        return moved
    }

    /// Bytes per row that fit a width, in multiples of 4 as Chrome's view
    /// reflows; at least 4.
    static func bytesPerRow(fitting width: Double, byteWidth: Double, fixed: Double) -> Int {
        guard byteWidth > 0 else { return 16 }
        let fits = Int((width - fixed) / byteWidth)
        return max(4, min(32, fits / 4 * 4))
    }

    static func clamp(_ address: Int, length: Int) -> Int {
        guard length > 0 else { return 0 }
        return min(max(0, address), length - 1)
    }
}

/// Chrome's back and forward through the addresses visited.
struct DeveloperMemoryHistory: Equatable {
    private(set) var entries: [Int] = []
    private(set) var index = -1
    let limit: Int

    init(limit: Int = 100) { self.limit = limit }

    var current: Int? { entries.indices.contains(index) ? entries[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < entries.count - 1 }

    /// A new address: what was ahead of it is dropped.
    mutating func visit(_ address: Int) {
        if current == address { return }
        entries = Array(entries.prefix(index + 1)) + [address]
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        index = entries.count - 1
    }

    mutating func back() -> Int? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }

    mutating func forward() -> Int? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }
}

enum DeveloperMemoryBytes {
    /// The ASCII column: printable characters, a dot for the rest.
    static func ascii(_ byte: UInt8) -> Character {
        (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "."
    }

    static func hex(_ byte: UInt8) -> String {
        let text = String(byte, radix: 16, uppercase: true)
        return text.count == 1 ? "0" + text : text
    }

    /// A byte as typed over a cell: one or two hex digits.
    static func parse(_ text: String) -> UInt8? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard (1...2).contains(trimmed.count) else { return nil }
        return UInt8(trimmed, radix: 16)
    }

    /// The page script's answer: an array of numbers, or base64.
    static func decode(_ raw: Any?) -> [UInt8]? {
        if let base64 = raw as? String { return Data(base64Encoded: base64).map { Array($0) } }
        guard let list = raw as? [Any] else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(list.count)
        for item in list {
            guard let number = item as? NSNumber, (0...255).contains(number.intValue) else { return nil }
            bytes.append(UInt8(number.intValue))
        }
        return bytes
    }
}

/// The value-interpretation pane: the bytes at the selected address read
/// as each of Chrome's formats.
enum DeveloperMemoryValue {
    enum Endianness: String, CaseIterable, Identifiable {
        case little = "Little Endian"
        case big = "Big Endian"
        var id: Self { self }
    }

    enum Format: String, CaseIterable, Identifiable {
        case int8 = "Integer 8-bit"
        case int16 = "Integer 16-bit"
        case int32 = "Integer 32-bit"
        case int64 = "Integer 64-bit"
        case float32 = "Float 32-bit"
        case float64 = "Float 64-bit"
        case pointer32 = "Pointer 32-bit"
        case pointer64 = "Pointer 64-bit"
        var id: Self { self }

        var size: Int {
            switch self {
            case .int8: 1
            case .int16: 2
            case .int32, .float32, .pointer32: 4
            case .int64, .float64, .pointer64: 8
            }
        }

        var isInteger: Bool { [.int8, .int16, .int32, .int64].contains(self) }
        var isPointer: Bool { self == .pointer32 || self == .pointer64 }
    }

    /// How an integer is shown, as Chrome's value pane offers.
    enum IntegerMode: String, CaseIterable, Identifiable {
        case decimal = "dec"
        case hexadecimal = "hex"
        case octal = "oct"
        var id: Self { self }
    }

    /// The bytes read as an unsigned number in the given order; nil when
    /// there aren't enough of them.
    static func unsigned(_ bytes: [UInt8], at offset: Int, size: Int, _ endian: Endianness) -> UInt64? {
        guard size > 0, size <= 8, offset >= 0, offset + size <= bytes.count else { return nil }
        let slice = bytes[offset..<offset + size]
        let ordered = endian == .little ? Array(slice.reversed()) : Array(slice)
        return ordered.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    static func signed(_ bytes: [UInt8], at offset: Int, size: Int, _ endian: Endianness) -> Int64? {
        guard let raw = unsigned(bytes, at: offset, size: size, endian) else { return nil }
        let bits = size * 8
        if bits == 64 { return Int64(bitPattern: raw) }
        let sign = UInt64(1) << (bits - 1)
        return raw & sign == 0 ? Int64(raw) : Int64(raw) - (Int64(1) << bits)
    }

    static func float32(_ bytes: [UInt8], at offset: Int, _ endian: Endianness) -> Swift.Float? {
        unsigned(bytes, at: offset, size: 4, endian).map { Swift.Float(bitPattern: UInt32($0)) }
    }

    static func float64(_ bytes: [UInt8], at offset: Int, _ endian: Endianness) -> Double? {
        unsigned(bytes, at: offset, size: 8, endian).map { Double(bitPattern: $0) }
    }

    /// One format's reading as text: "signed / unsigned" for integers in
    /// the given mode, the float's shortest form, a pointer in hex.
    static func text(_ format: Format, bytes: [UInt8], at offset: Int, endian: Endianness,
                     mode: IntegerMode = .decimal) -> String? {
        switch format {
        case .int8, .int16, .int32, .int64:
            guard let raw = unsigned(bytes, at: offset, size: format.size, endian),
                  let signed = signed(bytes, at: offset, size: format.size, endian) else { return nil }
            switch mode {
            case .decimal: return signed >= 0 ? "\(raw)" : "\(signed) / \(raw)"
            case .hexadecimal: return "0x" + String(raw, radix: 16, uppercase: true)
            case .octal: return "0o" + String(raw, radix: 8)
            }
        case .float32:
            return float32(bytes, at: offset, endian).map { floatText($0) }
        case .float64:
            return float64(bytes, at: offset, endian).map { floatText($0) }
        case .pointer32, .pointer64:
            return unsigned(bytes, at: offset, size: format.size, endian).map {
                "0x" + String($0, radix: 16, uppercase: true)
            }
        }
    }

    /// A pointer's target, when it lands inside the buffer: Chrome's
    /// "jump to pointer" is offered only then.
    static func pointerTarget(_ format: Format, bytes: [UInt8], at offset: Int, endian: Endianness, length: Int) -> Int? {
        guard format.isPointer, let raw = unsigned(bytes, at: offset, size: format.size, endian),
              raw < UInt64(max(0, length)) else { return nil }
        return Int(raw)
    }

    static func floatText<F: BinaryFloatingPoint & LosslessStringConvertible>(_ value: F) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
        return value.description
    }
}
