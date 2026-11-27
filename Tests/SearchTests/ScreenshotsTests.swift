import XCTest
@testable import Search

/// The Mac's screenshots in Downloads (Screenshots.swift): which files count,
/// where the Mac saves them, and only new ones listed.
@available(macOS 14, *)
@MainActor
final class ScreenshotsTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    func testNamedAsTheMacNamesThem() {
        for name in ["Screenshot 2026-11-25 at 22.33.22.png", "Capture d’écran 2026-11-25 à 22.33.22.png",
                     "Screen Shot 2019-01-02 at 10.00.00.png", "Bildschirmfoto 2026-11-25 um 22.33.22.png",
                     "截屏2026-11-25 22.33.22.png"] {
            XCTAssertTrue(Screenshots.named(name), name)
        }
        for name in ["Screenshot.png", "Screenshots of the app.png", "holiday.png", "Screenshot tips 2026.png"] {
            XCTAssertFalse(Screenshots.named(name), name)
        }
    }

    func testMarkOrNameAndKind() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        // Marked by the Mac, whatever its name.
        let marked = folder.appendingPathComponent("anything.png")
        try Data([0x89]).write(to: marked)
        try mark(marked, true)
        XCTAssertEqual(Screenshots.marked(marked), true)
        XCTAssertTrue(Screenshots.isScreenshot(marked))

        // Marked as not one, even named like one.
        let notOne = folder.appendingPathComponent("Screenshot 2026-11-25 at 22.33.22.png")
        try Data([0x89]).write(to: notOne)
        try mark(notOne, false)
        XCTAssertFalse(Screenshots.isScreenshot(notOne))

        // No mark: the name decides.
        let named = folder.appendingPathComponent("Screenshot 2026-11-25 at 22.40.00.png")
        try Data([0x89]).write(to: named)
        XCTAssertNil(Screenshots.marked(named))
        XCTAssertTrue(Screenshots.isScreenshot(named))

        // A recording, or another kind, isn't listed.
        let movie = folder.appendingPathComponent("Screenshot 2026-11-25 at 22.40.00.mov")
        try Data([0]).write(to: movie)
        XCTAssertFalse(Screenshots.isScreenshot(movie))
    }

    func testLocation() throws {
        let home = URL(fileURLWithPath: "/Users/nobody-here", isDirectory: true)
        let suite = "screenshots.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let saved = Store.settings.object(forKey: Screenshots.testFolderKey)
        Store.settings.removeObject(forKey: Screenshots.testFolderKey)
        defer { if let saved { Store.settings.set(saved, forKey: Screenshots.testFolderKey) } }

        XCTAssertEqual(Screenshots.location(defaults, home: home).path, "/Users/nobody-here/Desktop")
        // Moved to a folder that is there.
        let there = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: there, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: there) }
        defaults.set(there.path, forKey: "location")
        XCTAssertEqual(Screenshots.location(defaults, home: home).standardizedFileURL.path, there.standardizedFileURL.path)
        // Moved to a folder gone since: the Desktop, as the Mac falls back to.
        defaults.set("/no/such/folder", forKey: "location")
        XCTAssertEqual(Screenshots.location(defaults, home: home).path, "/Users/nobody-here/Desktop")
    }

    func testOnlyNewScreenshotsListed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try Data([1]).write(to: folder.appendingPathComponent("Screenshot 2026-11-25 at 09.00.00.png"))

        let saved = Store.settings.object(forKey: Screenshots.testFolderKey)
        Store.settings.set(folder.path, forKey: Screenshots.testFolderKey)
        defer {
            if let saved { Store.settings.set(saved, forKey: Screenshots.testFolderKey) }
            else { Store.settings.removeObject(forKey: Screenshots.testFolderKey) }
        }

        let shots = Screenshots()
        var added: [Keep] = []
        shots.add = { added.append($0) }
        shots.watch(true)
        let ready = expectation(description: "watching")
        func until(_ done: @escaping () -> Bool, _ then: XCTestExpectation) {
            if done() { then.fulfill(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { until(done, then) } }
        }
        until({ shots.folder != nil }, ready)
        wait(for: [ready], timeout: 5)
        XCTAssertNil(shots.refused)

        try Data([2]).write(to: folder.appendingPathComponent("Screenshot 2026-11-25 at 09.05.00.png"))
        try Data([3]).write(to: folder.appendingPathComponent("notes.txt"))
        try Data([4]).write(to: folder.appendingPathComponent(".Screenshot 2026-11-25 at 09.06.00.png"))
        let came = expectation(description: "listed")
        until({ !added.isEmpty }, came)
        wait(for: [came], timeout: 5)
        // A moment more for anything that shouldn't come.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(added.map(\.name), ["Screenshot 2026-11-25 at 09.05.00.png"])
        XCTAssertEqual(added.first?.from, "Screenshot")
        XCTAssertNotNil(added.first?.dragged)

        // Off: nothing more.
        shots.watch(false)
        try Data([5]).write(to: folder.appendingPathComponent("Screenshot 2026-11-25 at 09.10.00.png"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(added.count, 1)
    }

    private func mark(_ file: URL, _ on: Bool) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: on, format: .binary, options: 0)
        let result = data.withUnsafeBytes {
            setxattr(file.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, data.count, 0, 0)
        }
        XCTAssertEqual(result, 0)
    }
}
