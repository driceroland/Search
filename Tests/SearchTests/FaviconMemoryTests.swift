import AppKit
import CryptoKit
import XCTest
@testable import Search

@MainActor
final class FaviconMemoryTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "favicon-memory-\(getpid())", 1)
        super.setUp()
    }

    func testClearingHistoryReleasesItsCachedImagesButNotAnOpenTabs() async throws {
        _ = NSApplication.shared
        let icons = Favicons()
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        await icons.adopt(png, for: "favicon-memory.example")
        let cache = try XCTUnwrap(Mirror(reflecting: icons).children.first { $0.label == "memory" }?.value as? NSCache<NSString, NSImage>)
        cache.removeAllObjects()
        let tab = Tab(bench: true)
        tab.icon = try XCTUnwrap(icons.cached("favicon-memory.example"))
        let ident = SHA256.hash(data: Data("adopted:favicon-memory.example".utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
        func cachedImage() -> NSImage? {
            let cache = Mirror(reflecting: icons).children.first { $0.label == "memory" }?.value
            if let cache = cache as? [String: NSImage] { return cache[ident] }
            return (cache as? NSCache<NSString, NSImage>)?.object(forKey: ident as NSString)
        }
        XCTAssertNotNil(cachedImage())
        icons.forgetAll()
        XCTAssertNotNil(tab.icon, "an open tab keeps its own icon")
        XCTAssertNil(cachedImage(), "clearing history must empty the decoded image cache")
    }

    func testLargeAnswersAreStoppedWithAndWithoutALength() async throws {
        let large = String(repeating: "x", count: 10_000_000)
        let server = try LocalPageServer([
            "/known": .init(type: "image/png", body: large, slowly: true),
            "/unknown": .init(type: "image/png", body: large, withoutLength: true, slowly: true),
            "/small": .init(type: "image/png", body: String(repeating: "x", count: 100)),
        ])
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (small, _) = try await Favicons.readIcon(server.url("/small"), session: session)
        XCTAssertEqual(small.count, 100)
        let inline = try XCTUnwrap(URL(string: "data:image/png;base64," + Data(repeating: 42, count: 100).base64EncodedString()))
        let (inlineData, _) = try await Favicons.readIcon(inline, session: session)
        XCTAssertEqual(inlineData, Data(repeating: 42, count: 100))
        let (known, _) = try await Favicons.readIcon(server.url("/known"), session: session)
        XCTAssertTrue(known.isEmpty)
        let (unknown, _) = try await Favicons.readIcon(server.url("/unknown"), session: session)
        XCTAssertTrue(unknown.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        print("Icon bytes sent: known \(server.bytesSent("/known")), unknown \(server.bytesSent("/unknown"))")
        XCTAssertLessThan(server.bytesSent("/known"), 500_000)
        XCTAssertGreaterThanOrEqual(server.bytesSent("/unknown"), 2_000_000)
        XCTAssertLessThan(server.bytesSent("/unknown"), 4_000_000)
    }

    func testPrivateIconsStayPrivateAndCanBeRedrawnAfterEviction() async throws {
        _ = NSApplication.shared
        let icons = Favicons()
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let icon = try XCTUnwrap(URL(string: "data:image/png;base64," + png.base64EncodedString()))
        let site = "\(UUID().uuidString.lowercased()).example"
        let page = try XCTUnwrap(URL(string: "https://\(site)/private"))
        await icons.download([icon], site: site, page: "/private", dark: Favicons.dark, shy: true)
        XCTAssertNil(icons.cached(for: page))
        let cache = try XCTUnwrap(Mirror(reflecting: icons).children.first { $0.label == "memory" }?.value as? NSCache<NSString, NSImage>)
        XCTAssertEqual(cache.totalCostLimit, 16 * 1024 * 1024)
        cache.removeAllObjects()
        XCTAssertNotNil(icons.cached(for: page, shy: true))
        icons.forgetShy()
        XCTAssertNil(icons.cached(for: page, shy: true))
    }
}
