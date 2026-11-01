import Foundation

/// A tab group as sessions from before folders wrote one: read once, to be
/// made a folder (see Browser.foldGroups), and never written again.
struct TabGroup: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var collapsed: Bool
}

extension TabGroup {
    private enum Keys: String, CodingKey { case id, name, collapsed }

    /// A group saved without its folded state is an open one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        collapsed = (try? c.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? false
    }
}
