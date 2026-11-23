import XCTest
@testable import Search

/// Custom formatters' JsonML: what Chrome's renderer accepts, the style
/// subset it keeps, and how headers and bodies lay out as console lines.
final class DeveloperConsoleFormattersTests: XCTestCase {
    /// A JsonML element as the page's encoder sends it.
    private func element(_ tag: String, _ style: String, _ children: Any...) -> Any {
        var node: [Any] = [tag, ["style": style]]
        for child in children { node.append(child) }
        return node
    }

    private func reference(_ ref: Int, config: Int? = nil) -> Any {
        let attributes: [String: Any] = ["ref": ref, "config": config.map { $0 as Any } ?? NSNull()]
        return ["object", attributes] as [Any]
    }

    private func property(_ name: String, _ value: [String: Any]) -> [String: Any] {
        ["name": name, "value": value]
    }

    func testParsesTagsStylesTextAndObjectReferences() throws {
        let raw = element("div", "color: red; background: url(https://example.invalid/x.png)",
                          "Hi ", element("span", "font-weight: bold", "there"), reference(0), reference(1, config: 2))
        let node = try XCTUnwrap(ConsoleJsonML.parse(raw))
        XCTAssertEqual(node, .element(tag: "div", style: "color: red", children: [
            .text("Hi "),
            .element(tag: "span", style: "font-weight: bold", children: [.text("there")]),
            .object(ref: 0, config: nil),
            .object(ref: 1, config: 2),
        ]))
        XCTAssertEqual(ConsoleJsonML.parse(json: #"["span",{"style":""},"x"]"#), .element(tag: "span", style: "", children: [.text("x")]))
    }

    func testRefusesWhatChromeRefuses() {
        XCTAssertNil(ConsoleJsonML.parse(element("script", "", "alert(1)")))
        XCTAssertNil(ConsoleJsonML.parse(element("div", "", element("img", ""))))
        XCTAssertNil(ConsoleJsonML.parse(element("object", "")))
        XCTAssertNil(ConsoleJsonML.parse(42))
        XCTAssertNil(ConsoleJsonML.parse(json: "not json"))
        var deep: Any = "leaf"
        for _ in 0..<80 { deep = element("span", "", deep) }
        XCTAssertNil(ConsoleJsonML.parse(deep))
    }

    func testStyleKeepsTheSafeSubset() {
        XCTAssertEqual(ConsoleJsonMLStyle.sanitized(
            "color: #c00; position: fixed; margin-left: 10px; background: url(a.png); border: 1px solid red; font-style: italic"),
            "color: #c00; margin-left: 10px; border: 1px solid red; font-style: italic")
        XCTAssertEqual(ConsoleJsonMLStyle.sanitized("background-color: expression(alert(1)); padding: 2px 4px"), "padding: 2px 4px")
        XCTAssertEqual(ConsoleJsonMLStyle.sanitized(""), "")
        XCTAssertEqual(ConsoleJsonMLStyle.indent("margin-left: 12px; padding-left: 3px"), 15)
        XCTAssertEqual(ConsoleJsonMLStyle.indent("padding: 0 0 0 8px"), 8)
        XCTAssertEqual(ConsoleJsonMLStyle.indent("margin: 4px 6px"), 6)
    }

    func testChildStylesOverrideTheirParents() {
        let parent = ConsoleJsonMLStyle.text("color: red; font-weight: bold", over: .plain)
        let child = ConsoleJsonMLStyle.text("color: blue", over: parent)
        XCTAssertEqual(child.color, ConsoleColor(red: 0, green: 0, blue: 1))
        XCTAssertTrue(child.bold)
        XCTAssertEqual(ConsoleJsonMLStyle.text("", over: parent), parent)
    }

    func testBlocksBecomeIndentedLinesAndSpansRunInline() throws {
        let node = try XCTUnwrap(ConsoleJsonML.parse(element("div", "",
            element("div", "margin-left: 12px", "a"),
            element("div", "", "b ", element("span", "color: blue", "c"), reference(0)),
            element("ol", "", element("li", "", "item")))))
        let lines = ConsoleJsonMLLayout.lines(node)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].indent, 12)
        XCTAssertEqual(ConsoleJsonMLLayout.plain(lines[0].runs), "a")
        XCTAssertEqual(lines[1].indent, 0)
        XCTAssertEqual(ConsoleJsonMLLayout.plain(lines[1].runs), "b c{object 0}")
        XCTAssertEqual(lines[1].runs[1], .text("c", ConsoleJsonMLStyle.text("color: blue", over: .plain)))
        XCTAssertEqual(lines[2].indent, 14)
        XCTAssertEqual(ConsoleJsonMLLayout.plain(lines[2].runs), "item")
        XCTAssertEqual(ConsoleJsonMLLayout.plain(ConsoleJsonMLLayout.inline(node)), "ab c{object 0}item")
    }

    func testReadsThePageReply() throws {
        let reply = try XCTUnwrap(ConsoleCustomFormatting.reply([
            property("json", ["type": "string", "value": #"["span",{"style":""},"P"]"#]),
            property("hasBody", ["type": "boolean", "value": true]),
            property("formatter", ["type": "number", "value": 1]),
            property("o0", ["type": "object", "objectId": "obj-1"]),
            property("o1", ["type": "number", "value": 3]),
            property("__proto__", ["type": "object", "objectId": "proto"]),
        ]))
        XCTAssertTrue(reply.hasBody)
        XCTAssertEqual(reply.formatter, 1)
        XCTAssertEqual(reply.objects[0]?.objectId, "obj-1")
        XCTAssertEqual(reply.objects[1]?.value, .number(3))
        XCTAssertEqual(reply.objects.count, 2)
        XCTAssertEqual(ConsoleJsonML.parse(json: reply.json), .element(tag: "span", style: "", children: [.text("P")]))
        XCTAssertNil(ConsoleCustomFormatting.reply([]))
    }

    func testConfigArguments() {
        XCTAssertTrue(ConsoleCustomFormatting.argument(nil).isEmpty)
        XCTAssertEqual(ConsoleCustomFormatting.argument(ConsoleRemoteObject(type: "object", objectId: "c1"))["objectId"] as? String, "c1")
        XCTAssertEqual(ConsoleCustomFormatting.argument(ConsoleRemoteObject(type: "number", value: .number(2)))["value"] as? Double, 2)
        XCTAssertTrue(ConsoleCustomFormatting.argument(ConsoleRemoteObject(type: "undefined")).isEmpty)
        XCTAssertNotEqual(ConsoleCustomFormatting.key(ConsoleRemoteObject(type: "object", objectId: "a"), config: nil),
                          ConsoleCustomFormatting.key(ConsoleRemoteObject(type: "object", objectId: "a"),
                                                      config: ConsoleRemoteObject(type: "object", objectId: "c")))
    }

    func testSettingIsOffByDefault() throws {
        XCTAssertFalse(ConsoleSettings().customFormatters)
        let old = try JSONDecoder().decode(ConsoleSettings.self, from: Data(#"{"showTimestamps":true}"#.utf8))
        XCTAssertFalse(old.customFormatters)
        XCTAssertTrue(old.showTimestamps)
    }
}
