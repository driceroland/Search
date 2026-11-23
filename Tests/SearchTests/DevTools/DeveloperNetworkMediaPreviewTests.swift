import CoreText
import XCTest
@testable import Search

final class DeveloperNetworkMediaPreviewTests: XCTestCase {
    func testMediaKindFromMIMETypeOrExtension() {
        XCTAssertEqual(DeveloperResponseMedia.kind(mimeType: "font/woff2", url: "https://a.test/x"), .font)
        XCTAssertEqual(DeveloperResponseMedia.kind(mimeType: "application/x-font-ttf", url: "https://a.test/x"), .font)
        XCTAssertEqual(DeveloperResponseMedia.kind(mimeType: "audio/mpeg; charset=binary", url: "https://a.test/x"), .audio)
        XCTAssertEqual(DeveloperResponseMedia.kind(mimeType: "Video/MP4", url: "https://a.test/x"), .video)
        // A generic type falls back to the file's extension.
        XCTAssertEqual(DeveloperResponseMedia.kind(mimeType: "application/octet-stream", url: "https://a.test/f.otf?v=2"), .font)
        XCTAssertEqual(DeveloperResponseMedia.kind(mimeType: nil, url: "https://a.test/clip.webm"), .video)
        XCTAssertEqual(DeveloperResponseMedia.kind(mimeType: "", url: "https://a.test/song.mp3"), .audio)
        XCTAssertNil(DeveloperResponseMedia.kind(mimeType: "application/octet-stream", url: "https://a.test/blob.bin"))
        // A specific type wins over a misleading extension.
        XCTAssertNil(DeveloperResponseMedia.kind(mimeType: "text/html", url: "https://a.test/page.mp4"))
        XCTAssertNil(DeveloperResponseMedia.kind(mimeType: "image/png", url: "https://a.test/a.png"))
    }

    func testFileExtensionForThePlayer() {
        XCTAssertEqual(DeveloperResponseMedia.fileExtension(mimeType: "audio/mpeg", url: "https://a.test/stream"), "mp3")
        XCTAssertEqual(DeveloperResponseMedia.fileExtension(mimeType: "video/mp4", url: "https://a.test/stream"), "mp4")
        XCTAssertEqual(DeveloperResponseMedia.fileExtension(mimeType: "application/octet-stream", url: "https://a.test/a.MOV"), "mov")
    }

    func testWrittenBodyIsRemoved() throws {
        let file = try XCTUnwrap(DeveloperResponseMedia.write(Data([1, 2, 3]), fileExtension: "mp4"))
        XCTAssertEqual(file.pathExtension, "mp4")
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]))
        DeveloperResponseMedia.remove(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testFontSampleLoadsFromFontData() throws {
        let candidates = ["/System/Library/Fonts/Geneva.ttf", "/System/Library/Fonts/Keyboard.ttf",
                          "/System/Library/Fonts/Monaco.ttf", "/System/Library/Fonts/Helvetica.ttc",
                          "/System/Library/Fonts/Menlo.ttc"]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
              let data = FileManager.default.contents(atPath: path) else {
            throw XCTSkip("No system font file to read")
        }
        XCTAssertFalse(DeveloperFontSample.descriptors(data).isEmpty)
        let fonts = DeveloperFontSample.fonts(data)
        XCTAssertEqual(fonts.map { CTFontGetSize($0) }, DeveloperFontSample.sizes)
        XCTAssertFalse(DeveloperFontSample.name(try XCTUnwrap(fonts.first)).isEmpty)
        XCTAssertEqual(DeveloperFontSample.text, "ABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n1234567890")
    }

    func testFontSampleRejectsNonFontData() {
        XCTAssertTrue(DeveloperFontSample.descriptors(Data("not a font".utf8)).isEmpty)
        XCTAssertTrue(DeveloperFontSample.fonts(Data()).isEmpty)
    }
}
