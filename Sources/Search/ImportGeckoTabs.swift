import Foundation

// The tabs a Firefox, Zen or other Gecko browser has open, and its tab
// groups, from its session store (see MozillaSession.store): each normal
// window's tabs in order, a tab's page the entry it was on, groups by name
// and whether they were folded — into the same snapshot Chromium's are read
// into (see ImportSession.swift), and brought in the same way.

extension MozillaSession {
    /// Every normal window's tabs. `leavingPins` leaves pinned tabs and
    /// Essentials behind, for Zen, whose pins come with its spaces.
    static func read(_ top: [String: Any], leavingPins: Bool, salt: String = "") -> SessionImport.Snapshot {
        var snapshot = SessionImport.Snapshot()
        var unnamed = 0
        // The windows open; with none, the last one closed. A Mac browser
        // stays open with its last window closed, and its session store then
        // holds that window only among the closed ones (idea 1116).
        var windows = (top["windows"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.filter { normal($0) }
        if !windows.contains(where: { !($0["tabs"] as? [Any] ?? []).isEmpty }),
           let last = (top["_closedWindows"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }).first(where: { normal($0) }) {
            windows = [last]
        }
        for (number, window) in windows.enumerated() {
            for case let raw as [String: Any] in (window["spaces"] as? [Any]) ?? [] {
                guard let id = raw["uuid"] as? String, snapshot.spaceNames[id] == nil else { continue }
                snapshot.spaceNames[id] = Arc.named(raw["name"] as? String) ?? "Space"
            }
            var groups: [String: SessionImport.Group] = [:]
            for case let raw as [String: Any] in (window["groups"] as? [Any]) ?? [] {
                guard let id = raw["id"] as? String else { continue }
                // Zen's folders and split views are groups too; a folder's
                // tabs are pinned, and a split view's are tabs side by side,
                // not a group anyone named.
                if raw["splitView"] as? Bool == true { continue }
                let name = (raw["name"] as? String) ?? ""
                groups[id] = .init(title: name, collapsed: raw["collapsed"] as? Bool ?? false)
            }
            var tabs: [SessionImport.Tab] = []
            for case let tab as [String: Any] in (window["tabs"] as? [Any]) ?? [] {
                let pinned = tab["pinned"] as? Bool == true || tab["zenEssential"] as? Bool == true || tab["zenEssential"] as? String == "true"
                if leavingPins && pinned { continue }
                if tab["zenIsGlance"] as? Bool == true || tab["zenIsEmpty"] as? Bool == true { continue }
                let entries = (tab["entries"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
                guard !entries.isEmpty else { continue }
                let index = (tab["index"] as? Int).map { min(max($0, 1), entries.count) - 1 } ?? (entries.count - 1)
                guard let url = Arc.page(entries[index]["url"] as? String) else { continue }
                var token: SessionImport.Token?
                if !pinned, let id = tab["groupId"] as? String, let group = groups[id] {
                    let made = SessionImport.Token(high: fnv("\(salt)/\(number)"), low: fnv(id))
                    if snapshot.groups[made] == nil {
                        if group.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            unnamed += 1
                            snapshot.groups[made] = .init(title: "Group \(unnamed)", collapsed: group.collapsed)
                        } else {
                            snapshot.groups[made] = .init(title: SessionImport.titled(group.title, for: nil), collapsed: group.collapsed)
                        }
                    }
                    token = made
                }
                // Zen's workspace, kept on the tab or, older, as its attribute.
                let space = (tab["zenWorkspace"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? ((tab["attributes"] as? [String: Any])?["zen-workspace-id"] as? String)
                tabs.append(.init(url: url, title: SessionImport.titled(entries[index]["title"] as? String ?? "", for: url),
                                  pinned: pinned, group: token, space: space))
            }
            if !tabs.isEmpty { snapshot.windows.append(tabs) }
        }
        snapshot.found = snapshot.tabs
        return snapshot
    }

    /// FNV-1a, for a group's token from its id: the same id, the same group.
    private static func fnv(_ text: String) -> UInt64 {
        text.utf8.reduce(0xcbf29ce484222325) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
    }
}

extension Mozilla {
    /// The open tabs and tab groups of one profile, or every one, capped
    /// as Chromium's are. Zen's pins stay behind: they come with its spaces.
    static func sessions(in source: Source, profile: String? = nil) -> SessionImport.Snapshot {
        var all = SessionImport.Snapshot()
        for folder in Zen.folders(of: source, profile: profile) {
            // Zen's own file first: since its window sync it holds every
            // tab of every space, each with its space, whatever windows
            // are open; the session store is read when it has none.
            var read = source.keepsSpaces ? Zen.sessionTabs(inProfile: folder) : SessionImport.Snapshot()
            if read.tabs == 0, let top = MozillaSession.store(in: folder) {
                read = MozillaSession.read(top, leavingPins: source.keepsSpaces, salt: folder.lastPathComponent)
            }
            all.windows += read.windows
            all.found += read.found
            all.groups.merge(read.groups) { first, _ in first }
            all.spaceNames.merge(read.spaceNames) { first, _ in first }
        }
        return all.capped()
    }
}
