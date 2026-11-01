// Scrolling with the middle button, as on Windows: a click of the wheel on
// a page (not on a link, which it still opens in a new tab) leaves a mark
// where it was, and the page scrolls towards the pointer, faster the
// further away it is. Another click, Escape or the wheel stops it; held down
// and dragged, it stops when the button is let go.
//
// Off unless turned on in Settings › General. Done in the page, which knows
// what is under the pointer and which part of it scrolls.

enum AutoScroll {
    /// Settings › General › Scroll with the middle button.
    @MainActor static var on = false

    /// For a page already up when it is turned off.
    static let off = "window.__shyAutoScrollOff = true;"

    static let script = Scripts.load("auto-scroll")
}
