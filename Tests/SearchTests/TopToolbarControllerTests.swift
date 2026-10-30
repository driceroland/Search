import XCTest
@testable import Search

final class TopToolbarControllerTests: XCTestCase {
    func testEdgeDwellRevealsAndLeavingHides() async throws {
        let controller = await MainActor.run { () -> TopToolbarController in
            let controller = TopToolbarController()
            controller.configure(eligible: true, popup: false)
            controller.pointer(inside: true, atEdge: true)
            return controller
        }
        try await Task.sleep(nanoseconds: 220_000_000)
        await MainActor.run {
            XCTAssertTrue(controller.revealed)
            controller.pointer(inside: false, atEdge: false)
            XCTAssertTrue(controller.revealed)
        }
        try await Task.sleep(nanoseconds: 450_000_000)
        await MainActor.run { XCTAssertFalse(controller.revealed) }
    }

    func testMovingWithinTriggerDoesNotRestartTheRevealDwell() async throws {
        let controller = await MainActor.run { () -> TopToolbarController in
            let controller = TopToolbarController()
            controller.configure(eligible: true, popup: false)
            controller.pointer(inside: true, atEdge: true)
            return controller
        }
        for _ in 0..<6 {
            try await Task.sleep(nanoseconds: 15_000_000)
            await MainActor.run { controller.pointer(inside: true, atEdge: true) }
        }
        await MainActor.run { XCTAssertTrue(controller.revealed); controller.reset() }
    }

    func testEditingAndPopupHoldTheStripOpen() async throws {
        let controller = await MainActor.run { () -> TopToolbarController in
            let controller = TopToolbarController()
            controller.configure(eligible: true, popup: false)
            controller.showNow()
            controller.setEditing(true)
            controller.pointer(inside: false, atEdge: false)
            return controller
        }
        try await Task.sleep(nanoseconds: 450_000_000)
        await MainActor.run {
            XCTAssertTrue(controller.revealed)
            controller.configure(eligible: true, popup: true)
            controller.setEditing(false)
        }
        try await Task.sleep(nanoseconds: 450_000_000)
        await MainActor.run {
            XCTAssertTrue(controller.revealed)
            controller.configure(eligible: true, popup: false)
        }
        try await Task.sleep(nanoseconds: 450_000_000)
        await MainActor.run { XCTAssertFalse(controller.revealed) }
    }

    func testMenuHoldAndDisableCancelPendingReveal() async throws {
        let controller = await MainActor.run { () -> TopToolbarController in
            let controller = TopToolbarController()
            controller.configure(eligible: true, popup: false)
            controller.showNow()
            controller.setMenuTracking(true)
            controller.pointer(inside: false, atEdge: false)
            return controller
        }
        try await Task.sleep(nanoseconds: 450_000_000)
        await MainActor.run {
            XCTAssertTrue(controller.revealed)
            controller.configure(eligible: false, popup: false)
            XCTAssertFalse(controller.revealed)
            XCTAssertFalse(controller.menuTracking)
            controller.configure(eligible: true, popup: false)
            controller.pointer(inside: true, atEdge: true)
            controller.reset()
        }
        try await Task.sleep(nanoseconds: 220_000_000)
        await MainActor.run { XCTAssertFalse(controller.revealed) }
    }

    func testPointerOnlyRevealsAtTheTopEdgeAndKeepsTheShownBand() {
        let size = CGSize(width: 1100, height: 780)
        XCTAssertTrue(TopToolbarPointerPolicy.hit(point: CGPoint(x: 200, y: 2), size: size, revealed: false).atEdge)
        XCTAssertFalse(TopToolbarPointerPolicy.hit(point: CGPoint(x: 200, y: 10), size: size, revealed: false).atEdge)
        XCTAssertFalse(TopToolbarPointerPolicy.hit(point: CGPoint(x: 200, y: 13), size: size, revealed: false).atEdge)
        XCTAssertFalse(TopToolbarPointerPolicy.hit(point: CGPoint(x: 200, y: 20), size: size, revealed: false).inside)
        XCTAssertTrue(TopToolbarPointerPolicy.hit(point: CGPoint(x: 200, y: 20), size: size, revealed: true).inside)
        XCTAssertFalse(TopToolbarPointerPolicy.hit(point: CGPoint(x: -1, y: 2), size: size, revealed: true).atEdge)
        XCTAssertFalse(TopToolbarPointerPolicy.hit(point: CGPoint(x: 200, y: -1), size: size, revealed: true).inside)
        XCTAssertFalse(TopToolbarPointerPolicy.hit(point: CGPoint(x: 200, y: 100), size: size, revealed: true).inside)
    }

    func testNestedMenusKeepHoldingUntilLastMenuCloses() async throws {
        let controller = await MainActor.run { () -> TopToolbarController in
            let controller = TopToolbarController()
            controller.configure(eligible: true, popup: false)
            controller.showNow()
            controller.beginMenu()
            controller.beginMenu()
            controller.endMenu()
            controller.pointer(inside: false, atEdge: false)
            return controller
        }
        try await Task.sleep(nanoseconds: 450_000_000)
        await MainActor.run {
            XCTAssertTrue(controller.revealed)
            controller.endMenu()
        }
        try await Task.sleep(nanoseconds: 450_000_000)
        await MainActor.run { XCTAssertFalse(controller.revealed) }
    }

    func testPopupHasOnlyOneOwnerEvenWithTopAndSidebarControls() {
        let top = UUID(), sidebar = UUID()
        XCTAssertTrue(ToolbarPopupOwnership.presents(owner: top, candidate: top, defaultOwner: false))
        XCTAssertFalse(ToolbarPopupOwnership.presents(owner: top, candidate: sidebar, defaultOwner: true))
        XCTAssertTrue(ToolbarPopupOwnership.presents(owner: nil, candidate: sidebar, defaultOwner: true))
        XCTAssertFalse(ToolbarPopupOwnership.presents(owner: nil, candidate: top, defaultOwner: false))
    }

    func testAddressEditCannotNavigateAnotherTab() {
        let a = UUID(), b = UUID()
        XCTAssertTrue(TopToolbarAddressPolicy.canSubmit(editingTabID: a, activeTabID: a))
        XCTAssertFalse(TopToolbarAddressPolicy.canSubmit(editingTabID: a, activeTabID: b))
        XCTAssertFalse(TopToolbarAddressPolicy.canSubmit(editingTabID: nil, activeTabID: a))
        XCTAssertFalse(TopToolbarAddressPolicy.canSubmit(editingTabID: a, activeTabID: nil))
    }

    func testRemovingTemporaryToolbarAnchorRestoresSidebarAnchor() async {
        await MainActor.run {
            let registry = ToolbarAnchorRegistry()
            let sidebar = NSView(), top = NSView()
            registry.register(sidebar, for: "extensions")
            registry.register(top, for: "extensions")
            XCTAssertTrue(registry.latest(for: "extensions") === top)
            registry.remove(top, for: "extensions")
            XCTAssertTrue(registry.latest(for: "extensions") === sidebar)
            registry.remove(sidebar, for: "extensions")
            XCTAssertNil(registry.latest(for: "extensions"))
        }
    }

    func testHeliumRevealIsImmediateAndHasHoverLeeway() async {
        await MainActor.run {
            let controller = TopToolbarController()
            controller.configure(eligible: true, popup: false)
            controller.pointer(inside: true, atEdge: true)
            XCTAssertTrue(controller.revealed)
            XCTAssertTrue(TopToolbarPointerPolicy.hit(point: CGPoint(x: 200, y: 50), size: CGSize(width: 1100, height: 780), revealed: true).inside)
            controller.reset()
        }
    }

    func testLeavingTheWindowUsesLongerGraceThanEnteringPage() async throws {
        let controller = await MainActor.run { () -> TopToolbarController in
            let controller = TopToolbarController()
            controller.configure(eligible: true, popup: false)
            controller.pointer(inside: true, atEdge: true)
            controller.pointer(inside: false, atEdge: false, outsideWindow: true)
            return controller
        }
        try await Task.sleep(nanoseconds: 450_000_000)
        await MainActor.run { XCTAssertTrue(controller.revealed); controller.reset() }
    }

    func testAddressDisplayNeverShowsCredentials() {
        let display = TopToolbarAddressPolicy.display(URL(string: "https://user:secret@example.com/path?q=1")!)
        XCTAssertFalse(display.contains("user"))
        XCTAssertFalse(display.contains("secret"))
        XCTAssertTrue(display.contains("example.com"))
        XCTAssertEqual(TopToolbarAddressPolicy.display(nil), "")
        XCTAssertEqual(TopToolbarAddressPolicy.display(URL(string: "about:blank")), "")
    }
}
