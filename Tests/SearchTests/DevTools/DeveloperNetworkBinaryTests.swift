import XCTest
@testable import Search

final class DeveloperNetworkBinaryTests: XCTestCase {
    func testHexDumpRowsHaveOffsetsHexAndASCII() {
        let data = Data((0..<16).map { UInt8($0) } + [0x41, 0x0A, 0x7F])
        let lines = DeveloperBinaryFormat.hexDump(data).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "00000000  00 01 02 03 04 05 06 07  08 09 0a 0b 0c 0d 0e 0f  ................")
        // The short last row keeps the ASCII column in line; a newline
        // and DEL show as ".".
        XCTAssertEqual(lines[1], "00000010  41 0a 7f" + String(repeating: " ", count: 42) + "A..")
        XCTAssertEqual(lines[0].count, 76)
        XCTAssertEqual(lines[1].count, 63)
    }

    func testHexDumpPrintableASCIIAndLaterOffsets() {
        let data = Data(repeating: 0x2E, count: 32) + Data("Hello, world! ~".utf8)
        let lines = DeveloperBinaryFormat.hexDump(data).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[2].hasPrefix("00000020  48 65 6c 6c 6f 2c 20 77  6f 72 6c 64 21 20 7e "))
        XCTAssertTrue(lines[2].hasSuffix("  Hello, world! ~"))
        XCTAssertEqual(DeveloperBinaryFormat.hexDump(Data()), "")
    }

    func testHexDumpStopsAtTheLimit() {
        let data = Data(repeating: 0xFF, count: 100)
        let lines = DeveloperBinaryFormat.hexDump(data, limit: 20).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasPrefix("00000010  ff ff ff ff "))
        XCTAssertTrue(lines[1].hasSuffix("...."))
    }

    func testBase64AndUTF8() {
        let data = Data("héllo".utf8) + Data([0xFF])
        XCTAssertEqual(DeveloperBinaryFormat.base64(Data("hello".utf8)), "aGVsbG8=")
        XCTAssertEqual(DeveloperBinaryFormat.text(data, mode: .base64), data.base64EncodedString())
        // A malformed byte reads as the replacement character.
        XCTAssertEqual(DeveloperBinaryFormat.utf8(data), "héllo\u{FFFD}")
        XCTAssertEqual(DeveloperBinaryFormat.utf8(Data("hello".utf8), limit: 4), "hell")
        XCTAssertEqual(DeveloperBinaryFormat.base64(Data("hello".utf8), limit: 3), "aGVs")
        XCTAssertEqual(DeveloperBinaryFormat.text(Data([0x41]), mode: .hex).suffix(3), "  A")
    }

    func testModesReadAsChromeNamesThem() {
        XCTAssertEqual(DeveloperBinaryMode.allCases.map(\.rawValue), ["Base64", "Hex viewer", "UTF-8"])
        XCTAssertEqual(DeveloperBinaryMode.allCases.map { "Copy as \($0.copyName)" },
                       ["Copy as Base64", "Copy as Hex", "Copy as UTF-8"])
    }
}
