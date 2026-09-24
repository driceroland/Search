import Foundation

// What was open last time, in the same shape the Mac keeps it in: the
// addresses, their names, and which one you were looking at.

enum Session {
    struct Entry: Codable {
        var url: String
        var title: String
    }

    struct Shape: Codable {
        var tabs: [Entry]
        var active: Int
    }

    private static let file = Folder.file("session.json")

    static func read() -> Shape {
        guard let data = try? Data(contentsOf: file),
              let shape = try? JSONDecoder().decode(Shape.self, from: data)
        else { return Shape(tabs: [], active: 0) }
        return shape
    }

    /// Written where it's asked for, on the main thread: the file is a few
    /// hundred bytes, and GLib's loop doesn't drain Dispatch's main queue, so
    /// there is nowhere better to hand it.
    static func write(_ shape: Shape) {
        guard let data = try? JSONEncoder().encode(shape) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
