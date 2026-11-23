import XCTest
@testable import Search

/// Network settings › Group by frame, as Chrome's frame grouper.
@MainActor
final class DeveloperNetworkFrameGroupsTests: XCTestCase {
    private typealias Groups = DeveloperNetworkFrameGroups
    private typealias Frame = DeveloperToolsSession.ResourceFrame

    private func request(_ id: String, frame: String?, type: String = "Script",
                         url: String? = nil) -> DeveloperToolsSession.Request {
        var request = DeveloperToolsSession.Request(id: id, url: url ?? "https://example.test/\(id).js", method: "GET",
                                                    type: type, loader: nil, started: 1)
        request.frameId = frame
        return request
    }

    private let frames = [
        Frame(id: "main", parent: nil, url: "https://example.test/", name: ""),
        Frame(id: "ad", parent: "main", url: "https://ads.test/slot", name: ""),
        Frame(id: "chat", parent: "main", url: "https://chat.test/", name: "chat-widget"),
    ]

    private func ids(_ entries: [Groups.Entry]) -> [String] { entries.map(\.id) }

    func testSubframeRequestsSitUnderTheirFrameRow() {
        let rows = [
            request("1", frame: "main", type: "Document"),
            request("2", frame: "ad"),
            request("3", frame: "main"),
            request("4", frame: "chat"),
            request("5", frame: "ad"),
        ]
        let collapsed = Groups.entries(rows, frames: frames, main: "main", expanded: [])
        XCTAssertEqual(ids(collapsed), ["1", "frame:ad", "3", "frame:chat"],
                       "the main frame's requests stay at the top level; a frame's row is where its first request was")
        let open = Groups.entries(rows, frames: frames, main: "main", expanded: ["ad"])
        XCTAssertEqual(ids(open), ["1", "frame:ad", "2", "5", "3", "frame:chat"])
        XCTAssertEqual(Groups.requests(in: open).map(\.id), ["1", "2", "5", "3"], "what the keyboard moves through")
        guard case .frame(let ad) = open[1], case .frame(let chat) = open[5] else { return XCTFail("frame rows") }
        XCTAssertEqual(ad.count, 2)
        XCTAssertTrue(ad.expanded)
        XCTAssertFalse(chat.expanded)
        XCTAssertEqual(ad.title, "https://ads.test/slot", "an unnamed frame goes by its address")
        XCTAssertEqual(chat.title, "chat-widget", "a named frame by its name")
    }

    func testOnlyTheMainFrameLeavesTheListAsItWas() {
        let rows = [request("1", frame: "main"), request("2", frame: nil), request("3", frame: "main")]
        XCTAssertEqual(ids(Groups.entries(rows, frames: frames, main: "main", expanded: [])), ["1", "2", "3"])
        XCTAssertEqual(ids(Groups.entries([], frames: frames, main: "main", expanded: [])), [])
    }

    func testTheMainFrameIsTheTreesRootElseTheFirstDocuments() {
        let rows = [request("1", frame: "sub"), request("2", frame: "top", type: "Document")]
        XCTAssertEqual(Groups.mainFrame(frames, requests: rows), "main")
        XCTAssertEqual(Groups.mainFrame([], requests: rows), "top")
        XCTAssertEqual(Groups.mainFrame([], requests: [request("1", frame: "sub")]), "sub")
        XCTAssertNil(Groups.mainFrame([], requests: [request("1", frame: nil)]))
    }

    func testAFrameTheTreeDoesntKnowIsNamedForItsDocument() {
        let rows = [request("1", frame: "gone", type: "Document", url: "https://late.test/frame.html")]
        XCTAssertEqual(Groups.title("gone", frames: frames, requests: rows), "https://late.test/frame.html")
        var script = request("2", frame: "gone")
        script.documentURL = "https://late.test/doc"
        XCTAssertEqual(Groups.title("gone", frames: frames, requests: [script]), "https://late.test/doc")
        XCTAssertEqual(Groups.title("gone", frames: [], requests: [request("3", frame: "gone")]), "gone")
    }

    func testTheFrameTreeIsReadMainFrameFirst() {
        let tree: [String: Any] = [
            "frame": ["id": "main", "url": "https://example.test/", "name": ""],
            "childFrames": [
                ["frame": ["id": "child", "url": "https://ads.test/", "name": "ad"],
                 "childFrames": [["frame": ["id": "grandchild", "url": "about:blank"]]]],
            ],
        ]
        let list = Groups.frames(in: tree)
        XCTAssertEqual(list.map(\.id), ["main", "child", "grandchild"])
        XCTAssertNil(list[0].parent)
        XCTAssertEqual(list[1].parent, "main")
        XCTAssertEqual(list[1].name, "ad")
        XCTAssertEqual(list[2].parent, "child")
        XCTAssertEqual(list[2].name, "")
    }
}
