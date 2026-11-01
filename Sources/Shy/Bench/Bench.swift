import AppKit
import AuthenticationServices
import SwiftUI
import WebKit

// Test builds only: a release build has no bench (build.sh, `debug`).
#if DEBUG
// A way for a script on this Mac to drive the browser you already have open,
// in tabs of its own, without ever taking the window from you.
//
// Off unless switched on in Settings › General. On, the app listens on a Unix
// socket in its own folder — readable by this user and nobody else, and the
// other end is checked for the same uid before a word is read. One JSON
// object per line in, one per line out, one request per connection. The
// tabs it opens sit at the end of your row with a flask on them, are never
// selected on your behalf, never enter the session or the history, and go
// when the script says so. `./bench` at the root of the repository speaks
// this protocol from the shell.
//
// Pages a script has opened but you are not looking at live in a window of
// their own, off every screen: WebKit lays out and paints a page only when
// it has a size and a window, and a snapshot of a page that has neither is
// a snapshot of nothing.

@MainActor
final class Bench {
    static let shared = Bench()
    private var awake: NSObjectProtocol?

    weak var browser: Browser?
    private var server: LocalSocket?

    /// Where the socket is. Beside the session file, so a test run's bench is
    /// as separate from the real one as everything else it keeps.
    static var socket: URL { Store.file("bench.sock") }

    /// True while something is listening.
    private(set) var running = false

    /// How many times each view that counts itself was built ("hoversweep").
    /// Test runs only; anywhere else counting is one check of a constant.
    private static let counting = Store.testing
    static var bodies: [String: Int] = [:]
    static func count(_ name: String) {
        if counting { bodies[name, default: 0] += 1 }
    }
    /// Each row in the column's own answer to the pointer coming and going,
    /// the very one its onHover gives (SideRow), for "hoversweep". Counted,
    /// since a row built anew can appear before the one it replaces has
    /// gone: the last to appear answers, until the last one goes.
    static var hoverRows: [Tab.ID: (Bool) -> Void] = [:]
    private static var hoverRowsShown: [Tab.ID: Int] = [:]
    static func rowAppeared(_ id: Tab.ID, hover: @escaping (Bool) -> Void) {
        guard counting else { return }
        hoverRows[id] = hover
        hoverRowsShown[id, default: 0] += 1
    }
    static func rowDisappeared(_ id: Tab.ID) {
        guard counting else { return }
        hoverRowsShown[id, default: 1] -= 1
        if hoverRowsShown[id] == 0 { hoverRows[id] = nil; hoverRowsShown[id] = nil }
    }

    /// The key code of a letter on a US keyboard, which is what WebKit reads
    /// alongside the characters; anything else goes as the space bar's.
    static func keyCode(for character: Character) -> UInt16 {
        let codes: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
            "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        ]
        return codes[Character(character.lowercased())] ?? 49
    }

    /// Where the traffic lights are: each one's left edge and its centre's
    /// height from the top, in the window's points.
    static func lights(of window: NSWindow) -> [[Int]] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type in
            guard let button = window.standardWindowButton(type) else { return nil }
            let frame = button.convert(button.bounds, to: nil)
            return [Int(frame.minX.rounded()), Int((window.frame.height - frame.midY).rounded())]
        }
    }

    // MARK: - who switched it on

    /// Whether the bench was switched on in Settings, by you (see SwitchMark).
    @MainActor
    enum Consent {
        static var given: Bool { SwitchMark.given("consent") }
        static func grant() { SwitchMark.grant("consent") }
        static func revoke() { SwitchMark.revoke("consent") }
    }

    // MARK: - starting and stopping

    func start(for browser: Browser) {
        guard !running else { return }
        self.browser = browser
        if Store.testing { Bench.watchScreens() }
        // Nor App Nap, which a test run behind other windows falls into.
        if Store.testing, !Store.measuring, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Bench")
        }
        let server = LocalSocket(at: Bench.socket, decorate: { answer in
            var answer = answer
            if !Bench.caught.isEmpty { answer["onScreen"] = Bench.caught }
            return answer
        }) { [weak self] request, answer in self?.handle(request, answer) }
        guard server.start() else { return }
        self.server = server
        running = true
    }

    func stop() {
        guard running else { return }
        server?.stop()
        server = nil
        running = false
        // The tabs a script left open go with it.
        if let browser {
            for tab in browser.tabs where tab.bench { browser.close(tab) }
        }
    }

    // MARK: - the commands

    private func handle(_ request: [String: Any], _ given: @escaping ([String: Any]) -> Void) {
        // One answer, and always one: a page that never replies to a script
        // would otherwise hold the bench — every later command waits behind it.
        var answered = false
        let answer: ([String: Any]) -> Void = { reply in
            guard !answered else { return }
            answered = true
            given(reply)
        }
        let patience = (request["do"] as? String) == "wait" ? (request["seconds"] as? Double ?? 30) + 5 :
            (request["do"] as? String) == "import-file" ? (request["timeout"] as? Double ?? 120) : 25
        DispatchQueue.main.asyncAfter(deadline: .now() + patience) { answer(["error": "no answer within \(Int(patience)) s"]) }
        // --window N: the Nth window's browser, oldest first; the first
        // window's otherwise.
        let picked = (request["window"] as? Int).flatMap { n in Browsers.all.indices.contains(n - 1) ? Browsers.all[n - 1] : nil }
        let live = browser.flatMap { b in Browsers.all.contains { $0 === b } ? b : nil }
        guard let browser = picked ?? live ?? Browsers.primary else {
            answer(["error": "no browser"])
            return
        }
        let verb = request["do"] as? String ?? ""

        // With pages shown (`pages on`) the app is no longer hidden: whatever
        // opens or brings back a window would put it on the screen. Refused
        // until `pages off`; listing and closing windows stay.
        if Bench.pagesShown {
            let action = request["action"] as? String ?? "list"
            if ["little", "towindow"].contains(verb) || (verb == "windows" && !["list", "close"].contains(action)) {
                answer(["error": "pages are on: run `pages off` before opening or bringing back a window"])
                return
            }
        }

        switch verb {
        case "layouts", "tabs", "open", "go", "shut", "handover", "takeback", "approve", "agentpage", "close", "wait", "sleep", "openmark", "pin", "select", "text", "nowplaying", "eval", "tap", "click", "type", "submit", "towindow", "quit", "windows", "middle", "linkmenu", "shot":
            tabCommand(verb, request, browser, answer)

        case "developer", "probe", "press", "key", "resize", "hoversweep", "hit", "field", "switcher", "recording":
            inputCommand(verb, request, browser, answer)

        case "suggest", "sitesearch", "bookmark", "dropdown", "marks", "import-file", "remove-folder", "passwords", "history", "import-file-start", "import-file-status", "import-file-cancel", "tab-type", "menus", "textcheck", "menu", "keyeq", "image-data":
            libraryCommand(verb, request, browser, answer)

        case "find", "translate", "visible", "notifications", "answer", "accounts":
            pageCommand(verb, request, browser, answer)

        case "peek", "pull", "magnify", "wheel", "place", "folder", "tospace", "window", "pages", "picture", "film", "pdf", "consent", "fold", "little", "site", "column", "player", "space":
            windowCommand(verb, request, browser, answer)

        case "split", "ui", "sidepanel", "popups":
            interfaceCommand(verb, request, browser, answer)

        case "extensions", "ext-add", "ext-folder", "ext-press", "ext-remove", "ext-reload", "ext-page", "ext-popup", "ext-menu", "ext-pin", "ext-shot", "ext-answer", "ext-enable", "ext-private", "capture", "capture-stop":
            guard #available(macOS 15.4, *) else {
                answer(["error": "extensions need macOS 15.4"])
                return
            }
            extensionCommand(verb, request, browser: browser, answer)

        default:
            answer(["error": "unknown command “\(verb)”", "commands": [
                "tabs", "open", "go", "openmark", "developer", "close", "wait", "sleep", "select", "text", "nowplaying", "eval", "click", "type", "submit", "shot", "probe", "key", "textcheck", "resize", "hit", "film", "player", "window", "pages", "picture", "pdf", "place", "folder", "tospace", "field", "bookmark", "marks", "menu", "keyeq", "fill", "pin", "middle", "windows", "quit", "towindow", "pull", "magnify", "wheel", "space", "split", "strip", "column", "fold", "consent", "update", "site", "little", "ui", "import-file", "import-file-start", "import-file-status", "import-file-cancel", "remove-folder", "passwords", "accounts", "find", "answer", "visible", "notifications", "popups", "suggest", "translate", "handover", "approve", "agentpage", "shut",
            ]])
        }
    }

    /// A small model bridge for offline split regressions. The browser model is
    /// the system under test; this command is deliberately unavailable in the
    /// browser somebody is using because its actions move and close tabs.
    /// Where a page lent to the recording pill was before, for `recording`.
    static var lentFrom: [ObjectIdentifier: WeakView] = [:]
    final class WeakView {
        weak var view: NSView?
        init(_ view: NSView?) { self.view = view }
    }

    /// The view a `split mouse … to: view` press landed on, for the rest of it.
    weak var pressed: NSView?

    var room: NSWindow?
}

#endif
