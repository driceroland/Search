import Foundation

// Live video that doesn't jump.
//
// A live player keeps close to the broadcast by nudging its speed. X's goes
// to 1.04 when it has fallen behind and back to 1 once it has caught up,
// every few seconds for as long as you watch. In WebKit on macOS, every one
// of those steps across exactly 1 costs a pause: CoreMedia plays speed 1 on
// a path of its own, and moving on or off it tears the sound down and builds
// it again, with the picture held still until the sound is back — about
// 50 ms most times, more now and then. That was the little jump every few
// seconds on a live stream. Safari's engine is the same one, and so is the
// pause.
//
// Between two speeds that are both off 1, the sound follows without a break.
// So once a page has used a catch-up speed on a video, a 1 it asks for
// afterwards is played at 1.0001 — a tenth of a millisecond a second, nothing
// anyone can see or hear — and the page still reads back the 1 it asked for.
// A speed picked from a menu (1.25, 1.5, 2) never starts it, and a page that
// never nudges is never touched. Measured on a hidden probe with X's pattern:
// eleven pauses in 26 seconds before, one after — the first nudge.

enum LiveRate {
    /// In the page's own world, before any of its scripts: the player sets
    /// the speed through this very property.
    static let script = Scripts.load("live-rate")
}
