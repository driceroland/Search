import Foundation

// What was open last time. A list of addresses and their names, and which one
// you were looking at — nothing else, because everything else is either on the
// page or in the history file next door.
//
// One file per space, holding every window that was in that space. A file
// from before windows were kept decodes as one window, which is what it was.

enum Session {
    struct Entry: Codable {
        var url: String
        var title: String
        var pin: String?
        /// The name you gave the tab, when you gave it one.
        var name: String?
    }

    /// One window's row: the tabs it held and which was on screen.
    struct WindowShape: Codable {
        /// Which window this was, so a restore can put the row back where it
        /// belongs. Nil in a file written before windows were kept.
        var id: UUID?
        var tabs: [Entry]
        var active: Int
        /// Where the window sat, when it was somewhere worth remembering.
        var frame: CGRect?
    }

    struct Shape: Codable {
        var windows: [WindowShape]

        /// One window's worth, for a file that only ever held one row.
        init(windows: [WindowShape]) {
            self.windows = windows
        }

        /// A file from before windows: `{tabs, active}`, one row.
        init(tabs: [Entry], active: Int) {
            self.windows = [WindowShape(id: nil, tabs: tabs, active: active)]
        }

        enum CodingKeys: CodingKey {
            case windows, tabs, active
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let windows = try c.decodeIfPresent([WindowShape].self, forKey: .windows) {
                self.windows = windows
                return
            }
            // Legacy: one row, no window dimension.
            let tabs = try c.decodeIfPresent([Entry].self, forKey: .tabs) ?? []
            let active = try c.decodeIfPresent(Int.self, forKey: .active) ?? 0
            self.windows = [WindowShape(id: nil, tabs: tabs, active: active)]
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(windows, forKey: .windows)
        }
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
        guard let data = try? Data(contentsOf: file) else { return Shape(windows: []) }
        guard let shape = try? JSONDecoder().decode(Shape.self, from: data) else {
            // A file that's there but won't decode is not the same as no
            // file: something wrote it, and overwriting it on the next save
            // without a trace is how yesterday's tabs actually disappear.
            Store.quarantine(file)
            return Shape(windows: [])
        }
        return shape
    }

    /// `now` writes on the calling thread. Quitting doesn't wait for a
    /// background queue, and a session handed to one on the way out is a
    /// session that may never reach the disk.
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
            put()
        } else {
            DispatchQueue.global(qos: .utility).async(execute: put)
        }
    }
}
