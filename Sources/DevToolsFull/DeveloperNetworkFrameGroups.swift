import Foundation

/// Network settings › Group by frame, as Chrome's NetworkFrameGrouper: the
/// main frame's requests stay at the top level, and each other frame's sit
/// under a row of their own, named for the frame, which expands and
/// collapses.
enum DeveloperNetworkFrameGroups {
    typealias Request = DeveloperToolsSession.Request
    typealias Frame = DeveloperToolsSession.ResourceFrame

    /// A frame's row: its id, what it's called and how many of the listed
    /// requests it made.
    struct Group: Equatable {
        let id: String
        let title: String
        let count: Int
        let expanded: Bool
    }

    /// A row of the grouped list.
    enum Entry: Identifiable {
        case request(Request)
        case frame(Group)

        var id: String {
            switch self {
            case .request(let request): request.id
            case .frame(let group): "frame:" + group.id
            }
        }
    }

    /// The page's frames as Page.getResourceTree lists them, the main
    /// frame first.
    static func frames(in tree: [String: Any]) -> [Frame] {
        var frames: [Frame] = []
        add(tree, parent: nil, to: &frames)
        return frames
    }

    private static func add(_ tree: [String: Any], parent: String?, to frames: inout [Frame]) {
        guard frames.count < 200, let frame = tree["frame"] as? [String: Any], let id = frame["id"] as? String else { return }
        frames.append(Frame(id: id, parent: parent, url: frame["url"] as? String ?? "", name: frame["name"] as? String ?? ""))
        for child in tree["childFrames"] as? [[String: Any]] ?? [] { add(child, parent: id, to: &frames) }
    }

    /// The main frame: the frame tree's root, else the frame the first
    /// document was loaded in.
    static func mainFrame(_ frames: [Frame], requests: [Request]) -> String? {
        if let root = frames.first(where: { $0.parent == nil }) { return root.id }
        return requests.first { $0.type == "Document" && $0.frameId != nil }?.frameId
            ?? requests.first { $0.frameId != nil }?.frameId
    }

    /// The list with each subframe's requests under its row, the row where
    /// the frame's first request was; a collapsed frame's requests hidden.
    static func entries(_ rows: [Request], frames: [Frame], main: String?, expanded: Set<String>) -> [Entry] {
        var members: [String: [Request]] = [:]
        for row in rows {
            guard let frame = row.frameId, frame != main else { continue }
            members[frame, default: []].append(row)
        }
        guard !members.isEmpty else { return rows.map { .request($0) } }
        var entries: [Entry] = []
        var placed = Set<String>()
        for row in rows {
            guard let frame = row.frameId, let group = members[frame] else {
                entries.append(.request(row))
                continue
            }
            guard placed.insert(frame).inserted else { continue }
            let open = expanded.contains(frame)
            entries.append(.frame(Group(id: frame, title: title(frame, frames: frames, requests: group),
                                        count: group.count, expanded: open)))
            if open { entries += group.map { .request($0) } }
        }
        return entries
    }

    /// The requests the grouped list shows, in its order.
    static func requests(in entries: [Entry]) -> [Request] {
        entries.compactMap { entry in
            if case .request(let request) = entry { return request }
            return nil
        }
    }

    /// A frame's name, else its address, else the document it loaded.
    static func title(_ id: String, frames: [Frame], requests: [Request]) -> String {
        if let frame = frames.first(where: { $0.id == id }) {
            if !frame.name.isEmpty { return frame.name }
            if !frame.url.isEmpty { return frame.url }
        }
        if let document = requests.first(where: { $0.type == "Document" }) { return document.url }
        if let document = requests.lazy.compactMap(\.documentURL).first(where: { !$0.isEmpty }) { return document }
        return id
    }
}
