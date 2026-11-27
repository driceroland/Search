import XCTest
@testable import Search

/// Idea 1350: with Search in front, the tab paused last keeps the media keys
/// with no time limit; in the background, the ten-second hand-back stays.
@MainActor
final class MediaKeysKeeperTests: XCTestCase {
    final class FakeTab: HandsKeysBack {
        var handed = 0
        func handBack() { handed += 1 }
    }

    private func keeper(active: Bool) -> (MediaKeysKeeper, () -> Void) {
        var on = active
        let keeper = MediaKeysKeeper(watching: false)
        keeper.active = { on }
        return (keeper, { on.toggle() })
    }

    func testInFrontThePausedTabKeepsTheKeysForGood() {
        let (keeper, _) = keeper(active: true)
        let tab = FakeTab()
        XCTAssertNil(keeper.paused(tab))
        XCTAssertFalse(keeper.handsBack(tab), "ten seconds up, Search in front: kept")
        XCTAssertTrue(keeper.keeping)
    }

    func testInTheBackgroundTheTenSecondsStillHandThemBack() {
        let (keeper, _) = keeper(active: false)
        let tab = FakeTab()
        _ = keeper.paused(tab)
        XCTAssertTrue(keeper.handsBack(tab))
        XCTAssertNil(keeper.left(), "nothing was kept")
    }

    func testGoingToTheBackgroundHandsBackTheKeptTab() {
        let (keeper, flip) = keeper(active: true)
        let tab = FakeTab()
        _ = keeper.paused(tab)
        XCTAssertFalse(keeper.handsBack(tab))
        flip()
        XCTAssertTrue(keeper.left() === tab)
        XCTAssertNil(keeper.left(), "handed back once")
        XCTAssertFalse(keeper.keeping)
    }

    func testOnlyTheTabPausedLastKeepsThem() {
        let (keeper, _) = keeper(active: true)
        let first = FakeTab(), second = FakeTab()
        _ = keeper.paused(first)
        XCTAssertNil(keeper.paused(second), "the first's ten seconds weren't up: nothing kept yet")
        XCTAssertTrue(keeper.handsBack(first), "paused before another: hands back as before")
        XCTAssertFalse(keeper.handsBack(second))
        let third = FakeTab()
        XCTAssertTrue(keeper.paused(third) === second, "a newer pause takes the keys from the one that kept them")
        XCTAssertFalse(keeper.keeping)
    }

    func testPlayingAgainEndsTheKeeping() {
        let (keeper, flip) = keeper(active: true)
        let tab = FakeTab()
        _ = keeper.paused(tab)
        XCTAssertFalse(keeper.handsBack(tab))
        keeper.played(tab)
        flip()
        XCTAssertNil(keeper.left(), "playing: nothing to hand back on leaving")
    }

    func testAPauseWhileAnotherAppIsInFrontHandsBackAfterItsTenSeconds() {
        let (keeper, flip) = keeper(active: false)
        let tab = FakeTab()
        _ = keeper.paused(tab)
        flip()
        XCTAssertFalse(keeper.handsBack(tab), "Search in front again when they ran out: kept")
    }
}
