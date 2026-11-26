import SwiftUI

// Over the page of a split under the pointer, with Settings › Keyboard &
// Mouse › Controls over a page in Split View on: a small capsule at its top
// with what was only in the divider's right-click menu and the Tabs menu.
// Move the page left or right, take it out of the split as a tab of its own,
// or close it; the others stay together. Each button does what its menu item
// does, so the two never disagree.

/// The capsule itself, over the top of one page of a split.
struct SplitPaneControls: View {
    @ObservedObject var browser: Browser
    let tab: Tab
    /// Where the page stands in its split, from the left, of `count`.
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: 2) {
            Door(icon: "chevron.left", help: "Move Left") { browser.moveInSplit(tab, by: -1) }
                .disabled(index == 0)
                .opacity(index == 0 ? 0.35 : 1)
            Door(icon: "chevron.right", help: "Move Right") { browser.moveInSplit(tab, by: 1) }
                .disabled(index == count - 1)
                .opacity(index == count - 1 ? 0.35 : 1)
            // Remove from Split View in the tab's menu; of a pair, the same
            // as Separate Split Tabs.
            Door(icon: "rectangle.portrait.and.arrow.right", help: "Remove from Split View") { browser.leaveSplit(tab) }
            // As the row's cross: a grouped page is put away rather than closed.
            Door(icon: "xmark", help: browser.putsAway(tab) ? "Put Away" : "Close Tab") { browser.closeTab(tab) }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Capsule(style: .continuous).fill(.regularMaterial))
        .overlay(Capsule(style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}
