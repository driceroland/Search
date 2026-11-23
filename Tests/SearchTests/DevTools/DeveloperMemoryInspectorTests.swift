import XCTest
@testable import Search

/// The Memory inspector's pure logic: which objects it opens, addresses
/// parsed and formatted, the hex view's rows and pages, history, bytes,
/// and values read across widths and byte orders.
final class DeveloperMemoryInspectorTests: XCTestCase {
    private typealias Value = DeveloperMemoryValue

    // MARK: Inspectable objects

    func testBuffersViewsAndWasmMemoryAreInspectable() {
        XCTAssertEqual(DeveloperMemoryInspectable.kind(className: "ArrayBuffer"), .buffer)
        XCTAssertEqual(DeveloperMemoryInspectable.kind(className: "SharedArrayBuffer"), .buffer)
        XCTAssertEqual(DeveloperMemoryInspectable.kind(className: "Float64Array"), .typedArray)
        XCTAssertEqual(DeveloperMemoryInspectable.kind(className: "BigUint64Array"), .typedArray)
        XCTAssertEqual(DeveloperMemoryInspectable.kind(className: "DataView"), .dataView)
        XCTAssertEqual(DeveloperMemoryInspectable.kind(className: "WebAssembly.Memory"), .wasmMemory)
        XCTAssertNil(DeveloperMemoryInspectable.kind(className: "Array"))
        XCTAssertNil(DeveloperMemoryInspectable.kind(className: "ArrayBuffer", type: "function"))
        XCTAssertFalse(DeveloperMemoryInspectable.inspectable(className: "Uint8Array", objectId: nil))
        XCTAssertTrue(DeveloperMemoryInspectable.inspectable(className: "Uint8Array", objectId: "{\"id\":1}"))
    }

    // MARK: Addresses

    func testAddressesParseInHexOrDecimal() {
        XCTAssertEqual(DeveloperMemoryAddress.parse("0x1A"), 26)
        XCTAssertEqual(DeveloperMemoryAddress.parse("0X1a"), 26)
        XCTAssertEqual(DeveloperMemoryAddress.parse("26"), 26)
        XCTAssertEqual(DeveloperMemoryAddress.parse(" 1Ah "), 26)
        XCTAssertEqual(DeveloperMemoryAddress.parse("ff"), 255, "hex digits mean hex")
        XCTAssertEqual(DeveloperMemoryAddress.parse("0x0000_0100"), 256)
        XCTAssertNil(DeveloperMemoryAddress.parse(""))
        XCTAssertNil(DeveloperMemoryAddress.parse("0x"))
        XCTAssertNil(DeveloperMemoryAddress.parse("-4"))
        XCTAssertNil(DeveloperMemoryAddress.parse("zz"))
    }

    func testAddressesAreWrittenInEightHexDigitsOrMore() {
        XCTAssertEqual(DeveloperMemoryAddress.format(26), "0x0000001A")
        XCTAssertEqual(DeveloperMemoryAddress.digits(0), "00000000")
        XCTAssertEqual(DeveloperMemoryAddress.digits(16, length: 0x1_0000_0000 + 1), "000000010")
    }

    // MARK: Layout

    func testPagesAndRows() {
        let layout = DeveloperMemoryLayout(bytesPerRow: 16, rows: 16)
        XCTAssertEqual(layout.pageSize, 256)
        XCTAssertEqual(layout.pageStart(0), 0)
        XCTAssertEqual(layout.pageStart(255), 0)
        XCTAssertEqual(layout.pageStart(256), 256)
        XCTAssertEqual(layout.pageStart(1000), 768)
        XCTAssertEqual(layout.rowStarts(page: 0, length: 40), [0, 16, 32])
        XCTAssertEqual(layout.rowStarts(page: 256, length: 300), [256, 272, 288])
        XCTAssertEqual(layout.rowStarts(page: 0, length: 0), [])
    }

    func testPagingKeepsTheColumnAndStaysInTheBuffer() {
        let layout = DeveloperMemoryLayout(bytesPerRow: 16, rows: 16)
        XCTAssertEqual(layout.step(10, pages: 1, length: 1024), 266)
        XCTAssertEqual(layout.step(266, pages: -1, length: 1024), 10)
        XCTAssertEqual(layout.step(10, pages: -1, length: 1024), 10, "already on the first page")
        XCTAssertEqual(layout.step(300, pages: -2, length: 1024), 44, "the same column on the first page")
        XCTAssertEqual(layout.step(200, pages: 1, length: 300), 299, "to the last byte of a short last page")
        XCTAssertEqual(layout.step(290, pages: 1, length: 300), 290, "already on the last page")
        XCTAssertEqual(layout.step(5, pages: 1, length: 0), 0)
    }

    func testRowsReflowInFoursToTheWidth() {
        XCTAssertEqual(DeveloperMemoryLayout.bytesPerRow(fitting: 600, byteWidth: 28, fixed: 110), 16)
        XCTAssertEqual(DeveloperMemoryLayout.bytesPerRow(fitting: 100, byteWidth: 28, fixed: 110), 4)
        XCTAssertEqual(DeveloperMemoryLayout.bytesPerRow(fitting: 5_000, byteWidth: 28, fixed: 110), 32)
        XCTAssertEqual(DeveloperMemoryLayout.clamp(99, length: 10), 9)
        XCTAssertEqual(DeveloperMemoryLayout.clamp(-1, length: 10), 0)
    }

    // MARK: History

    func testHistoryGoesBackAndForwardAndForgetsWhatWasAhead() {
        var history = DeveloperMemoryHistory()
        history.visit(0)
        history.visit(16)
        history.visit(16)
        history.visit(32)
        XCTAssertEqual(history.entries, [0, 16, 32])
        XCTAssertEqual(history.back(), 16)
        XCTAssertEqual(history.back(), 0)
        XCTAssertNil(history.back())
        XCTAssertEqual(history.forward(), 16)
        history.visit(100)
        XCTAssertEqual(history.entries, [0, 16, 100])
        XCTAssertFalse(history.canGoForward)
    }

    func testHistoryIsBounded() {
        var history = DeveloperMemoryHistory(limit: 3)
        for address in 0..<5 { history.visit(address) }
        XCTAssertEqual(history.entries, [2, 3, 4])
        XCTAssertEqual(history.current, 4)
    }

    // MARK: Bytes

    func testBytesAsHexAndASCII() {
        XCTAssertEqual(DeveloperMemoryBytes.hex(0x0A), "0A")
        XCTAssertEqual(DeveloperMemoryBytes.hex(0xFF), "FF")
        XCTAssertEqual(DeveloperMemoryBytes.ascii(0x41), "A")
        XCTAssertEqual(DeveloperMemoryBytes.ascii(0x7F), ".")
        XCTAssertEqual(DeveloperMemoryBytes.ascii(0x00), ".")
        XCTAssertEqual(DeveloperMemoryBytes.parse("ff"), 255)
        XCTAssertEqual(DeveloperMemoryBytes.parse("7"), 7)
        XCTAssertNil(DeveloperMemoryBytes.parse("100"))
        XCTAssertNil(DeveloperMemoryBytes.parse("g1"))
    }

    func testThePageScriptsBytesDecodeFromNumbersOrBase64() {
        XCTAssertEqual(DeveloperMemoryBytes.decode([1, 2, 255]), [1, 2, 255])
        XCTAssertEqual(DeveloperMemoryBytes.decode("AQL/"), [1, 2, 255])
        XCTAssertNil(DeveloperMemoryBytes.decode([1, 256]))
        XCTAssertNil(DeveloperMemoryBytes.decode(nil))
    }

    // MARK: Values

    private let bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x80, 0x3F]

    func testIntegersInBothByteOrders() {
        XCTAssertEqual(Value.unsigned(bytes, at: 0, size: 2, .little), 0x0201)
        XCTAssertEqual(Value.unsigned(bytes, at: 0, size: 2, .big), 0x0102)
        XCTAssertEqual(Value.unsigned(bytes, at: 0, size: 4, .little), 0x0403_0201)
        XCTAssertEqual(Value.unsigned(bytes, at: 0, size: 4, .big), 0x0102_0304)
        XCTAssertEqual(Value.unsigned(bytes, at: 0, size: 8, .little), 0xFFFF_FFFF_0403_0201)
        XCTAssertNil(Value.unsigned(bytes, at: 10, size: 4, .little), "past the bytes read")
    }

    func testSignedIntegersOfEachWidth() {
        XCTAssertEqual(Value.signed(bytes, at: 4, size: 1, .little), -1)
        XCTAssertEqual(Value.signed(bytes, at: 4, size: 2, .little), -1)
        XCTAssertEqual(Value.signed(bytes, at: 4, size: 4, .little), -1)
        XCTAssertEqual(Value.signed(bytes, at: 0, size: 1, .little), 1)
        XCTAssertEqual(Value.signed([0x80], at: 0, size: 1, .little), -128)
        XCTAssertEqual(Value.signed([0x00, 0x80], at: 0, size: 2, .little), -32768)
        XCTAssertEqual(Value.signed([0, 0, 0, 0, 0, 0, 0, 0x80], at: 0, size: 8, .little), Int64.min)
    }

    func testFloats() {
        XCTAssertEqual(Value.float32(bytes, at: 8, .little), 1.0)
        XCTAssertEqual(Value.float32([0x3F, 0x80, 0x00, 0x00], at: 0, .big), 1.0)
        let pi = withUnsafeBytes(of: Double.pi.bitPattern.littleEndian) { Array($0) }
        XCTAssertEqual(Value.float64(pi, at: 0, .little), .pi)
        XCTAssertEqual(Value.text(.float32, bytes: bytes, at: 8, endian: .little), "1.0")
        XCTAssertEqual(Value.text(.float32, bytes: [0x00, 0x00, 0xC0, 0x7F], at: 0, endian: .little), "NaN")
        XCTAssertEqual(Value.text(.float32, bytes: [0x00, 0x00, 0x80, 0x7F], at: 0, endian: .little), "Infinity")
    }

    func testIntegerTextShowsSignedAndUnsignedWhenTheyDiffer() {
        XCTAssertEqual(Value.text(.int8, bytes: bytes, at: 0, endian: .little), "1")
        XCTAssertEqual(Value.text(.int8, bytes: bytes, at: 4, endian: .little), "-1 / 255")
        XCTAssertEqual(Value.text(.int16, bytes: bytes, at: 4, endian: .little), "-1 / 65535")
        XCTAssertEqual(Value.text(.int32, bytes: bytes, at: 0, endian: .big), "16909060")
        XCTAssertEqual(Value.text(.int32, bytes: bytes, at: 0, endian: .little, mode: .hexadecimal), "0x4030201")
        XCTAssertEqual(Value.text(.int8, bytes: bytes, at: 4, endian: .little, mode: .octal), "0o377")
        XCTAssertNil(Value.text(.int64, bytes: bytes, at: 6, endian: .little))
    }

    func testPointersAndWhereTheyLead() {
        XCTAssertEqual(Value.text(.pointer32, bytes: [0x10, 0, 0, 0], at: 0, endian: .little), "0x10")
        XCTAssertEqual(Value.text(.pointer64, bytes: bytes, at: 0, endian: .big), "0x1020304FFFFFFFF")
        XCTAssertEqual(Value.pointerTarget(.pointer32, bytes: [0x10, 0, 0, 0], at: 0, endian: .little, length: 64), 16)
        XCTAssertNil(Value.pointerTarget(.pointer32, bytes: [0x10, 0, 0, 0], at: 0, endian: .little, length: 16))
        XCTAssertNil(Value.pointerTarget(.int32, bytes: [0x10, 0, 0, 0], at: 0, endian: .little, length: 64))
    }

    func testFormatSizes() {
        XCTAssertEqual(Value.Format.int8.size, 1)
        XCTAssertEqual(Value.Format.int16.size, 2)
        XCTAssertEqual(Value.Format.float32.size, 4)
        XCTAssertEqual(Value.Format.pointer64.size, 8)
    }
}
