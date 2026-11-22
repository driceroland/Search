import WebKit
import XCTest
@testable import Search

@MainActor
final class PageDraftTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "frame-drafts-\(getpid())", 1)
        super.setUp()
    }

    func testEmbeddedDraftsKeepTabAwakeUntilClearedOrRemoved() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(configuration: configuration)
        defer { tab.close(); browser.closeAll() }
        let web = tab.web
        let url = try XCTUnwrap(URL(string: "https://draft.example/"))
        tab.setAddressOptimistically(url)
        web.loadHTMLString("<title>Drafts</title><textarea></textarea>", baseURL: url)
        let deadline = Date().addingTimeInterval(5)
        while (web.title != "Drafts" || web.isLoading) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let made = try await web.callAsyncJavaScript("""
            const child = `
              <form><textarea></textarea></form><script>
              const box = document.querySelector('textarea');
              onmessage = e => {
                if (e.data === 'edit') {
                  box.focus();
                  document.execCommand('insertText', false, 'draft');
                } else { document.forms[0].reset(); }
                parent.postMessage(Boolean(box.value), '*');
              };
              </script>`;
            for (const sandbox of ['', 'allow-scripts']) {
              const frame = document.createElement('iframe');
              if (sandbox) frame.setAttribute('sandbox', sandbox);
              frame.srcdoc = child;
              await new Promise(ok => { frame.onload = ok; document.body.append(frame); });
            }
            window.ask = (i, command) => new Promise(ok => {
              window.addEventListener('message', e => ok([e.origin, e.data]), {once:true});
              frames[i].postMessage(command, '*');
            });
            return frames.length;
            """, in: nil, contentWorld: .page)
        XCTAssertEqual(made as? Int, 2)

        func edit(_ frame: Int, _ command: String) async throws -> [Any] {
            let result = try await web.callAsyncJavaScript("return await ask(i, command);",
                arguments: ["i": frame, "command": command], in: nil, contentWorld: .page)
            return try XCTUnwrap(result as? [Any])
        }
        func unsaved() async -> Bool {
            await withCheckedContinuation { c in tab.unsaved { c.resume(returning: $0) } }
        }

        let clean = await unsaved()
        XCTAssertFalse(clean)
        let same = try await edit(0, "edit")
        XCTAssertEqual(same.last as? Bool, true)
        let cross = try await edit(1, "edit")
        XCTAssertEqual(cross.first as? String, "null", "The sandboxed sibling has an opaque origin")
        XCTAssertEqual(cross.last as? Bool, true)
        _ = try await edit(0, "reset")
        let reason = await withCheckedContinuation { c in browser.sleep(tab) { c.resume(returning: $0) } }
        XCTAssertEqual(reason, "holding something typed")
        XCTAssertNotNil(tab.built)
        _ = try await edit(1, "reset")
        let cleared = await unsaved()
        XCTAssertFalse(cleared)
        _ = try await edit(1, "edit")
        let again = await unsaved()
        XCTAssertTrue(again)
        _ = try await web.evaluateJavaScript("document.querySelectorAll('iframe')[1].remove()")
        let afterRemoval = await unsaved()
        XCTAssertFalse(afterRemoval)
        _ = try await web.evaluateJavaScript("sessionStorage.setItem('step', 'review')", contentWorld: .page)
        let afterDraft = await withCheckedContinuation { c in browser.sleep(tab) { c.resume(returning: $0) } }
        XCTAssertEqual(afterDraft, "asleep")
        XCTAssertNil(tab.built)
        XCTAssertTrue(try XCTUnwrap(KeptSession.script(for: tab)).contains("review"))
    }
}
