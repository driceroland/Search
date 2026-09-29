import XCTest
@testable import Search

/// Pins every space shows (Pins.shared): moving a pin in and out of them,
/// a row's order, and pins.json with and without them. In memory only.
final class SharedPinsTests: XCTestCase {
    private func def(_ letter: String, listed: Bool? = nil) -> PinDef {
        PinDef(id: UUID(), letter: letter, home: "https://\(letter.lowercased()).example/",
               title: letter, name: nil, listed: listed)
    }

    func testSharingMovesAPinToTheEndOfTheSharedOnes() {
        let a = def("A"), b = def("B"), m = def("M")
        let moved = Pins.share(a.id, own: [a, b], shared: [m])
        XCTAssertEqual(moved.own, [b])
        XCTAssertEqual(moved.shared, [m, a])
    }

    func testUnsharingMovesAPinToTheStartOfTheSpacesOwn() {
        let a = def("A"), m = def("M"), n = def("N")
        let moved = Pins.unshare(m.id, own: [a], shared: [m, n])
        XCTAssertEqual(moved.own, [m, a])
        XCTAssertEqual(moved.shared, [n])
    }

    func testAnUnknownPinChangesNothing() {
        let a = def("A"), m = def("M")
        XCTAssertEqual(Pins.share(UUID(), own: [a], shared: [m]).own, [a])
        XCTAssertEqual(Pins.share(UUID(), own: [a], shared: [m]).shared, [m])
        XCTAssertEqual(Pins.unshare(UUID(), own: [a], shared: [m]).own, [a])
        XCTAssertEqual(Pins.unshare(UUID(), own: [a], shared: [m]).shared, [m])
    }

    func testSplittingARowKeepsEachListInRowOrder() {
        // A shared pin dragged among the space's own is still a shared one,
        // in the order the shared ones had in the row.
        let a = def("A"), m = def("M"), b = def("B"), n = def("N")
        let parts = Pins.split([a, m, b, n], shared: [m.id, n.id])
        XCTAssertEqual(parts.own, [a, b])
        XCTAssertEqual(parts.shared, [m, n])
    }

    func testARowIsTheSharedPinsThenTheSpacesOwn() {
        let a = def("A"), m = def("M")
        XCTAssertEqual(Pins.row(own: [a], shared: [m], showing: true), [m, a])
    }

    func testWithSharedPinsHiddenARowIsTheSpacesOwn() {
        let a = def("A"), m = def("M")
        XCTAssertEqual(Pins.row(own: [a], shared: [m], showing: false), [a])
    }

    func testARowWithItsSharedPinsSaysWhatTheyAre() {
        let m = def("M"), n = def("N")
        XCTAssertEqual(Pins.sharedToWrite([n, m], showing: true), [n, m])
    }

    func testARowNotYetGivenTheSharedPinsCannotWipeThem() {
        // The switch just turned on, the row not rebuilt yet: it holds no
        // shared pin, and must not write an empty list over the real one.
        XCTAssertNil(Pins.sharedToWrite([], showing: true))
    }

    func testWithSharedPinsHiddenARowSaysNothingAboutThem() {
        XCTAssertNil(Pins.sharedToWrite([def("M")], showing: false))
    }

    func testAFileWithSharedPinsReadsBothLists() throws {
        let space = UUID()
        let json = """
        {"\(space.uuidString)": [{"id": "\(UUID().uuidString)", "letter": "A", "home": "https://a.example/", "title": "A"}],
         "shared": [{"id": "\(UUID().uuidString)", "letter": "M", "home": "https://m.example/", "title": "M"}]}
        """
        let read = try XCTUnwrap(Pins.decode(Data(json.utf8)))
        XCTAssertEqual(read.bySpace[space]?.map(\.letter), ["A"])
        XCTAssertEqual(read.shared.map(\.letter), ["M"])
        XCTAssertEqual(read.bySpace.count, 1)
    }

    func testAFileFromBeforeHasNoSharedPins() throws {
        let space = UUID()
        let json = #"{"\#(space.uuidString)": [{"id": "\#(UUID().uuidString)", "letter": "A", "home": "https://a.example/", "title": "A"}]}"#
        let read = try XCTUnwrap(Pins.decode(Data(json.utf8)))
        XCTAssertEqual(read.shared, [])
        XCTAssertEqual(read.bySpace[space]?.count, 1)
    }

    func testWritingAndReadingBackKeepsBothLists() throws {
        let space = UUID(), a = def("A", listed: true), m = def("M")
        let data = try XCTUnwrap(Pins.encode(bySpace: [space: [a]], shared: [m]))
        let read = try XCTUnwrap(Pins.decode(data))
        XCTAssertEqual(read.bySpace[space], [a])
        XCTAssertEqual(read.shared, [m])
    }

    func testNoSharedPinsWritesNoSharedKey() throws {
        // Someone who never turns the switch on keeps the file they had.
        let data = try XCTUnwrap(Pins.encode(bySpace: [UUID(): [def("A")]], shared: []))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertFalse(keys.contains("shared"))
    }
}
