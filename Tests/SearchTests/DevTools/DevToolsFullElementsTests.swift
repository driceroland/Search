import WebKit
import XCTest

extension DevToolsFullTests {
    /// Reuses this suite's installed Full package on its loopback page.
    func verifyElementsParity(on page: WKWebView,
                              perform: (String, [String: Any]) async throws -> [String: Any]) async throws {
        let heading = try await perform("elements.select", ["selector": "#title"])
        let rules = try XCTUnwrap(heading["rules"] as? [[String: Any]], "\(heading)")
        XCTAssertTrue(rules.contains { rule in
            let selector = rule["selector"] as? String ?? ""
            let properties = rule["properties"] as? [String] ?? []
            return selector.contains("heading") && properties.contains { $0.hasPrefix("font-size:") }
        }, "WebKit's user-agent heading rule includes font-size: \(rules)")

        _ = try await page.evaluateJavaScript("""
            (() => {
                const documentSheet = new CSSStyleSheet();
                documentSheet.replaceSync(":root { --base: 12px; --gap: var(--base); }");
                document.adoptedStyleSheets = [documentSheet];
                const host = document.createElement("div");
                host.id = "parity-shadow";
                const shadow = host.attachShadow({ mode: "open" });
                const shadowSheet = new CSSStyleSheet();
                shadowSheet.replaceSync("span { color: teal; }");
                shadow.adoptedStyleSheets = [shadowSheet];
                shadow.append(document.createElement("span"));

                const wrap = document.createElement("div");
                wrap.style.width = "400px";
                const box = document.createElement("div");
                box.id = "parity-box";
                box.setAttribute("role", "buton");
                box.style.width = "calc(50% - var(--gap) * 2)";
                wrap.append(box);
                document.body.append(wrap, host);
            })();
            true
            """)

        let document = try await perform("elements.adoptedSheets", [:])
        let documentSheets = try XCTUnwrap(document["sheets"] as? [[String]], "\(document)")
        XCTAssertEqual(documentSheets.count, 1)
        XCTAssertTrue(documentSheets.first?.first?.contains("--gap: var(--base)") == true)
        XCTAssertTrue((document["rows"] as? [String])?.contains("#adopted-style-sheets") == true, "\(document)")

        let shadow = try await perform("elements.adoptedSheets", ["shadowHost": "#parity-shadow", "index": 0,
                                                                 "text": "span { color: rebeccapurple; }"])
        let shadowSheets = try XCTUnwrap(shadow["sheets"] as? [[String]], "\(shadow)")
        XCTAssertTrue(shadowSheets.first?.first?.contains("rebeccapurple") == true)
        XCTAssertTrue((shadow["rows"] as? [String])?.contains("#adopted-style-sheets") == true, "\(shadow)")
        let color = try await page.evaluateJavaScript("getComputedStyle(document.querySelector('#parity-shadow').shadowRoot.firstChild).color")
        XCTAssertEqual(color as? String, "rgb(102, 51, 153)")

        let selection = try await perform("elements.select", ["selector": "#parity-box"])
        let node = try XCTUnwrap(selection["node"] as? Int, "\(selection)")
        let hints = try await perform("elements.styleHints", ["reference": "var(--gap)", "property": "width",
                                                             "value": "calc(50% - var(--gap) * 2)"])
        let chain = try XCTUnwrap(hints["chain"] as? [String], "\(hints)")
        XCTAssertTrue(chain.contains { $0.contains("--gap: var(--base)") }, "\(chain)")
        XCTAssertEqual(chain.last, "Value: 12px")
        XCTAssertEqual((hints["steps"] as? [String])?.last, "calc(50% - var(--gap) * 2)")
        XCTAssertTrue((hints["math"] as? [String])?.contains("calc(50% - var(--gap) * 2) = 176px") == true, "\(hints)")

        let issues = try await perform("elements.issueMarks", ["node": node])
        XCTAssertTrue((issues["attributes"] as? [String])?.contains("role") == true, "\(issues)")

        let helpers = try await perform("elements.styleHelpers", [:])
        XCTAssertGreaterThan(helpers["apca"] as? Double ?? 0, 100)
        XCTAssertEqual(helpers["dense"] as? Bool, true)
        XCTAssertEqual(helpers["direction"] as? String, "column")
        XCTAssertEqual(helpers["regexp"] as? Bool, true)
        XCTAssertEqual(helpers["order"] as? [String], ["display", "color", "gap"])
    }
}
