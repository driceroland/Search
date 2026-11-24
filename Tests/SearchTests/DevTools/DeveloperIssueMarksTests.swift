import XCTest
@testable import Search

/// Issue underlines in the Elements tree: which element and attribute each
/// issue marks (DeveloperIssueRules.marks), and where on a row's line the
/// wave goes (DeveloperDOMTreeModel.issueSpans).
@MainActor
final class DeveloperIssueMarksTests: XCTestCase {
    func testIssuesMarkTheirElementsAndTheAttributeTheyAreAbout() {
        let snapshot = DeveloperFormSnapshot(ids: [], aria: [
            DeveloperAriaElement(index: 0, label: "div", role: "buton"),
            DeveloperAriaElement(index: 1, label: "span", attributes: [("aria-lable", "Close")]),
        ])
        var issues = DeveloperIssueRules.aria(snapshot, scan: "s1")
        issues.append(DeveloperIssue(code: .formAutocompleteMissing, key: "missing", resources: [
            DeveloperAffectedResource(kind: .element, label: "input", detail: "type=password",
                                      element: DeveloperIssueElement(scan: "s1", index: 2)),
        ]))
        issues.append(DeveloperIssue(code: .formLabelForNonExistingId, key: "for", resources: [
            DeveloperAffectedResource(kind: .element, label: "label", detail: "for=nowhere",
                                      element: DeveloperIssueElement(scan: "s1", index: 1)),
        ]))
        let groups = DeveloperIssueRules.aggregate(issues, includeThirdParty: false)
        let marks = DeveloperIssueRules.marks(groups)
        XCTAssertEqual(marks[DeveloperIssueElement(scan: "s1", index: 0)]?.map(\.attribute), ["role"])
        XCTAssertEqual(Set(marks[DeveloperIssueElement(scan: "s1", index: 1)]?.map(\.attribute) ?? []), ["aria-lable", "for"])
        // A missing attribute marks the tag.
        XCTAssertEqual(marks[DeveloperIssueElement(scan: "s1", index: 2)]?.map(\.attribute), [nil])
        let role = marks[DeveloperIssueElement(scan: "s1", index: 0)]?.first
        XCTAssertEqual(role?.title, DeveloperIssueCode.ariaInvalidRole.title)
        XCTAssertEqual(role?.group, groups.first { $0.code == .ariaInvalidRole }?.id)

        XCTAssertNil(DeveloperIssueRules.attribute(.lowTextContrast, "Contrast ratio 2.1, minimum AA ratio 4.5"))
        XCTAssertEqual(DeveloperIssueRules.attribute(.ariaHiddenFocusable, "aria-hidden=\"true\" on a focusable element"),
                       "aria-hidden")
    }

    func testSpansFallOnTheTagNameOrTheAttributeName() {
        let node = DeveloperToolsSession.DOMNode(id: 7, parent: 1, type: 1, name: "div", text: "",
                                                 attributes: ["id", "x", "role", "buton"], children: [], count: 0)
        func mark(_ attribute: String?) -> DeveloperIssueMark {
            DeveloperIssueMark(attribute: attribute, title: "t", group: "g", kind: .improvement)
        }
        // <div id="x" role="buton">: "div" at 1, "role" at 12.
        let spans = DeveloperDOMTreeModel.issueSpans(node, [mark("role"), mark(nil), mark("aria-gone")])
        XCTAssertEqual(spans.map(\.start), [1, 12])
        XCTAssertEqual(spans.map(\.length), [3, 4])
        // An attribute the row doesn't show is marked on the tag.
        XCTAssertEqual(spans[0].marks.map(\.attribute), [nil, "aria-gone"])
        XCTAssertTrue(DeveloperDOMTreeModel.issueSpans(node, []).isEmpty)
    }
}
