import AppKit
import UniformTypeIdentifiers

/// The save and open panels for the Memory panel's heap snapshots, as
/// Chrome's Save profile… and Load profile. Files are .heapsnapshot, as
/// Chrome names them, holding WebKit's snapshot JSON; plain .json opens too.
@MainActor
enum DeveloperMemoryFiles {
    static let snapshotType = UTType(filenameExtension: "heapsnapshot", conformingTo: .json) ?? .json

    static func save(_ entry: DeveloperMemory.Entry, from memory: DeveloperMemory) {
        guard entry.canSave else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = DeveloperMemory.snapshotFileName()
        panel.allowedContentTypes = [snapshotType]
        panel.canCreateDirectories = true
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                memory.save(entry, to: url)
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            memory.save(entry, to: url)
        }
    }

    static func load(into memory: DeveloperMemory) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [snapshotType, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                memory.load(from: url)
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            memory.load(from: url)
        }
    }
}
