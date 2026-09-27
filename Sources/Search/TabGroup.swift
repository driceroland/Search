import Foundation

/// A named section of ordinary tabs in one space's tab layout.
/// Its tabs remain ordinary tabs; their own group IDs describe membership.
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

extension TabGroup {
    /// The number an extension knows the group by, as Chrome numbers its
    /// groups. Taken from the identifier, so it stays the same for as long
    /// as the group lasts, across launches too, with nothing to keep.
    static func number(_ id: UUID) -> Int {
        let u = id.uuid
        let n = Int(u.0 & 0x7F) << 24 | Int(u.1) << 16 | Int(u.2) << 8 | Int(u.3)
        return n == 0 ? 1 : n
    }
}
