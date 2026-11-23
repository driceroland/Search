import Foundation
import SwiftUI

/// The CSS overview drawer tool's capture: the page script run once, its
/// answer turned into a report, and the elements it found kept in the
/// page (in an object group) so one can be highlighted or revealed in
/// Elements by its index. One per DevTools session.
@MainActor
final class DeveloperCSSOverviewModel: ObservableObject {
    @Published private(set) var report: DeveloperCSSOverview.Report?
    @Published private(set) var capturing = false
    @Published private(set) var problem: String?
    /// The page the report is of; a different page makes it stale.
    @Published private(set) var capturedAddress: URL?

    static let collect = DevToolsResources.script("DeveloperCSSOverview-collect.js")
    private static let objectGroup = "perch-css-overview"

    private weak var session: DeveloperToolsSession?
    /// The page object holding the captured elements.
    private var holder: String?
    private var holderTarget: String?
    private var hoverTask: Task<Void, Never>?

    static func model(for session: DeveloperToolsSession) -> DeveloperCSSOverviewModel {
        DeveloperSessionModels.model(for: session, make: DeveloperCSSOverviewModel.init)
    }

    private init(session: DeveloperToolsSession) {
        self.session = session
    }

    var stale: Bool { report != nil && session?.address != capturedAddress }

    func capture() {
        guard let session, session.ready, !capturing else { return }
        capturing = true
        problem = nil
        let target = session.runtimeTargetID
        Task { [weak self] in
            defer { self?.capturing = false }
            do {
                try await self?.run(session, target: target)
            } catch {
                self?.problem = error.localizedDescription
            }
        }
    }

    private func run(_ session: DeveloperToolsSession, target: String?) async throws {
        release()
        let reply = try await session.command("Runtime.evaluate", [
            "expression": Self.collect, "objectGroup": Self.objectGroup,
            "doNotPauseOnExceptionsAndMuteConsole": true, "includeCommandLineAPI": false,
        ], targetID: target)
        if reply["wasThrown"] as? Bool == true {
            let description = (reply["result"] as? [String: Any])?["description"] as? String
            throw DeveloperCSSOverviewError(description ?? "The page refused the capture.")
        }
        guard let object = reply["result"] as? [String: Any], let id = object["objectId"] as? String else {
            throw DeveloperCSSOverviewError("The page sent nothing back.")
        }
        let data = try await session.command("Runtime.callFunctionOn", [
            "objectId": id, "functionDeclaration": "function() { return this.data; }", "returnByValue": true,
        ], targetID: target)
        guard let value = (data["result"] as? [String: Any])?["value"] as? [String: Any] else {
            throw DeveloperCSSOverviewError("The capture was too large to read back.")
        }
        holder = id
        holderTarget = target
        report = DeveloperCSSOverview.report(value)
        capturedAddress = session.address
    }

    func clear() {
        release()
        report = nil
        problem = nil
        capturedAddress = nil
    }

    private func release() {
        hoverTask?.cancel()
        guard let session, holder != nil else { holder = nil; return }
        let target = holderTarget
        holder = nil
        Task { _ = try? await session.command("Runtime.releaseObjectGroup", ["objectGroup": Self.objectGroup], targetID: target) }
    }

    // MARK: Elements

    /// The captured element's node id, pushed to the inspector.
    private func node(_ index: Int) async -> Int? {
        guard let session, let holder, !stale else { return nil }
        let target = holderTarget
        guard let reply = try? await session.command("Runtime.callFunctionOn", [
            "objectId": holder, "functionDeclaration": "function(index) { return this.elements[index] || null; }",
            "arguments": [["value": index]],
        ], targetID: target),
            let object = (reply["result"] as? [String: Any])?["objectId"] as? String else { return nil }
        let node = try? await session.command("DOM.requestNode", ["objectId": object], targetID: session.domTargetID)
        _ = try? await session.command("Runtime.releaseObject", ["objectId": object], targetID: target)
        guard let id = (node?["nodeId"] as? NSNumber)?.intValue, id > 0 else { return nil }
        return id
    }

    /// An element hovered in a list: drawn on the page as Elements draws
    /// a hovered node; nil hides it.
    func hover(_ index: Int?) {
        hoverTask?.cancel()
        guard let session else { return }
        guard let index else { session.hideHighlight(); return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, let node = await self?.node(index), !Task.isCancelled else { return }
            session.highlightNode(node)
        }
    }

    /// Shows the element in the Elements panel. Entering Elements reads
    /// the document afresh, which renumbers WebKit's nodes, so the node is
    /// asked for once that is done (as the Console's reveal does).
    func reveal(_ index: Int) {
        guard let session else { return }
        hoverTask?.cancel()
        session.hideHighlight()
        let switching = session.panel != .elements
        let before = session.root
        session.select(.elements)
        Task { [weak self] in
            for _ in 0..<40 where switching {
                guard session.root == before || session.root == nil else { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let node = await self?.node(index) else { return }
            for _ in 0..<40 where session.nodes[node] == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            session.selectNode(node)
        }
    }
}

struct DeveloperCSSOverviewError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
