import XCTest
@testable import Search

final class DeveloperNetworkDetailsTests: XCTestCase {
    // MARK: JSON

    func testJSONKeepsKeyOrderAsJavaScriptDoes() throws {
        let value = try XCTUnwrap(DeveloperJSONValue.parse(#"{"b": 1, "a": 2, "10": 3, "2": 4, "b": 5, "01": 6}"#))
        guard case .object(let members) = value else { return XCTFail("not an object") }
        // Array indices first, ascending; then insertion order, a repeated
        // key keeping its first place and its last value.
        XCTAssertEqual(members.map(\.key), ["2", "10", "b", "a", "01"])
        XCTAssertEqual(members[2].value, .number("5"))
    }

    func testJSONParsesEscapesAndRejectsBadInput() {
        XCTAssertEqual(DeveloperJSONValue.parse(#""a\"b\\c\né😀""#), .string("a\"b\\c\né😀"))
        XCTAssertEqual(DeveloperJSONValue.parse(" [true, false, null, -1.5e3] "),
                       .array([.bool(true), .bool(false), .null, .number("-1.5e3")]))
        XCTAssertNil(DeveloperJSONValue.parse("{a: 1}"))
        XCTAssertNil(DeveloperJSONValue.parse("[1,]"))
        XCTAssertNil(DeveloperJSONValue.parse("01"))
        XCTAssertNil(DeveloperJSONValue.parse("[1] x"))
        XCTAssertNil(DeveloperJSONValue.parse("\"tab\there\""))
        XCTAssertNil(DeveloperJSONValue.parse(String(repeating: "[", count: 2_000) + String(repeating: "]", count: 2_000)))
    }

    func testNumbersShowAsJavaScriptPrintsThem() {
        let cases = [
            "1": "1", "1.0": "1", "1e3": "1000", "0.1": "0.1", "1.5": "1.5", "-2.5e-8": "-2.5e-8",
            "1e-7": "1e-7", "0.000001": "0.000001", "1e21": "1e+21", "1e20": "100000000000000000000",
            "12345678901234567890": "12345678901234567000", "-0": "0", "5e-324": "5e-324", "123.450": "123.45",
        ]
        for (raw, shown) in cases {
            XCTAssertEqual(DeveloperJSONValue.display(number: raw), shown, raw)
        }
    }

    func testPrettyJSONKeepsOrderAndIndentsLikeStringify() {
        XCTAssertEqual(DeveloperRequestDetails.prettyJSON(#"{"z":1,"a":[1,{"y":"/x"}],"e":{},"f":[]}"#), """
            {
              "z": 1,
              "a": [
                1,
                {
                  "y": "/x"
                }
              ],
              "e": {},
              "f": []
            }
            """)
        XCTAssertNil(DeveloperRequestDetails.prettyJSON("not json"))
    }

    func testSummaryReadsLikeChromesPreview() throws {
        let value = try XCTUnwrap(DeveloperJSONValue.parse(#"{"id": 1, "name": "a\nb", "tags": [1, 2], "meta": {"x": null}, " pad": true}"#))
        XCTAssertEqual(value.summary, #"{id: 1, name: "a↵b", tags: [1, 2], meta: {x: null}, " pad": true}"#)
        let long = try XCTUnwrap(DeveloperJSONValue.parse("[" + (0..<60).map(String.init).joined(separator: ",") + "]"))
        let summary = long.summary
        XCTAssertTrue(summary.hasSuffix(",…]"), summary)
        XCTAssertLessThanOrEqual(summary.utf16.count, 104)
        XCTAssertTrue(summary.hasPrefix("[0, 1, 2, "))
        let nested = try XCTUnwrap(DeveloperJSONValue.parse(#"[{"title": "\#(String(repeating: "x", count: 150))"}, 2]"#))
        XCTAssertEqual(nested.summary, "[{,…}, 2]")
    }

    func testOutlineOpensOnlyTheRootAndGroupsLongArrays() throws {
        let value = try XCTUnwrap(DeveloperJSONValue.parse(#"{"a": {"b": 1}, "list": [\#((0..<250).map(String.init).joined(separator: ","))]}"#))
        let shut = DeveloperJSONOutline.visibleRows(value, expanded: [DeveloperJSONOutline.rootID])
        XCTAssertEqual(shut.map(\.name), [nil, "a", "list"])
        let list = shut[2]
        let ranges = DeveloperJSONOutline.children(of: list)
        XCTAssertEqual(ranges.count, 3)
        if case .range(_, let lower, let upper) = ranges[2].content {
            XCTAssertEqual([lower, upper], [200, 249])
        } else {
            XCTFail("expected a range")
        }
        let all = DeveloperJSONOutline.expandableIDs(under: DeveloperJSONOutline.root(value))
        XCTAssertEqual(all.count, 1 + 1 + 1 + 3)
        let open = DeveloperJSONOutline.visibleRows(value, expanded: Set(all))
        XCTAssertEqual(open.count, 1 + 2 + 1 + 3 + 250)
        XCTAssertNil(DeveloperJSONOutline.ranges(lower: 0, upper: 99))
        XCTAssertEqual(DeveloperJSONOutline.ranges(lower: 0, upper: 10_000)?.count, 2)
    }

    func testPropertyPathAsChromeCopiesIt() {
        XCTAssertEqual(DeveloperJSONOutline.propertyPath([.key("data"), .key("items"), .index(0), .key("name")]),
                       "data.items[0].name")
        XCTAssertEqual(DeveloperJSONOutline.propertyPath([.key("a-b"), .key("$ok"), .key("12")]), #"["a-b"].$ok[12]"#)
        XCTAssertEqual(DeveloperJSONOutline.propertyPath([.index(3)]), "[3]")
        XCTAssertEqual(DeveloperJSONOutline.copyValue(.string("plain")), "plain")
        XCTAssertEqual(DeveloperJSONOutline.copyValue(.array([.number("1")])), "[\n  1\n]")
    }

    // MARK: Cookies

    func testSetCookieAttributesParse() throws {
        let cookies = DeveloperRequestCookie.responseCookies([
            ("Set-Cookie", "sid=abc; Path=/; Domain=.example.test; Expires=Wed, 21 Oct 2015 07:28:00 GMT; HttpOnly; Secure; SameSite=lax; Priority=HIGH\nother=1; Max-Age=3600"),
        ])
        XCTAssertEqual(cookies.count, 2)
        let sid = cookies[0]
        XCTAssertEqual(sid.name, "sid")
        XCTAssertEqual(sid.value, "abc")
        XCTAssertEqual(sid.path, "/")
        XCTAssertEqual(sid.domain, ".example.test")
        XCTAssertTrue(sid.httpOnly)
        XCTAssertTrue(sid.secure)
        XCTAssertEqual(sid.sameSite, "Lax")
        XCTAssertEqual(sid.priority, "High")
        XCTAssertEqual(sid.expiresText, "2015-10-21T07:28:00.000Z")
        XCTAssertEqual(sid.size, "sid=abc; Path=/; Domain=.example.test; Expires=Wed, 21 Oct 2015 07:28:00 GMT; HttpOnly; Secure; SameSite=lax; Priority=HIGH".utf16.count)
        let other = cookies[1]
        XCTAssertEqual(other.maxAge, 3600)
        XCTAssertEqual(other.expiresText, "1.0 hrs")
        XCTAssertEqual(other.priority, "Medium")
        XCTAssertFalse(other.httpOnly)
        XCTAssertEqual(DeveloperRequestCookie.setCookie("session=1")?.expiresText, "Session")
    }

    func testSetCookieFoldedWithCommasSplitsOutsideDates() {
        let lines = DeveloperRequestCookie.setCookieLines("a=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT, b=2; Path=/, c=x,y")
        XCTAssertEqual(lines, ["a=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT", "b=2; Path=/", "c=x,y"])
    }

    func testRequestCookiesCarryNameValueAndSize() {
        let cookies = DeveloperRequestCookie.requestCookies([("Cookie", "a=1; b=two=2;  c"), ("Accept", "*/*")])
        XCTAssertEqual(cookies.map(\.name), ["a", "b", "c"])
        XCTAssertEqual(cookies.map(\.value), ["1", "two=2", ""])
        XCTAssertEqual(cookies.map(\.size), [3, 7, 1])
        XCTAssertEqual(cookies[0].expiresText, "N/A")
        let details = DeveloperRequestDetails(["url": "https://example.test/", "requestHeaders": [["Cookie", "a=1"]]])
        XCTAssertEqual(details.requestCookies.map(\.name), ["a"])
    }

    // MARK: Payload

    func testParametersDecodeOrStayEncoded() {
        let query = "q=a+b%20c&empty=&flag&bad=%E0%A4%A"
        let decoded = DeveloperRequestDetails.parameters(query, decoded: true)
        XCTAssertEqual(decoded.map(\.name), ["q", "empty", "flag", "bad"])
        XCTAssertEqual(decoded.map(\.value), ["a b c", "", "", "(unable to decode value)"])
        let encoded = DeveloperRequestDetails.parameters(query, decoded: false)
        XCTAssertEqual(encoded.map(\.value), ["a+b%20c", "", "", "%E0%A4%A"])
        let details = DeveloperRequestDetails(["url": "https://example.test/p?x=1&y=%2F#top"])
        XCTAssertEqual(details.rawQuery, "x=1&y=%2F")
        XCTAssertNil(DeveloperRequestDetails(["url": "https://example.test/p"]).rawQuery)
    }

    // MARK: Timing

    func testTimingHeaderFromTheStartOfTheLog() throws {
        let header = try XCTUnwrap(DeveloperRequestTimingText.header(started: 10.5, queueing: 12, origin: 10))
        XCTAssertEqual(header.queued, "Queued at 500 ms")
        XCTAssertEqual(header.started, "Started at 512 ms")
        let later = try XCTUnwrap(DeveloperRequestTimingText.header(started: 12.5, queueing: 5, origin: 10))
        XCTAssertEqual(later.queued, "Queued at 2.50 s")
        XCTAssertEqual(DeveloperRequestTimingText.header(started: 10, queueing: 0, origin: 10)?.queued, "Queued at 0")
        XCTAssertNil(DeveloperRequestTimingText.header(started: nil, queueing: 0, origin: 10))
        XCTAssertEqual(DeveloperRequestTimingText.milliseconds(90_000), "1.5 min")
        XCTAssertEqual(DeveloperRequestTimingText.milliseconds(3 * 86_400_000), "3.0 days")
    }
}
