import AppKit
import WebKit
import XCTest
@testable import Search

/// Shared teardown for DevTools tests that drive a real page and inspector.
///
/// "InvalidTransition { phase: idle targetPhase: failed(deinit) }" is
/// AppKit's gesture graph (the private Gestures framework's
/// `GesturePhaseQueue.InvalidTransition`), reported when a gesture node is
/// destroyed while idle: a web view (the page, or the inspector's hidden
/// frontend) deallocating while its inspector is still closing. XCTest
/// records that report against whichever test is running. Closing the
/// session fully, stopping the page and letting the run loop settle while
/// everything is still alive keeps that teardown inside the test, in order.
@MainActor
enum DeveloperTestSupport {
    static func finish(_ session: DeveloperToolsSession?, page: WKWebView, keeping others: Any...) async {
        if let session { await session.disconnect().value }
        page.stopLoading()
        page.navigationDelegate = nil
        page.uiDelegate = nil
        // A few run loop turns for WebKit's inspector close and the frontend's
        // release to finish before the test's locals go away.
        for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(60)) }
        withExtendedLifetime(others) {}
    }

    /// Polls `condition` every 100 ms, for up to `seconds`; a timeout names
    /// what was awaited and, when given, the state at that moment.
    static func wait(_ action: String, seconds: Double = 20, in domain: String,
                     state: () -> String = { "" }, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        if condition() { return }
        let detail = state()
        let message = "Timed out after \(Int(seconds))s waiting for \(action)" + (detail.isEmpty ? "" : " (\(detail))")
        // Recorded now: the teardown's gesture report (see above) can stand in
        // for the thrown error in XCTest's log, and the reason would be lost.
        XCTFail(message)
        throw NSError(domain: domain, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
