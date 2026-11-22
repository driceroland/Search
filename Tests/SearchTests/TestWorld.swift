import Foundation
import XCTest
@testable import Search

/// The unit tests' world: one for the whole run, in a temporary folder, and
/// gone when the run ends.
///
/// Store.world and Store.folder are read once, so every test of a run lives
/// in whichever world was asked for first — the run is one world however
/// many test classes name their own. It used to be a folder under
/// ~/Library/Application Support, "Search (<first class>-<pid>)", left
/// behind by every run. And since no test brings back last launch's windows,
/// the run never left "launching": each Browsers.save() wrote the windows
/// open and then everything already in windows.json again (see
/// Browsers.save), so the file doubled up from save to save — 42,970 records
/// of 19 windows, 8 MB rewritten on every change, a test that takes 2 s
/// alone taking 30 min, and every other write behind it on the Disk queue
/// late enough to fail tests that read a file back.
///
/// Every test class that needs the world calls `TestWorld.enter()` in its
/// class setUp, in place of setting SEARCH_PROBE itself.
enum TestWorld {
    /// Where the run's home is: Store.folder is under it. In /tmp rather
    /// than the per-user temporary folder, whose long path would put the
    /// agent socket (Agent/agent.sock in Store.folder) past the 104 bytes a
    /// Unix socket's path can have.
    static let home = URL(fileURLWithPath: "/tmp/search-unit-\(getpid())", isDirectory: true)
    nonisolated(unsafe) private static var entered = false

    static func enter() {
        guard !entered else { return }
        entered = true
        // Before anything reads Store: its folder is under this home, never
        // the person's own Library.
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("CFFIXED_USER_HOME", home.path, 1)
        setenv("SEARCH_PROBE", "unit-\(getpid())", 1)
        precondition(Store.testing && Store.folder.resolvingSymlinksInPath().path
                        .hasPrefix(home.resolvingSymlinksInPath().path + "/"),
                     "the unit tests' world must be in \(home.path), not \(Store.folder.path)")
        MainActor.assumeIsolated {
            // A clean windows.json, and last launch's windows brought back —
            // none — so saving writes the windows open and nothing more.
            try? FileManager.default.removeItem(at: Store.file("windows.json"))
            Browsers.restoreOnce()
        }
        XCTestObservationCenter.shared.addTestObserver(Cleanup.shared)
    }

    /// The world removed once the run is over: its folder, and its settings,
    /// which macOS keeps in ~/Library/Preferences whatever the home.
    private final class Cleanup: NSObject, XCTestObservation {
        static let shared = Cleanup()

        func testBundleDidFinish(_ testBundle: Bundle) {
            Disk.drain()
            try? FileManager.default.removeItem(at: home)
            if let world = Store.world {
                let suite = "com.officecommun.search.test.\(world)"
                UserDefaults.standard.removePersistentDomain(forName: suite)
                CFPreferencesAppSynchronize(suite as CFString)
                // The emptied file too, from the real home: this run's own.
                if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
                    let plist = URL(fileURLWithPath: String(cString: dir))
                        .appendingPathComponent("Library/Preferences/\(suite).plist")
                    try? FileManager.default.removeItem(at: plist)
                }
            }
        }
    }
}
