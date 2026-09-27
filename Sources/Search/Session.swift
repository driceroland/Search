import Foundation

// What was open last time. A list of addresses and their names, and which one
// you were looking at — nothing else, because everything else is either on the
// page or in the history file next door.

enum Session {
    struct Entry: Codable {
        var url: String
        var title: String
        var pin: String?
        /// The name you gave the tab, when you gave it one.
        var name: String?
        /// A pin's own page, the one it was pinned at (see Browser.goHome).
        var home: String?
        /// The group this ordinary tab belongs to, if any.
        var groupID: UUID? = nil
    }

    struct Shape: Codable {
        var tabs: [Entry]
        var active: Int
        /// Nil in sessions written before tab groups existed. Written whether
        /// or not groups are turned on, so turning them off loses nothing.
        var groups: [TabGroup]? = nil
    }

    /// The first space's is the session there always was; each other space
    /// keeps its own beside it.
    private static func file(_ space: UUID) -> URL {
        Store.file(space == Space.firstID ? "session.json" : "session-\(space.uuidString).json")
    }

    static func erase(space: UUID) {
        guard space != Space.firstID else { return }
        try? FileManager.default.removeItem(at: file(space))
    }

    static func read(space: UUID = Space.firstID) -> Shape {
        let file = file(space)
        guard let data = try? Data(contentsOf: file) else { return Shape(tabs: [], active: 0) }
        guard let shape = try? JSONDecoder().decode(Shape.self, from: data) else {
            // A file that's there but won't decode is not the same as no
            // file: something wrote it, and overwriting it on the next save
            // without a trace is how yesterday's tabs actually disappear.
            Store.quarantine(file)
            return Shape(tabs: [], active: 0)
        }
        return shape
    }

    /// `now` writes on the calling thread. Quitting doesn't wait for a
    /// background queue, and a session handed to one on the way out is a
    /// session that may never reach the disk.
    static func write(now: Bool = false, space: UUID = Space.firstID, _ shape: Shape) {
        // One after another, the newest last (see Disk).
        Disk.write(file(space), now: now) { try? JSONEncoder().encode(shape) }
    }
}

// The groups are the one part of the file an older or newer version may not
// agree on, so they are read leniently: a value that doesn't make sense is
// taken for no groups at all, never for a file that won't decode. That would
// put the whole session in quarantine and bring back not a single tab. An
// older version reading this file skips both keys, as JSONDecoder skips any
// key it isn't asked for. In extensions, so the memberwise initialisers stay.

extension Session.Entry {
    private enum Keys: String, CodingKey { case url, title, pin, name, home, groupID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        pin = try c.decodeIfPresent(String.self, forKey: .pin)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        home = try c.decodeIfPresent(String.self, forKey: .home)
        groupID = try? c.decodeIfPresent(UUID.self, forKey: .groupID)
    }
}

extension Session.Shape {
    private enum Keys: String, CodingKey { case tabs, active, groups }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        tabs = try c.decode([Session.Entry].self, forKey: .tabs)
        active = try c.decode(Int.self, forKey: .active)
        groups = try? c.decodeIfPresent([TabGroup].self, forKey: .groups)
    }
}
