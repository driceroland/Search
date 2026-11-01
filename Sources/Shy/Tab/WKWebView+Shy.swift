import Combine
import ImageIO
import SwiftUI
import WebKit

// What every web view of Shy's can do: open an address or a file, and run Shy's own scripts without a click.

extension WKWebView {
    /// An address, or a file on this Mac. WebKit reads a file only when told
    /// which folder the page may read from, and loads nothing at all
    /// otherwise: an .html double-clicked in the Finder, once Shy is the
    /// Mac's browser, opened a tab that stayed empty.
    func open(_ url: URL) {
        if url.isFileURL {
            // Its folder, for the pictures and styles beside it — unless the
            // folder is the home folder, the disk or a volume, where the
            // file alone is what was opened.
            let folder = url.deletingLastPathComponent().standardizedFileURL
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            let tooWide = folder == home || ["/", "/Users", "/Volumes"].contains(folder.path)
                || folder.deletingLastPathComponent().path == "/Volumes"
            loadFileURL(url, allowingReadAccessTo: tooWide ? url : folder)
        } else {
            load(URLRequest(url: url))
        }
    }

    /// JavaScript run in Shy's own world (see Web.world), where its page
    /// scripts are, answered the way `evaluateJavaScript` answers: the value,
    /// or nil for none or an error.
    func evaluateInShy(_ js: String, then: ((Any?) -> Void)? = nil) {
        quietly(js) { result in then?(try? result.get()) }
    }

    /// A script Shy runs on its own account, without a click. WebKit's
    /// public calls run every script as though the page had just been
    /// clicked, and a page that waits for that (navigator.userActivation)
    /// could then write to the clipboard, go full screen, play sound or
    /// open a file chooser whenever Shy looked at it — on every load, every
    /// icon change, every switch back to the tab. WebKit's own variant
    /// without the click is asked for by name (as the agent's is, see
    /// Agent.run); only where it is missing does the public one run.
    /// `asFunction`: the body of an async function, with `arguments`, as
    /// callAsyncJavaScript takes it.
    func quietly(_ js: String, asFunction: Bool = false, arguments: [String: Any] = [:],
                 in frame: WKFrameInfo? = nil, in world: WKContentWorld? = nil,
                 then: ((Result<Any?, Error>) -> Void)? = nil) {
        // Shy's own world unless another is named.
        let world = world ?? Web.world
        typealias Done = @convention(block) (Any?, NSError?) -> Void
        typealias Call = @convention(c) (AnyObject, Selector, NSString, ObjCBool, NSURL?, NSDictionary?, ObjCBool,
                                         WKFrameInfo?, WKContentWorld, Done) -> Void
        let call = NSSelectorFromString(
            "_evaluateJavaScript:asAsyncFunction:withSourceURL:withArguments:forceUserGesture:inFrame:inWorld:completionHandler:"
        )
        guard responds(to: call), let imp = method(for: call) else {
            if asFunction {
                callAsyncJavaScript(js, arguments: arguments, in: frame, in: world) { then?($0.map { $0 }) }
            } else {
                evaluateJavaScript(js, in: frame, in: world) { then?($0.map { $0 }) }
            }
            return
        }
        let done: Done = { value, error in
            let result: Result<Any?, Error> = error.map { .failure($0) } ?? .success(value is NSNull ? nil : value)
            if Thread.isMainThread {
                MainActor.assumeIsolated { then?(result) }
            } else {
                DispatchQueue.main.async { then?(result) }
            }
        }
        unsafeBitCast(imp, to: Call.self)(self, call, js as NSString, ObjCBool(asFunction), nil,
                                          asFunction ? arguments as NSDictionary : nil, false, frame, world, done)
    }

    /// The same, awaited.
    func quietly(_ js: String, asFunction: Bool = false, arguments: [String: Any] = [:],
                 in frame: WKFrameInfo? = nil, in world: WKContentWorld? = nil) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            quietly(js, asFunction: asFunction, arguments: arguments, in: frame, in: world) { continuation.resume(with: $0) }
        }
    }
}
