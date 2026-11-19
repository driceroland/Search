import CoreServices
import XCTest
@testable import Search

final class MarkDownloadedTests: XCTestCase {
    func testASavedFileIsMarkedAsDownloaded() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mark-downloaded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.pdf")
        try Data("%PDF-1.4".utf8).write(to: file)

        Browser.markDownloaded(file)

        let properties = try XCTUnwrap(try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        XCTAssertEqual(properties[kLSQuarantineTypeKey as String] as? String, kLSQuarantineTypeWebDownload as String)
        XCTAssertEqual(properties[kLSQuarantineAgentNameKey as String] as? String, "Search")
    }
}
