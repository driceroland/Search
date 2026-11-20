import SwiftUI

// The panel that asks which space a link from another app opens in: what it
// lists, how it is numbered, what it remembers and which links wait for it.
// No windows here; the panel (LinkChooserPanel.swift) builds on this.

enum LinkChooser {
    struct Row: Equatable {
        let space: UUID
        let name: String
        let symbol: String
        /// The colour its dot wears (Space.tint), nil for none.
        let tint: Color?
        let profile: String
        /// The key that picks it: 1 to 9, then 0, for the first ten rows.
        let digit: Int?
    }

    /// Every profile's spaces in the order of the Spaces menu.
    static func rows(profiles: [(id: UUID, name: String)], spaces: (UUID) -> [Space]) -> [Row] {
        let all = profiles.flatMap { profile in
            spaces(profile.id).map { (space: $0, profile: profile.name) }
        }
        return all.enumerated().map { index, entry in
            Row(space: entry.space.id, name: entry.space.name, symbol: entry.space.symbol,
                tint: entry.space.tint, profile: entry.profile, digit: index < 10 ? (index + 1) % 10 : nil)
        }
    }

    // MARK: - keys

    private static let rowKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
    private static let keypadKeys: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92, 82]

    /// The digit a key code types, on the main row or the keypad.
    static func digit(keyCode: UInt16) -> Int? {
        (rowKeys.firstIndex(of: keyCode) ?? keypadKeys.firstIndex(of: keyCode)).map { ($0 + 1) % 10 }
    }

    static func row(forDigit digit: Int, in rows: [Row]) -> Row? {
        rows.first { $0.digit == digit }
    }

    // MARK: - memory

    /// A site and the space it was last sent to.
    struct Choice: Equatable {
        let site: String
        let space: UUID

        /// As it is kept in the settings: a plain dictionary, like a SpaceRoute.
        var plist: [String: String] { ["site": site, "space": space.uuidString] }

        init(site: String, space: UUID) {
            self.site = site
            self.space = space
        }

        init?(plist: Any) {
            guard let entry = plist as? [String: String],
                  let site = entry["site"], let space = entry["space"].flatMap(UUID.init)
            else { return nil }
            self.init(site: site, space: space)
        }
    }

    private static let memorySize = 200

    /// The list with this choice first and the oldest dropped past the cap.
    static func remembered(_ list: [Choice], site: String, space: UUID) -> [Choice] {
        Array(([Choice(site: site, space: space)] + list.filter { $0.site != site }).prefix(memorySize))
    }

    /// The row to pick first: where this site went last, else the space in
    /// front, else the top.
    static func preselected(site: String?, rows: [Row], memory: [Choice], front: UUID?) -> Int {
        let last = memory.first { $0.site == site }?.space
        return rows.firstIndex { $0.space == last } ?? rows.firstIndex { $0.space == front } ?? 0
    }

    static func pruned(_ list: [Choice], known: Set<UUID>) -> [Choice] {
        list.filter { known.contains($0.space) }
    }

    /// What is left after clearing the history of these spaces.
    static func cleared(_ list: [Choice], spaces: Set<UUID>) -> [Choice] {
        list.filter { !spaces.contains($0.space) }
    }

    // MARK: - copy

    static func title(sender: String?) -> String {
        sender.map { "Open a link from \($0)" } ?? "Open a link"
    }

    // MARK: - waiting links

    /// Links that arrive while the panel is open, asked about one at a time
    /// in the order they came, each with the app it came from: its name,
    /// and its process when the event says.
    struct Queue {
        private var waiting: [(url: URL, sender: String?, pid: pid_t?)] = []

        var current: (url: URL, sender: String?, pid: pid_t?)? { waiting.first }
        /// How many came after the current one.
        var behind: Int { max(waiting.count - 1, 0) }

        mutating func add(_ url: URL, sender: String?, pid: pid_t? = nil) {
            waiting.append((url, sender, pid))
        }

        mutating func finishCurrent() {
            if !waiting.isEmpty { waiting.removeFirst() }
        }
    }
}
