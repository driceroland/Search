import AppKit
import WebKit
import XCTest
@testable import Search

/// A tab on screen whose page process keeps dying. It used to be loaded
/// again every time, for ever — the page "refreshing itself" until Search
/// was quit. Now: twice, then it says so, and Try again brings it back.
@MainActor
final class CrashLoopTests: XCTestCase {
    override class func setUp() {
        if ProcessInfo.processInfo.environment["SEARCH_PROBE"] == nil {
            setenv("SEARCH_PROBE", "crash-loop-\(getpid())", 1)
        }
        super.setUp()
    }

    func testAPageThatKeepsDyingStopsReloadingAndTryAgainBringsItBack() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let server = try LocalPageServer([
            "/": .init(type: "text/html; charset=utf-8", body: "<!doctype html><title>Alive</title><p>alive</p>"),
        ])
        defer { server.stop() }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let tab = try XCTUnwrap(browser.active)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = tab.web
        tab.go(to: server.url("/"))
        try await until("the page loads") { await self.alive(tab.web) }

        for round in 1...2 {
            kill(tab.web)
            try await until("death \(round) is met with a reload") { await self.alive(tab.web) }
            XCTAssertNil(tab.failure)
        }

        kill(tab.web)
        try await until("the third death in a minute is left to say so") { tab.failure != nil }
        XCTAssertEqual(tab.failure, "This page kept crashing.")
        // Past loadAndVerify's own second look: nothing loads it behind the message.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let revived = await alive(tab.web)
        XCTAssertFalse(revived, "the page is not asked for again behind the message")
        XCTAssertNotNil(tab.failure)

        tab.reload()
        XCTAssertNil(tab.failure)
        try await until("Try again brings the page back") { await self.alive(tab.web) }
    }

    /// What the fix leans on: WebKit hands the reason to the private
    /// callback, and doesn't call the public one as well.
    func testWebKitSaysWhyThroughThePrivateCallback() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        XCTAssertTrue(Browser(record: WindowRecord()).responds(to: NSSelectorFromString("_webView:webContentProcessDidTerminateWithReason:")))

        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let witness = Witness()
        web.navigationDelegate = witness
        web.loadHTMLString("<title>Alive</title>", baseURL: nil)
        try await until("the page loads") { await self.alive(web) }
        kill(web)
        try await until("WebKit says the process went") { !witness.heard.isEmpty }
        XCTAssertEqual(witness.heard, ["reason \(PageEnd.crash.rawValue)"])
    }

    // MARK: - plumbing

    private final class Witness: NSObject, WKNavigationDelegate {
        var heard: [String] = []
        @objc(_webView:webContentProcessDidTerminateWithReason:)
        func webView(_ webView: WKWebView, webContentProcessDidTerminateWithReason reason: Int) {
            heard.append("reason \(reason)")
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            heard.append("public")
        }
    }

    /// The page's process killed outright, as a crash or the system's
    /// memory killer ends it. (`_killWebContentProcess` won't do: WebKit
    /// ends the process quietly then, and tells its delegate nothing.)
    private func kill(_ web: WKWebView) {
        guard let pid = web.value(forKey: "_webProcessIdentifier") as? Int32, pid > 0 else {
            return XCTFail("no process behind the page")
        }
        XCTAssertEqual(Darwin.kill(pid, SIGKILL), 0)
    }

    /// A live page answers. A dead one's answer is an error — or, with no
    /// process behind the page at all, no answer, so a second is the limit.
    private func alive(_ web: WKWebView) async -> Bool {
        await withCheckedContinuation { continuation in
            var answered = false
            let answer = { (live: Bool) in
                guard !answered else { return }
                answered = true
                continuation.resume(returning: live)
            }
            web.evaluateJavaScript("document.title") { value, error in
                answer(error == nil && (value as? String) == "Alive")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { answer(false) }
        }
    }

    private func until(_ what: String, timeout: TimeInterval = 15, _ check: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await check() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting: \(what)")
        throw CancellationError()
    }
}
