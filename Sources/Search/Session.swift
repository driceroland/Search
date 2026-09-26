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
        /// The folder it sits in, in the column (see Folders.swift).
        var folder: String?
    }

    struct Shape: Codable {
        var tabs: [Entry]
        var active: Int
    }

    /// Keep older background saves ahead of the final save made on quit.
    private static let writes = DispatchQueue(label: "search.session", qos: .utility)

    /// The first space's is the session there always was; each other space
    /// keeps its own beside it.
    private static func file(_ space: UUID) -> URL {
        Store.file(space == Space.firstID ? "session.json" : "session-\(space.uuidString).json")
    }

    static func erase(space: UUID) {
        guard space != Space.firstID else { return }
        writes.sync { try? FileManager.default.removeItem(at: file(space)) }
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

    /// `now` waits for earlier saves and this write to reach disk. Otherwise
    /// an older background save could overwrite the final session on quit.
    static func write(now: Bool = false, space: UUID = Space.firstID, _ shape: Shape) {
        let file = file(space)
        let put = {
            guard let data = try? JSONEncoder().encode(shape) else { return }
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: file, options: .atomic)
        }
        if now {
            writes.sync(execute: put)
        } else {
            writes.async(execute: put)
        }
    }
}
