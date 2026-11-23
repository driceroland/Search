import Foundation

// The Sources navigator's "Group by Authored/Deployed" (its ⋮ menu, as in
// Chrome): the Page tree split in two, the files source maps name under
// Authored, the files the page loaded under Deployed.

extension SourceTree {
    /// UserDefaults key for the navigator's toggle; off by default, as in Chrome.
    static let groupByAuthoredKey = "DeveloperSourcesGroupByAuthored"
    static let authoredGroupID = "group:authored"
    static let deployedGroupID = "group:deployed"

    /// The Page tree grouped: "Authored", the source-mapped originals by
    /// origin and folder; then "Deployed", the frames and the files they
    /// loaded. A group with nothing in it is left out.
    static func grouped(_ resources: [SourceResource], frames: [DeveloperToolsSession.ResourceFrame],
                        authored: [SourceResource]) -> [SourceTreeNode] {
        var nodes: [SourceTreeNode] = []
        let originals = self.authored(authored)
        if !originals.isEmpty {
            nodes.append(SourceTreeNode(id: authoredGroupID, name: "Authored", kind: .folder, children: originals))
        }
        let deployed = build(resources, frames: frames)
        if !deployed.isEmpty {
            nodes.append(SourceTreeNode(id: deployedGroupID, name: "Deployed", kind: .folder, children: deployed))
        }
        return nodes
    }
}
