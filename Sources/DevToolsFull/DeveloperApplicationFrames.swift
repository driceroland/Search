import Foundation
import WebKit


/// The Application panel's additions that act on the page beyond reading
/// it: the back/forward cache test, the frame view's owner element and
/// links, and extension storage.
@MainActor
enum DeveloperApplicationMore {
    enum Issue: LocalizedError {
        case pageChanged, couldNotLeave, couldNotReturn, unavailable, saveFailed
        case message(String)

        var errorDescription: String? {
            switch self {
            case .pageChanged: "Wait for the current website to finish loading, then try again."
            case .couldNotLeave: "Search could not navigate away from the page to test it."
            case .couldNotReturn: "Search could not come back to the page. Use Back to return to it."
            case .unavailable: "The inspected page could not provide this information."
            case .saveFailed: "The extension did not save the change."
            case .message(let text): text
            }
        }
    }


    private static func wait(seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    // MARK: Network records

    /// The document's response as Network recorded it, when it did.
    static func documentDetails(_ url: String, in session: DeveloperToolsSession) async -> DeveloperRequestDetails? {
        guard let request = session.requests.last(where: { $0.url == url && $0.type == "Document" })
            ?? session.requests.last(where: { $0.url == url }) else { return nil }
        return await session.requestDetails(request.id)
    }

    /// Network, with the request for `url` selected. False when Network has none.
    @discardableResult
    static func revealInNetwork(_ url: String, in session: DeveloperToolsSession) -> Bool {
        guard let request = session.requests.last(where: { $0.url == url }) else { return false }
        let id = request.id
        session.select(.network)
        // The Network view may only now be appearing (as the Issues panel's link does).
        Task { @MainActor in
            NotificationCenter.default.post(name: DeveloperIssuesModel.revealRequestNotification, object: session,
                                            userInfo: ["id": id])
            try? await Task.sleep(for: .milliseconds(150))
            NotificationCenter.default.post(name: DeveloperIssuesModel.revealRequestNotification, object: session,
                                            userInfo: ["id": id])
        }
        return true
    }

    /// A frame resource: scripts, stylesheets and documents in Sources, the rest in Network.
    static func open(_ resource: DeveloperFrameNode.Resource, in session: DeveloperToolsSession) {
        if DeveloperFrameDetails.opensInSources(resource.type) || !revealInNetwork(resource.url, in: session) {
            session.revealSource(url: resource.url, line: 1)
        }
    }

    // MARK: Frames

    /// Reaches a frame's window by its index path from the top, as
    /// window.frames numbers subframes, and the element that holds it.
    private static let frameWalk = """
        let w = window, owner = null;
        for (const index of path) {
            const child = w.frames[index];
            if (!child) return null;
            owner = null;
            try {
                owner = Array.from(w.document.querySelectorAll('iframe, frame, object, embed'))
                    .find((element) => element.contentWindow === child) || null;
            } catch {}
            w = child;
        }
        """

    /// What the frame says of itself where Search may ask it: a cross-origin
    /// frame answers nothing, and its owner only while its parent is reachable.
    static func frameContext(path: [Int], in session: DeveloperToolsSession, address: URL) async -> DeveloperFrameDetails.Context {
        var context = DeveloperFrameDetails.Context()
        guard let web = session.web, web.url == address else { return context }
        let source = frameWalk + "\n" + """
            const describe = (element) => {
                if (!element) return null;
                let text = '<' + element.localName;
                for (const name of ['id', 'name', 'src', 'sandbox', 'allow']) {
                    const value = element.getAttribute(name);
                    if (value !== null) text += ' ' + name + '="' + value.slice(0, 160) + '"';
                }
                return text + '>';
            };
            const result = { owner: describe(owner), secure: null, isolated: null, features: null };
            try {
                result.secure = !!w.isSecureContext;
                result.isolated = !!w.crossOriginIsolated;
                const policy = w.document.featurePolicy || w.document.permissionsPolicy;
                if (policy && typeof policy.allowedFeatures === 'function') result.features = Array.from(policy.allowedFeatures()).map(String);
            } catch {}
            return result;
            """
        guard let reply = (try? await web.callAsyncJavaScript(source, arguments: ["path": path], in: nil,
                                                               contentWorld: DevHost.world)) as? [String: Any] else { return context }
        context.owner = reply["owner"] as? String
        context.secure = reply["secure"] as? Bool
        context.crossOriginIsolated = reply["isolated"] as? Bool
        context.allowedFeatures = reply["features"] as? [String]
        return context
    }

    /// Elements, with the frame's owner element selected. Entering Elements
    /// reads the document afresh, which renumbers WebKit's nodes, so the node
    /// is asked for once that is done (as the Issues panel's reveal does).
    static func revealOwner(path: [Int], in session: DeveloperToolsSession) {
        guard !path.isEmpty, let json = try? JSONSerialization.data(withJSONObject: path) else { return }
        let expression = "(() => { const path = \(String(decoding: json, as: UTF8.self)); "
            + frameWalk + "\n"
            + " return owner; })()"
        let switching = session.panel != .elements
        let before = session.root
        session.select(.elements)
        Task { @MainActor in
            for _ in 0..<40 where switching {
                guard session.root == before || session.root == nil else { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            let target = session.runtimeTargetID
            guard let reply = try? await session.command("Runtime.evaluate", [
                "expression": expression, "objectGroup": "search-application",
                "doNotPauseOnExceptionsAndMuteConsole": true, "includeCommandLineAPI": false,
            ], targetID: target),
                let object = (reply["result"] as? [String: Any])?["objectId"] as? String else { return }
            let node = try? await session.command("DOM.requestNode", ["objectId": object], targetID: session.domTargetID)
            _ = try? await session.command("Runtime.releaseObject", ["objectId": object], targetID: target)
            guard let id = (node?["nodeId"] as? NSNumber)?.intValue, id > 0 else { return }
            for _ in 0..<40 where session.nodes[id] == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            session.selectNode(id)
        }
    }
}
