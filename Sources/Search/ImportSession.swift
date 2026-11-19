import Foundation

// The tabs a Chromium browser has open, and their tab groups, read from the
// newest "Session_*" file in a profile's Sessions/ folder (or the older
// "Current Session" beside it). Read-only: the file is read whole into
// memory through the same checked, size-capped read every other import
// uses, so a browser that is running and still writing it is never touched,
// and what is read is a copy of it as it stood.
//
// A session file is SNSS: "SNSS", a version, then frames — a size, a command
// and the command's bytes — appended as the browser goes. Only the commands
// that say what is open are read; any other is passed over by its size. A
// torn frame at the end ends the read; a file that isn't SNSS, or is
// encrypted, has nothing to bring. Recently closed tabs ("Tabs_*") and
// saved tab groups (kept in the sync store) are left behind.
//
// First written by @timwuhaotian (#841).

enum SessionImport {
    /// At most this many tabs come over, so a session of thousands doesn't
    /// make thousands of tabs at once.
    static let limit = 300

    struct Token: Hashable {
        var high: UInt64
        var low: UInt64
    }

    struct Tab: Equatable {
        var url: URL
        var title: String
        var pinned: Bool
        var group: Token?
    }

    struct Group: Equatable {
        var title: String
        var collapsed: Bool
    }

    struct Snapshot: Equatable {
        /// Each open normal window's tabs, in the order they stand there.
        var windows: [[Tab]] = []
        /// The groups those tabs are in, by token. Only ones with tabs.
        var groups: [Token: Group] = [:]
        /// How many there were before the limit, when more than it.
        var found = 0
        var tabs: Int { windows.reduce(0) { $0 + $1.count } }

        /// No more than `limit` tabs, window by window, and only the groups
        /// those still hold.
        func capped(_ limit: Int = SessionImport.limit) -> Snapshot {
            var out = Snapshot(found: max(found, tabs))
            var room = limit
            for window in windows where room > 0 {
                let kept = Array(window.prefix(room))
                room -= kept.count
                out.windows.append(kept)
            }
            for token in Set(out.windows.joined().compactMap(\.group)) { out.groups[token] = groups[token] }
            return out
        }
    }

    /// The commands that say what is open (components/sessions in Chromium).
    private enum Command: UInt8 {
        case window = 0
        case index = 2
        case navigation = 6
        case selectedNavigation = 7
        case windowType = 9
        case pinned = 12
        case tabClosed = 16
        case windowClosed = 17
        case pruned = 24
        case group = 25
        case groupMetadata = 27
    }

    static func read(_ data: Data) -> Snapshot {
        var file = Cursor(data)
        // The magic, then a version this reads: 1, or 3 with its marker.
        // Anything else — an encrypted file among them — is none to bring.
        guard file.bytes(4) == Array("SNSS".utf8), let version = file.i32(),
              version == 1 || version == 3
        else { return Snapshot() }

        var windowOf: [Int32: Int32] = [:]
        var windowTabs: [Int32: Set<Int32>] = [:]
        var windowOrder: [Int32] = []
        var windowSeen: Set<Int32> = []
        var windowType: [Int32: Int32] = [:]
        var tabIndex: [Int32: Int32] = [:]
        var tabSeen: [Int32: Int] = [:]
        var entries: [Int32: [Int32: (url: String, title: String)]] = [:]
        var selected: [Int32: Int32] = [:]
        var pinned: Set<Int32> = []
        var tabGroup: [Int32: Token] = [:]
        var meta: [Token: Group] = [:]

        func note(_ tab: Int32) {
            if tabSeen[tab] == nil { tabSeen[tab] = tabSeen.count }
        }
        func noteWindow(_ window: Int32) {
            if windowSeen.insert(window).inserted { windowOrder.append(window) }
        }
        func close(tab: Int32) {
            if let window = windowOf.removeValue(forKey: tab) { windowTabs[window]?.remove(tab) }
            tabIndex[tab] = nil
            entries[tab] = nil
            selected[tab] = nil
            pinned.remove(tab)
            tabGroup[tab] = nil
        }

        while file.left > 0 {
            guard let size = file.u16(), size >= 1, file.left >= Int(size),
                  let id = file.u8(), let body = file.bytes(Int(size) - 1)
            else { break }
            var frame = Cursor(Data(body))
            switch Command(rawValue: id) {
            case .window:
                if let window = frame.i32(), let tab = frame.i32() {
                    if let old = windowOf[tab] { windowTabs[old]?.remove(tab) }
                    windowOf[tab] = window
                    windowTabs[window, default: []].insert(tab)
                    noteWindow(window)
                    note(tab)
                }
            case .index:
                if let tab = frame.i32(), let index = frame.i32() {
                    tabIndex[tab] = index
                    note(tab)
                }
            case .navigation:
                // A pickle: its size, the tab, the entry's index, its
                // address, its title, then the page's own state, not needed.
                frame.skip(4)
                if let tab = frame.i32(), let index = frame.i32(),
                   let url = frame.utf8(), let title = frame.utf16() {
                    entries[tab, default: [:]][index] = (url, title)
                    note(tab)
                }
            case .selectedNavigation:
                if let tab = frame.i32(), let index = frame.i32() {
                    selected[tab] = index
                    note(tab)
                }
            case .windowType:
                if let window = frame.i32(), let type = frame.i32() {
                    windowType[window] = type
                    noteWindow(window)
                }
            case .pinned:
                if let tab = frame.i32(), let state = frame.u8() {
                    if state != 0 { pinned.insert(tab) } else { pinned.remove(tab) }
                    note(tab)
                }
            case .tabClosed:
                if let tab = frame.i32() { close(tab: tab) }
            case .windowClosed:
                if let window = frame.i32() {
                    windowType[window] = nil
                    for tab in windowTabs.removeValue(forKey: window) ?? [] { close(tab: tab) }
                }
            case .pruned:
                // Entries [index, index + count) are gone, and the ones after
                // them move down by count, as Chromium does. Only the entries
                // there are are looked at, whatever count the file says.
                if let tab = frame.i32(), let index = frame.i32(), let count = frame.i32(),
                   index >= 0, count > 0, let navs = entries[tab] {
                    let from = Int64(index), end = Int64(index) + Int64(count)
                    func moved(_ at: Int64) -> Int32? {
                        at < from ? Int32(at) : at >= end ? Int32(at - Int64(count)) : nil
                    }
                    var kept: [Int32: (url: String, title: String)] = [:]
                    for (at, entry) in navs { if let to = moved(Int64(at)) { kept[to] = entry } }
                    entries[tab] = kept
                    if let current = selected[tab] {
                        selected[tab] = moved(Int64(current)) ?? (index > 0 ? index - 1 : nil)
                    }
                }
            case .group:
                // A raw struct: the tab, padding for the token's alignment,
                // the token, and whether it is in a group at all.
                if let tab = frame.i32() {
                    frame.skip(4)
                    if let high = frame.u64(), let low = frame.u64() {
                        tabGroup[tab] = frame.u8() == 0 ? nil : Token(high: high, low: low)
                    }
                    note(tab)
                }
            case .groupMetadata:
                // A pickle: its size, the token, the name, the colour, then
                // (in newer files) whether it is folded. Search's groups
                // have no colour.
                frame.skip(4)
                if let high = frame.u64(), let low = frame.u64(), let title = frame.utf16() {
                    frame.skip(4)
                    let collapsed = frame.i32().map { $0 != 0 } ?? false
                    meta[Token(high: high, low: low)] = Group(title: title, collapsed: collapsed)
                }
            case nil:
                break
            }
        }

        var snapshot = Snapshot()
        for window in windowOrder {
            // Popups, apps and devtools aren't tabs to keep. A window never
            // given a type is a normal one.
            if let type = windowType[window], type != 0 { continue }
            let tabs = (windowTabs[window] ?? [])
                .sorted {
                    let a = tabIndex[$0] ?? .max, b = tabIndex[$1] ?? .max
                    return a != b ? a < b : (tabSeen[$0] ?? 0) < (tabSeen[$1] ?? 0)
                }
                .compactMap { tab -> Tab? in
                    guard let navs = entries[tab], !navs.isEmpty else { return nil }
                    let at = selected[tab].flatMap { navs[$0] != nil ? $0 : nil } ?? navs.keys.max()
                    guard let at, let entry = navs[at], let url = URL(string: entry.url),
                          url.scheme == "http" || url.scheme == "https"
                    else { return nil }
                    // A pin is never in a group.
                    let pin = pinned.contains(tab)
                    return Tab(url: url, title: titled(entry.title, for: url), pinned: pin,
                               group: pin ? nil : tabGroup[tab])
                }
            if !tabs.isEmpty { snapshot.windows.append(tabs) }
        }
        // Only groups that still have tabs; one never named gets a plain name.
        var unnamed = 0
        for token in snapshot.windows.joined().compactMap(\.group) where snapshot.groups[token] == nil {
            if let found = meta[token], !found.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                snapshot.groups[token] = Group(title: titled(found.title, for: nil), collapsed: found.collapsed)
            } else {
                unnamed += 1
                snapshot.groups[token] = Group(title: "Group \(unnamed)", collapsed: meta[token]?.collapsed ?? false)
            }
        }
        snapshot.found = snapshot.tabs
        return snapshot
    }

    /// A title fit to keep: trimmed, capped, never empty.
    static func titled(_ title: String, for url: URL?) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return String(trimmed.prefix(300)) }
        return url?.host() ?? url?.absoluteString ?? "Untitled"
    }

    /// Bytes a frame at a time, little-endian; a read past the end is nil,
    /// never a trap.
    struct Cursor {
        let data: Data
        var at: Data.Index

        init(_ data: Data) {
            self.data = data
            at = data.startIndex
        }

        var left: Int { data.endIndex - at }

        mutating func bytes(_ count: Int) -> [UInt8]? {
            guard count >= 0, left >= count else { return nil }
            let out = [UInt8](data[at ..< at + count])
            at += count
            return out
        }

        mutating func skip(_ count: Int) { at += min(max(count, 0), left) }

        mutating func u8() -> UInt8? { bytes(1)?.first }

        mutating func u16() -> UInt16? { bytes(2).map { UInt16($0[0]) | UInt16($0[1]) << 8 } }

        mutating func i32() -> Int32? {
            bytes(4).map { Int32(bitPattern: UInt32($0[0]) | UInt32($0[1]) << 8 | UInt32($0[2]) << 16 | UInt32($0[3]) << 24) }
        }

        mutating func u64() -> UInt64? {
            bytes(8).map { $0.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) } }
        }

        /// A pickle string: a byte count, the bytes, padding to four.
        mutating func utf8() -> String? {
            guard let count = i32(), count >= 0, let bytes = bytes(Int(count)) else { return nil }
            skip((4 - Int(count) % 4) % 4)
            return String(decoding: bytes, as: UTF8.self)
        }

        /// A pickle string16: a unit count, UTF-16LE, padding to four. A lone
        /// surrogate becomes the replacement character.
        mutating func utf16() -> String? {
            guard let count = i32(), count >= 0, Int(count) * 2 <= left, let bytes = bytes(Int(count) * 2) else { return nil }
            skip((4 - (Int(count) * 2) % 4) % 4)
            let units = stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
            return String(decoding: units, as: UTF16.self)
        }
    }
}

extension Chromium {
    /// The open tabs and tab groups of one profile, or of every one when
    /// `profile` is nil, from the newest session file in each, at most
    /// SessionImport.limit of them. Read off the main thread, with the
    /// counts, and kept for the moment they are brought in.
    static func sessions(in source: Source, profile: String? = nil) -> SessionImport.Snapshot {
        var all = SessionImport.Snapshot()
        for folder in source.profiles(only: profile) {
            guard let data = sessionData(in: folder, source: source) else { continue }
            let read = SessionImport.read(data)
            all.windows += read.windows
            all.found += read.found
            // Tokens are random per group, so two profiles never share one.
            all.groups.merge(read.groups) { first, _ in first }
        }
        return all.capped()
    }

    /// The newest "Session_*" in Sessions/, or "Current Session" in an older
    /// profile, through the same checked read as every other import file:
    /// a regular file, no link followed, inside the browser's folder.
    private static func sessionData(in folder: URL, source: Source) -> Data? {
        if let dir = source.file("Sessions", in: folder),
           let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let newest = names.filter { $0.hasPrefix("Session_") }
                .compactMap { name -> (name: String, date: Date)? in
                    guard let file = source.file("Sessions/\(name)", in: folder),
                          let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                          values.isRegularFile == true
                    else { return nil }
                    return (name, values.contentModificationDate ?? .distantPast)
                }
                .max { $0.date != $1.date ? $0.date < $1.date : $0.name < $1.name }
            if let newest, let data = try? source.data("Sessions/\(newest.name)", in: folder) { return data }
        }
        return try? source.data("Current Session", in: folder)
    }
}
