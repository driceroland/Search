import XCTest
@testable import Search

final class TabGroupsTests: XCTestCase {
    func testOldSessionDecodesWithoutGroups() throws {
        let data = Data(#"{"tabs":[{"url":"https://github.com","title":"GitHub"}],"active":0}"#.utf8)
        let session = try JSONDecoder().decode(Session.Shape.self, from: data)

        XCTAssertNil(session.groups)
        XCTAssertNil(session.tabs[0].groupID)
    }

    func testGroupsAndTabMembershipSurviveSessionRoundTrip() throws {
        let group = TabGroup(id: UUID(), name: "GitHub", collapsed: true)
        let session = Session.Shape(
            tabs: [Session.Entry(url: "https://github.com", title: "GitHub", pin: nil,
                                 name: nil, groupID: group.id)],
            active: 0,
            groups: [group]
        )

        let restored = try JSONDecoder().decode(Session.Shape.self, from: JSONEncoder().encode(session))

        XCTAssertEqual(restored.groups, [group])
        XCTAssertEqual(restored.tabs[0].groupID, group.id)
    }
}
