import SwiftUI

/// The row at the bottom of the column. Never wider than the column: wider,
/// the column took its width, and centred in its own frame it slid half the
/// overflow off each side (#535). The space's door, the puzzle, bookmarks and
/// downloads stay put; the pinned extensions that don't fit give way, from
/// the last, and are still in the puzzle's list.
struct SideFoot: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var fetches: Fetches

    var body: some View {
        HStack(spacing: 2) {
            SpaceDot(browser: browser)
            ExtensionSlot(edge: .trailing, room: room)
            BookmarkDoor(browser: browser, arrowEdge: .trailing)
            // Only while a download is running, and a moment after.
            FetchDoor(browser: browser, fetches: fetches)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    /// How many pinned extensions fit beside the doors that stay. Every door
    /// is 26 points, with 2 between them.
    private var room: Int {
        let door: CGFloat = 26 + 2
        var kept = 3  // the puzzle, bookmarks and the space
        if FetchDoor.shows(fetches, prefs) { kept += 1 }
        let free = prefs.sideWidth - 2 * 10 + 2 - CGFloat(kept) * door
        return max(0, Int((free / door).rounded(.down)))
    }
}
