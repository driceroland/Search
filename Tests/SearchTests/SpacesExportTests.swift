import Foundation
import XCTest
@testable import Search

/// File › Export Spaces…: the bookmarks page any browser imports, and
/// Search's own spaces file read back into the shape every spaces import
/// takes (see SpacesExport.swift). Made-up spaces only.
final class SpacesExportTests: XCTestCase {
    private func sample() -> SpacesExport.Bundle {
        var work = SpacesExport.Space(name: "Work & <Play>", colour: 1, icon: "briefcase")
        work.pins = [
            .init(title: "Mail", url: "https://mail.example.com/"),
            .init(title: "Loose row", url: "https://example.com/loose", listed: true),
            .init(title: "Deep row", url: "https://example.com/deep", listed: true, folder: "F2"),
            .init(title: "Top row \"quoted\"", url: "https://example.com/top?a=1&b=2", listed: true, folder: "F1"),
        ]
        work.folders = [.init(id: "F1", name: "Projects"), .init(id: "F2", name: "Inner", parent: "F1")]
        work.groups = [.init(id: "G1", name: "Research")]
        work.tabs = [.init(title: "Open one", url: "https://example.org/1"),
                     .init(title: "Grouped", url: "https://example.org/2", group: "G1")]
        let home = SpacesExport.Space(name: "Home", pins: [.init(title: "News", url: "https://news.example.com/", listed: true)])
        return SpacesExport.Bundle(profiles: [
            .init(name: "Personal", everySpace: [.init(title: "Calendar", url: "https://cal.example.com/")], spaces: [work, home]),
        ])
    }

    func testBookmarksPageHasAFolderPerSpaceAndTheSharedPinsFirst() {
        let html = SpacesExport.html(sample())
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        let roots = BookmarksFile.parse(html)
        XCTAssertEqual(roots.map(\.title), ["Every Space", "Work & <Play>", "Home"])
        XCTAssertEqual(roots[0].children?.map(\.title), ["Calendar"])
    }

    func testASpaceHoldsItsSquaresThenItsFoldersNestedThenItsRowsThenItsOpenTabs() throws {
        let roots = BookmarksFile.parse(SpacesExport.html(sample()))
        let work = try XCTUnwrap(roots.first { $0.title == "Work & <Play>" }?.children)
        XCTAssertEqual(work.map(\.title), ["Mail", "Projects", "Loose row", "Open Tabs"])
        let projects = try XCTUnwrap(work[1].children)
        XCTAssertEqual(projects.map(\.title), ["Inner", "Top row \"quoted\""])
        XCTAssertEqual(projects[1].url, "https://example.com/top?a=1&b=2")
        XCTAssertEqual(projects[0].children?.map(\.title), ["Deep row"])
        let open = try XCTUnwrap(work[3].children)
        XCTAssertEqual(open.map(\.title), ["Research", "Open one"])
        XCTAssertEqual(open[0].children?.map(\.title), ["Grouped"])
    }

    func testNamesAndAddressesAreEscaped() {
        let html = SpacesExport.html(sample())
        XCTAssertTrue(html.contains("<H3>Work &amp; &lt;Play&gt;</H3>"))
        XCTAssertTrue(html.contains("HREF=\"https://example.com/top?a=1&amp;b=2\""))
        XCTAssertTrue(html.contains("Top row &quot;quoted&quot;"))
        XCTAssertFalse(html.contains("<Play>"))
    }

    func testAFolderWhoseParentIsGoneAndAFolderInItselfStillCome() {
        var space = SpacesExport.Space(name: "Odd")
        space.folders = [.init(id: "A", name: "Orphan", parent: "missing"), .init(id: "B", name: "Self", parent: "B")]
        space.pins = [.init(title: "In orphan", url: "https://example.com/a", listed: true, folder: "A"),
                      .init(title: "Lost", url: "https://example.com/b", listed: true, folder: "nowhere")]
        let roots = BookmarksFile.parse(SpacesExport.html(.init(profiles: [.init(name: "P", spaces: [space])])))
        let odd = roots.first?.children ?? []
        XCTAssertEqual(odd.map(\.title), ["Orphan", "Lost"])
        XCTAssertEqual(odd.first?.children?.map(\.title), ["In orphan"])
    }

    func testSeveralProfilesNameTheirSharedFolders() {
        var bundle = sample()
        bundle.profiles.append(.init(name: "Club", everySpace: [.init(title: "Chat", url: "https://chat.example.com/")],
                                     spaces: [.init(name: "Games")]))
        let roots = BookmarksFile.parse(SpacesExport.html(bundle))
        XCTAssertEqual(roots.map(\.title), ["Every Space (Personal)", "Every Space (Club)", "Work & <Play>", "Home", "Games"])
    }

    // MARK: - Search's own file

    func testTheSpacesFileReadsBackAsItWasWritten() throws {
        let bundle = sample()
        let read = try XCTUnwrap(SpacesExport.bundle(SpacesExport.json(bundle)))
        XCTAssertEqual(read.profiles, bundle.profiles)
        XCTAssertNil(SpacesExport.bundle(Data(#"{"history": []}"#.utf8)))
        XCTAssertNil(SpacesExport.bundle(Data(#"{"format": "other", "version": 1, "exported": "2026-01-01T00:00:00Z", "profiles": []}"#.utf8)))
    }

    func testTheSpacesFileComesInAsSpacesWithPinsFoldersAndTabs() throws {
        let sidebar = SpacesExport.sidebar(sample())
        XCTAssertEqual(sidebar.spaces.map(\.name), ["Work & <Play>", "Home"])
        XCTAssertEqual(sidebar.everySpace.map(\.title), ["Calendar"])
        let work = sidebar.spaces[0]
        XCTAssertEqual(work.colour, 1)
        XCTAssertEqual(work.symbol, "briefcase")
        XCTAssertEqual(work.profile, "Default")
        XCTAssertEqual(work.favorites?.map(\.title), ["Mail"])
        guard case .folder(let projects) = try XCTUnwrap(work.pinned.first) else { return XCTFail("a folder first") }
        XCTAssertEqual(projects.title, "Projects")
        guard case .folder(let inner) = try XCTUnwrap(projects.items.first) else { return XCTFail("its folder first") }
        XCTAssertEqual(inner.items, [.item(.init(title: "Deep row", url: URL(string: "https://example.com/deep")!))])
        XCTAssertEqual(work.pinned.last, .item(.init(title: "Loose row", url: URL(string: "https://example.com/loose")!)))
        XCTAssertEqual(work.open.map(\.item.title), ["Open one", "Grouped"])
        XCTAssertEqual(work.open.map(\.group), [nil, "Research"])
    }

    func testAnotherProfilesSharedPinsBecomeEachOfItsSpacesPins() {
        var bundle = sample()
        bundle.profiles.append(.init(name: "Club", everySpace: [.init(title: "Chat", url: "https://chat.example.com/")],
                                     spaces: [.init(name: "Games")]))
        let sidebar = SpacesExport.sidebar(bundle)
        let games = sidebar.spaces.first { $0.name == "Games" }
        XCTAssertEqual(games?.profile, "Profile 1")
        XCTAssertEqual(sidebar.profileNames?["Profile 1"], "Club")
        XCTAssertEqual(games?.favorites?.map(\.title), ["Chat"])
    }
}
