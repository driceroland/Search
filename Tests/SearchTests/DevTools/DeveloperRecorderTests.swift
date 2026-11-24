import XCTest
@testable import Search

final class DeveloperRecorderTests: XCTestCase {
    /// A recording as Chrome's Recorder exports it.
    private let chromeJSON = #"""
    {
      "title": "Sign in",
      "steps": [
        {
          "type": "setViewport",
          "width": 1280,
          "height": 720,
          "deviceScaleFactor": 2,
          "isMobile": false,
          "hasTouch": false,
          "isLandscape": false
        },
        {
          "type": "navigate",
          "url": "https://example.com/",
          "assertedEvents": [
            {
              "type": "navigation",
              "url": "https://example.com/",
              "title": "Example"
            }
          ]
        },
        {
          "type": "click",
          "target": "main",
          "selectors": [
            [
              "aria/Submit[role=\"button\"]"
            ],
            [
              "#submit"
            ],
            [
              "xpath///*[@id=\"submit\"]"
            ],
            [
              "pierce/#submit"
            ],
            [
              "text/Submit"
            ]
          ],
          "offsetY": 9,
          "offsetX": 54.5
        },
        {
          "type": "change",
          "value": "hello \"you\"",
          "selectors": [
            [
              "#name"
            ]
          ],
          "target": "main"
        },
        {
          "type": "keyDown",
          "target": "main",
          "key": "Enter"
        },
        {
          "type": "scroll",
          "target": "main",
          "x": 0,
          "y": 500
        }
      ]
    }
    """#

    private func sample() throws -> DeveloperRecording {
        try DeveloperRecording(data: Data(chromeJSON.utf8))
    }

    private func click(_ selector: String, at x: Double = 1, _ y: Double = 2) -> DeveloperRecorderStep {
        var step = DeveloperRecorderStep(type: "click", fields: ["target": .string("main")])
        step.selectors = [[selector]]
        step.offsetX = x
        step.offsetY = y
        return step
    }

    private func change(_ selector: String, _ value: String) -> DeveloperRecorderStep {
        var step = DeveloperRecorderStep(type: "change", fields: ["target": .string("main")])
        step.selectors = [[selector]]
        step.value = value
        return step
    }

    // MARK: Chrome's JSON

    func testChromeJSONRoundTripsExactly() throws {
        let recording = try sample()
        XCTAssertEqual(recording.title, "Sign in")
        XCTAssertEqual(recording.steps.map(\.type), ["setViewport", "navigate", "click", "change", "keyDown", "scroll"])
        XCTAssertEqual(recording.steps[2].offsetX, 54.5)
        XCTAssertEqual(recording.steps[2].selectors.count, 5)
        XCTAssertEqual(recording.steps[3].value, "hello \"you\"")
        XCTAssertEqual(recording.steps[1].assertedEvents, [DeveloperRecorderAssertedEvent(url: "https://example.com/", title: "Example")])
        XCTAssertEqual(recording.exportedJSON, chromeJSON + "\n")
    }

    func testUnknownFieldsSurviveAndKnownOnesFollowChromesOrder() throws {
        let text = #"{"steps":[{"offsetX":1,"selectors":[["a"]],"type":"click","custom":true,"offsetY":2,"target":"main"}],"title":"T","timeout":3000,"extra":1}"#
        let recording = try DeveloperRecording(data: Data(text.utf8))
        XCTAssertEqual(recording.timeout, 3000)
        let again = try DeveloperRecording(data: Data(recording.exportedJSON.utf8))
        XCTAssertEqual(again.steps.first?.fields, recording.steps.first?.fields)
        XCTAssertEqual(again.extra["extra"], .number(1))
        let keys = recording.steps[0].json.object?.map(\.0)
        XCTAssertEqual(keys, ["type", "target", "selectors", "offsetY", "offsetX", "custom"])
        XCTAssertEqual(recording.json.object?.map(\.0), ["title", "timeout", "extra", "steps"])
    }

    func testImportRejectsWhatIsNotARecording() {
        XCTAssertThrowsError(try DeveloperRecording(data: Data("[]".utf8)))
        XCTAssertThrowsError(try DeveloperRecording(data: Data(#"{"title":"x"}"#.utf8)))
        XCTAssertThrowsError(try DeveloperRecording(data: Data(#"{"steps":[{"url":"x"}]}"#.utf8)))
        XCTAssertThrowsError(try DeveloperRecording(data: Data("not json".utf8)))
    }

    func testStringifyMatchesJavaScript() {
        XCTAssertEqual(DeveloperRecorderJSON.format(12), "12")
        XCTAssertEqual(DeveloperRecorderJSON.format(-3), "-3")
        XCTAssertEqual(DeveloperRecorderJSON.format(0.25), "0.25")
        XCTAssertEqual(DeveloperRecorderJSON.format(.nan), "null")
        XCTAssertEqual(DeveloperRecorderJSON.quote("a\"b\\c\nd\u{01}é"), #""a\"b\\c\nd\u0001é""#)
        XCTAssertEqual(DeveloperRecorderJSON.array([]).stringified(), "[]")
        XCTAssertEqual(DeveloperRecorderJSON.object([]).stringified(), "{}")
        XCTAssertEqual(DeveloperRecorderJSON.object([("a", .array([.number(1), .bool(true)]))]).stringified(),
                       "{\n  \"a\": [\n    1,\n    true\n  ]\n}")
    }

    func testSavedRecordingKeepsBreakpointsAndSelectorKinds() throws {
        var recording = try sample()
        recording.steps[2].breakpoint = true
        recording.selectorTypes = [.css, .aria]
        let data = try JSONSerialization.data(withJSONObject: recording.saved)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let back = try XCTUnwrap(DeveloperRecording(saved: object))
        XCTAssertEqual(back.id, recording.id)
        XCTAssertEqual(back.steps.map(\.breakpoint), [false, false, true, false, false, false])
        XCTAssertEqual(back.selectorTypes, [.css, .aria])
        XCTAssertEqual(back.exportedJSON, recording.exportedJSON)
    }

    // MARK: Selectors

    func testSelectorStrings() {
        XCTAssertEqual(DeveloperRecorderSelector.kind(of: "aria/x"), .aria)
        XCTAssertEqual(DeveloperRecorderSelector.kind(of: "xpath//html"), .xpath)
        XCTAssertEqual(DeveloperRecorderSelector.kind(of: "pierce/div"), .pierce)
        XCTAssertEqual(DeveloperRecorderSelector.kind(of: "text/Hi"), .text)
        XCTAssertEqual(DeveloperRecorderSelector.kind(of: "div > a:nth-child(2)"), .css)
        XCTAssertEqual(DeveloperRecorderSelector.body(of: "xpath//html"), "/html")
    }

    func testSelectorsAsPuppeteerLocators() {
        XCTAssertEqual(DeveloperRecorderSelector.puppeteer([#"aria/Submit[role="button"]"#]), #"::-p-aria(Submit[role=\"button\"])"#)
        XCTAssertEqual(DeveloperRecorderSelector.puppeteer([#"xpath///*[@id="q"]"#]), #"::-p-xpath(//*[@id=\"q\"])"#)
        XCTAssertEqual(DeveloperRecorderSelector.puppeteer(["pierce/#q"]), ":scope >>> #q")
        XCTAssertEqual(DeveloperRecorderSelector.puppeteer(["text/Go"]), "::-p-text(Go)")
        XCTAssertEqual(DeveloperRecorderSelector.puppeteer(["my-app", "#inner"]), "my-app >>>> #inner")
    }

    func testSelectorsAreKeptToTheChosenKinds() {
        let all = [["aria/A"], ["#a"], ["xpath///*[@id=\"a\"]"], ["pierce/#a"], ["text/A"]]
        XCTAssertEqual(DeveloperRecorderSelector.filter(all, to: [.css, .text]), [["#a"], ["text/A"]])
        let message: [String: Any] = ["type": "click", "selectors": all, "offsetX": 1, "offsetY": 2]
        let step = DeveloperRecorderFlow.step(from: message, types: [.aria])
        XCTAssertEqual(step?.selectors, [["aria/A"]])
        XCTAssertEqual(step?.target, "main")
        XCTAssertNil(DeveloperRecorderFlow.step(from: ["type": "click", "selectors": [["#a"]]], types: [.xpath]),
                     "a click with none of the chosen selectors has nothing to replay")
        XCTAssertNil(DeveloperRecorderFlow.step(from: ["type": "bogus"], types: [.css]))
    }

    // MARK: Folding

    func testTypingIsOneChangeWithTheFinalValue() {
        var steps: [DeveloperRecorderStep] = [click("#name")]
        for value in ["h", "he", "hel", "hello"] {
            DeveloperRecorderFlow.append(change("#name", value), to: &steps)
        }
        XCTAssertEqual(steps.map(\.type), ["click", "change"])
        XCTAssertEqual(steps.last?.value, "hello")

        DeveloperRecorderFlow.append(change("#other", "x"), to: &steps)
        DeveloperRecorderFlow.append(change("#name", "again"), to: &steps)
        XCTAssertEqual(steps.map(\.value), [nil, "hello", "x", "again"])
    }

    func testDoubleClickReplacesItsClicks() {
        var steps: [DeveloperRecorderStep] = [click("#other")]
        DeveloperRecorderFlow.append(click("#cell"), to: &steps)
        DeveloperRecorderFlow.append(click("#cell"), to: &steps)
        var double = click("#cell")
        double.type = "doubleClick"
        DeveloperRecorderFlow.append(double, to: &steps)
        XCTAssertEqual(steps.map(\.type), ["click", "doubleClick"])
        XCTAssertEqual(steps.first?.selectors, [["#other"]])
    }

    func testScrollingAgainIsOneScroll() {
        var steps: [DeveloperRecorderStep] = []
        for y in [100.0, 300, 450] {
            var scroll = DeveloperRecorderStep(type: "scroll", fields: ["target": .string("main")])
            scroll.x = 0
            scroll.y = y
            DeveloperRecorderFlow.append(scroll, to: &steps)
        }
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].y, 450)
    }

    func testNavigationIsAssertedOnTheStepThatCausedIt() {
        let now = Date()
        var steps = DeveloperRecorderFlow.opening(width: 1280, height: 720, scale: 2, url: "https://a.test/", title: nil)
        DeveloperRecorderFlow.loaded(url: "https://a.test/", title: "A", into: &steps, lastAction: nil, now: now, first: true)
        XCTAssertEqual(steps.map(\.type), ["setViewport", "navigate"])
        XCTAssertEqual(steps[1].assertedEvents, [DeveloperRecorderAssertedEvent(url: "https://a.test/", title: "A")])

        DeveloperRecorderFlow.append(click("a"), to: &steps)
        DeveloperRecorderFlow.loaded(url: "https://a.test/b", title: "B", into: &steps, lastAction: now, now: now + 1, first: false)
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps[2].assertedEvents.first?.url, "https://a.test/b")

        // Long after anything was done: an address typed, a step of its own.
        DeveloperRecorderFlow.loaded(url: "https://c.test/", title: "C", into: &steps, lastAction: now, now: now + 60, first: false)
        XCTAssertEqual(steps.last?.type, "navigate")
        XCTAssertEqual(steps.last?.url, "https://c.test/")

        // Enter: on the key going down.
        var down = DeveloperRecorderStep(type: "keyDown", fields: ["target": .string("main"), "key": .string("Enter")])
        var up = down
        up.type = "keyUp"
        up.id = UUID()
        DeveloperRecorderFlow.append(down, to: &steps)
        DeveloperRecorderFlow.append(up, to: &steps)
        DeveloperRecorderFlow.loaded(url: "https://c.test/search", title: "S", into: &steps, lastAction: now, now: now, first: false)
        XCTAssertEqual(steps[steps.count - 2].type, "keyDown")
        XCTAssertTrue(steps[steps.count - 2].assertsNavigation)
        XCTAssertFalse(steps[steps.count - 1].assertsNavigation)
        down = steps[steps.count - 2]
        XCTAssertEqual(down.assertedEvents.count, 1)
    }

    func testOpeningSteps() {
        let steps = DeveloperRecorderFlow.opening(width: 1279.6, height: 720.2, scale: 2, url: "https://a.test/", title: "A")
        XCTAssertEqual(steps[0]["width"], .number(1280))
        XCTAssertEqual(steps[0]["height"], .number(720))
        XCTAssertEqual(steps[0]["isMobile"], .bool(false))
        XCTAssertEqual(steps[1].url, "https://a.test/")
    }

    // MARK: Exports

    func testPuppeteerStepText() throws {
        var step = try sample().steps[2]
        step.assertedEvents = [DeveloperRecorderAssertedEvent(url: "https://example.com/next", title: "")]
        let expected = #"""
        {
            const targetPage = page;
            const promises = [];
            const startWaitingForEvents = () => {
                promises.push(targetPage.waitForNavigation());
            }
            await puppeteer.Locator.race([
                targetPage.locator('::-p-aria(Submit[role=\\"button\\"])'),
                targetPage.locator('#submit'),
                targetPage.locator('::-p-xpath(//*[@id=\\"submit\\"])'),
                targetPage.locator(':scope >>> #submit'),
                targetPage.locator('::-p-text(Submit)')
            ])
                .setTimeout(timeout)
                .on('action', () => startWaitingForEvents())
                .click({
                  offset: {
                    x: 54.5,
                    y: 9,
                  },
                });
            await Promise.all(promises);
        }
        """#
        XCTAssertEqual(DeveloperRecorderExport.puppeteerStep(step).joined(separator: "\n"), expected)
    }

    func testPuppeteerScript() throws {
        let script = DeveloperRecorderExport.puppeteer(try sample())
        XCTAssertTrue(script.hasPrefix("const puppeteer = require('puppeteer'); // v23.0.0 or later\n\n(async () => {\n"))
        XCTAssertTrue(script.contains("    const timeout = 5000;\n    page.setDefaultTimeout(timeout);\n"))
        XCTAssertTrue(script.contains("""
            {
                const targetPage = page;
                await targetPage.setViewport({
                    width: 1280,
                    height: 720
                })
            }
        """))
        XCTAssertTrue(script.contains("""
                const targetPage = page;
                const promises = [];
                const startWaitingForEvents = () => {
                    promises.push(targetPage.waitForNavigation());
                }
                startWaitingForEvents();
                await targetPage.goto('https://example.com/');
                await Promise.all(promises);
        """))
        XCTAssertTrue(script.contains("            .fill('hello \"you\"');\n"))
        XCTAssertTrue(script.contains("        await targetPage.keyboard.down('Enter');\n"))
        XCTAssertTrue(script.contains("        await targetPage.evaluate((x, y) => { window.scroll(x, y); }, 0, 500)\n"))
        XCTAssertTrue(script.hasSuffix("    await browser.close();\n\n})().catch(err => {\n    console.error(err);\n    process.exit(1);\n});\n"))
    }

    func testPuppeteerReplayScript() throws {
        let script = DeveloperRecorderExport.puppeteerReplay(try sample())
        XCTAssertTrue(script.hasPrefix("import url from 'url';\nimport { createRunner } from '@puppeteer/replay';\n\nexport async function run(extension) {\n  const runner = await createRunner(extension);\n\n  await runner.runBeforeAllSteps();\n\n"))
        XCTAssertTrue(script.contains("""
          await runner.runStep({
            type: 'keyDown',
            target: 'main',
            key: 'Enter'
          });
        """))
        XCTAssertTrue(script.contains("""
            selectors: [
              [
                'aria/Submit[role="button"]'
              ],
        """))
        XCTAssertTrue(script.hasSuffix("  await runner.runAfterAllSteps();\n}\n\nif (process && import.meta.url === url.pathToFileURL(process.argv[1]).href) {\n  run()\n}\n"))
    }

    func testJavaScriptStrings() {
        XCTAssertEqual(DeveloperRecorderExport.jsString("it's \\ here\n"), #"'it\'s \\ here\n'"#)
        XCTAssertEqual(DeveloperRecorderExport.jsLiteral(.object([("a-b", .number(1)), ("c", .string("d"))])),
                       "{\n  'a-b': 1,\n  c: 'd'\n}")
    }

    func testNewStepsAndTitles() {
        let step = DeveloperRecorderStep(.click)
        XCTAssertEqual(step.type, "click")
        XCTAssertEqual(step.selectors, [["body"]])
        XCTAssertEqual(step.title, "Click")
        var right = step
        right.button = "secondary"
        XCTAssertEqual(right.title, "Right click")
        XCTAssertEqual(DeveloperRecorderSpeed.extremelySlow.delay, .milliseconds(2000))
        XCTAssertTrue(DeveloperRecording.defaultTitle().hasPrefix("Recording "))
    }
}
