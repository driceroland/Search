import XCTest
@testable import Search

/// Application's storage value preview: JSON objects and arrays open as
/// a tree, other values stay text, and "Show URL-decoded" decodes as
/// decodeURIComponent does.
final class DeveloperStorageValuePreviewTests: XCTestCase {
    func testJSONObjectsAndArraysBecomeATree() throws {
        let tree = try XCTUnwrap(DeveloperStorageValuePreview.json(" {\"user\":{\"id\":7,\"tags\":[\"a\",\"b\"]},\"on\":true} "))
        let closed = DeveloperJSONOutline.visibleRows(tree, expanded: [DeveloperJSONOutline.rootID])
        XCTAssertEqual(closed.compactMap(\.name), ["user", "on"])
        let user = try XCTUnwrap(closed.first { $0.name == "user" })
        XCTAssertTrue(user.expandable)
        let open = DeveloperJSONOutline.visibleRows(tree, expanded: [DeveloperJSONOutline.rootID, user.id])
        XCTAssertEqual(open.compactMap(\.name), ["user", "id", "tags", "on"])
        XCTAssertNotNil(DeveloperStorageValuePreview.json("[1, 2, 3]"))
    }

    func testOtherValuesStayText() {
        XCTAssertNil(DeveloperStorageValuePreview.json("hello"))
        XCTAssertNil(DeveloperStorageValuePreview.json("42"))
        XCTAssertNil(DeveloperStorageValuePreview.json("\"quoted\""))
        XCTAssertNil(DeveloperStorageValuePreview.json("{not json"))
        XCTAssertNil(DeveloperStorageValuePreview.json(""))
    }

    func testURLDecoding() {
        XCTAssertEqual(DeveloperStorageValuePreview.urlDecoded("a%20b%3Dc"), "a b=c")
        XCTAssertEqual(DeveloperStorageValuePreview.urlDecoded("%7B%22k%22%3A1%7D"), "{\"k\":1}")
        // decodeURIComponent leaves + alone, and a malformed escape keeps the value.
        XCTAssertEqual(DeveloperStorageValuePreview.urlDecoded("a+b"), "a+b")
        XCTAssertEqual(DeveloperStorageValuePreview.urlDecoded("100%"), "100%")
        XCTAssertEqual(DeveloperStorageValuePreview.urlDecoded("caf%C3%A9"), "café")
        // A URL-encoded JSON cookie previews as a tree once decoded.
        XCTAssertNotNil(DeveloperStorageValuePreview.json(DeveloperStorageValuePreview.urlDecoded("%5B1%2C2%5D")))
    }

    func testWhichSectionsDecodeAndWhereTheValueIs() {
        XCTAssertTrue(DeveloperStorageValuePreview.decodes(.cookies))
        XCTAssertTrue(DeveloperStorageValuePreview.decodes(.local))
        XCTAssertTrue(DeveloperStorageValuePreview.decodes(.session))
        XCTAssertFalse(DeveloperStorageValuePreview.decodes(.indexedDB))
        XCTAssertEqual(DeveloperStorageValuePreview.valueColumn(["Name", "Value", "Domain"]), 1)
        XCTAssertEqual(DeveloperStorageValuePreview.valueColumn(["Key", "value"]), 1)
        XCTAssertNil(DeveloperStorageValuePreview.valueColumn(["Name", "URL"]))
    }
}
