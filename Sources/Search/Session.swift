import Foundation

// What was open last time. A list of addresses and their names, and which one
// you were looking at — per profile, or across the session.

enum Session {
    struct Entry: Codable {
        var url: String
        var title: String
        var pin: String?
    }

    struct ProfileSession: Codable {
        var profileID: UUID
        var tabs: [Entry]
        var active: Int
    }

    struct Shape: Codable {
        var tabs: [Entry]
        var active: Int
        var profiles: [ProfileSession]?
        var activeProfileID: UUID?

        init(tabs: [Entry] = [], active: Int = 0, profiles: [ProfileSession]? = nil, activeProfileID: UUID? = nil) {
            self.tabs = tabs
            self.active = active
            self.profiles = profiles
            self.activeProfileID = activeProfileID
        }
    }

    private static var file: URL { Store.file("session.json") }

    static func read() -> Shape {
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
    static func write(now: Bool = false, _ shape: Shape) {
        let file = Session.file
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
