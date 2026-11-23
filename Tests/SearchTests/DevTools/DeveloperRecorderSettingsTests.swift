import XCTest
@testable import Search

/// Recorder's Add assertion, Replay settings and Show code.
@MainActor
final class DeveloperRecorderSettingsTests: XCTestCase {
    private func click(_ selectors: [[String]], frame: [Int]? = nil) -> DeveloperRecorderStep {
        var step = DeveloperRecorderStep(type: "click", fields: ["target": .string("main"), "offsetX": .number(1),
                                                                 "offsetY": .number(2)])
        step.selectors = selectors
        if let frame { step["frame"] = .array(frame.map { .number(Double($0)) }) }
        return step
    }

    // MARK: Add assertion

    func testAddAssertionWaitsForTheElementLastActedOn() {
        let steps = DeveloperRecorderFlow.opening(width: 800, height: 600, scale: 2, url: "https://example.com/", title: "E")
            + [click([["#first"]]), click([["aria/Submit"], ["#submit"]], frame: [0]),
               DeveloperRecorderStep(type: "keyDown", fields: ["target": .string("main"), "key": .string("Enter")])]
        let assertion = DeveloperRecorderFlow.assertion(after: steps)
        XCTAssertEqual(assertion.kind, .waitForElement)
        XCTAssertEqual(assertion.selectors, [["aria/Submit"], ["#submit"]])
        XCTAssertEqual(assertion.target, "main")
        XCTAssertEqual(assertion["frame"], .array([.number(0)]))
        XCTAssertEqual(assertion.json["type"]?.string, "waitForElement")
    }

    func testAddAssertionWithNothingActedOnWaitsForTheBody() {
        let steps = DeveloperRecorderFlow.opening(width: 800, height: 600, scale: 1, url: "https://example.com/", title: nil)
        let assertion = DeveloperRecorderFlow.assertion(after: steps)
        XCTAssertEqual(assertion.kind, .waitForElement)
        XCTAssertEqual(assertion.selectors, [["body"]])
    }

    // MARK: Replay settings

    func testNetworkGoesInAsAnEmulateNetworkConditionsStepAfterTheViewport() throws {
        var recording = DeveloperRecording(title: "Flow", steps: DeveloperRecorderFlow.opening(
            width: 800, height: 600, scale: 1, url: "https://example.com/", title: "E"))
        XCTAssertEqual(DeveloperRecorderNetwork.condition(of: recording), .unrestricted)

        DeveloperRecorderNetwork.set(.threeG, in: &recording)
        XCTAssertEqual(recording.steps.map(\.type), ["setViewport", "emulateNetworkConditions", "navigate"])
        let step = recording.steps[1]
        XCTAssertEqual(step["download"]?.number, 50_000)
        XCTAssertEqual(step["upload"]?.number, 50_000)
        XCTAssertEqual(step["latency"]?.number, 2_000)
        XCTAssertEqual(DeveloperRecorderNetwork.condition(of: recording), .threeG)
        XCTAssertEqual(step.title, "Emulate network conditions")
        XCTAssertEqual(step.subtitle, "3G")

        DeveloperRecorderNetwork.set(.offline, in: &recording)
        XCTAssertEqual(recording.steps.filter { $0.kind == .emulateNetworkConditions }.count, 1)
        XCTAssertEqual(DeveloperRecorderNetwork.condition(of: recording), .offline)

        DeveloperRecorderNetwork.set(.unrestricted, in: &recording)
        XCTAssertEqual(recording.steps.map(\.type), ["setViewport", "navigate"])
    }

    func testChromesSlowPresetReadsAsTheNearestPreset() throws {
        let step = try XCTUnwrap(DeveloperRecorderStep(json: .object([
            ("type", .string("emulateNetworkConditions")), ("download", .number(180_000)),
            ("upload", .number(84_375)), ("latency", .number(562.5)),
        ])))
        XCTAssertEqual(DeveloperRecorderNetwork.condition(of: step), .slow4G)
    }

    func testTheNetworkStepSurvivesChromesJSONAndExportsToPuppeteer() throws {
        var recording = DeveloperRecording(title: "Flow", steps: DeveloperRecorderFlow.opening(
            width: 800, height: 600, scale: 1, url: "https://example.com/", title: "E"), timeout: 9_000)
        DeveloperRecorderNetwork.set(.fast4G, in: &recording)
        let reread = try DeveloperRecording(data: Data(recording.exportedJSON.utf8))
        XCTAssertEqual(reread.timeout, 9_000)
        XCTAssertEqual(DeveloperRecorderNetwork.condition(of: reread), .fast4G)
        XCTAssertTrue(recording.exportedJSON.contains("\"type\": \"emulateNetworkConditions\""))

        let script = DeveloperRecorderExport.puppeteer(recording)
        XCTAssertTrue(script.contains("const timeout = 9000;"))
        XCTAssertTrue(script.contains("await targetPage.emulateNetworkConditions({"))
        XCTAssertTrue(script.contains("latency: 165,"))
        XCTAssertTrue(script.contains("offline: false,"))
    }

    // MARK: Show code

    func testShowCodeOffersJSONReplayAndPuppeteer() {
        var recording = DeveloperRecording(title: "Flow", steps: DeveloperRecorderFlow.opening(
            width: 800, height: 600, scale: 1, url: "https://example.com/", title: "E"))
        recording.steps.append(DeveloperRecorderFlow.assertion(after: recording.steps + [click([["#go"]])]))
        let formats = DeveloperRecorderModel.ExportFormat.allCases
        XCTAssertEqual(formats.map(\.rawValue), ["JSON", "@puppeteer/replay", "Puppeteer", "Puppeteer (for Firefox)",
                                                 "Puppeteer (including Lighthouse analysis)"])
        XCTAssertEqual(DeveloperRecorderModel.ExportFormat.json.text(recording), recording.exportedJSON)
        let replay = DeveloperRecorderModel.ExportFormat.replay.text(recording)
        XCTAssertTrue(replay.contains("import { createRunner } from '@puppeteer/replay';"))
        XCTAssertTrue(replay.contains("type: 'waitForElement'"))
        let puppeteer = DeveloperRecorderModel.ExportFormat.puppeteer.text(recording)
        XCTAssertTrue(puppeteer.contains("targetPage.locator('#go')"))
        XCTAssertTrue(puppeteer.contains(".wait();"))
    }

    // MARK: Puppeteer for Firefox and Lighthouse exports

    private func flow() -> DeveloperRecording {
        var recording = DeveloperRecording(title: "Checkout 'flow'", steps: DeveloperRecorderFlow.opening(
            width: 800, height: 600, scale: 1, url: "https://example.com/", title: "E"))
        recording.steps.append(click([["#add"]]))
        var next = click([["#next"]])
        next.assertedEvents = [DeveloperRecorderAssertedEvent(url: "https://example.com/cart", title: "Cart")]
        recording.steps.append(next)
        recording.steps.append(click([["#pay"]]))
        return recording
    }

    func testPuppeteerForFirefoxLaunchesFirefox() {
        let recording = flow()
        let chrome = DeveloperRecorderModel.ExportFormat.puppeteer.text(recording)
        let firefox = DeveloperRecorderModel.ExportFormat.puppeteerFirefox.text(recording)
        XCTAssertTrue(firefox.contains("    const browser = await puppeteer.launch({\n        browser: 'firefox'\n    });\n"))
        XCTAssertFalse(chrome.contains("firefox"))
        // The rest is the same script.
        XCTAssertEqual(firefox.replacingOccurrences(of: "puppeteer.launch({\n        browser: 'firefox'\n    });", with: "puppeteer.launch();"),
                       chrome)
    }

    func testPuppeteerWithLighthouseIsAUserFlow() throws {
        let script = DeveloperRecorderModel.ExportFormat.puppeteerLighthouse.text(flow())
        XCTAssertTrue(script.hasPrefix("const fs = require('fs');\nconst puppeteer = require('puppeteer'); // v23.0.0 or later\n"))
        XCTAssertTrue(script.contains("    const lhApi = await import('lighthouse'); // v10.0.0 or later\n"))
        XCTAssertTrue(script.contains("    const config = lhApi.desktopConfig;\n"))
        XCTAssertTrue(script.contains("    const lhFlow = await lhApi.startFlow(page, {name: 'Checkout \\'flow\\'', config, flags});\n"))
        XCTAssertTrue(script.contains("    const lhFlowReport = await lhFlow.generateReport();\n"))
        XCTAssertTrue(script.contains("fs.writeFileSync(__dirname + '/flow.report.html', lhFlowReport)"))
        // The flow's calls in order: the viewport outside the flow, the
        // opening navigation, a timespan for the click, the click that
        // navigates as a navigation, then a timespan for the last click.
        let calls = script.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("await lhFlow.") || $0.hasPrefix("await targetPage.setViewport") || $0.hasPrefix("targetPage.locator(")
                || $0.hasPrefix("await targetPage.goto(") }
        XCTAssertEqual(calls, [
            "await targetPage.setViewport({",
            "await lhFlow.startNavigation();",
            "await targetPage.goto('https://example.com/');",
            "await lhFlow.endNavigation();",
            "await lhFlow.startTimespan();",
            "targetPage.locator('#add')",
            "await lhFlow.endTimespan();",
            "await lhFlow.startNavigation();",
            "targetPage.locator('#next')",
            "await lhFlow.endNavigation();",
            "await lhFlow.startTimespan();",
            "targetPage.locator('#pay')",
            "await lhFlow.endTimespan();",
        ])
        XCTAssertTrue(script.hasSuffix("    await browser.close();\n\n})().catch(err => {\n    console.error(err);\n    process.exit(1);\n});\n"))
    }
}
