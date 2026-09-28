import Foundation
import XCTest
import Darwin
import AppKit
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
        let existing = Bookmark.site("Already here", existingURL)
        _ = bookmarks.take([existing], from: "Other")
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
        _ = bookmarks.withdraw([existing.id] + incoming.map(\.id))
        Disk.drain()
    }

    @MainActor
    func testReplaceWithReadableEmptyProfileRemovesOnlyThatSourcesBookmarks() throws {
        let browser = makeImportTestBrowser()
        let bookmarks = browser.bookmarks
        let previousTop = Store.settings.string(forKey: "bookmarks.top")
        let previousRecords = Store.settings.data(forKey: "import.records")
        let (source, root) = try makeChromiumSource(name: "Replace Empty \(UUID().uuidString)")
        defer {
            if let record = ImportRecords.of(source.name) { _ = bookmarks.withdraw(record.bookmarkIDs) }
            try? FileManager.default.removeItem(at: root)
            if let previousTop { Store.settings.set(previousTop, forKey: "bookmarks.top") }
            else { Store.settings.removeObject(forKey: "bookmarks.top") }
            if let previousRecords { Store.settings.set(previousRecords, forKey: "import.records") }
            else { Store.settings.removeObject(forKey: "import.records") }
            Disk.drain()
        }

        let profile = try makeProfile("Default", under: root)
        let sourceURL = "https://replace-source.example/"
        try writeChromiumBookmarks([chromiumURL("From source", sourceURL)], to: profile)
        let first = browser.takeBookmarks(from: .chromium(source))
        XCTAssertEqual(first.added, 1)
        XCTAssertFalse(first.kept)
        let priorRecord = try XCTUnwrap(ImportRecords.of(source.name))
        XCTAssertEqual(priorRecord.bookmarks, 1)
        XCTAssertEqual(Bookmarks.urls(bookmarks.roots).map(\.absoluteString).filter { $0 == sourceURL }.count, 1)

        let manualURL = URL(string: "https://manual-bookmark.example/")!
        let manual = try XCTUnwrap(bookmarks.add(manualURL, title: "Manual"))
        defer { _ = bookmarks.withdraw([manual.id]) }
        let otherSource = try makeChromiumSource(name: "Other Browser \(UUID().uuidString)")
        defer {
            if let record = ImportRecords.of(otherSource.0.name) { _ = bookmarks.withdraw(record.bookmarkIDs) }
            try? FileManager.default.removeItem(at: otherSource.1)
        }
        let otherProfile = try makeProfile("Default", under: otherSource.1)
        let otherURL = "https://other-browser.example/"
        try writeChromiumBookmarks([chromiumURL("Other browser", otherURL)], to: otherProfile)
        XCTAssertEqual(browser.takeBookmarks(from: .chromium(otherSource.0)).added, 1)
        let otherRecordBefore = try XCTUnwrap(ImportRecords.of(otherSource.0.name))

        try writeChromiumBookmarks([], to: profile)
        let replacement = browser.takeBookmarks(from: .chromium(source), replacing: true)

        XCTAssertEqual(replacement.added, 0)
        XCTAssertEqual(replacement.already, 0)
        XCTAssertFalse(replacement.kept)
        let urls = Set(Bookmarks.urls(bookmarks.roots).map(\.absoluteString))
        XCTAssertFalse(urls.contains(sourceURL), "a clean empty profile replaces its earlier import with nothing")
        XCTAssertTrue(urls.contains(manualURL.absoluteString), "manual bookmarks must survive source replacement")
        XCTAssertTrue(urls.contains(otherURL), "bookmarks from another browser must survive source replacement")
        let sourceRecord = try XCTUnwrap(ImportRecords.of(source.name))
        XCTAssertEqual(sourceRecord.bookmarks, 0)
        XCTAssertTrue(sourceRecord.bookmarkIDs.isEmpty)
        XCTAssertEqual(ImportRecords.of(otherSource.0.name)?.bookmarkIDs, otherRecordBefore.bookmarkIDs)
    }

    @MainActor
    func testReplaceWithMissingOrMalformedProfilePreservesEarlierImportAndProvenance() throws {
        let browser = makeImportTestBrowser()
        let bookmarks = browser.bookmarks
        let previousTop = Store.settings.string(forKey: "bookmarks.top")
        let previousRecords = Store.settings.data(forKey: "import.records")
        let (source, root) = try makeChromiumSource(name: "Replace Partial \(UUID().uuidString)")
        defer {
            if let record = ImportRecords.of(source.name) { _ = bookmarks.withdraw(record.bookmarkIDs) }
            try? FileManager.default.removeItem(at: root)
            if let previousTop { Store.settings.set(previousTop, forKey: "bookmarks.top") }
            else { Store.settings.removeObject(forKey: "bookmarks.top") }
            if let previousRecords { Store.settings.set(previousRecords, forKey: "import.records") }
            else { Store.settings.removeObject(forKey: "import.records") }
            Disk.drain()
        }

        let usual = try makeProfile("Default", under: root)
        let broken = try makeProfile("Profile 1", under: root)
        let originalURL = "https://original-profile.example/"
        try writeChromiumBookmarks([chromiumURL("Original", originalURL)], to: usual)
        XCTAssertEqual(browser.takeBookmarks(from: .chromium(source), profile: "Default").added, 1)
        let originalRecord = try XCTUnwrap(ImportRecords.of(source.name))

        let missing = browser.takeBookmarks(from: .chromium(source), profile: "Missing profile", replacing: true)
        XCTAssertTrue(missing.kept)
        XCTAssertTrue(Bookmarks.urls(bookmarks.roots).map(\.absoluteString).contains(originalURL))
        let afterMissing = try XCTUnwrap(ImportRecords.of(source.name))
        XCTAssertEqual(afterMissing.bookmarks, originalRecord.bookmarks)
        XCTAssertEqual(afterMissing.bookmarkIDs, originalRecord.bookmarkIDs)

        let readableURL = "https://readable-profile.example/"
        try writeChromiumBookmarks([chromiumURL("Updated", readableURL)], to: usual)
        try Data("malformed profile bookmarks".utf8).write(to: broken.appendingPathComponent("Bookmarks"))
        let partial = browser.takeBookmarks(from: .chromium(source), replacing: true)

        XCTAssertTrue(partial.kept, "a malformed profile means the set was not completely read")
        let urls = Set(Bookmarks.urls(bookmarks.roots).map(\.absoluteString))
        XCTAssertTrue(urls.contains(originalURL), "unreadable replacement must preserve prior source bookmarks")
        XCTAssertTrue(urls.contains(readableURL), "readable profiles still contribute their current bookmarks")
        let afterMalformed = try XCTUnwrap(ImportRecords.of(source.name))
        XCTAssertEqual(afterMalformed.bookmarks, 2)
        XCTAssertTrue(originalRecord.bookmarkIDs.allSatisfy(afterMalformed.bookmarkIDs.contains), "prior source provenance must remain attached")
    }

    @MainActor
    func testAsyncFileMergeOverlappingEmptyReplaceKeepsFileAndReplacementState() async throws {
        let browser = makeImportTestBrowser()
        let bookmarks = browser.bookmarks
        let previousTop = Store.settings.string(forKey: "bookmarks.top")
        let previousRecords = Store.settings.data(forKey: "import.records")
        let (source, root) = try makeChromiumSource(name: "Replace During File \(UUID().uuidString)")
        let fileName = "Concurrent File \(UUID().uuidString)"
        let manualURL = URL(string: "https://manual-during-file-merge.example/")!
        let manual = try XCTUnwrap(bookmarks.add(manualURL, title: "Manual"))
        let fileBookmarks = (0..<10_000).map { index in
            Bookmark.site("File bookmark \(index)", URL(string: "https://file-\(index).example/")!)
        }
        defer {
            if let record = ImportRecords.of(source.name) { _ = bookmarks.withdraw(record.bookmarkIDs) }
            try? FileManager.default.removeItem(at: root)
            _ = bookmarks.withdraw([manual.id])
            _ = bookmarks.withdraw(fileBookmarks.map(\.id))
            if let folder = bookmarks.roots.first(where: { $0.isFolder && $0.title == fileName }) { _ = bookmarks.withdraw([folder.id]) }
            if let previousTop { Store.settings.set(previousTop, forKey: "bookmarks.top") }
            else { Store.settings.removeObject(forKey: "bookmarks.top") }
            if let previousRecords { Store.settings.set(previousRecords, forKey: "import.records") }
            else { Store.settings.removeObject(forKey: "import.records") }
            Disk.drain()
        }

        let profile = try makeProfile("Default", under: root)
        let sourceURL = "https://to-be-replaced.example/"
        try writeChromiumBookmarks([chromiumURL("Old source bookmark", sourceURL)], to: profile)
        XCTAssertEqual(browser.takeBookmarks(from: .chromium(source)).added, 1)
        try writeChromiumBookmarks([], to: profile)

        let started = expectation(description: "file merge started preparing its snapshot")
        let merge = Task { @MainActor in
            started.fulfill()
            return try await bookmarks.takeFile(fileBookmarks, from: fileName, control: ImportFile.Control())
        }
        await fulfillment(of: [started], timeout: 5)
        let replacement = browser.takeBookmarks(from: .chromium(source), replacing: true)
        let merged = try await merge.value

        XCTAssertFalse(replacement.kept)
        XCTAssertEqual(merged.added, fileBookmarks.count)
        let urls = Set(Bookmarks.urls(bookmarks.roots).map(\.absoluteString))
        XCTAssertFalse(urls.contains(sourceURL), "a prepared async merge must not resurrect a source bookmark removed by Replace")
        XCTAssertTrue(urls.contains(manualURL.absoluteString))
        XCTAssertTrue(urls.contains("https://file-0.example/"))
        XCTAssertTrue(urls.contains("https://file-9999.example/"))
        XCTAssertEqual(urls.intersection(Set(fileBookmarks.compactMap(\.url))).count, fileBookmarks.count)
        let sourceRecord = try XCTUnwrap(ImportRecords.of(source.name))
        XCTAssertTrue(sourceRecord.bookmarkIDs.isEmpty, "the file import must not acquire the replaced browser's provenance")
    }

    @MainActor
    func testArcImportKeepsSpacesFoldersPinsAndImportRecordCounts() throws {
        let browser = makeImportTestBrowser()
        let previousRecords = Store.settings.data(forKey: "import.records")
        let previousUsesSpaces = browser.prefs.usesSpaces
        let previousUsesTabGroups = browser.prefs.usesTabGroups
        let previousSpaces = browser.spaces
        let suffix = UUID().uuidString
        let workName = "Arc Engineering \(suffix)"
        let personalName = "Arc Personal \(suffix)"
        let oldArcFolder = Arc.file.deletingLastPathComponent()
        let oldArcFolderExisted = FileManager.default.fileExists(atPath: oldArcFolder.path)
        let oldArcFile = try? Data(contentsOf: Arc.file)
        try FileManager.default.createDirectory(at: oldArcFolder, withIntermediateDirectories: true)
        defer {
            for space in browser.spaces where space.name == workName || space.name == personalName {
                Pins.forget(space.id)
                Session.erase(space: space.id)
            }
            browser.spaces = previousSpaces
            Spaces.write(previousSpaces)
            browser.prefs.usesSpaces = previousUsesSpaces
            browser.prefs.usesTabGroups = previousUsesTabGroups
            if let oldArcFile { try? oldArcFile.write(to: Arc.file, options: .atomic) }
            else {
                try? FileManager.default.removeItem(at: Arc.file)
                if !oldArcFolderExisted { try? FileManager.default.removeItem(at: oldArcFolder) }
            }
            if let previousRecords { Store.settings.set(previousRecords, forKey: "import.records") }
            else { Store.settings.removeObject(forKey: "import.records") }
            Disk.drain()
        }

        let source = ImportSource.chromium(Chromium.Source(
            name: "Arc", folder: "Arc/User Data", service: "Arc Safe Storage", account: "Arc", app: "Arc.app"))
        let sidebar = try makeArcSidebarFixture(workName: workName, personalName: personalName)
        try sidebar.write(to: Arc.file, options: .atomic)
        browser.prefs.usesSpaces = false
        browser.prefs.usesTabGroups = true

        let imported = try XCTUnwrap(source.arcSidebar(profile: nil))
        XCTAssertEqual(source.arcCounts(profile: nil)?.spaces, 2)
        XCTAssertEqual(source.arcCounts(profile: nil)?.pinned, 5)
        XCTAssertEqual(imported.spaces.map(\.name), [workName, personalName])
        XCTAssertEqual(imported.spaces[0].pinned.count, 1, "Arc folders remain folders until Search places their tabs in a group")
        if case .folder(let folder) = imported.spaces[0].pinned[0] {
            XCTAssertEqual(folder.title, "Research")
            XCTAssertEqual(Arc.count([imported.spaces[0].pinned[0]]), 2)
        } else {
            XCTFail("Arc's pinned folder was flattened while reading the sidebar")
        }

        let result = browser.takeArc(imported)
        ImportRecords.note(source.name, spaces: result.spaces, pinned: result.pins + result.tabs)
        XCTAssertEqual(result.spaces, 2)
        XCTAssertEqual(result.pins, 2, "each space gets the favourites from its own profile")
        XCTAssertEqual(result.tabs, 3, "pinned tabs from nested folders are restored asleep")

        let again = browser.takeArc(imported)
        XCTAssertEqual(again.spaces, 0)
        XCTAssertEqual(again.pins, 0)
        XCTAssertEqual(again.tabs, 0)

        let work = try XCTUnwrap(browser.spaces.first { $0.name == workName })
        let personal = try XCTUnwrap(browser.spaces.first { $0.name == personalName })
        XCTAssertEqual(work.sharesSignIns, true)
        XCTAssertEqual(personal.sharesSignIns, false)
        XCTAssertEqual(Pins.defs(work.id).map(\.home), ["https://favorite-work.example/"])
        XCTAssertEqual(Pins.defs(personal.id).map(\.home), ["https://favorite-personal.example/"])
        let workSession = browser.readRow(work.id)
        XCTAssertEqual(workSession.tabs.map(\.url), ["https://work-one.example/", "https://work-two.example/"])
        let research = try XCTUnwrap(workSession.groups?.first { $0.name == "Research" })
        XCTAssertEqual(workSession.tabs.map(\.groupID), [research.id, research.id])
        XCTAssertEqual(browser.readRow(personal.id).tabs.map(\.url), ["https://personal.example/"])
        let record = try XCTUnwrap(ImportRecords.of(source.name))
        XCTAssertEqual(record.spaces, 2)
        XCTAssertEqual(record.pinned, 5)
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

@MainActor
private func makeImportTestBrowser() -> Browser {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    return Browser(record: WindowRecord())
}

private func makeChromiumSource(name: String) throws -> (Chromium.Source, URL) {
    let folder = "SearchTests/\(UUID().uuidString)"
    let root = Chromium.base.appendingPathComponent(folder, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (Chromium.Source(name: name, folder: folder, service: "Test Safe Storage", account: "Test", app: "Test.app"), root)
}

private func makeProfile(_ name: String, under root: URL) throws -> URL {
    let profile = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    return profile
}

private func chromiumURL(_ title: String, _ url: String) -> [String: Any] {
    ["type": "url", "name": title, "url": url]
}

private func writeChromiumBookmarks(_ entries: [[String: Any]], to profile: URL) throws {
    let bar: [String: Any] = ["children": entries]
    let other: [String: Any] = ["children": [] as [[String: Any]]]
    let synced: [String: Any] = ["children": [] as [[String: Any]]]
    let roots: [String: Any] = ["bookmark_bar": bar, "other": other, "synced": synced]
    let data = try JSONSerialization.data(withJSONObject: ["roots": roots])
    try data.write(to: profile.appendingPathComponent("Bookmarks"), options: .atomic)
}

private func makeArcSidebarFixture(workName: String, personalName: String) throws -> Data {
    func tab(_ id: String, _ title: String, _ url: String) -> [String: Any] {
        ["id": id, "title": title, "data": ["tab": ["savedURL": url, "savedTitle": title]]]
    }

    let items: [[String: Any]] = [
        ["id": "work-pins", "childrenIds": ["work-folder"]],
        ["id": "work-folder", "title": "Research", "data": ["list": [String: Any]()], "childrenIds": ["work-one", "work-two"]],
        tab("work-one", "One", "https://work-one.example/"),
        tab("work-two", "Two", "https://work-two.example/"),
        ["id": "personal-pins", "childrenIds": ["personal-tab"]],
        tab("personal-tab", "Personal page", "https://personal.example/"),
        ["id": "default-favorites", "childrenIds": ["favorite-work"]],
        tab("favorite-work", "Work favourite", "https://favorite-work.example/"),
        ["id": "profile-favorites", "childrenIds": ["favorite-personal"]],
        tab("favorite-personal", "Personal favourite", "https://favorite-personal.example/"),
    ]
    let profileOne: [String: Any] = ["custom": ["_0": ["directoryBasename": "Profile 1"]]]
    let spaces: [[String: Any]] = [
        ["title": workName, "profile": ["default": [String: Any]()],
         "customInfo": ["iconType": ["emoji_v2": "💻"]], "newContainerIDs": ["pinned", "work-pins"]],
        ["title": personalName, "profile": profileOne, "newContainerIDs": ["pinned", "personal-pins"]],
    ]
    let main: [String: Any] = [
        "items": items,
        "spaces": spaces,
        "topAppsContainerIDs": [["default": [String: Any]()], "default-favorites", profileOne, "profile-favorites"],
    ]
    return try JSONSerialization.data(withJSONObject: ["sidebar": ["containers": [main]]])
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
