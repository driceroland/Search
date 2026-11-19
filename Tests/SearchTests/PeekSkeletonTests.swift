import AppKit
import SwiftUI
import XCTest
@testable import Search

@MainActor
final class PeekSkeletonTests: XCTestCase {
    private final class Host: NSHostingView<PeekSkeleton> {
        var layouts = 0

        override func layout() {
            layouts += 1
            super.layout()
        }
    }

    func testSweepDoesNotKeepLayingOutTheWindow() async throws {
        _ = NSApplication.shared
        let host = Host(rootView: PeekSkeleton(reducedMotion: false))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .seconds(1))
        let before = host.layouts
        try await Task.sleep(for: .seconds(3))
        let layouts = host.layouts - before
        print("Peek skeleton host layouts in 3 seconds: \(layouts)")
        XCTAssertLessThan(layouts, 10, "The sweep should not keep laying out the window")
    }

    func testSweepAppearsOnlyWithMotionAndStopsOutsideAWindow() async throws {
        _ = NSApplication.shared
        let host = Host(rootView: PeekSkeleton(reducedMotion: false))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        XCTAssertNil(sweep(in: host), "The bones wait before appearing")
        try await Task.sleep(for: .milliseconds(500))
        let view = try XCTUnwrap(sweep(in: host))
        var parent = view.layer
        var masked = false
        while let layer = parent {
            if layer.mask != nil { masked = true }
            parent = layer.superlayer
        }
        XCTAssertTrue(masked, "The light is confined to the bones")
        let gradient = try XCTUnwrap(view.layer?.sublayers?.first as? CAGradientLayer)
        let animation = try XCTUnwrap(gradient.animation(forKey: "sweep") as? CABasicAnimation)
        XCTAssertEqual(gradient.bounds.width, 480, accuracy: 0.1)
        XCTAssertEqual(animation.fromValue as? CGFloat, -240)
        XCTAssertEqual(animation.toValue as? CGFloat, 1040)
        XCTAssertEqual(animation.duration, 1.3)
        XCTAssertFalse(animation.autoreverses)
        let first = try XCTUnwrap(gradient.presentation()).position.x
        try await Task.sleep(for: .milliseconds(150))
        let second = try XCTUnwrap(gradient.presentation()).position.x
        XCTAssertNotEqual(first, second, "The light moves while the window is present")
        let container = try XCTUnwrap(view.superview)
        view.removeFromSuperview()
        XCTAssertNil(gradient.animation(forKey: "sweep"))
        container.addSubview(view)
        XCTAssertNotNil(gradient.animation(forKey: "sweep"), "The light returns with its window")

        host.rootView = PeekSkeleton(reducedMotion: true)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(sweep(in: host), "Reduce Motion leaves the bones still")
    }

    private func sweep(in view: NSView) -> PeekSweep.SweepView? {
        if let sweep = view as? PeekSweep.SweepView { return sweep }
        return view.subviews.compactMap { sweep(in: $0) }.first
    }
}
