import AppKit
import SwiftUI
import XCTest
@testable import Search

/// A window's column or strip off screen, with presses sent to it: what
/// the tests of the rows stand on (SidebarPressTests, SharedPinReuseTests).
@MainActor
class ColumnPressCase: XCTestCase {
    var browsers: [Browser] = []
    var windows: [NSWindow] = []
    var restorePreferences: (() -> Void)?
    var activationPolicy: NSApplication.ActivationPolicy?

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        // Pins are kept for the space in every window (Pins.swift): put down,
        // or the next test's column starts with them, its rows lower than
        // rowPoint has them, and a drag from there carries a pin, not the row.
        for browser in browsers {
            browser.cancelTabEdit()
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            browser.closeAll()
        }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
        try await settle()
        try await super.tearDown()
    }

    func makeBrowser(privateRows: Bool = false) -> Browser {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        let previous = (prefs.sidebar, prefs.usesTabGroups, prefs.splitView, prefs.listsPins, prefs.roomyTabs)
        restorePreferences = {
            (prefs.sidebar, prefs.usesTabGroups, prefs.splitView, prefs.listsPins, prefs.roomyTabs) = previous
        }
        let browser = Browser(record: WindowRecord())
        if privateRows { browser.leaveFiles() }
        browsers.append(browser)
        browser.prefs.sidebar = true
        browser.prefs.usesTabGroups = false
        browser.prefs.splitView = false
        browser.prefs.listsPins = false
        browser.prefs.roomyTabs = false
        for word in ["one", "two", "three"] {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(word)")!, title: word)
        }
        return browser
    }

    func makeWindow(_ browser: Browser) -> NSWindow {
        makeWindow(root: SideBar(browser: browser, prefs: browser.prefs), width: browser.prefs.sideWidth, height: 500)
    }

    func makeWindow<V: View>(root: V, width: CGFloat = 250, height: CGFloat = 40) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    func makeStripWindow(_ browser: Browser) -> NSWindow {
        makeWindow(root: TabBar(browser: browser), width: 900, height: Metrics.strip)
    }

    /// The middle of a pill in the 900-point strip of three tabs: each is
    /// about 180 points wide, the first starting after the window's lights.
    func pillPoint(_ index: Int) -> NSPoint {
        NSPoint(x: 195 + CGFloat(index) * 185, y: Metrics.strip / 2)
    }

    func rowPoint(_ index: Int, in window: NSWindow) -> NSPoint {
        NSPoint(x: 70, y: window.frame.height - Metrics.strip - 14 - CGFloat(index) * 30)
    }

    func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    /// As PinStuckTests posts: to this app alone, taken off the queue here.
    func post(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
        NSApp.postEvent(try event(type, at: point, in: window), atStart: false)
        // Until this one is through, however many are queued before it:
        // what earlier tests left on the queue (their windows' AppKit events,
        // forty and more by this point of a full run) ran past a count of
        // twenty, and the press was never sent.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            guard let queued = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.2),
                                               inMode: .default, dequeue: true) else { break }
            NSApp.sendEvent(queued)
            if queued.type == type, queued.window === window { break }
        }
        try await Task.sleep(for: .milliseconds(30))
    }

    func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clicks: Int = 1) async throws {
        window.sendEvent(try event(type, at: point, in: window, clicks: clicks))
        try await Task.sleep(for: .milliseconds(30))
    }

    func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clicks: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }
}
