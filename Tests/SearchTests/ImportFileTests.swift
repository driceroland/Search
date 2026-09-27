import Foundation
import XCTest
import Darwin
@testable import Search

final class ImportFileTests: XCTestCase {
    private static var probeWorld: String?

    override class func setUp() {
        super.setUp()
        let world = "import-tests-\(UUID().uuidString.lowercased())"
        probeWorld = world
        setenv("SEARCH_PROBE", world, 1)
    }

    override class func tearDown() {
        Disk.drain()
        if let probeWorld, Store.world == probeWorld {
            try? FileManager.default.removeItem(at: Store.folder)
            UserDefaults(suiteName: "com.officecommun.search.test.\(probeWorld)")?.removePersistentDomain(forName: "com.officecommun.search.test.\(probeWorld)")
        }
        unsetenv("SEARCH_PROBE")
        super.tearDown()
    }

    func testBookmarksParserKeepsNetscapeFoldersAndDecodedTitles() {
        let html = #"""
        <DL><p>
          <DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks Bar</H3><DL><p>
            <DT><A HREF="https://example.com/?a=1&amp;b=2">A &amp; B</A>
          </DL><p>
          <DT><H3>Folder &amp; one</H3><DL><p>
            <DT><A HREF="https://inside.example/">Nested</A>
          </DL><p>
        </DL>
        """#

        let bookmarks = BookmarksFile.parse(html)
        XCTAssertEqual(bookmarks.map(\.title), ["A & B", "Folder & one"])
        XCTAssertEqual(bookmarks[0].url, "https://example.com/?a=1&b=2")
        XCTAssertEqual(bookmarks[1].children?.map(\.title), ["Nested"])
    }

    func testFolderReadsOnlyRootAndImmediateFilesInLexicographicOrder() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefixFolder = root.appendingPathComponent("a", isDirectory: true)
        let siblingFolder = root.appendingPathComponent("a-branch", isDirectory: true)
        let deepFolder = prefixFolder.appendingPathComponent("deep", isDirectory: true)
        let hiddenFolder = root.appendingPathComponent(".hidden", isDirectory: true)
        let outside = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: prefixFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deepFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenFolder, withIntermediateDirectories: true)

        try writeBookmark("Root", url: "https://root.example/", to: root.appendingPathComponent("a.html"))
        try writeBookmark("Inside", url: "https://inside.example/", to: prefixFolder.appendingPathComponent("inside.html"))
        try writeBookmark("Sibling", url: "https://sibling.example/", to: siblingFolder.appendingPathComponent("inside.html"))
        try writeBookmark("Deep", url: "https://deep.example/", to: deepFolder.appendingPathComponent("too-deep.html"))
        try writeBookmark("Hidden", url: "https://hidden.example/", to: root.appendingPathComponent(".hidden.html"))
        try writeBookmark("Hidden folder", url: "https://hidden-folder.example/", to: hiddenFolder.appendingPathComponent("hidden.html"))
        let unreadable = root.appendingPathComponent("unreadable.csv")
        try "unreadable fixture".write(to: unreadable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        let canReadUnreadable: Bool
        do {
            let handle = try FileHandle(forReadingFrom: unreadable)
            _ = try handle.read(upToCount: 1)
            try handle.close()
            canReadUnreadable = true
        } catch {
            canReadUnreadable = false
        }
        let outsideFile = outside.appendingPathComponent("outside.html")
        try writeBookmark("Symlink", url: "https://outside.example/", to: outsideFile)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.html"), withDestinationURL: outsideFile)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-folder", isDirectory: true), withDestinationURL: outside)

        let first = try ImportFile.read(root)
        let second = try ImportFile.read(root)
        let expected = ["Sibling", "Root", "Inside"]
        XCTAssertEqual(first.bookmarks.map(\.title), expected)
        XCTAssertEqual(second.bookmarks.map(\.title), expected)
        if !canReadUnreadable {
            XCTAssertTrue(first.passwords.isEmpty, "an unreadable folder member must not discard the valid bookmarks or become a password file")
        }
    }

    func testProgressResetsForNewStagesAndThrottlesRepeatedUpdates() {
        let lock = NSLock()
        var updates: [ImportFile.Progress] = []
        let control = ImportFile.Control { update in
            lock.lock()
            updates.append(update)
            lock.unlock()
        }

        let started = ProcessInfo.processInfo.systemUptime
        control.report(.init(message: "Reading file", completed: 0, total: 100_000))
        for count in 1...10_000 {
            control.report(.init(message: "Reading file", completed: count, total: 100_000))
        }
        Thread.sleep(forTimeInterval: 0.12)
        control.report(.init(message: "Saving passwords", completed: 0, total: 3))
        Thread.sleep(forTimeInterval: 0.12)
        control.report(.init(message: "Saving passwords", completed: 3, total: 3))

        lock.lock()
        let captured = updates
        lock.unlock()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThanOrEqual(captured.count, Int(elapsed / 0.1) + 1)
        XCTAssertEqual(captured.first?.completed, 0)
        let savingStage = captured.first { $0.message == "Saving passwords" }
        XCTAssertEqual(savingStage?.completed, 0, "a new phase should reset its displayed count")
        XCTAssertEqual(captured.last?.completed, 3)
        XCTAssertEqual(captured.last?.total, 3)
    }

    func testProgressThrottleBoundsRapidDistinctFileMessages() {
        let lock = NSLock()
        var updates: [ImportFile.Progress] = []
        let control = ImportFile.Control { update in
            lock.lock()
            updates.append(update)
            lock.unlock()
        }

        let started = ProcessInfo.processInfo.systemUptime
        control.report(.init(message: "Folder: Scanning", completed: 0))
        for index in 1...5_000 {
            control.report(.init(message: "file-\(index): File complete", completed: 1))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        lock.lock()
        let count = updates.count
        lock.unlock()

        XCTAssertLessThanOrEqual(count, Int(elapsed / 0.1) + 1, "filename and finished-file changes must share the global throttle")
    }

    func testHTMLParserProgressCanCancelDuringRegexEnumeration() throws {
        let html = "<DL>" + (0..<2_000).map { index in
            #"<DT><A HREF="https://example.com/\#(index)">Bookmark \#(index)</A>"#
        }.joined() + "</DL>"
        let control = ImportFile.Control()
        var progressThrough = 0
        XCTAssertThrowsError(try BookmarksFile.parse(html, control: control, progress: { stage, completed, _ in
            if stage == "Parsing bookmarks" {
                progressThrough = completed
                if completed > 1_000 { control.cancel() }
            }
        })) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertGreaterThan(progressThrough, 1_000)
        XCTAssertLessThan(progressThrough, (html as NSString).length)
    }

    func testPasswordCSVPrecancelAndProgressNeverContainsItsContents() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("passwords.csv")
        let secret = "private-test-password-91c"
        let csv = "url,username,password\nhttps://example.com,alice,\(secret)\n"
        try csv.write(to: file, atomically: true, encoding: .utf8)
        let cancelled = ImportFile.Control()
        cancelled.cancel()
        XCTAssertThrowsError(try ImportFile.read(file, control: cancelled)) { error in
            XCTAssertTrue(error is CancellationError)
        }

        var updates: [ImportFile.Progress] = []
        let control = ImportFile.Control { updates.append($0) }
        let imported = try ImportFile.read(file, control: control)
        XCTAssertEqual(imported.passwords, [csv])
        XCTAssertTrue(updates.contains { $0.message == "passwords.csv: Reading CSV" })
        XCTAssertTrue(updates.allSatisfy { !$0.message.contains(secret) })
        XCTAssertTrue(updates.contains { $0.total != nil })

        updates.removeAll()
        let safeToSkip = "url,username,password\n,alice,\(secret)\n"
        let vaultControl = ImportFile.Control { updates.append($0) }
        let result = Vault.take(csv: safeToSkip, control: vaultControl)
        XCTAssertEqual(result.kept, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(updates.contains { $0.message == "Reading password CSV…" })
        XCTAssertTrue(updates.allSatisfy { !$0.message.contains(secret) })
    }

    @MainActor
    func testBookmarkMergeKeepsAConcurrentEditAndDeduplicates() async throws {
        let bookmarks = Bookmarks()
        let existingURL = URL(string: "https://already.example/")!
        _ = bookmarks.take([Bookmark.site("Already here", existingURL)], from: "Other")
        let incoming = [Bookmark.site("Duplicate", existingURL)] + (0..<20_000).map { index in
            Bookmark.site("Imported \(index)", URL(string: "https://imported-\(index).example/")!)
        }
        let started = expectation(description: "merge captured its snapshot")
        let task = Task { @MainActor in
            started.fulfill()
            return try await bookmarks.takeFile(incoming, from: "Other", control: ImportFile.Control())
        }
        await fulfillment(of: [started], timeout: 5)
        let concurrentURL = URL(string: "https://concurrent.example/")!
        _ = bookmarks.add(concurrentURL, title: "Concurrent edit")

        let result = try await task.value

        XCTAssertEqual(result.already, 1)
        XCTAssertEqual(result.added, 20_000)
        XCTAssertTrue(Bookmarks.urls(bookmarks.roots).contains(concurrentURL))
        XCTAssertEqual(Bookmarks.count(bookmarks.roots), 20_002)
    }

    func testZIPReadCleansExtractionAndOnlyZIPHistoryMarksSafari() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let export = root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try writeBookmark("From zip", url: "https://zip.example/", to: export.appendingPathComponent("bookmarks.html"))
        let history: [String: Any] = [
            "metadata": ["data_type": "history"],
            "history": [["url": "https://history.example/", "title": "History", "time_usec": 1_000_000, "visits_count": 1]],
        ]
        let historyData = try JSONSerialization.data(withJSONObject: history)
        try historyData.write(to: export.appendingPathComponent("history.json"))

        let archive = root.appendingPathComponent("export.zip")
        try runDitto(arguments: ["-c", "-k", "--sequesterRsrc", export.path, archive.path])
        let tempBefore = officeImportFolders()
        let preCancelled = ImportFile.Control()
        preCancelled.cancel()
        XCTAssertThrowsError(try ImportFile.read(archive, control: preCancelled)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(officeImportFolders(), tempBefore)
        let found = try ImportFile.read(archive)
        XCTAssertEqual(found.bookmarks.map(\.title), ["From zip"])
        XCTAssertEqual(found.places.count, 1)
        XCTAssertTrue(found.fromSafari)
        XCTAssertEqual(officeImportFolders(), tempBefore)

        let ordinary = root.appendingPathComponent("ordinary", isDirectory: true)
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)
        try historyData.write(to: ordinary.appendingPathComponent("history.json"))
        XCTAssertFalse(try ImportFile.read(ordinary).fromSafari)

        let invalidArchive = root.appendingPathComponent("broken.zip")
        try Data("not a zip".utf8).write(to: invalidArchive)
        XCTAssertTrue(try ImportFile.read(invalidArchive).isEmpty)
        XCTAssertEqual(officeImportFolders(), tempBefore)
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("search-import-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeBookmark(_ title: String, url: String, to file: URL) throws {
    let html = #"<DL><DT><A HREF="\#(url)">\#(title)</A></DL>"#
    try html.write(to: file, atomically: true, encoding: .utf8)
}

private func runDitto(arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
}

private func officeImportFolders() -> Set<String> {
    let items = (try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
    return Set(items.filter { $0.lastPathComponent.hasPrefix("office-import-") }.map(\.lastPathComponent))
}
