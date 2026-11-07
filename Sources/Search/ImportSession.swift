import Foundation

// Open tabs, windows and tab groups read from a Chromium browser's session
// file: the newest "Session_*" in its profile's Sessions/ folder, or the
// "Current Session" beside it in an older profile.
//
// A session file is SNSS frames: "SNSS", a version, then a size, a command
// and the command's bytes, over and over. Only the commands that say what
// is open now are read; anything else is passed over by its size, and a torn
// frame at the end — Chrome appends without waiting for the disk — ends the
// read instead of failing it. Saved tab groups are not here; they live in
// the sync store, which needs LevelDB to read. Recently closed tabs
// ("Tabs_*") are left behind on purpose.

enum SessionImport {
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
        var tabs: Int { windows.reduce(0) { $0 + $1.count } }
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
        // Anything else — including an encrypted store — is none to bring.
        guard file.bytes(4) == Array("SNSS".utf8), let version = file.i32(),
              version == 1 || version == 3
        else { return Snapshot() }

        // Everything a frame says, by tab and window, before it is known
        // which tabs are still open and which entry of each is showing.
        var tabWindow: [Int32: Int32] = [:]
        var windowOrder: [Int32] = []
        var windowType: [Int32: Int32] = [:]
        var tabIndex: [Int32: Int32] = [:]
        var tabSeen: [Int32: Int] = [:]
        var seen = 0
        var entries: [Int32: [Int32: (url: String, title: String)]] = [:]
        var selected: [Int32: Int32] = [:]
        var pinned: Set<Int32> = []
        var tabGroup: [Int32: Token] = [:]
        var meta: [Token: Group] = [:]

        func note(_ tab: Int32) {
            if tabSeen[tab] == nil {
                tabSeen[tab] = seen
                seen += 1
            }
        }

        func close(tab: Int32) {
            tabWindow[tab] = nil
            tabIndex[tab] = nil
            tabSeen[tab] = nil
            entries[tab] = nil
            selected[tab] = nil
            pinned.remove(tab)
            tabGroup[tab] = nil
        }

        while file.left > 0 {
            guard let size = file.u16(), size >= 1, file.left >= Int(size) else { break }
            guard let id = file.u8() else { break }
            var frame = Cursor(Data(file.bytes(Int(size) - 1) ?? []))
            switch Command(rawValue: id) {
            case .window:
                if let window = frame.i32(), let tab = frame.i32() {
                    tabWindow[tab] = window
                    if !windowOrder.contains(window) { windowOrder.append(window) }
                    note(tab)
                }
            case .index:
                if let tab = frame.i32(), let index = frame.i32() {
                    tabIndex[tab] = index
                    note(tab)
                }
            case .navigation:
                // A pickle: its size, the tab, the entry's index, its
                // address, its title — then the page's own state, which is
                // not needed to bring the tab over.
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
                    if !windowOrder.contains(window) { windowOrder.append(window) }
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
                    windowOrder.removeAll { $0 == window }
                    windowType[window] = nil
                    for tab in tabWindow.filter({ $0.value == window }).keys { close(tab: tab) }
                }
            case .pruned:
                if let tab = frame.i32(), let index = frame.i32(), let count = frame.i32(), count > 0 {
                    // An index past the entry type's range ends the prune,
                    // never traps it.
                    let from = Int(index)
                    for offset in 0 ..< Int(count) {
                        let gone = from + offset
                        guard gone <= Int(Int32.max) else { break }
                        entries[tab]?[Int32(gone)] = nil
                    }
                }
            case .group:
                // A raw struct: the tab, padding for the token's alignment,
                // the token, and whether it is still in a group. Files from
                // before the flag carry the tab and the token alone.
                if let tab = frame.i32() {
                    frame.skip(4)
                    if let high = frame.u64(), let low = frame.u64() {
                        if frame.u8() == 0 { tabGroup[tab] = nil } else { tabGroup[tab] = Token(high: high, low: low) }
                    }
                    note(tab)
                }
            case .groupMetadata:
                // A pickle: the token, the name, the colour, then — in newer
                // files — folded, saved and the saved group's id. Only the
                // name and the fold come over; Search's groups have no colour.
                frame.skip(4)
                if let high = frame.u64(), let low = frame.u64(),
                   let title = frame.utf16() {
                    frame.skip(4)
                    let collapsed = frame.i32().map { $0 != 0 } ?? false
                    meta[Token(high: high, low: low)] = Group(title: title, collapsed: collapsed)
                }
            case nil:
                break
            }
        }

        var snapshot = Snapshot()
        var unnamed = 0
        for window in windowOrder {
            // Popups, apps and devtools are that window's own business, not
            // tabs to keep. A window never named a type is a normal one.
            if let type = windowType[window], type != 0 { continue }
            let tabs = tabWindow.filter { $0.value == window }.keys
                .sorted {
                    let ai = tabIndex[$0] ?? Int32.max, bi = tabIndex[$1] ?? Int32.max
                    return ai != bi ? ai < bi : (tabSeen[$0] ?? 0) < (tabSeen[$1] ?? 0)
                }
                .compactMap { tab -> Tab? in
                    guard let navs = entries[tab], !navs.isEmpty else { return nil }
                    let at = selected[tab].flatMap { navs[$0] != nil ? $0 : nil }
                        ?? navs.keys.max()
                    guard let at, let entry = navs[at],
                          let url = URL(string: entry.url),
                          url.scheme == "http" || url.scheme == "https"
                    else { return nil }
                    let title = SessionImport.titled(entry.title, for: url)
                    return Tab(url: url, title: title, pinned: pinned.contains(tab), group: tabGroup[tab])
                }
            guard !tabs.isEmpty else { continue }
            snapshot.windows.append(tabs)
        }
        // Only the groups that still have tabs. One never named is still a
        // group — its tabs came over together — under a plain name.
        var kept: [Token: Group] = [:]
        for tab in snapshot.windows.flatMap({ $0 }) {
            guard let token = tab.group, kept[token] == nil else { continue }
            if let found = meta[token] {
                kept[token] = Group(title: SessionImport.titled(found.title, for: nil), collapsed: found.collapsed)
            } else {
                unnamed += 1
                kept[token] = Group(title: "Group \(unnamed)", collapsed: false)
            }
        }
        snapshot.groups = kept
        return snapshot
    }

    /// A title fit to keep: trimmed, capped, and never empty.
    static func titled(_ title: String, for url: URL?) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return String(trimmed.prefix(300)) }
        return url?.host() ?? url?.absoluteString ?? "Untitled"
    }

    /// Reading bytes a frame at a time. Everything is little-endian; every
    /// read past the end fails instead of trapping.
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

        mutating func skip(_ count: Int) {
            at += min(max(count, 0), left)
        }

        mutating func u8() -> UInt8? { bytes(1)?.first }

        mutating func u16() -> UInt16? {
            bytes(2).map { UInt16($0[0]) | UInt16($0[1]) << 8 }
        }

        mutating func i32() -> Int32? {
            bytes(4).map {
                Int32($0[0]) | Int32($0[1]) << 8 | Int32($0[2]) << 16 | Int32($0[3]) << 24
            }
        }

        mutating func u64() -> UInt64? {
            bytes(8).map {
                UInt64($0[0]) | UInt64($0[1]) << 8 | UInt64($0[2]) << 16 | UInt64($0[3]) << 24
                    | UInt64($0[4]) << 32 | UInt64($0[5]) << 40 | UInt64($0[6]) << 48 | UInt64($0[7]) << 56
            }
        }

        /// A pickle string: a character count, the bytes, padding to four.
        mutating func utf8() -> String? {
            guard let count = i32(), count >= 0, let bytes = bytes(Int(count)) else { return nil }
            skip((4 - Int(count) % 4) % 4)
            return String(bytes: bytes, encoding: .utf8)
        }

        /// A pickle string16: a unit count, UTF-16LE, padding to four.
        mutating func utf16() -> String? {
            guard let count = i32(), count >= 0, count <= left,
                  let bytes = bytes(Int(count) * 2)
            else { return nil }
            skip((4 - (Int(count) * 2) % 4) % 4)
            var units: [UInt16] = []
            units.reserveCapacity(Int(count))
            for i in stride(from: 0, to: bytes.count, by: 2) {
                units.append(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
            }
            // Lone halves become the replacement character rather than
            // losing the whole title.
            var out = ""
            var i = 0
            while i < units.count {
                let unit = units[i]
                if unit >= 0xD800, unit <= 0xDBFF, i + 1 < units.count,
                   units[i + 1] >= 0xDC00, units[i + 1] <= 0xDFFF {
                    out.unicodeScalars.append(Unicode.Scalar(
                        0x10000 + (UInt32(unit - 0xD800) << 10) + UInt32(units[i + 1] - 0xDC00))!)
                    i += 2
                } else if unit >= 0xD800, unit <= 0xDFFF {
                    out.unicodeScalars.append("�")
                    i += 1
                } else if let scalar = Unicode.Scalar(unit) {
                    out.unicodeScalars.append(scalar)
                    i += 1
                } else {
                    out.unicodeScalars.append("�")
                    i += 1
                }
            }
            return out
        }
    }
}

extension Chromium {
    /// The open tabs, windows and tab groups of one profile, or of all of
    /// them when `profile` is nil: the newest session file in each. A
    /// profile with no session file has nothing open to bring.
    static func sessions(in source: Source, profile: String? = nil) -> SessionImport.Snapshot {
        var snapshot = SessionImport.Snapshot()
        for folder in source.profiles(only: profile) {
            guard let data = sessionData(in: folder, source: source) else { continue }
            let read = SessionImport.read(data)
            snapshot.windows += read.windows
            for (token, group) in read.groups where snapshot.groups[token] == nil {
                snapshot.groups[token] = group
            }
            // A group named while merging stays named; tokens are random per
            // browser run, so two profiles never share one that matters.
        }
        return snapshot
    }

    /// The newest session file's bytes: the newest "Session_*" in Sessions/,
    /// or the "Current Session" beside it in an older profile. Each
    /// candidate goes through the same check every other import read does:
    /// a real file, no followed link, inside the browser's folder.
    private static func sessionData(in folder: URL, source: Source) -> Data? {
        let root = source.root
        if let dir = source.file("Sessions", in: folder),
           let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            var sessions: [(file: URL, date: Date, name: String)] = []
            for name in names where name.hasPrefix("Session_") {
                guard let file = source.file("Sessions/\(name)", in: folder) else { continue }
                var directory = ObjCBool(false)
                guard FileManager.default.fileExists(atPath: file.path, isDirectory: &directory),
                      !directory.boolValue
                else { continue }
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                sessions.append((file, date, name))
            }
            sessions.sort { $0.date != $1.date ? $0.date < $1.date : $0.name < $1.name }
            if let newest = sessions.last,
               let data = try? ImportRead.data(newest.file, inside: root.resolvingSymlinksInPath()) {
                return data
            }
        }
        if let legacy = source.file("Current Session", in: folder),
           let data = try? ImportRead.data(legacy, inside: root.resolvingSymlinksInPath()) {
            return data
        }
        return nil
    }
}
