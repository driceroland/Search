import XCTest
@testable import Search

/// Which frames of an extension's panel get Claude's own fallback
/// (PanelFrameFallback, idea 686): claude.ai's /cic pages and nothing else.
@available(macOS 14, *)
final class PanelFrameFallbackTests: XCTestCase {
    private func script(_ text: String) -> String? {
        PanelFrameFallback.script(for: URL(string: text), hosts: PanelFrameFallback.claudeHosts)
    }

    func testClaudesPanelFrameGetsTheFallback() {
        for text in ["https://claude.ai/cic/new?surface=cic_sidepanel", "https://claude.ai/cic",
                     "https://CLAUDE.ai/cic/new", "https://preview.claude.ai/cic/new?surface=cic_sidepanel"] {
            let found = script(text)
            XCTAssertNotNil(found, text)
            XCTAssertTrue(found?.contains("cic_sidepanel_cowork_unavailable") == true, text)
            XCTAssertTrue(found?.contains("origin: \"https://claude.ai\"") == true, text)
        }
    }

    func testEveryOtherFrameIsLeftAlone() {
        for text in ["https://claude.ai/new", "https://claude.ai/login?returnTo=%2Fcic%2Fnew", "https://claude.ai/cicada",
                     "http://claude.ai/cic/new", "https://evil.example/cic/new", "https://claude.ai.evil.example/cic/new",
                     "https://chatgpt.com/cic/new", "https://a.claude.ai/cic/new", "chrome-extension://fcoeoabgfenejglbffodgkkbkcdhcgfn/cic/x"] {
            XCTAssertNil(script(text), text)
        }
        XCTAssertNil(PanelFrameFallback.script(for: nil))
    }

    func testAStandInIsOnlyWhatTheTestNames() {
        XCTAssertNil(script("http://localhost:8080/cic/new"))
        XCTAssertNotNil(PanelFrameFallback.script(for: URL(string: "http://localhost:8080/cic/new"),
                                                  hosts: PanelFrameFallback.claudeHosts + ["localhost"]))
    }
}
