import Foundation
import AppKit

// What you have kept. Downloads work already; this is only the memory of them,
// so a file you fetched an hour ago is one click from the Finder rather than a
// hunt through a folder.

struct Keep: Codable, Identifiable, Equatable {
    var name: String
    var from: String
    var path: String
    var date: Date
    /// Where the file came from, for Copy Address. Nil for a file listed
    /// before this was noted, one from inside its page or from a private tab,
    /// and one whose address went with the history.
    var address: String?

    var id: String { path }

    var url: URL { URL(fileURLWithPath: path) }
    var stillThere: Bool { FileManager.default.fileExists(atPath: path) }

    /// The address as another app can fetch it. A blob: or data: one means
    /// nothing outside its page, and a data: one is the whole file again. A
    /// password in the address goes in neither the list's file nor the
    /// clipboard.
    static func address(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        parts.user = nil
        parts.password = nil
        return parts.string
    }
}

extension Shared {
    /// History cleared or a profile deleted: where files came from goes too,
    /// from the list and from what is still coming in. No Keep says which
    /// profile it is from, so this is every profile's, as Clear History's
    /// icons are.
    @MainActor static func forgetDownloadAddresses() {
        loot.forgetAddresses()
        fetches.entries.forEach { $0.addressForgotten = true }
    }
}

@MainActor
final class Loot: ObservableObject {
    @Published private(set) var kept: [Keep] = []

    init() { load() }

    func add(_ keep: Keep) {
        kept.removeAll { $0.path == keep.path }
        kept.insert(keep, at: 0)
        // Fifty is more than anybody scrolls back through.
        if kept.count > 50 { kept.removeLast(kept.count - 50) }
        save()
    }

    func forget(_ keep: Keep) {
        kept.removeAll { $0.id == keep.id }
        save()
    }

    /// Only the list is emptied. Files you asked for are yours, and deleting
    /// them is the Finder's business, not a browser's.
    func forgetAll() {
        kept = []
        save()
    }

    /// History cleared: the addresses are a list of where you have been, and
    /// can carry a signed link. The files stay listed.
    func forgetAddresses() {
        guard kept.contains(where: { $0.address != nil }) else { return }
        for index in kept.indices { kept[index].address = nil }
        save()
    }

    func reveal(_ keep: Keep) {
        NSWorkspace.shared.activateFileViewerSelecting([keep.url])
    }

    func open(_ keep: Keep) {
        NSWorkspace.shared.open(keep.url)
    }

    private static var file: URL { Store.file("downloads.json") }

    private func load() {
        guard let data = try? Data(contentsOf: Loot.file),
              let list = try? JSONDecoder().decode([Keep].self, from: data)
        else { return }
        kept = list
    }

    private func save() {
        let snapshot = kept
        // One after another, the newest last (see Disk).
        Disk.write(Loot.file) { try? JSONEncoder().encode(snapshot) }
    }
}
