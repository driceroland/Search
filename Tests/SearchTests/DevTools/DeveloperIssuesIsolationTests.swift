import XCTest
@testable import Search

/// The Issues tool's cross-origin isolation, SharedArrayBuffer and ARIA
/// rules (DeveloperIssuesIsolation.swift), over hand-made headers, console
/// messages and page scans.
final class DeveloperIssuesIsolationTests: XCTestCase {
    private typealias Rules = DeveloperIssueRules
    private typealias Response = DeveloperIsolationResponse

    private let page = "https://app.example.test/"

    // MARK: Cross-origin isolation

    func testRequireCorpFlagsCrossOriginResourcesWithoutCORPOrCORS() {
        let document = Response(requestID: "d", url: page, type: "Document", coop: "same-origin", coep: "require-corp")
        let responses = [
            document,
            Response(requestID: "1", url: "https://app.example.test/same.js", type: "Script"),
            Response(requestID: "2", url: "https://cdn.other.test/lib.js", type: "Script", failed: true),
            Response(requestID: "3", url: "https://img.other.test/a.png", type: "Image", corp: "cross-origin"),
            Response(requestID: "4", url: "https://api.other.test/data", type: "Fetch", allowOrigin: "*"),
            Response(requestID: "5", url: "https://static.example.test/b.png", type: "Image", corp: "same-site"),
            Response(requestID: "6", url: "https://static.example.test/c.png", type: "Image", corp: "same-origin"),
        ]
        let issues = Rules.isolation(document: document, responses: responses, crossOriginIsolated: true)
        XCTAssertEqual(issues.map(\.code), [.coepCorpMissing, .coepCorpMissing])
        XCTAssertEqual(issues.map { $0.resources.first?.requestID }, ["2", "6"])
        XCTAssertEqual(issues.first?.resources.first?.detail, "Blocked: no Cross-Origin-Resource-Policy")
        XCTAssertEqual(issues.last?.resources.first?.detail, "Cross-Origin-Resource-Policy: same-origin")
        XCTAssertEqual(issues.first?.kind, .pageError)
        XCTAssertEqual(issues.first?.code.category, .crossOriginEmbedderPolicy)
    }

    func testInvalidValuesAndIncompleteIsolation() {
        let invalid = Response(requestID: "d", url: page, type: "Document", coop: "same-orign", coep: "require-corp; report-to=\"x\"")
        let found = Rules.isolation(document: invalid, responses: [invalid], crossOriginIsolated: false)
        XCTAssertEqual(found.map(\.code), [.coopCoepInvalid, .crossOriginIsolationIncomplete])
        XCTAssertEqual(found.first?.resources.first?.detail, "Cross-Origin-Opener-Policy: same-orign")
        XCTAssertEqual(found.last?.resources.first?.detail, "Cross-Origin-Opener-Policy: same-orign")
        XCTAssertEqual(found.last?.kind, .improvement)

        let coepOnly = Response(requestID: "d", url: page, type: "Document", coep: "credentialless")
        XCTAssertEqual(Rules.isolation(document: coepOnly, responses: [], crossOriginIsolated: false).first?.resources.first?.detail,
                       "Cross-Origin-Opener-Policy: missing")
        // COOP alone is a security choice, not a wish for isolation.
        let coopOnly = Response(requestID: "d", url: page, type: "Document", coop: "same-origin")
        XCTAssertTrue(Rules.isolation(document: coopOnly, responses: [], crossOriginIsolated: false).isEmpty)
        // Unknown isolation (no scan yet) says nothing.
        XCTAssertTrue(Rules.isolation(document: coepOnly, responses: [], crossOriginIsolated: nil).isEmpty)
        XCTAssertTrue(Rules.isolation(document: nil, responses: [invalid], crossOriginIsolated: false).isEmpty)
        XCTAssertEqual(Rules.policyValue(" Same-Origin ; report-to=a"), "same-origin")
    }

    func testSharedArrayBufferAndCOEPConsoleMessages() throws {
        let messages = [
            DeveloperIssueMessage(level: "error", text: "ReferenceError: Can't find variable: SharedArrayBuffer",
                                  url: "https://app.example.test/worker.js", line: 12),
            DeveloperIssueMessage(level: "error", text: "Refused to display 'https://embed.other.test/' in a frame because of Cross-Origin-Embedder-Policy."),
            DeveloperIssueMessage(level: "log", text: "SharedArrayBuffer is great"),
        ]
        XCTAssertTrue(Rules.isCandidate(messages[0]))
        XCTAssertFalse(Rules.isCandidate(messages[2]))
        let issues = Rules.classify(messages.filter(Rules.isCandidate))
        XCTAssertEqual(issues.map(\.code), [.sharedArrayBuffer, .coepCorpMissing])
        let source = try XCTUnwrap(issues.first?.resources.first)
        XCTAssertEqual(source.kind, .source)
        XCTAssertEqual(source.line, 12)
        XCTAssertEqual(issues.last?.resources.first?.url, "https://embed.other.test/")
        // The same resource found from headers and from the Console is one issue.
        let fromHeaders = Rules.isolation(
            document: Response(requestID: "d", url: page, type: "Document", coep: "require-corp"),
            responses: [Response(requestID: "9", url: "https://embed.other.test/", type: "Document")], crossOriginIsolated: true)
        XCTAssertEqual(Rules.aggregate(issues + fromHeaders, includeThirdParty: false)
            .first { $0.code == .coepCorpMissing }?.count, 1)
    }

    // MARK: ARIA

    func testARIARulesJudgeRolesAttributesValuesReferencesAndHiddenFocus() {
        let snapshot = DeveloperFormSnapshot(ids: ["title", "help"], aria: [
            DeveloperAriaElement(index: 0, label: "div#ok", role: "button", attributes: [("aria-labelledby", "title")],
                                 focusable: true),
            DeveloperAriaElement(index: 1, label: "div", role: "buton"),
            DeveloperAriaElement(index: 2, label: "nav", role: "fancy navigation"),
            DeveloperAriaElement(index: 3, label: "span", attributes: [("aria-lable", "Close")]),
            DeveloperAriaElement(index: 4, label: "button", attributes: [("aria-expanded", "yes"), ("aria-checked", "Mixed")]),
            DeveloperAriaElement(index: 5, label: "div", attributes: [("aria-describedby", "help missing"), ("aria-controls", "")]),
            DeveloperAriaElement(index: 6, label: "a", attributes: [("aria-hidden", "true")], focusable: true),
            DeveloperAriaElement(index: 7, label: "section", attributes: [("aria-hidden", "true")], containsFocusable: true),
            DeveloperAriaElement(index: 8, label: "div", attributes: [("aria-hidden", "true")]),
            DeveloperAriaElement(index: 9, label: "input#q", attributes: [("aria-labelledby", "nowhere")], formField: true),
        ])
        let issues = Rules.aria(snapshot, scan: "s1")
        XCTAssertEqual(issues.map(\.code), [.ariaInvalidRole, .ariaUnknownAttribute, .ariaInvalidValue,
                                            .ariaMissingReference, .ariaHiddenFocusable, .ariaHiddenFocusable])
        XCTAssertEqual(issues.map { $0.resources.first?.element?.index }, [1, 3, 4, 5, 6, 7])
        XCTAssertEqual(issues[2].resources.first?.detail, "aria-expanded=\"yes\"")
        XCTAssertEqual(issues[3].resources.first?.detail, "aria-describedby=missing")
        XCTAssertTrue(issues.allSatisfy { $0.code.category == .generic && $0.kind == .improvement })
    }

    func testTheScanReadsARIAElementsAndIsolation() {
        let snapshot = DeveloperFormSnapshot(raw: [
            "aria": [["i": 3, "label": "div", "role": "tab", "attributes": [["ARIA-Selected", "true"]], "focusable": true]],
            "isolated": false,
        ])
        XCTAssertEqual(snapshot.aria.first?.index, 3)
        XCTAssertEqual(snapshot.aria.first?.attributes.first?.name, "aria-selected")
        XCTAssertEqual(snapshot.aria.first?.focusable, true)
        XCTAssertEqual(snapshot.crossOriginIsolated, false)
        XCTAssertNil(DeveloperFormSnapshot(raw: [:]).crossOriginIsolated)
    }
}
