import XCTest
@testable import Search

/// The Console's pure logic that matches Chrome DevTools: error stacks,
/// links in messages, prompt history, following the bottom, Find,
/// property paths, timestamps and the element tree's markup.
final class DeveloperConsoleParityTests: XCTestCase {
    // MARK: Error stacks

    func testWebKitStackFramesBecomeLinks() {
        let stack = """
        inner@https://example.com/app.js:12:5
        outer@https://example.com/app.js:20:3
        global code@https://example.com/index.html:4:9
        forEach@[native code]
        """
        let frames = ConsoleErrorStack.parse(stack)
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames[0], ConsoleCallFrame(functionName: "inner", url: "https://example.com/app.js", lineNumber: 12, columnNumber: 5))
        XCTAssertEqual(frames[2].functionName, "", "global code shows as (anonymous)")
        XCTAssertEqual(frames[2].lineNumber, 4)
        XCTAssertEqual(frames[3].url, "")
        XCTAssertEqual(frames[3].functionName, "forEach")
    }

    func testV8StackInTheDescriptionSplitsFromItsMessage() {
        let description = """
        TypeError: x is not a function
            at handler (https://example.com/a.js:3:15)
            at async load (https://example.com/b.js:10:1)
            at https://example.com/c.js:7:2
        """
        let split = ConsoleErrorStack.split(description: description, stack: nil)
        XCTAssertEqual(split.header, "TypeError: x is not a function")
        XCTAssertEqual(split.frames.map(\.functionName), ["handler", "load", ""])
        XCTAssertEqual(split.frames.map(\.lineNumber), [3, 10, 7])
        XCTAssertEqual(split.frames[2].url, "https://example.com/c.js")
    }

    func testDescriptionWithoutFramesUsesTheStackProperty() {
        let split = ConsoleErrorStack.split(description: "Error: boom", stack: "fail@https://a.test/x.js:1:2")
        XCTAssertEqual(split.header, "Error: boom")
        XCTAssertEqual(split.frames.first?.url, "https://a.test/x.js")
        XCTAssertEqual(split.frames.first?.columnNumber, 2)
    }

    func testMessageLinesAreNotFrames() {
        XCTAssertNil(ConsoleErrorStack.frame("Error: boom"))
        XCTAssertNil(ConsoleErrorStack.frame("write to me@example"))
        XCTAssertTrue(ConsoleErrorStack.parse("").isEmpty)
    }

    // MARK: Links

    func testURLsInMessagesAreFoundWithoutTrailingPunctuation() {
        let text = "See https://example.com/docs, or (https://example.com/a_(b)) now."
        let links = ConsoleLinks.find(in: text)
        XCTAssertEqual(links.map(\.url), ["https://example.com/docs", "https://example.com/a_(b)"])
        XCTAssertEqual(String(text[links[0].range]), "https://example.com/docs")
    }

    func testScriptLocationsOpenSourcesAndPortsStayInTheAddress() {
        let links = ConsoleLinks.find(in: "at https://cdn.test/app.js:12:5 and http://localhost:8080/ and https://a.test/b.js:7")
        XCTAssertEqual(links.count, 3)
        XCTAssertEqual(links[0].url, "https://cdn.test/app.js")
        XCTAssertEqual(links[0].line, 12)
        XCTAssertEqual(links[0].column, 5)
        XCTAssertEqual(links[1].url, "http://localhost:8080/")
        XCTAssertNil(links[1].line)
        XCTAssertEqual(links[2].line, 7)
        XCTAssertNil(links[2].column)

        let target = ConsoleLinks.target(links[0])
        XCTAssertEqual(target?.scheme, "perch-console")
        let source = target.flatMap(ConsoleLinks.source)
        XCTAssertEqual(source?.url, "https://cdn.test/app.js")
        XCTAssertEqual(source?.line, 12)
        XCTAssertEqual(ConsoleLinks.target(links[1])?.absoluteString, "http://localhost:8080/")
    }

    func testTextWithoutURLsHasNoLinks() {
        XCTAssertTrue(ConsoleLinks.find(in: "plain text: 12:5").isEmpty)
    }

    // MARK: History

    func testHistoryPersistsCappedWithoutRepeatingTheLastEntry() throws {
        let suite = "perch-console-history-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var history: [String] = []
        history = ConsoleHistory.appending("a", to: history)
        history = ConsoleHistory.appending("a", to: history)
        history = ConsoleHistory.appending("  ", to: history)
        history = ConsoleHistory.appending("b", to: history)
        XCTAssertEqual(history, ["a", "b"])

        for index in 0..<400 { history = ConsoleHistory.appending("e\(index)", to: history) }
        XCTAssertEqual(history.count, ConsoleHistory.limit)
        XCTAssertEqual(history.last, "e399")

        ConsoleHistory.save(history, defaults)
        XCTAssertEqual(ConsoleHistory.load(defaults), history)
    }

    // MARK: Following the bottom

    func testListFollowsOnlyWhenAtTheBottomOrAfterACommand() {
        XCTAssertTrue(ConsoleScrollPin.isAtBottom(visibleMaxY: 1000, contentHeight: 1000))
        XCTAssertTrue(ConsoleScrollPin.isAtBottom(visibleMaxY: 990, contentHeight: 1000))
        XCTAssertFalse(ConsoleScrollPin.isAtBottom(visibleMaxY: 600, contentHeight: 1000))
        XCTAssertTrue(ConsoleScrollPin.shouldFollow(pinned: true, ranCommand: false))
        XCTAssertTrue(ConsoleScrollPin.shouldFollow(pinned: false, ranCommand: true))
        XCTAssertFalse(ConsoleScrollPin.shouldFollow(pinned: false, ranCommand: false))
    }

    // MARK: Find

    func testFindCountsEveryMatchIgnoringCaseAndWraps() {
        let rows = [(id: "1", text: "Hello hello"), (id: "2", text: "nothing"), (id: "3", text: "HELLO")]
        let matches = ConsoleFind.matches(rows, query: "hello")
        XCTAssertEqual(matches, [ConsoleFindMatch(row: "1", occurrence: 0), ConsoleFindMatch(row: "1", occurrence: 1),
                                 ConsoleFindMatch(row: "3", occurrence: 0)])
        XCTAssertEqual(ConsoleFind.step(nil, count: 3, backwards: false), 0)
        XCTAssertEqual(ConsoleFind.step(nil, count: 3, backwards: true), 2)
        XCTAssertEqual(ConsoleFind.step(2, count: 3, backwards: false), 0)
        XCTAssertEqual(ConsoleFind.step(0, count: 3, backwards: true), 2)
        XCTAssertNil(ConsoleFind.step(0, count: 0, backwards: false))
        XCTAssertTrue(ConsoleFind.matches(rows, query: "").isEmpty)
    }

    // MARK: Property paths

    func testPropertyPathsReadLikeChromes() {
        XCTAssertEqual(ConsolePropertyPath.format(["items", "0", "name"]), "items[0].name")
        XCTAssertEqual(ConsolePropertyPath.format(["map", "a b"]), "map[\"a b\"]")
        XCTAssertEqual(ConsolePropertyPath.format(["[[Prototype]]", "constructor"]), "constructor")
        XCTAssertEqual(ConsolePropertyPath.format(["0"]), "[0]")
        XCTAssertEqual(ConsolePropertyPath.format(["$el", "_x"]), "$el._x")
        XCTAssertEqual(ConsolePropertyPath.format(["a/b"]), "[\"a/b\"]")
    }

    // MARK: Timestamps

    func testTimestampsReadHoursMinutesSecondsAndMilliseconds() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(ConsoleFormat.timestamp(3_723.456, timeZone: utc), "01:02:03.456")
        // 14 Nov 2023 00:00 UTC, plus 1 h 2 min 3.456 s: WebKit's epoch seconds,
        // and the same moment in milliseconds.
        let moment = 1_699_920_000 + 3_723.456
        XCTAssertEqual(ConsoleFormat.timestamp(moment, timeZone: utc), "01:02:03.456")
        XCTAssertEqual(ConsoleFormat.timestamp(moment * 1000, timeZone: utc), "01:02:03.456", "a millisecond stamp reads the same")
        XCTAssertEqual(ConsoleFormat.timestamp(0, timeZone: utc), "00:00:00.000")
    }

    // MARK: Settings

    func testSettingsSavedBeforeTimestampsKeepTheirValues() throws {
        let old = #"{"networkMessages":false,"logXMLHttpRequests":true,"eagerEvaluation":false,"historyAutocomplete":true,"groupSimilar":false,"userActivation":true,"corsErrors":true}"#
        let settings = try JSONDecoder().decode(ConsoleSettings.self, from: Data(old.utf8))
        XCTAssertFalse(settings.networkMessages)
        XCTAssertFalse(settings.groupSimilar)
        XCTAssertTrue(settings.logXMLHttpRequests)
        XCTAssertFalse(settings.showTimestamps)
    }

    // MARK: Element tree

    func testNodeMarkupReadsLikeChromesElementTree() {
        let closed = ConsoleNodeSummary(type: 1, name: "div", attributes: [["id", "main"], ["hidden", ""]], children: 2)
        XCTAssertEqual(ConsoleNodeMarkup.text(ConsoleNodeMarkup.opening(closed, open: false)), "<div id=\"main\" hidden>…</div>")
        XCTAssertEqual(ConsoleNodeMarkup.text(ConsoleNodeMarkup.opening(closed, open: true)), "<div id=\"main\" hidden>")
        XCTAssertEqual(ConsoleNodeMarkup.text(ConsoleNodeMarkup.closing(closed)), "</div>")
        let inline = ConsoleNodeSummary(type: 1, name: "span", text: "hi")
        XCTAssertEqual(ConsoleNodeMarkup.text(ConsoleNodeMarkup.opening(inline, open: false)), "<span>hi</span>")
        let image = ConsoleNodeSummary(type: 1, name: "img", attributes: [["src", "a.png"]])
        XCTAssertEqual(ConsoleNodeMarkup.text(ConsoleNodeMarkup.opening(image, open: false)), "<img src=\"a.png\">")
        XCTAssertEqual(ConsoleNodeMarkup.text(ConsoleNodeMarkup.opening(ConsoleNodeSummary(type: 3, name: "#text", text: "x"), open: false)), "\"x\"")
        XCTAssertEqual(ConsoleNodeMarkup.text(ConsoleNodeMarkup.opening(ConsoleNodeSummary(type: 8, name: "#comment", text: "c"), open: false)), "<!--c-->")
    }

    func testNodeTreeReadsTheBridgeReply() {
        let tree = ConsoleNodeTree([
            "summary": ["type": 1, "name": "ul", "children": 1, "attributes": [["class", "list"]]],
            "children": [["summary": ["type": 1, "name": "li", "text": "one"], "object": ["type": "object", "subtype": "node", "objectId": "7"]]],
        ])
        XCTAssertEqual(tree.summary?.name, "ul")
        XCTAssertEqual(tree.summary?.attributes, [["class", "list"]])
        XCTAssertEqual(tree.children.count, 1)
        XCTAssertEqual(tree.children[0].object?.objectId, "7")
        XCTAssertEqual(tree.children[0].summary.text, "one")
    }

    // MARK: Contexts

    func testContextTitlesFollowChromesSelector() {
        let top = ConsoleExecutionContext(contextID: 1, targetID: nil, name: "", frameName: "example.com", isTop: true, isContentScript: false, depth: 0)
        let frame = ConsoleExecutionContext(contextID: 2, targetID: nil, name: "", frameName: "ad.html (ads.test)", isTop: false, isContentScript: false, depth: 1)
        let script = ConsoleExecutionContext(contextID: 3, targetID: nil, name: "Ad Blocker", frameName: "example.com", isTop: false, isContentScript: true, depth: 0)
        XCTAssertEqual(top.title, "top")
        XCTAssertEqual(frame.title, "ad.html (ads.test)")
        XCTAssertEqual(script.title, "Ad Blocker")
        XCTAssertEqual(ConsoleExecutionContext(["id": 4, "frame": "x", "contentScript": false])?.contextID, 4)
        XCTAssertNil(ConsoleExecutionContext(["frame": "x"]))
    }
}
