import SwiftUI
import XCTest
@testable import Search

/// The tree's badges from the node's flags: Chrome's container,
/// scroll-snap, slot and top-layer beside scroll and event, as Badge
/// settings has them.
@MainActor
final class DeveloperElementsBadgesTests: XCTestCase {
    private typealias Tree = DeveloperDOMTreeView

    func testPageBadgesShowWhenSwitchedOnInChromesOrder() {
        let all: Set<String> = ["container", "scroll-snap", "slot", "top-layer"]
        XCTAssertEqual(Tree.badges(flags: ["event", "top-layer", "container", "scrollable", "scroll-snap", "slot"],
                                   scroll: true, event: true, page: all),
                       ["container", "scroll-snap", "slot", "top-layer", "scroll", "event"])
        XCTAssertEqual(Tree.badges(flags: ["container", "slot"], scroll: true, event: true, page: ["slot"]), ["slot"],
                       "a badge switched off in Badge settings isn't shown")
        XCTAssertEqual(Tree.badges(flags: ["container"], scroll: true, event: true), [],
                       "without page badges asked for, only scroll and event")
    }

    /// Chrome's anchor badges: "anchor" on an element with an anchor-name,
    /// and on an anchor-positioned one the name its position-anchor gives,
    /// as a badge that reveals the anchor. Both follow the anchor setting.
    func testAnchorBadgesFollowTheAnchorSetting() {
        let flags = ["anchored:--tip", "anchor", "top-layer"]
        XCTAssertEqual(Tree.badges(flags: flags, scroll: true, event: true, page: ["top-layer", "anchor"]),
                       ["top-layer", "anchor", "anchored:--tip"])
        XCTAssertEqual(Tree.badges(flags: flags, scroll: true, event: true, page: ["top-layer"]), ["top-layer"],
                       "the anchor setting off hides both anchor badges")
        XCTAssertEqual(Tree.anchorName("anchored:--tip"), "--tip")
        XCTAssertNil(Tree.anchorName("anchor"))
        XCTAssertNil(Tree.anchorName("anchored:"))
    }

    func testOnlyContainerAndScrollSnapSwitchAnOverlay() {
        XCTAssertEqual(Tree.overlayBadges, ["container", "scroll-snap"])
    }

    /// A plain (not selected) row's container and scroll-snap badges switch
    /// their overlay as the selected row's do, and a row redraws when one
    /// of its overlays comes on.
    func testPlainRowBadgesSwitchTheirOverlay() {
        var sent: [(Int, String, Bool)] = []
        let actions = DeveloperDOMRowActions(
            toggle: { _ in }, select: { _ in }, hover: { _ in }, overlay: { _, _ in },
            drop: { _, _, _ in }, target: { _, _ in },
            pageOverlay: { sent.append(($0, $1, $2)) })
        let node = DeveloperToolsSession.DOMNode(id: 7, parent: 1, type: 1, name: "div", text: "", attributes: [],
                                                 children: [], count: 0, flags: ["container", "scroll-snap"])
        func row(_ shown: Set<String>) -> DeveloperDOMPlainRow<EmptyView> {
            DeveloperDOMPlainRow(row: .init(node: node, depth: 1, expanded: false), line: AttributedString("<div>"),
                                 found: false, hidden: false, layout: nil, badges: ["container", "scroll-snap"],
                                 pageOverlays: shown, overlayShown: false, dropTarget: false, wraps: false, width: 400,
                                 actions: actions, menu: { EmptyView() })
        }
        row([]).toggleOverlay("container")
        row(["scroll-snap"]).toggleOverlay("scroll-snap")
        XCTAssertEqual(sent.map { $0.0 }, [7, 7])
        XCTAssertEqual(sent.map { $0.1 }, ["container", "scroll-snap"])
        XCTAssertEqual(sent.map { $0.2 }, [true, false])
        XCTAssertFalse(row([]) == row(["container"]), "a row redraws when its overlay comes on")
        XCTAssertTrue(row(["container"]) == row(["container"]))

        let shown: Set<DeveloperElementsState.PageOverlay> = [.init(node: 7, kind: "container"),
                                                               .init(node: 8, kind: "scroll-snap")]
        XCTAssertEqual(Tree.pageOverlays(for: 7, in: shown), ["container"])
        XCTAssertEqual(Tree.pageOverlays(for: 9, in: shown), [])
    }

    func testPageOverlaysAreForgottenWithTheDocument() {
        let state = DeveloperElementsState()
        state.pageOverlays.insert(.init(node: 4, kind: "container"))
        state.reset()
        XCTAssertTrue(state.pageOverlays.isEmpty)
    }
}
