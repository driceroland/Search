import Foundation
import XCTest
@testable import Search

/// Saves of the same file, one after another: the newest is written, and one
/// a newer save overtook before it began is never even encoded.
final class DiskTests: XCTestCase {
    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.lock(); value += 1; lock.unlock() }
        var now: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testOvertakenWriteIsNeitherEncodedNorWritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("disk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("session.json")

        // The queue held up by a write of another file, so the two saves of
        // this one are both waiting when it moves on.
        let hold = DispatchSemaphore(value: 0)
        Disk.write(folder.appendingPathComponent("other.json")) {
            hold.wait()
            return Data()
        }
        let older = Count()
        let newer = Count()
        Disk.write(file) { older.add(); return Data("older".utf8) }
        Disk.write(file) { newer.add(); return Data("newer".utf8) }
        hold.signal()
        Disk.drain()

        XCTAssertEqual(older.now, 0, "The save overtaken before it began is not encoded")
        XCTAssertEqual(newer.now, 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "newer")
    }

    func testWriteOvertakenWhileEncodingIsNotWritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("disk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("session.json")

        // A save at once, on the way out, arrives while the queued one is
        // still encoding: the queued one, older, is dropped.
        let encoding = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        Disk.write(file) {
            encoding.signal()
            resume.wait()
            return Data("older".utf8)
        }
        encoding.wait()
        Disk.write(file, now: true) { Data("newer".utf8) }
        resume.signal()
        Disk.drain()

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "newer")
    }
}
