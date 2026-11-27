import WebKit
import XCTest
@testable import Search

/// Search's own controls count as using the site, for tracking prevention
/// (Store.interacted): what WebKit itself reads back says so.
@available(macOS 14, *)
@MainActor
final class SiteInteractionTests: XCTestCase {
    private typealias Answer = @convention(c) (Bool, UnsafeMutableRawPointer?) -> Void
    private typealias Ask = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UnsafeMutableRawPointer?, Answer) -> Void
    private typealias Text = @convention(c) (UnsafePointer<CChar>) -> UnsafeRawPointer

    /// WebKit's own record for `url`'s site: whether it was used.
    private func used(_ url: String, in store: WKWebsiteDataStore) async throws -> Bool {
        let kit = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_NOW)
        guard let ask = dlsym(kit, "WKWebsiteDataStoreIsStatisticsHasHadUserInteraction"),
              let text = dlsym(kit, "WKStringCreateWithUTF8CString") else { throw XCTSkip("no WebKit C API to read it back") }
        final class Box { var value: Bool?; }
        let box = Box()
        let answer: Answer = { value, context in
            Unmanaged<Box>.fromOpaque(context!).takeUnretainedValue().value = value
        }
        unsafeBitCast(ask, to: Ask.self)(Unmanaged.passUnretained(store).toOpaque(),
                                         unsafeBitCast(text, to: Text.self)(url),
                                         Unmanaged.passUnretained(box).toOpaque(), answer)
        for _ in 0..<200 where box.value == nil { try await Task.sleep(for: .milliseconds(25)) }
        return try XCTUnwrap(box.value)
    }

    func testAPauseFromSearchCountsAsUsingTheSite() async throws {
        let id = UUID()
        let store = WKWebsiteDataStore(forIdentifier: id)
        let on = NSSelectorFromString("_setResourceLoadStatisticsEnabled:")
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(store.method(for: on), to: Setter.self)(store, on, true)
        let site = "https://www.youtube.example/watch?v=1", other = "https://news.example/"

        let before = try await used(site, in: store)
        XCTAssertFalse(before, "nothing yet")
        await withCheckedContinuation { done in
            Store.interacted(with: URL(string: site)!, in: store) { done.resume() }
        }
        let after = try await used(site, in: store)
        XCTAssertTrue(after, "counted as used")
        let elsewhere = try await used(other, in: store)
        XCTAssertFalse(elsewhere, "and only that site")
        // Never a page of Search's own.
        await withCheckedContinuation { done in
            Store.interacted(with: URL(string: "about:blank")!, in: store) { done.resume() }
        }
        await withCheckedContinuation { done in WKWebsiteDataStore.remove(forIdentifier: id) { _ in done.resume() } }
    }
}
