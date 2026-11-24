import AppKit
import WebKit
@testable import Search

/// A live DevTools test's page: served from loopback, in an on-screen
/// borderless window off to the side (a page in no window now and then
/// stops answering the inspector), loaded, with a DevTools session attached
/// and ready.
@MainActor
struct DeveloperLivePage {
    let server: LocalPageServer
    let page: WKWebView
    let window: NSWindow
    let tab: Tab
    let session: DeveloperToolsSession

    /// `wait` is the test's own, so its timeouts name the test; `opened`
    /// hears the session before it is ready, for those waits to describe.
    static func open(_ pages: [String: LocalPageServer.Page], title: String,
                     configure: (WKWebViewConfiguration) -> Void = { _ in },
                     opened: (DeveloperToolsSession) -> Void = { _ in },
                     wait: (String, () -> Bool) async throws -> Void) async throws -> DeveloperLivePage {
        _ = NSApplication.shared
        let server = try LocalPageServer(pages)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configure(configuration)
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        page.load(URLRequest(url: server.url("/")))
        do {
            try await wait("page to load") { page.title == title }
        } catch {
            window.close()
            throw error
        }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        opened(session)
        let live = DeveloperLivePage(server: server, page: page, window: window, tab: tab, session: session)
        do {
            try await wait("inspector") { session.ready }
        } catch {
            await live.finish()
            window.close()
            throw error
        }
        return live
    }

    func finish() async {
        await DeveloperTestSupport.finish(session, page: page, keeping: tab, server)
    }

    /// Runs `body`, then finishes the page whether it threw or not.
    func run(_ body: @MainActor () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await finish()
            throw error
        }
        await finish()
    }
}
