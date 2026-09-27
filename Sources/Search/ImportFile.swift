import Foundation

// What another browser exported to a file, brought in: the way in from a
// browser Search can't read directly, from another Mac, or from Safari,
// whose own files macOS keeps from other apps.
//
// One chooser takes all of it. A bookmarks page (.html), a passwords file
// (.csv), or Safari's own export — File › Export Browsing Data, a ZIP with
// its bookmarks, its passwords and a history file per profile. The files in
// that ZIP are named in the Mac's language, so they are told apart by what
// they hold, not by their names.

enum ImportFile {
    struct Found {
        var bookmarks: [Bookmark] = []
        var places: [Chromium.Place] = []
        /// A passwords file's text, for Vault.take(csv:).
        var passwords: [String] = []
        /// Safari's export holds passwords in the clear; said once brought in.
        var fromSafari = false

        var isEmpty: Bool { bookmarks.isEmpty && places.isEmpty && passwords.isEmpty }
    }

    /// Everything in the file or folder: one file, a folder of them, or a
    /// ZIP, opened into a folder of its own and gone afterwards.
    static func read(_ url: URL) -> Found {
        var found = Found()
        if url.pathExtension.lowercased() == "zip" {
            guard let folder = unzip(url) else { return found }
            defer { try? FileManager.default.removeItem(at: folder) }
            found.fromSafari = true
            collect(in: folder, into: &found)
        } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            collect(in: url, into: &found)
        } else {
            take(url, into: &found)
        }
        return found
    }

    private static func collect(in folder: URL, into found: inout Found) {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
            .compactMap { $0 as? URL } ?? []
        for file in files.sorted(by: { $0.path < $1.path }) { take(file, into: &found) }
    }

    private static func take(_ file: URL, into found: inout Found) {
        switch file.pathExtension.lowercased() {
        case "html", "htm":
            if let marks = BookmarksFile.read(file) { found.bookmarks += marks }
        case "csv":
            if let text = try? String(contentsOf: file, encoding: .utf8) { found.passwords.append(text) }
        case "json":
            found.places += history(in: file)
        default:
            break
        }
    }

    /// Safari's history file: an object with "metadata" (its "data_type"
    /// says "history") and "history", one entry per page — its address, its
    /// title, when it was last seen in microseconds since 1970, and how
    /// often. The first steps of a redirect, and pages that failed to load,
    /// are left out: they aren't places anyone meant to go.
    private static func history(in file: URL) -> [Chromium.Place] {
        guard let data = try? Data(contentsOf: file),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (top["metadata"] as? [String: Any])?["data_type"] as? String == "history",
              let entries = top["history"] as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            guard entry["destination_url"] == nil,
                  entry["latest_visit_was_load_failure"] as? Bool != true,
                  let text = entry["url"] as? String, let url = URL(string: text),
                  url.scheme == "http" || url.scheme == "https"
            else { return nil }
            let stamp = (entry["time_usec"] as? NSNumber)?.doubleValue ?? 0
            let last = stamp > 0 ? Date(timeIntervalSince1970: stamp / 1_000_000) : Date()
            let count = (entry["visits_count"] as? NSNumber)?.intValue ?? 1
            return Chromium.Place(url: url, title: entry["title"] as? String ?? "", count: max(1, count), last: last)
        }
    }

    /// The ZIP opened into a folder of its own, by the Mac's own ditto.
    private static func unzip(_ zip: URL) -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("office-import-\(UUID().uuidString)", isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return folder
    }
}
