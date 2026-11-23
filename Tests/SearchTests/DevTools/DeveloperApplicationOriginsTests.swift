import AppKit
import WebKit
import XCTest
@testable import Search

/// Application › Local storage, Session storage and Cookies list one entry
/// per origin among the page's frames, and each reads that origin's own.
@MainActor
final class DeveloperApplicationOriginsTests: XCTestCase {
    // MARK: Origins from the frame tree

    func testOriginsComeFromEveryFrameOnceThePagesFirst() throws {
        let raw: [String: Any] = [
            "frame": ["id": "top", "url": "https://example.com/", "securityOrigin": "https://example.com"],
            "childFrames": [
                ["frame": ["id": "ad", "url": "https://ads.example/slot", "securityOrigin": "https://ads.example"],
                 "childFrames": [
                    ["frame": ["id": "deep", "url": "http://tracker.example:8080/p", "securityOrigin": "http://tracker.example:8080"]],
                 ]],
                ["frame": ["id": "same", "url": "https://example.com/inner", "securityOrigin": "https://example.com"]],
                ["frame": ["id": "again", "url": "https://ads.example/other", "securityOrigin": "https://ads.example"]],
                ["frame": ["id": "opaque", "url": "data:text/html,hi", "securityOrigin": "null"]],
                ["frame": ["id": "blank", "url": "about:blank", "securityOrigin": ""]],
            ],
        ]
        let root = try XCTUnwrap(DeveloperFrameNode.parse(raw))
        XCTAssertEqual(DeveloperApplicationTree.storageOrigins(main: "https://example.com", frame: root),
                       ["https://example.com", "https://ads.example", "http://tracker.example:8080"])
        // Without the page's origin, the frames' order alone.
        XCTAssertEqual(DeveloperApplicationTree.storageOrigins(main: nil, frame: root),
                       ["https://example.com", "https://ads.example", "http://tracker.example:8080"])
        // A trailing slash is the same origin.
        XCTAssertEqual(DeveloperApplicationTree.storageOrigins(main: "https://example.com/", frame: nil),
                       ["https://example.com"])
        XCTAssertEqual(DeveloperApplicationTree.address(of: "https://ads.example", in: root)?.absoluteString,
                       "https://ads.example/slot")
        XCTAssertNil(DeveloperApplicationTree.address(of: "https://missing.example", in: root))
    }

    // MARK: A cross-origin frame's storage, live

    func testTheTreeListsEachFramesOriginAndReadsItsStorage() async throws {
        _ = NSApplication.shared
        // A second server is a second origin: same host, another port.
        let child = try LocalPageServer([
            "/child": .init(type: "text/html", body: """
                <!doctype html><title>Child</title>
                <script>
                localStorage.setItem('child fixture', 'child value');
                sessionStorage.setItem('child session', 'child session value');
                parent.postMessage('child ready', '*');
                </script>
                """),
        ])
        let childURL = child.url("/child")
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: """
                <!doctype html><title>Origins fixture</title>
                <script>
                localStorage.setItem('top fixture', 'top value');
                addEventListener('message', (event) => {
                    if (event.data === 'child ready') document.title = 'Origins ready';
                });
                </script>
                <iframe src="\(childURL.absoluteString)"></iframe>
                """),
        ])
        let address = server.url("/")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 440), configuration: configuration)
        page.load(URLRequest(url: address))
        try await DeveloperTestSupport.wait("page and frame to load", in: "DeveloperApplicationOriginsTests") {
            page.title == "Origins ready" && !page.isLoading
        }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        do {
            try await DeveloperTestSupport.wait("inspector", in: "DeveloperApplicationOriginsTests") { session.ready }
            let top = "http://127.0.0.1:\(server.port)"
            let other = "http://127.0.0.1:\(child.port)"

            var tree = DeveloperApplicationTree()
            for _ in 0..<40 {
                tree = await DeveloperApplication.tree(in: session, address: address)
                if tree.origins.count >= 2 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(tree.origin, top)
            XCTAssertEqual(tree.origins, [top, other])

            let own = try await DeveloperApplication.read(.init(section: .local), in: session, address: address)
            XCTAssertTrue(own.rows.contains { $0.values == ["top fixture", "top value"] })
            XCTAssertFalse(own.rows.contains { $0.values.first == "child fixture" })

            let frameLocal = try await DeveloperApplication.read(.init(section: .local, origin: other),
                                                                 in: session, address: address)
            XCTAssertTrue(frameLocal.rows.contains { $0.values == ["child fixture", "child value"] },
                          "\(frameLocal.rows.map(\.values))")
            XCTAssertFalse(frameLocal.rows.contains { $0.values.first == "top fixture" })
            let frameSession = try await DeveloperApplication.read(.init(section: .session, origin: other),
                                                                   in: session, address: address)
            XCTAssertTrue(frameSession.rows.contains { $0.values == ["child session", "child session value"] })

            // Edits go to the frame's origin, not the page's.
            let reference = try XCTUnwrap(frameLocal.rows.first { $0.values.first == "child fixture" }?.editableValue)
            let value = try await DeveloperApplication.value(for: reference, in: session)
            XCTAssertEqual(value, "child value")
            try await DeveloperApplication.setValue("edited", replacing: value, for: reference, in: session)
            try await DeveloperApplication.setStorageItem(key: "added", value: "new", replacing: nil, persistent: true,
                                                          in: session, address: address, origin: other)
            let edited = try await DeveloperApplication.read(.init(section: .local, origin: other),
                                                             in: session, address: address)
            XCTAssertTrue(edited.rows.contains { $0.values == ["child fixture", "edited"] })
            XCTAssertTrue(edited.rows.contains { $0.values == ["added", "new"] })
            let ownAfter = try await DeveloperApplication.read(.init(section: .local), in: session, address: address)
            XCTAssertFalse(ownAfter.rows.contains { $0.values.first == "added" })

            let container = try XCTUnwrap(edited.container)
            try await DeveloperApplication.delete([container], in: session)
            let cleared = try await DeveloperApplication.read(.init(section: .local, origin: other),
                                                              in: session, address: address)
            XCTAssertTrue(cleared.rows.isEmpty, "\(cleared.rows.map(\.values))")
            let ownKept = try await DeveloperApplication.read(.init(section: .local), in: session, address: address)
            XCTAssertTrue(ownKept.rows.contains { $0.values == ["top fixture", "top value"] })

            do {
                _ = try await DeveloperApplication.read(.init(section: .local, origin: "http://127.0.0.1:1"),
                                                        in: session, address: address)
                XCTFail("An origin no frame has must not be read")
            } catch DeveloperApplication.Issue.frameGone {}
        } catch {
            await DeveloperTestSupport.finish(session, page: page, keeping: tab, server, child)
            throw error
        }
        await DeveloperTestSupport.finish(session, page: page, keeping: tab, server, child)
    }
}
