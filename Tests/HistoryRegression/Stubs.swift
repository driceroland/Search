import Foundation

// The regression runner compiles History.swift outside the app target. These
// small stand-ins keep that compile honest while fixing storage to a fresh
// directory made by run.sh.
protocol ObservableObject {}

final class ChangePublisher {
    func send() {}
}

extension ObservableObject {
    var objectWillChange: ChangePublisher { ChangePublisher() }
}

enum AddressCommand {
    case settings

    var title: String { "Settings" }
}

enum Store {
    private static let testRoot: URL = {
        guard let path = ProcessInfo.processInfo.environment["SEARCH_HISTORY_TEST_ROOT"] else {
            fatalError("Run through Tests/HistoryRegression/run.sh to isolate history storage")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    private(set) static var folder = testRoot

    static func use(_ name: String) {
        folder = testRoot.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            fatalError("Could not prepare isolated history store: \(error)")
        }
    }

    static func file(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    static func quarantine(_ url: URL) {
        try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
    }
}

// History schedules its saves itself. Keep this runner's isolated write
// synchronous so savedFile() can inspect the bytes after that delay.
enum Disk {
    static func write(_ file: URL, now: Bool = false, _ encode: @escaping @Sendable () -> Data?) {
        guard let data = encode() else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
