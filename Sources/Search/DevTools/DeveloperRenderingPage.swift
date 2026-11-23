import Foundation
import WebKit

/// Rendering's emulations that WebKit's Page domain doesn't have, done in
/// the inspected page's own world by DeveloperRendering-page.js: Frame
/// rendering stats, Layout shift regions, Emulate a focused page, and the
/// media features WebKit can't override (by rewriting the page's media
/// queries and wrapping matchMedia). All approximations, and labelled so.
///
/// While any is on, the script goes in ahead of each document the tab
/// loads, as the Application probe's does: it goes back in as each
/// navigation begins, since the tab puts its own scripts back then
/// (Tab.arm), and runs at once in the page already up.
@MainActor
final class DeveloperRenderingPage {
    struct State: Equatable {
        var frameStats = false
        var layoutShifts = false
        var focused = false
        /// Media feature to the value it should match, as
        /// "forced-colors": "active".
        var media: [String: String] = [:]

        var isEmpty: Bool { self == State() }

        /// The state as the script takes it, keys sorted.
        var json: String {
            let object: [String: Any] = ["frameStats": frameStats, "layoutShifts": layoutShifts,
                                         "focused": focused, "media": media]
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
                return "{}"
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    static let script = DevToolsResources.script("DeveloperRendering-page.js")
    /// `(text, overrides) => text`: the media query rewrite on its own.
    static let mediaRewriter = DevToolsResources.script("DeveloperRendering-media.js")

    /// The script called with the rewriter, the layout-shift estimator and `state`.
    static func source(_ state: State) -> String {
        "(\n" + script + "\n)(\n" + mediaRewriter + "\n,\n" + DeveloperLayoutShiftEstimator.source + "\n,\n"
            + state.json + "\n);"
    }

    private(set) var state = State()
    private weak var web: WKWebView?
    private var userScript: WKUserScript?
    private var observation: NSKeyValueObservation?

    /// Puts `next` into `web`'s page now and into each page it loads after.
    /// An empty state takes the script out and gives the page back.
    func apply(_ next: State, to web: WKWebView?) {
        if let current = self.web, current !== web { stop() }
        guard let web else { return }
        removeScript()
        let wasEmpty = state.isEmpty
        state = next
        if !(wasEmpty && next.isEmpty) {
            web.evaluateJavaScript(Self.source(next), in: nil, in: .page, completionHandler: nil)
        }
        guard !next.isEmpty else {
            observation?.invalidate()
            observation = nil
            self.web = nil
            return
        }
        self.web = web
        userScript = WKUserScript(source: Self.source(next), injectionTime: .atDocumentStart,
                                  forMainFrameOnly: true, in: .page)
        ensure(web)
        if observation == nil {
            observation = web.observe(\.isLoading, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated {
                    guard let self, web === self.web, web.isLoading else { return }
                    self.ensure(web)
                }
            }
        }
    }

    /// Developer Tools closed: the script comes out and the page is itself again.
    func stop() {
        let web = self.web
        let wasEmpty = state.isEmpty
        removeScript()
        observation?.invalidate()
        observation = nil
        self.web = nil
        state = State()
        if let web, !wasEmpty {
            web.evaluateJavaScript(Self.source(State()), in: nil, in: .page, completionHandler: nil)
        }
    }

    private func ensure(_ web: WKWebView) {
        guard let script = userScript else { return }
        let controller = web.configuration.userContentController
        // Kept by Tab.arm at each navigation, as the tab's own scripts are.
        ArmedRiders.add(script, to: controller)
        if !controller.userScripts.contains(where: { $0 === script }) { controller.addUserScript(script) }
    }

    private func removeScript() {
        guard let script = userScript else { return }
        ArmedRiders.remove(script)
        if let web {
            let controller = web.configuration.userContentController
            if controller.userScripts.contains(where: { $0 === script }) {
                // WebKit takes user scripts out all at once; the tab's go back.
                let others = controller.userScripts.filter { $0 !== script }
                controller.removeAllUserScripts()
                others.forEach(controller.addUserScript)
            }
        }
        userScript = nil
    }
}
