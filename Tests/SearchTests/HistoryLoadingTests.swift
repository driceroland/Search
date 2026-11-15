import Foundation
import XCTest
@testable import Search

@MainActor
final class HistoryLoadingTests: XCTestCase {
    private func fixture() throws -> (String, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent(".build/history-load-\(UUID().uuidString).json")
        let from = Store.folder.standardizedFileURL.pathComponents
        let to = file.standardizedFileURL.pathComponents
        let common = zip(from, to).prefix { $0 == $1 }.count
        let name = (Array(repeating: "..", count: from.count - common) + to.dropFirst(common)).joined(separator: "/")
        let rows: [[String: Any]] = (0..<2_000).map { i in
            let url = "https://site\(i).example/article/\(i)"
            return ["url": url, "key": url, "title": "Page \(i) " + String(repeating: "x", count: 350),
                    "count": 1, "last": Date().timeIntervalSinceReferenceDate]
        }
        try JSONSerialization.data(withJSONObject: rows).write(to: file)
        return (name, file)
    }

    func testInitReturnsBeforeLoadingAndKeepsAnEarlyVisit() async throws {
        let (name, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }
        let history = History(file: name)
        XCTAssertTrue(history.everything().isEmpty, "History.init should not wait for disk loading")
        let early = try XCTUnwrap(URL(string: "https://early.example/"))
        history.record(early, title: "Early")
        for _ in 0..<2_000 {
            if history.everything(matching: "site1999.example").count == 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(history.everything(matching: "site1999.example").count, 1)
        XCTAssertEqual(history.everything(matching: "early.example").count, 1)
        XCTAssertTrue(history.suggestions(for: "site1999.example").contains { $0.url.host() == "site1999.example" })
        XCTAssertTrue(history.suggestions(for: "early.example").contains { $0.url == early })
        history.flush()
    }

    func testHistoryInitTiming() throws {
        let (name, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }
        var times: [Double] = []
        for _ in 0..<7 {
            let start = Date()
            let history = History(file: name)
            times.append(Date().timeIntervalSince(start) * 1_000)
            history.flush()
        }
        print("History.init ms: \(times), median \(times.sorted()[times.count / 2])")
    }

    func testEarlyChangesWaitForTheFileAndReplayInOrder() async throws {
        let (name, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }
        let original = try Data(contentsOf: file)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let history = History(file: name, read: { url in
            gate.wait()
            return try? Data(contentsOf: url)
        })
        let visited = try XCTUnwrap(URL(string: "https://site0.example/article/0"))
        let imported = try XCTUnwrap(URL(string: "https://site1.example/article/1"))
        let renamed = try XCTUnwrap(URL(string: "https://site2.example/article/2"))
        let forgotten = try XCTUnwrap(URL(string: "https://site3.example/article/3"))
        let early = try XCTUnwrap(URL(string: "https://early.example/"))
        history.record(visited, title: "Again")
        history.take(imported, title: "Imported", count: 30, last: Date())
        history.retitle(renamed, "Renamed")
        history.forget(History.identity(for: forgotten))
        history.record(early, title: "Early")
        history.settle()

        // Let the normal delayed write fire while the read is held back.
        try await Task.sleep(nanoseconds: 1_800_000_000)
        XCTAssertEqual(try Data(contentsOf: file), original)
        gate.signal()
        history.flush()
        let rows = history.everything()
        XCTAssertEqual(rows.first { $0.url == visited }?.count, 2)
        XCTAssertEqual(rows.first { $0.url == imported }?.count, 30)
        XCTAssertEqual(rows.first { $0.url == renamed }?.title, "Renamed")
        XCTAssertFalse(rows.contains { $0.url == forgotten })
        XCTAssertTrue(rows.contains { $0.url == early })
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        let urls = Set(saved.compactMap { $0["url"] as? String })
        XCTAssertTrue(urls.contains(visited.absoluteString))
        XCTAssertTrue(urls.contains(imported.absoluteString))
        XCTAssertTrue(urls.contains(early.absoluteString))
        XCTAssertFalse(urls.contains(forgotten.absoluteString))
    }

    func testClearDuringLoadingWinsAndTheNextVisitIsKept() throws {
        let (name, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: file) }
        let history = History(file: name)
        history.forget()
        let early = try XCTUnwrap(URL(string: "https://after-clear.example/"))
        history.record(early, title: "After clear")
        history.flush()
        XCTAssertEqual(history.everything().map(\.url), [early])
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        XCTAssertEqual(saved.compactMap { $0["url"] as? String }, [early.absoluteString])
    }

    func testRetirementDuringLoadingNeverRestoresTheFile() throws {
        let (name, file) = try fixture()
        let history = History(file: name)
        history.record(try XCTUnwrap(URL(string: "https://early.example/")), title: "Early")
        history.retire()
        history.flush()
        Disk.drain()
        XCTAssertTrue(history.everything().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testCorruptFileIsQuarantinedBeforeEarlyVisitIsWritten() throws {
        let (name, file) = try fixture()
        let prefix = file.deletingPathExtension().lastPathComponent + ".unreadable-"
        defer {
            try? FileManager.default.removeItem(at: file)
            if let names = try? FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) {
                for name in names where name.hasPrefix(prefix) {
                    try? FileManager.default.removeItem(at: file.deletingLastPathComponent().appendingPathComponent(name))
                }
            }
        }
        let bad = Data("not json".utf8)
        try bad.write(to: file)
        let history = History(file: name)
        let early = try XCTUnwrap(URL(string: "https://early.example/"))
        history.record(early, title: "Early")
        history.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        let quarantined = try XCTUnwrap(names.first { $0.hasPrefix(prefix) })
        XCTAssertEqual(try Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent(quarantined)), bad)
        XCTAssertEqual(history.everything().map(\.url), [early])
    }
}
