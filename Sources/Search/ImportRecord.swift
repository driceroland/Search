import Foundation

/// What was brought over from each browser, and when: the sheet says so
/// beside the browser, and "Replace" takes back out exactly the bookmarks
/// that came from it. Kept by the browser's name, whichever profile; only
/// imports made since this was kept have one — an older one is never
/// guessed at.
struct ImportRecord: Codable, Equatable {
    var date: Date
    var bookmarks = 0
    var places = 0
    var passwords = 0
    /// Every bookmark and folder an import from it added, still to be found
    /// or not.
    var bookmarkIDs: [UUID] = []
    /// Arc's spaces made, and its pins and pinned tabs brought (see
    /// takeArc). Absent in a record from before they were kept.
    var spaces: Int?
    var pinned: Int?
}

@MainActor
enum ImportRecords {
    private static let key = "import.records"

    static func of(_ name: String) -> ImportRecord? { all[name] }

    /// What an import from `name` just added, on top of what was noted
    /// before.
    static func note(_ name: String, bookmarks ids: [UUID] = [], bookmarks added: Int = 0, places: Int = 0, passwords: Int = 0,
                     spaces: Int = 0, pinned: Int = 0) {
        var records = all
        var record = records[name] ?? ImportRecord(date: Date())
        record.date = Date()
        record.bookmarks += added
        record.places += places
        record.passwords += passwords
        record.bookmarkIDs += ids
        if spaces > 0 { record.spaces = (record.spaces ?? 0) + spaces }
        if pinned > 0 { record.pinned = (record.pinned ?? 0) + pinned }
        records[name] = record
        all = records
    }

    /// Its bookmarks taken back out: what is recorded of them goes too.
    static func forgetBookmarks(_ name: String) {
        var records = all
        records[name]?.bookmarkIDs = []
        records[name]?.bookmarks = 0
        all = records
    }

    private static var all: [String: ImportRecord] {
        get {
            Store.settings.data(forKey: key)
                .flatMap { try? JSONDecoder().decode([String: ImportRecord].self, from: $0) } ?? [:]
        }
        set { Store.settings.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }
}
