import AppKit
import SwiftUI
import XCTest
@testable import Search

/// The two animations that never end, the empty tab's breath and the loading
/// ring: each asks for no more frames than it needs, and the breath rests
/// while its window is not the one in use.
@MainActor
final class EndlessAnimationTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        windows.removeAll()
        try await super.tearDown()
    }

    func testBreathAsksForThirtyFramesAndGoesOnFromWhereItStopped() throws {
        let breath = Breath.breath(from: 1.3)
        XCTAssertEqual(breath.preferredFrameRateRange.maximum, 30)
        XCTAssertEqual(breath.preferredFrameRateRange.preferred, 30)
        XCTAssertEqual(breath.timeOffset, 1.3)
    }

    func testRingAsksForSixtyFrames() async throws {
        let window = makeWindow(root: Ring(size: 10))
        try await settle()
        let turn = try XCTUnwrap(animation("turn", in: window))
        XCTAssertEqual(turn.preferredFrameRateRange.maximum, 60)
    }

    func testBreathRestsUnlessItsWindowIsInUse() async throws {
        _ = NSApplication.shared
        var inUse = true
        let before = Breath.inUse
        Breath.inUse = { _ in inUse }
        defer { Breath.inUse = before }
        let window = makeWindow(root: Breath().frame(width: 300, height: 40))
        try await settle()
        let running = try XCTUnwrap(animation("breath", in: window), "In use, it breathes")
        XCTAssertEqual(running.preferredFrameRateRange.maximum, 30)

        // Another window takes the keys, or this one is covered: it rests.
        try await Task.sleep(for: .milliseconds(700))
        inUse = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertNil(animation("breath", in: window), "Not in use, the breath rests")

        // Back in use: it breathes again, from where it had got to.
        inUse = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        let again = try XCTUnwrap(animation("breath", in: window), "In use again, it breathes again")
        XCTAssertGreaterThan(again.timeOffset, 0.5, "from where it stopped, not from the start")
        XCTAssertLessThan(again.timeOffset, 5.2)

        // Covered, or on another Space: it rests too.
        inUse = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertNil(animation("breath", in: window))
    }

    // MARK: - helpers

    private func makeWindow<V: View>(root: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 320, height: 60),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    private func animation(_ key: String, in window: NSWindow) -> CAAnimation? {
        func find(_ layer: CALayer) -> CAAnimation? {
            if let found = layer.animation(forKey: key) { return found }
            for sub in layer.sublayers ?? [] { if let found = find(sub) { return found } }
            return nil
        }
        return window.contentView?.layer.flatMap(find)
    }

    private func settle() async throws {
        for window in windows { window.contentView?.layoutSubtreeIfNeeded() }
        try await Task.sleep(for: .milliseconds(300))
    }
}
