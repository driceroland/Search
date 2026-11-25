import AppKit
import Darwin
import Foundation
import SwiftUI

// The Mac's screenshots in Downloads (Settings › Downloads): one taken with
// ⇧⌘3, ⇧⌘4 or ⇧⌘5 shows at the top of the list as it lands, ready to drag
// onto a page as a finished download is (Keep.dragged), as Arc's Library
// lists them. Off unless turned on: it reads a folder of yours.
//
// Where screenshots go is the Mac's own choice (⇧⌘5 › Options › Save to,
// written as com.apple.screencapture's `location`), the Desktop unless
// moved. The folder is watched, not polled: the system says when it
// changes, and only then is it listed. Only files that arrive while the
// switch is on are added — never what was there before — and only those
// the Mac marked as a screen capture (the kMDItemIsScreenCapture it writes
// on the file), or, on a volume that keeps no such mark, named as the Mac
// names them.
//
// The Desktop and Documents are folders macOS asks you about first. Asked
// and refused, nothing is listed, and Settings says where to allow it.

@MainActor
final class Screenshots: ObservableObject {
    static let shared = Screenshots()
    nonisolated static let key = "downloads.screenshots"
    /// Test runs only: the folder to watch instead of the Mac's, so a probe
    /// never reads (or makes macOS ask about) a real one.
    nonisolated static let testFolderKey = "downloads.screenshots.folder"

    /// The folder couldn't be read: macOS refused, or it isn't there.
    @Published private(set) var refused: URL?
    /// Being watched, for the bench.
    private(set) var folder: URL?

    private var source: DispatchSourceFileSystemObject?
    /// What was in the folder already, by name: never listed.
    private var seen: Set<String> = []
    /// Read again shortly after a change: the system writes a screenshot
    /// under a hidden name first and renames it.
    private var pending = false
    /// Where a new one goes; Shared.loot in the app.
    var add: (Keep) -> Void = { Shared.loot.add($0) }

    /// Each start, so one overtaken by a later one does nothing.
    private var generation = 0

    /// Started or stopped with the switch, and at launch.
    func watch(_ on: Bool) {
        stop()
        generation += 1
        guard on else { refused = nil; return }
        let folder: URL
        if Store.testing {
            // A test run never reads the Mac's own folder: only one it was given.
            guard let test = Store.settings.string(forKey: Self.testFolderKey) else { refused = nil; return }
            folder = URL(fileURLWithPath: test, isDirectory: true)
        } else {
            folder = Self.location()
        }
        let started = generation
        // Listing it is what macOS asks about, once, and the asking holds
        // whoever lists until it is answered: not the main thread.
        DispatchQueue.global(qos: .utility).async {
            let names = Self.list(folder)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.generation == started else { return }
                    self.begin(folder, names)
                }
            }
        }
    }

    private func begin(_ folder: URL, _ names: [String]?) {
        self.folder = folder
        guard let names else {
            // Refused, it stays so until allowed in System Settings.
            refused = folder
            return
        }
        refused = nil
        seen = Set(names)
        let handle = open(folder.path, O_EVTONLY)
        guard handle >= 0 else { refused = folder; return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: handle, eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                // The folder itself moved or went: watched again from where
                // the Mac now says screenshots go.
                if !source.data.intersection([.rename, .delete]).isEmpty {
                    self.watch(true)
                    return
                }
                self.changed()
            }
        }
        source.setCancelHandler { close(handle) }
        source.resume()
        self.source = source
    }

    private func stop() {
        source?.cancel()
        source = nil
        folder = nil
        seen = []
        pending = false
    }

    private func changed() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.look() }
        }
    }

    /// The folder listed again: whatever is new, and a screenshot, goes in.
    func look() {
        pending = false
        guard let folder, let names = Self.list(folder) else { return }
        let new = names.filter { !seen.contains($0) }
        seen = Set(names)
        for name in new.sorted() {
            let file = folder.appendingPathComponent(name)
            guard Self.isScreenshot(file) else { continue }
            add(Keep(name: name, from: "Screenshot", path: file.path, date: Date(), address: nil))
        }
    }

    // MARK: - what counts

    /// Where the Mac saves screenshots now: its own setting, the Desktop
    /// without one, or the Desktop again if the setting names nothing there.
    static func location(_ defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.screencapture"),
                         home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        guard let set = defaults?.string(forKey: "location")?.trimmingCharacters(in: .whitespaces), !set.isEmpty
        else { return desktop }
        let path = (set as NSString).expandingTildeInPath
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue
        else { return desktop }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The names in `folder`, hidden ones left out; nil when it can't be read.
    nonisolated private static func list(_ folder: URL) -> [String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        return names.filter { !$0.hasPrefix(".") }
    }

    /// The kinds a screenshot is saved as (⇧⌘5 › Options, or `defaults
    /// write com.apple.screencapture type`).
    static let kinds: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "pdf", "bmp"]

    static func isScreenshot(_ file: URL) -> Bool {
        guard kinds.contains(file.pathExtension.lowercased()) else { return false }
        if let marked = marked(file) { return marked }
        return named(file.lastPathComponent)
    }

    /// The mark the Mac writes on a screenshot, nil for a file without it.
    static func marked(_ file: URL) -> Bool? {
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        let size = getxattr(file.path, name, nil, 0, 0, 0)
        guard size > 0, size < 1024 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(file.path, name, $0.baseAddress, size, 0, 0) }
        guard read == size,
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    /// How the Mac names one in the languages it is most often set to, then
    /// a date: "Screenshot 2026-11-25 at 22.33.22", "Capture d’écran
    /// 2026-11-25 à 22.33.22", and the older "Screen Shot".
    static func named(_ name: String) -> Bool {
        let prefixes = ["Screenshot ", "Screen Shot ", "Capture d’écran ", "Capture d'écran ", "Bildschirmfoto ",
                        "Captura de pantalla ", "Schermafbeelding ", "Istantanea schermo ",
                        "Skärmavbild ", "Skjermbilde ", "Skærmbillede ", "Näyttökuva ", "Zrzut ekranu ",
                        "Captura de Tela ", "Captura de ecrã ", "Снимок экрана ", "スクリーンショット ",
                        "截屏", "螢幕快照", "스크린샷 "]
        guard let prefix = prefixes.first(where: name.hasPrefix) else { return false }
        // A date follows: four digits, a dash.
        let rest = name.dropFirst(prefix.count)
        let digits = rest.prefix(5)
        return digits.count == 5 && digits.prefix(4).allSatisfy(\.isNumber) && digits.last == "-"
    }
}

/// Settings' switch, saying so when macOS keeps the folder from Search.
struct ScreenshotsSwitch: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var screenshots = Screenshots.shared

    var body: some View {
        HStack(spacing: 8) {
            if prefs.screenshotsInDownloads, let folder = screenshots.refused {
                Text("Can't see \(folder.lastPathComponent): allow it in System Settings › Privacy & Security › Files and Folders")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
            Switch(on: $prefs.screenshotsInDownloads)
        }
    }
}
