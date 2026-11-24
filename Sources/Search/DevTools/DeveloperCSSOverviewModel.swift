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
        let (id, value) = try await session.scanPage(Self.collect, group: Self.objectGroup, target: target,
                                                     refused: "The page refused the capture.",
                                                     tooLarge: "The capture was too large to read back.")
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
        return await session.scannedNode(holder: holder, index: index, target: holderTarget)
    }

    /// An element hovered in a list: drawn on the page; nil hides it.
    func hover(_ index: Int?) {
        hoverTask?.cancel()
        guard let index else { session?.hideHighlight(); return }
        hoverTask = session?.hoverScanned { [weak self] in await self?.node(index) }
    }

    /// Shows the element in the Elements panel.
    func reveal(_ index: Int) {
        hoverTask?.cancel()
        session?.revealScanned { [weak self] in await self?.node(index) }
    }
}
