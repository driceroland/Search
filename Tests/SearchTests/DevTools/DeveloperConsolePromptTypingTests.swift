import AppKit
import WebKit
import XCTest
import class SwiftUI.NSHostingView
@testable import Search

/// Fast typing into the Console prompt while its completions and eager
/// preview come back: every key lands where the caret was, in order.
@MainActor
final class DeveloperConsolePromptTypingTests: XCTestCase {
    func testFastTypingKeepsItsOrder() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: "<!doctype html><title>Prompt fixture</title><body>"),
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let pageWindow = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 400, height: 300),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        pageWindow.isReleasedWhenClosed = false
        pageWindow.contentView = page
        pageWindow.orderFrontRegardless()
        defer { pageWindow.close() }
        page.load(URLRequest(url: server.url("/")))
        try await DeveloperTestSupport.wait("page", in: "DeveloperConsolePromptTypingTests") { page.title == "Prompt fixture" }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        do {
            try await DeveloperTestSupport.wait("inspector", in: "DeveloperConsolePromptTypingTests") { session.ready }
            let hosting = NSHostingView(rootView: DeveloperConsoleView(session: session))
            hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
            let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 500, height: 400),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            // The typing goes straight to the text view. Lay it out offscreen
            // without making the test process's window key.
            window.orderFrontRegardless()
            defer { window.contentView = nil; window.close() }
            try await Task.sleep(for: .milliseconds(300))
            let prompt = try XCTUnwrap(Self.find(hosting))
            window.makeFirstResponder(prompt)
            for typed in ["1 + 2 + 3 + 4 + 5", "({a: 1, list: [1,2,3], el: document.body})"] {
                prompt.string = ""
                prompt.didChangeText()
                try await Task.sleep(for: .milliseconds(400))
                for character in typed {
                    prompt.insertText(String(character), replacementRange: prompt.selectedRange())
                    // About a fast typist's pace, with SwiftUI updating between keys.
                    try await Task.sleep(for: .milliseconds(12))
                }
                try await Task.sleep(for: .milliseconds(500))
                XCTAssertEqual(prompt.string, typed)
            }
            await session.disconnect().value
            withExtendedLifetime(tab) {}
        } catch {
            await session.disconnect().value
            throw error
        }
    }

    private static func find(_ view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.accessibilityIdentifier() == "developer-console-prompt" { return text }
        for child in view.subviews { if let found = find(child) { return found } }
        return nil
    }
}
