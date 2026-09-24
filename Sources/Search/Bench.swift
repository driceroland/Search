import AppKit
import AuthenticationServices
import SwiftUI
import WebKit

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

    private weak var browser: Browser?
    private var listener: Int32 = -1
    private var accepting: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]

    /// Where the socket is. Beside the session file, so a test run's bench is
    /// as separate from the real one as everything else it keeps.
    static var socket: URL { Store.file("bench.sock") }

    /// True while something is listening.
    private(set) var running = false

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

    // MARK: - starting and stopping

    func start(for browser: Browser) {
        guard !running else { return }
        self.browser = browser
        // Nor App Nap, which a test run behind other windows falls into.
        if Store.testing, !Store.measuring, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Bench")
        }
        let path = Bench.socket.path
        try? FileManager.default.createDirectory(
            at: Bench.socket.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        unlink(path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < room else { close(fd); return }
        withUnsafeMutablePointer(to: &address.sun_path) { sun in
            sun.withMemoryRebound(to: CChar.self, capacity: room) { bytes in
                _ = strlcpy(bytes, path, room)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            unlink(path)
            return
        }
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        accepting = source
        listener = fd
        running = true
    }

    func stop() {
        guard running else { return }
        accepting?.cancel()
        accepting = nil
        close(listener)
        listener = -1
        unlink(Bench.socket.path)
        clients.values.forEach { $0.drop() }
        clients = [:]
        running = false
        // The tabs a script left open go with it.
        if let browser {
            for tab in browser.tabs where tab.bench { browser.close(tab) }
        }
    }

    private func accept() {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        // Only this user. The file mode already says so; this says it again,
        // for the day the folder's permissions are not what they were.
        var uid = uid_t(0)
        var gid = gid_t(0)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            return
        }
        let client = Client(fd: fd) { [weak self] request, answer in
            self?.handle(request, answer)
        } gone: { [weak self] fd in
            self?.clients[fd] = nil
        }
        clients[fd] = client
    }

    // MARK: - one connection

    /// Reads until a newline, hands the line up, writes the answer, closes.
    private final class Client {
        let fd: Int32
        private var bytes = Data()
        private let source: DispatchSourceRead
        private let handle: ([String: Any], @escaping ([String: Any]) -> Void) -> Void
        private let gone: (Int32) -> Void
        private var answered = false

        init(
            fd: Int32,
            handle: @escaping ([String: Any], @escaping ([String: Any]) -> Void) -> Void,
            gone: @escaping (Int32) -> Void
        ) {
            self.fd = fd
            self.handle = handle
            self.gone = gone
            fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in self?.read() }
            source.resume()
        }

        private func read() {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 {
                if count == 0 || errno != EAGAIN { drop() }
                return
            }
            bytes.append(contentsOf: chunk[0..<count])
            // A line that never ends is not a request.
            if bytes.count > 4_000_000 {
                say(["error": "request too long"])
                return
            }
            guard let newline = bytes.firstIndex(of: 0x0A) else { return }
            let line = bytes[bytes.startIndex..<newline]
            bytes = Data()
            source.cancel()
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                say(["error": "not a JSON object"])
                return
            }
            handle(json) { [weak self] answer in self?.say(answer) }
        }

        private func say(_ answer: [String: Any]) {
            guard !answered else { return }
            answered = true
            var out = (try? JSONSerialization.data(withJSONObject: answer)) ?? Data("{\"error\":\"unwritable answer\"}".utf8)
            out.append(0x0A)
            out.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                    if n <= 0 {
                        if errno == EAGAIN { usleep(2000); continue }
                        break
                    }
                    sent += n
                }
            }
            drop()
        }

        func drop() {
            if !source.isCancelled { source.cancel() }
            close(fd)
            gone(fd)
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
        let patience = (request["do"] as? String) == "wait" ? (request["seconds"] as? Double ?? 30) + 5 : 25
        DispatchQueue.main.asyncAfter(deadline: .now() + patience) { answer(["error": "no answer within \(Int(patience)) s"]) }
        guard let browser else {
            answer(["error": "no browser"])
            return
        }
        let verb = request["do"] as? String ?? ""

        switch verb {
        case "tabs":
            answer(["tabs": browser.tabs.map(describe)])

        case "open":
            guard let url = (request["url"] as? String).flatMap(Address.url(from:)) else {
                answer(["error": "open needs a url"])
                return
            }
            let tab = browser.benchOpen(url)
            house(tab)
            answer(describe(tab))

        case "go":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            guard let url = (request["url"] as? String).flatMap(Address.url(from:)) else {
                answer(["error": "go needs a url"])
                return
            }
            tab.go(to: url)
            answer(describe(tab))

        case "close":
            if (request["id"] as? String) == "all" {
                let mine = browser.tabs.filter { $0.bench }
                mine.forEach { browser.close($0) }
                answer(["closed": mine.count])
                return
            }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            guard tab.bench else {
                answer(["error": "not a bench tab — only tabs the bench opened can be closed from here"])
                return
            }
            browser.close(tab)
            answer(["closed": 1])

        case "wait":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            let limit = Date().addingTimeInterval(request["seconds"] as? Double ?? 20)
            wait(for: tab, until: limit, answer)

        case "sleep":
            // Now rather than after half an hour, but past every other check
            // a tab has to clear — the answer says which one kept it awake.
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            browser.sleep(tab) { said in answer(["said": said, "asleep": tab.asleep]) }

        case "select":
            // Picking a tab takes the window over, which the bench never does
            // to someone using it: only on a SEARCH_PROBE run.
            guard Store.testing else {
                answer(["error": "select only works on a --test run — it would take your window over"])
                return
            }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            browser.select(tab)
            answer(describe(tab))

        case "text":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            house(tab)
            tab.web.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, error in
                MainActor.assumeIsolated {
                    if let error { answer(["error": error.localizedDescription]); return }
                    var text = (value as? String) ?? ""
                    var cut = false
                    if text.count > 120_000 { text = String(text.prefix(120_000)); cut = true }
                    answer(["text": text, "truncated": cut, "url": tab.address?.absoluteString ?? "", "title": tab.title])
                }
            }

        case "eval":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            guard let js = request["js"] as? String else { answer(["error": "eval needs js"]); return }
            house(tab)
            tab.web.evaluateJavaScript(js) { value, error in
                MainActor.assumeIsolated {
                    if let error { answer(["error": error.localizedDescription]); return }
                    answer(["value": Bench.plain(value)])
                }
            }

        case "tap":
            // A real click on an element, delivered to the view as mouse
            // events — trusted, as a hand's is — where `click` only runs
            // element.click() in the page, which a password manager, for one,
            // is right to ignore. `text=Sign in` picks a button or link by its
            // words. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "tap only works on a --test run — it would click in your page"]); return }
            guard let tab = find(request, in: browser), let selector = request["selector"] as? String else { answer(missing(request)); return }
            house(tab)
            let view = tab.web
            view.evaluateJavaScript(Bench.locate(selector)) { value, error in
                MainActor.assumeIsolated {
                    guard let point = value as? [Double], point.count == 2, let window = view.window else {
                        answer(["error": error?.localizedDescription ?? "nothing matches \(selector)"])
                        return
                    }
                    let local = NSPoint(x: point[0], y: view.isFlipped ? point[1] : view.bounds.height - point[1])
                    let spot = view.convert(local, to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        guard let event = NSEvent.mouseEvent(
                            with: type, location: spot, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil,
                            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                        ) else { continue }
                        if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
                    }
                    answer(["ok": true, "at": point.map { Int($0) }])
                }
            }

        case "click", "type", "submit":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            guard let selector = request["selector"] as? String else {
                answer(["error": "\(verb) needs a selector"])
                return
            }
            house(tab)
            let text = request["text"] as? String ?? ""
            tab.web.evaluateJavaScript(Bench.act(verb, selector: selector, text: text)) { value, error in
                MainActor.assumeIsolated {
                    if let error { answer(["error": error.localizedDescription]); return }
                    let said = (value as? String) ?? "?"
                    answer(said == "ok" ? ["ok": true] : ["error": said])
                }
            }

        case "shot":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            house(tab)
            let path = (request["path"] as? String)
                ?? NSTemporaryDirectory() + "search-bench-\(Bench.short(tab)).png"
            let width = request["width"] as? Double
            shoot(tab, to: URL(fileURLWithPath: path), width: width, answer)

        case "probe":
            // The state of the window itself, for the bug that is not in a
            // page: which panels are up, whether something modal has the
            // app, and every window the app owns.
            var out: [String: Any] = [
                "settings": browser.tuning,
                "welcome": browser.welcoming,
                "passwords": browser.managing,
                "history": browser.recalling,
                "downloads": browser.hoarding,
                "bookmarks": browser.bookmarking,
                "field": browser.editing,
                "suggesting": browser.suggesting != nil,
                "offering": browser.offering != nil,
                "modal": NSApp.modalWindow.map { "\(type(of: $0)) “\($0.title)”" } ?? "",
                "look": browser.prefs.look.rawValue,
                "appearance": NSApp.appearance?.name.rawValue ?? "system",
                "key": NSApp.keyWindow.map { "\(type(of: $0)) “\($0.title)”" } ?? "",
            ]
            out["windows"] = NSApp.windows.map { window -> [String: Any] in
                [
                    "kind": "\(type(of: window))",
                    "title": window.title,
                    "visible": window.isVisible,
                    "level": window.level.rawValue,
                    "frame": [Int(window.frame.minX), Int(window.frame.minY), Int(window.frame.width), Int(window.frame.height)],
                    "number": window.windowNumber,
                ]
            }
            if let window = Links.window { out["lights"] = Bench.lights(of: window) }
            out["keysQuieted"] = PageView.quieted
            // Settings › General › Web Inspector, as each page's WebKit has it.
            let asked = NSSelectorFromString("_developerExtrasEnabled")
            out["inspector"] = browser.tabs.compactMap { tab -> Bool? in
                guard let preferences = tab.built?.configuration.preferences, preferences.responds(to: asked) else { return nil }
                return preferences.value(forKey: "developerExtrasEnabled") as? Bool
            }
            // Settings › General › Pages at 120 Hz, as each page's WebKit has
            // it: true is held near 60, WebKit's own default.
            out["prefersNear60FPS"] = browser.tabs.compactMap { tab -> Bool? in
                guard let preferences = tab.built?.configuration.preferences else { return nil }
                return FrameRate.prefersNear60(preferences)
            }
            // The column folded away, out for a look, and the lights with it (see Fold.swift).
            out["folded"] = browser.folded
            out["peeking"] = browser.peeking
            out["sideHides"] = browser.prefs.sideHides
            out["lightsHidden"] = Fold.titlebar?.isHidden ?? false
            // Whether this Mac lets the browser use its passkeys at all — the
            // one-time permission macOS asks a browser other than Safari for.
            switch ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials {
            case .authorized: out["passkeyAccess"] = "authorized"
            case .denied: out["passkeyAccess"] = "denied"
            default: out["passkeyAccess"] = "notDetermined"
            }
            out["passkeyAsks"] = Passkeys.asked
            out["passkeyLast"] = Passkeys.last
            answer(out)

        case "press":
            // A key pressed on the app as a whole, through its event queue —
            // so its own shortcuts see it first, as they do a real press;
            // `key` goes straight to a page instead. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "press only works on a --test run — it would press keys in your browser"]); return }
            guard let code = request["code"] as? Int, let chars = request["chars"] as? String
            else { answer(["error": "press needs a key code and the characters it types"]); return }
            var flags: NSEvent.ModifierFlags = []
            for name in request["mods"] as? [String] ?? [] {
                switch name {
                case "cmd": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "ctrl": flags.insert(.control)
                case "opt": flags.insert(.option)
                default: break
                }
            }
            // "repeat": the press a key held down sends again and again.
            let repeats = (request["mods"] as? [String] ?? []).contains("repeat")
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: Links.window?.windowNumber ?? 0, context: nil,
                    characters: chars, charactersIgnoringModifiers: chars,
                    isARepeat: repeats && type == .keyDown, keyCode: UInt16(code)
                ) else { continue }
                NSApp.postEvent(event, atStart: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                answer(["active": browser.active.map { String($0.id.uuidString.prefix(8)).lowercased() } ?? ""])
            }

        case "key":
            // Keys pressed on a tab, as real key events handed to its view —
            // for what the page does with them, and what comes back unused.
            // Only on a SEARCH_PROBE run: it types into a page.
            guard Store.testing else { answer(["error": "key only works on a --test run — it would type into your page"]); return }
            guard let tab = find(request, in: browser), let text = request["text"] as? String else { answer(missing(request)); return }
            house(tab)
            let view = tab.web
            view.window?.makeFirstResponder(view)
            let before = PageView.quieted
            // What WebKit sends back through the app because the page didn't
            // use it: a key press seen here again after it was handed over.
            var pressed: [NSEvent] = []
            var resent = 0
            let watch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if pressed.contains(where: { PageView.same($0, event) }) { resent += 1 }
                return event
            }
            for character in text {
                let chars = String(character)
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    guard let event = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: view.window?.windowNumber ?? 0, context: nil,
                        characters: chars, charactersIgnoringModifiers: chars,
                        isARepeat: false, keyCode: Bench.keyCode(for: character)
                    ) else { continue }
                    if type == .keyDown { pressed.append(event); view.keyDown(with: event) } else { view.keyUp(with: event) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let watch { NSEvent.removeMonitor(watch) }
                answer(["typed": text, "sentBackUnused": resent, "quieted": PageView.quieted - before])
            }

        case "resize":
            // The window taken to another size in steps, a frame apart, the
            // way a hand drags its corner — for what that does to the title
            // bar. It moves the window, so only on a SEARCH_PROBE run.
            guard Store.testing else {
                answer(["error": "resize only works on a --test run — it would move your window"])
                return
            }
            guard let window = Links.window,
                  let width = request["width"] as? Double, let height = request["height"] as? Double
            else { answer(["error": "resize needs a width and a height"]); return }
            let steps = max(1, request["steps"] as? Int ?? 12)
            let from = window.frame
            func step(_ n: Int) {
                let t = CGFloat(n) / CGFloat(steps)
                var frame = from
                frame.size.width = from.width + (CGFloat(width) - from.width) * t
                frame.size.height = from.height + (CGFloat(height) - from.height) * t
                frame.origin.y = from.maxY - frame.height
                window.setFrame(frame, display: true)
                if n < steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { step(n + 1) }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        answer(["size": [Int(window.frame.width), Int(window.frame.height)], "lights": Bench.lights(of: window)])
                    }
                }
            }
            step(1)

        case "hit":
            // What a press at a point of the window lands on, and whether
            // AppKit would carry the window off on a drag from there — the
            // question behind a tab that moved the window instead of itself.
            // Only looked at, unless asked for a double-click.
            guard let window = Links.window, let x = request["x"] as? Double, let y = request["y"] as? Double,
                  let frame = window.contentView?.superview
            else { answer(["error": "hit needs an x and a y"]); return }
            let point = NSPoint(x: x, y: Double(window.frame.height) - y)
            let hit = frame.hitTest(frame.convert(point, from: nil))
            if request["middle"] as? Bool == true {
                // The middle button pressed and let go there. A probe's window
                // is hidden and takes no events through the app, so they are
                // handed to the view that catches the middle button over the
                // tabs (MiddleClick in TabBar.swift), the topmost one there.
                guard Store.testing else { answer(["error": "hit … middle only works on a --test run"]); return }
                func catcher(in view: NSView) -> NSView? {
                    for sub in view.subviews.reversed() { if let found = catcher(in: sub) { return found } }
                    guard String(describing: type(of: view)).contains("Catch") else { return nil }
                    return view.convert(view.bounds, to: nil).contains(point) ? view : nil
                }
                guard let target = catcher(in: frame) else { answer(["error": "nothing catches the middle button there"]); return }
                let before = browser.tabs.count
                for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp] {
                    guard let event = NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                        pressure: type == .otherMouseUp ? 0 : 1
                    ) else { continue }
                    if type == .otherMouseDown { target.otherMouseDown(with: event) } else { target.otherMouseUp(with: event) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    answer(["tabsBefore": before, "tabsAfter": browser.tabs.count])
                }
                return
            }
            if request["double"] as? Bool == true {
                // A double-click there, handed to the view under it — through
                // the window it would never arrive, the probe being in the
                // back. On a test run only, and meant for a probe started
                // hidden, where the window changing size shows on no screen.
                guard Store.testing else { answer(["error": "hit … double only works on a --test run"]); return }
                let before = window.frame
                func event(_ type: NSEvent.EventType, _ clicks: Int) -> NSEvent? {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                                       pressure: type == .leftMouseUp ? 0 : 1)
                }
                for clicks in [1, 2] {
                    if let down = event(.leftMouseDown, clicks) { hit?.mouseDown(with: down) }
                    if let up = event(.leftMouseUp, clicks) { hit?.mouseUp(with: up) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    let after = window.frame
                    answer(["view": hit.map { String("\(type(of: $0))".prefix(60)) } ?? "",
                            "before": [Int(before.width), Int(before.height)], "after": [Int(after.width), Int(after.height)],
                            "zoomed": window.isZoomed])
                }
                return
            }
            answer([
                "view": hit.map { String("\(type(of: $0))".prefix(60)) } ?? "",
                "canMoveWindow": hit?.mouseDownCanMoveWindow ?? false,
                "windowMovable": window.isMovable,
                "titleBar": y <= Double(window.frame.height - window.contentLayoutRect.height),
            ])

        case "field":
            // Text put into the address field the way a paste puts it — the
            // whole of it replacing what is selected — or typed a character
            // at a time, each timed from the moment it goes in to the moment
            // the run loop next rests: the list worked out, SwiftUI's update
            // and Core Animation's commit included. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "field only works on a --test run — it would type into your browser"]); return }
            guard let text = request["text"] as? String, !text.isEmpty else { answer(["error": "field needs some text"]); return }
            let pieces = request["type"] as? Bool == true ? text.map(String.init) : [text]
            if browser.fieldShowing { browser.askFocus() } else { browser.edit() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let field = Bench.addressField(in: Links.window?.contentView),
                      let editor = field.currentEditor() as? NSTextView
                else { answer(["error": "the address field has no editor"]); return }
                var times: [[Double]] = []
                @MainActor func next(_ index: Int) {
                    guard index < pieces.count else {
                        var out: [String: Any] = ["field": field.stringValue, "typed": browser.typed, "offers": browser.offers.map(\.key), "ms": times]
                        guard request["go"] as? Bool == true, let tab = browser.active else { answer(out); return }
                        // Then Return, as the field's own delegate takes it:
                        // how long until WebKit is loading the page.
                        out["viewWasBuilt"] = tab.built != nil
                        let start = CACurrentMediaTime()
                        var loading: Double?
                        let watch = tab.$loading.first(where: { $0 }).sink { _ in loading = (CACurrentMediaTime() - start) * 1000 }
                        browser.submit()
                        out["returned"] = (CACurrentMediaTime() - start) * 1000
                        Bench.whenResting(since: start) { rested in
                            out["rested"] = rested
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                watch.cancel()
                                out["loading"] = loading ?? -1
                                answer(out)
                            }
                        }
                        return
                    }
                    let start = CACurrentMediaTime()
                    editor.insertText(pieces[index], replacementRange: NSRange(location: NSNotFound, length: 0))
                    let inserted = (CACurrentMediaTime() - start) * 1000
                    Bench.whenResting(since: start) { rested in
                        times.append([inserted, rested])
                        DispatchQueue.main.async { next(index + 1) }
                    }
                }
                next(0)
            }

        case "bookmark":
            // A bookmark picked from the button's list, through the same
            // call the list makes: how long until WebKit is loading it, and
            // until the run loop rests. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "bookmark only works on a --test run — it would load a page in your tab"]); return }
            guard let url = (request["url"] as? String).flatMap(Address.url(from:)) else { answer(["error": "bookmark needs a url"]); return }
            // "new": into a new tab, whose page has yet to be built.
            if request["new"] as? Bool == true { browser.newTab() }
            guard let tab = browser.active else { answer(["error": "no tab to open it in"]); return }
            browser.bookmarksOpen = true
            let built = tab.built != nil
            var loading: Double?
            let start = CACurrentMediaTime()
            let watch = tab.$loading.first(where: { $0 }).sink { _ in loading = (CACurrentMediaTime() - start) * 1000 }
            browser.pickBookmark(url)
            let returned = (CACurrentMediaTime() - start) * 1000
            Bench.whenResting(since: start) { rested in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    watch.cancel()
                    answer(["returned": returned, "loading": loading ?? -1, "rested": rested,
                            "viewWasBuilt": built, "listStillOpen": browser.bookmarksOpen, "sameTab": browser.active?.id == tab.id])
                }
            }

        case "menu":
            // The Bookmarks menu as it is about to open: the menu bar
            // told it is being tracked, SwiftUI's own update run on it, its
            // first folder opened — then what each holds. Only on a
            // SEARCH_PROBE run; nothing is drawn.
            guard Store.testing else { answer(["error": "menu only works on a --test run"]); return }
            guard let main = NSApp.mainMenu, let menu = main.items.first(where: { $0.title == "Bookmarks" })?.submenu
            else { answer(["error": "no Bookmarks menu"]); return }
            let before = menu.items.count
            let wrapped = menu.delegate.map { "\(type(of: $0))" } ?? "none"
            let start = CACurrentMediaTime()
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: main)
            let filled = (CACurrentMediaTime() - start) * 1000
            menu.delegate?.menuNeedsUpdate?(menu)
            let folder = menu.items.first { $0.submenu != nil && $0.tag != 0 }?.submenu
            if let folder { folder.delegate?.menuNeedsUpdate?(folder) }
            // "open": the first bookmark in that folder picked, as a click would.
            if request["open"] as? Bool == true, let folder,
               let index = folder.items.firstIndex(where: { $0.representedObject is URL }) {
                folder.performActionForItem(at: index)
            }
            answer(["delegate": wrapped, "before": before, "after": menu.items.count, "ours": BookmarkMenu.shared.count, "fillMs": filled,
                    "titles": menu.items.prefix(8).map { $0.isSeparatorItem ? "—" : $0.title },
                    "firstFolder": folder?.items.prefix(4).map(\.title) ?? [],
                    "active": browser.active?.address?.absoluteString ?? ""])

        case "place":
            // A tab put at another place in the row, as a drag would.
            guard let id = request["id"] as? String, let to = request["to"] as? Int,
                  let tab = browser.tabs.first(where: { Bench.short($0) == id })
            else { answer(["error": "place needs a tab id and an index"]); return }
            browser.move(tab, to: to)
            answer(["at": browser.tabs.firstIndex { $0.id == tab.id } ?? -1])

        case "window":
            // The browser's window, when a probe started hidden came up
            // without one: the Window menu's own item for it.
            guard Store.testing else { answer(["error": "window only works on a --test run"]); return }
            if Links.window?.contentView != nil, NSApp.windows.contains(where: { $0 === Links.window }) {
                answer(["window": "there"])
                return
            }
            let items = NSApp.mainMenu?.items.first { $0.submenu?.title == "Window" }?.submenu?.items ?? []
            guard let item = items.first(where: { $0.title == "Search" }), let action = item.action else {
                answer(["error": "no Search item in the Window menu", "items": items.map(\.title)])
                return
            }
            NSApp.sendAction(action, to: item.target, from: item)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                answer(["window": NSApp.windows.map { "\(type(of: $0))" }, "hidden": NSApp.isHidden])
            }

        case "pages":
            // Pages that WebKit will paint, for `picture`, from a probe started
            // hidden: the app shown again without coming forward, but only
            // once its windows are all off the screen — the browser's own put
            // away, the bench's room far off every screen. Anything of the
            // app's that would show on a screen and the app is hidden again.
            guard Store.testing, let window = Links.window else { answer(["error": "pages only works on a --test run"]); return }
            func onScreen(_ w: NSWindow) -> Bool { NSScreen.screens.contains { $0.frame.intersects(w.frame) } }
            if request["on"] as? Bool == true {
                _ = room ?? makeRoom()
                window.orderOut(nil)
                for other in NSApp.windows where other !== room && onScreen(other) { other.orderOut(nil) }
                NSApp.unhideWithoutActivation()
                let showing = NSApp.windows.filter { $0.isVisible && onScreen($0) }
                if !showing.isEmpty {
                    NSApp.hide(nil)
                    answer(["error": "a window would have shown: \(showing.map { "\(type(of: $0))" })"])
                    return
                }
                answer(["pages": true])
            } else {
                NSApp.hide(nil)
                window.orderFront(nil)
                answer(["pages": false])
            }

        case "picture":
            // The whole window as a picture — the app's own drawing, with each
            // page on screen put in as WebKit pictures it — from a probe
            // started hidden, so nothing shows on anybody's screen. For the
            // images on the site.
            guard Store.testing else { answer(["error": "picture only works on a --test run"]); return }
            guard let window = Links.window, let frame = window.contentView?.superview,
                  let path = request["path"] as? String, !path.isEmpty
            else { answer(["error": "picture needs a path"]); return }
            func pages(in view: NSView) -> [WKWebView] {
                if let web = view as? WKWebView { return [web] }
                return view.subviews.flatMap(pages)
            }
            // The page, when WebKit paints (see `pages`): the tab's address
            // loaded afresh in a view of its own in the bench's room, sized
            // as the page is, and pictured there.
            if !NSApp.isHidden, request["page"] as? Bool != false, let tab = browser.active, let address = tab.address,
               let live = tab.built, live.window === window {
                let rect = live.convert(live.bounds, to: nil)
                guard let chrome = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { answer(["error": "nothing drawn"]); return }
                frame.cacheDisplay(in: frame.bounds, to: chrome)
                let stand = room ?? makeRoom()
                // The tab's own page by default — as it is, reader view or
                // things hidden included — lent to the room for the picture
                // and handed back; or, with `fresh`, the address loaded anew.
                let fresh = request["fresh"] as? Bool == true
                let home = live.superview
                let homeFrame = live.frame
                let page = fresh ? WKWebView(frame: NSRect(origin: .zero, size: rect.size), configuration: Web.configuration()) : live
                if !fresh {
                    live.removeFromSuperview()
                    live.frame = NSRect(origin: .zero, size: rect.size)
                    live.alphaValue = 1
                }
                func giveBack() {
                    guard !fresh else { page.removeFromSuperview(); return }
                    live.removeFromSuperview()
                    live.frame = homeFrame
                    home?.addSubview(live)
                }
                // A window off every screen counts as covered, and WebKit
                // paints nothing it thinks nobody sees; this one is told to
                // paint regardless.
                let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
                if page.responds(to: occlusion) {
                    typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
                    unsafeBitCast(page.method(for: occlusion), to: Setter.self)(page, occlusion, false)
                }
                stand.contentView?.addSubview(page)
                if fresh { page.load(URLRequest(url: address)) }
                let settle = request["settle"] as? Double ?? 3
                func whenLoaded(_ tries: Int) {
                    guard page.isLoading, tries > 0 else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                            page.takeSnapshot(with: nil) { image, _ in
                                MainActor.assumeIsolated {
                                    giveBack()
                                    let drawn = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: chrome.pixelsWide, pixelsHigh: chrome.pixelsHigh,
                                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                                    guard let drawn else { answer(["error": "nothing drawn"]); return }
                                    drawn.size = frame.bounds.size
                                    NSGraphicsContext.saveGraphicsState()
                                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: drawn)
                                    chrome.draw(in: frame.bounds)
                                    image?.draw(in: rect)
                                    NSGraphicsContext.restoreGraphicsState()
                                    do {
                                        try drawn.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                                        answer(["saved": path, "pixels": [drawn.pixelsWide, drawn.pixelsHigh], "page": [Int(rect.minX), Int(frame.bounds.height - rect.maxY), Int(rect.width), Int(rect.height)],
                                                "points": [Int(frame.bounds.width), Int(frame.bounds.height)], "lights": Bench.lights(of: window)])
                                    } catch { answer(["error": error.localizedDescription]) }
                                }
                            }
                        }
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { whenLoaded(tries - 1) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { whenLoaded(80) }
                return
            }
            let shown = pages(in: frame).filter { !$0.isHidden && $0.alphaValue > 0 && !$0.frame.isEmpty }
            var taken: [(WKWebView, NSImage)] = []
            var left = shown.count
            func draw() {
                // Each page's picture where the page is, the page itself put
                // aside for the one drawing.
                var covers: [NSImageView] = []
                for (web, image) in taken {
                    let cover = NSImageView(frame: web.frame)
                    cover.image = image
                    cover.imageScaling = .scaleAxesIndependently
                    cover.autoresizingMask = web.autoresizingMask
                    web.superview?.addSubview(cover, positioned: .above, relativeTo: web)
                    web.isHidden = true
                    covers.append(cover)
                }
                frame.layoutSubtreeIfNeeded()
                defer {
                    covers.forEach { $0.removeFromSuperview() }
                    taken.forEach { $0.0.isHidden = false }
                }
                guard let picture = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
                    answer(["error": "nothing drawn"])
                    return
                }
                frame.cacheDisplay(in: frame.bounds, to: picture)
                do {
                    try picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    answer(["saved": path, "pixels": [picture.pixelsWide, picture.pixelsHigh],
                            "points": [Int(frame.bounds.width), Int(frame.bounds.height)], "lights": Bench.lights(of: window)])
                } catch { answer(["error": error.localizedDescription]) }
            }
            guard left > 0 else { draw(); return }
            for web in shown {
                web.takeSnapshot(with: nil) { image, _ in
                    MainActor.assumeIsolated {
                        if let image { taken.append((web, image)) }
                        left -= 1
                        if left == 0 { draw() }
                    }
                }
            }

        case "film":
            // The whole window, title bar and lights included, drawn every few
            // hundredths of a second while something animates — what a person
            // would see of it, from a probe started hidden that nobody sees.
            // The lights' own slide is a Core Animation one, which a drawing
            // doesn't show: where they are is reported beside each frame.
            guard Store.testing else { answer(["error": "film only works on a --test run"]); return }
            guard let window = Links.window, let frame = window.contentView?.superview,
                  let path = request["path"] as? String, !path.isEmpty
            else { answer(["error": "film needs something to do and a path"]); return }
            let count = min(60, max(1, request["frames"] as? Int ?? 14))
            let every = min(0.5, max(0.01, request["every"] as? Double ?? 0.03))
            // The column's corner — the lights, the pins, the first rows — is
            // what moves; the whole window would take longer to draw than a
            // frame lasts. Written out once the filming is over.
            let corner = NSRect(x: 0, y: frame.bounds.height - 460, width: min(380, frame.bounds.width), height: 460)
            // The pages under it take a third of a second each to draw into a
            // picture, longer than the whole animation: they sit the filming
            // out, and come back after.
            func pages(in view: NSView) -> [NSView] { view is WKWebView ? [view] : view.subviews.flatMap(pages) }
            let resting = pages(in: frame).filter { !$0.isHidden }
            resting.forEach { $0.isHidden = true }
            var shots: [[String: Any]] = []
            var pictures: [NSBitmapImageRep] = []
            let started = CACurrentMediaTime()
            func take(_ index: Int) {
                guard index < count else {
                    resting.forEach { $0.isHidden = false }
                    for (index, picture) in pictures.enumerated() {
                        let file = path + String(format: "-%02d.png", index)
                        if let data = picture.representation(using: .png, properties: [:]),
                           (try? data.write(to: URL(fileURLWithPath: file))) != nil { shots[index]["file"] = file }
                    }
                    answer(["frames": shots])
                    return
                }
                var shot: [String: Any] = ["t": Int((CACurrentMediaTime() - started) * 1000)]
                if let picture = frame.bitmapImageRepForCachingDisplay(in: corner) {
                    frame.cacheDisplay(in: corner, to: picture)
                    pictures.append(picture)
                }
                if let bar = Fold.titlebar {
                    let moved = bar.layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
                    let lifted = bar.layer?.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
                    shot["lights"] = ["hidden": bar.isHidden, "x": Int(moved.rounded()), "y": Int(lifted.rounded()),
                                      "flipped": bar.superview?.isFlipped ?? false]
                }
                shots.append(shot)
                DispatchQueue.main.asyncAfter(deadline: .now() + every) { take(index + 1) }
            }
            take(0)
            switch request["action"] as? String {
            case "peek": browser.peek(true)
            case "unpeek": browser.peek(false)
            case "fold": browser.toggleFold()
            default: break
            }

        case "strip":
            // The row of tabs across the top, drawn off screen at a width,
            // with what the browser has now — for what the row looks like
            // without a window on anybody's screen.
            guard let path = request["path"] as? String else { answer(["error": "strip needs a path"]); return }
            let width = request["width"] as? Double ?? 1100
            let host = NSHostingView(rootView: TabBar(browser: browser).frame(width: width, height: Metrics.strip).background(Palette.ground))
            host.frame = NSRect(x: 0, y: 0, width: width, height: Double(Metrics.strip))
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSApp.effectiveAppearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { answer(["error": "nothing drawn"]); return }
                host.cacheDisplay(in: host.bounds, to: picture)
                do {
                    try picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    answer(["saved": path])
                } catch { answer(["error": error.localizedDescription]) }
                window.contentView = nil
            }

        case "column":
            // The column of tabs, drawn off screen at its width, with what the
            // browser has now — the rows, the card for a new space, the dots.
            guard let path = request["path"] as? String else { answer(["error": "column needs a path"]); return }
            let height = request["height"] as? Double ?? 600
            let width = Double(browser.prefs.sideWidth)
            let host = NSHostingView(rootView: SideBar(browser: browser, prefs: browser.prefs).frame(width: width, height: height))
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSApp.effectiveAppearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { answer(["error": "nothing drawn"]); return }
                host.cacheDisplay(in: host.bounds, to: picture)
                do {
                    try picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    answer(["saved": path])
                } catch { answer(["error": error.localizedDescription]) }
                window.contentView = nil
            }

        case "space":
            // The spaces, and switching between them, for a test of what a
            // space keeps apart. Test runs only: it moves your tabs about.
            guard Store.testing else { answer(["error": "space only works on a --test run"]); return }
            switch request["action"] as? String ?? "" {
            case "new": browser.addSpace(named: request["name"] as? String ?? "Test", sharesSignIns: request["fresh"] as? Bool != true)
            case "go": browser.switchSpace(index: (request["index"] as? Int ?? 1) - 1)
            case "delete": browser.deleteSpace(browser.spaceID)
            case "swipe":
                // Two fingers sideways over the column, as the swipe reads
                // them — the trackpad's own events can't reach a probe in the back.
                let dx = request["dx"] as? Double ?? -120
                SpaceSwipe.shared.start(for: browser)
                SpaceSwipe.shared.began()
                for _ in 0..<12 { SpaceSwipe.shared.moved(along: dx / 12) }
                SpaceSwipe.shared.ended()
            case "hold":
                // The fingers down and DX along, not yet let go — for a look
                // at the column mid-swipe.
                let dx = request["dx"] as? Double ?? -120
                SpaceSwipe.shared.start(for: browser)
                SpaceSwipe.shared.began()
                for _ in 0..<12 { SpaceSwipe.shared.moved(along: dx / 12) }
            case "release":
                SpaceSwipe.shared.ended()
            case "move":
                if let index = request["index"] as? Int { browser.moveSpace(browser.spaceID, to: index - 1) }
            default: break
            }
            let out: [String: Any] = [
                "on": browser.prefs.usesSpaces,
                "current": browser.space.name,
                "spaces": browser.spaces.map { ["name": $0.name, "id": $0.id.uuidString, "downloads": $0.downloads ?? "", "shared": $0.sharesSignIns == true] },
                "parked": browser.parked.map { [$0.key.uuidString: $0.value.tabs.count] },
                "tabs": browser.tabs.count,
                "making": browser.makingSpace,
                "swipe": Double(browser.spaceSwipe),
                "pages": Web.pages.allObjects.map { $0.configuration.websiteDataStore.identifier?.uuidString ?? "default" },
            ]
            // And the stores WebKit keeps by identifier, a moment later —
            // what a deleted space should have taken with it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                WKWebsiteDataStore.fetchAllDataStoreIdentifiers { ids in
                    MainActor.assumeIsolated {
                        // What is still in the stores of deleted spaces — none, if deleting emptied them.
                        let erasing = (Store.settings.stringArray(forKey: "spaces.erasing") ?? []).compactMap(UUID.init)
                        guard request["records"] as? Bool == true, !erasing.isEmpty else {
                            answer(out.merging(["stores": ids.map(\.uuidString)]) { a, _ in a })
                            return
                        }
                        Task { @MainActor in
                            var left: [String: [String]] = [:]
                            for id in erasing where ids.contains(id) {
                                let records = await WKWebsiteDataStore(forIdentifier: id)
                                    .dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
                                left[id.uuidString] = records.map { "\($0.displayName): \($0.dataTypes.sorted().joined(separator: ","))" }
                            }
                            answer(out.merging(["stores": ids.map(\.uuidString), "erasingRecords": left]) { a, _ in a })
                        }
                    }
                }
            }

        case "ui":
            // Open or close the app's own panels, to reproduce what a person
            // did without a person.
            if let on = request["settings"] as? Bool { browser.tuning = on }
            if let on = request["passwords"] as? Bool { browser.managing = on }
            if let on = request["welcome"] as? Bool { browser.welcoming = on }
            if let on = request["history"] as? Bool { browser.recalling = on }
            if let on = request["downloads"] as? Bool { browser.hoarding = on }
            if let on = request["bookmarks"] as? Bool { browser.bookmarking = on }
            if let on = request["hidden"] as? Bool { browser.reviewing = on }
            if let look = (request["look"] as? String).flatMap(Look.init) { browser.prefs.look = look }
            if let on = request["pages120"] as? Bool { browser.prefs.fastPages = on }
            if let on = request["sidebar"] as? Bool { browser.prefs.sidebar = on }
            if let on = request["spaces"] as? Bool { browser.prefs.usesSpaces = on }
            if let on = request["hides"] as? Bool { browser.prefs.sideHides = on }
            if let on = request["folded"] as? Bool { browser.folded = on }
            if let on = request["peek"] as? Bool { browser.peeking = on }
            // The address of the tab on screen being edited in the tab, with
            // this typed, and that edit let go of by a click elsewhere.
            if let text = request["edittab"] as? String, let tab = browser.active {
                browser.beginTabEdit(tab)
                browser.tabDraft = text
            }
            if request["finishedit"] as? Bool == true { browser.finishTabEdit() }
            if #available(macOS 15.4, *), let on = request["extensions"] as? Bool { Extensions.shared.menuOpen = on }
            answer(["ok": true])

        case "extensions", "ext-add", "ext-folder", "ext-press", "ext-remove", "ext-reload", "ext-page", "ext-popup", "ext-menu", "ext-pin", "ext-shot", "ext-answer", "ext-enable":
            guard #available(macOS 15.4, *) else {
                answer(["error": "extensions need macOS 15.4"])
                return
            }
            extensionCommand(verb, request, browser: browser, answer)

        default:
            answer(["error": "unknown command “\(verb)”", "commands": [
                "tabs", "open", "go", "close", "wait", "sleep", "select", "text", "eval", "click", "type", "submit", "shot", "probe", "key", "resize", "hit", "film", "window", "pages", "picture", "place", "field", "bookmark", "menu", "space", "strip", "column", "ui",
            ]])
        }
    }

    /// Extensions, from the shell. Installing asks as it always does, except
    /// in a test run given `yes` — a real browser can't be made to skip it.
    @available(macOS 15.4, *)
    private func extensionCommand(_ verb: String, _ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let extensions = Extensions.shared
        let skip = Store.testing && (request["yes"] as? Bool ?? false)
        switch verb {
        case "extensions":
            answer(["busy": extensions.busy ?? "", "extensions": extensions.installed.map { item -> [String: Any] in
                let context = extensions.contexts[item.id]
                let action = context?.action(for: extensions.activeAdapter)
                return [
                    "id": item.id, "name": item.name, "version": item.version, "enabled": item.enabled,
                    "loaded": context != nil,
                    "base": context?.baseURL.absoluteString ?? "",
                    "errors": (context?.errors ?? []).map { error in
                        let e = error as NSError
                        let under = (e.userInfo[NSUnderlyingErrorKey] as? NSError).map { " ← \($0.localizedDescription) \($0.userInfo)" } ?? ""
                        return e.localizedDescription + under + (e.userInfo.isEmpty ? "" : " \(e.userInfo.filter { $0.key != NSLocalizedDescriptionKey && $0.key != NSUnderlyingErrorKey })")
                    },
                    "reported": extensions.errors[item.id] ?? [],
                    "action": action?.label ?? "", "badge": action?.badgeText ?? "",
                    "popup": action?.presentsPopup ?? false,
                    "pinned": item.pinned ?? false, "source": item.source ?? "",
                ]
            }])
        case "ext-add":
            guard let text = request["id"] as? String else { answer(["error": "ext-add needs an id or link"]); return }
            extensions.install(from: text, confirm: !skip)
            answer(["started": true])
        case "ext-folder":
            guard let path = request["path"] as? String else { answer(["error": "ext-folder needs a path"]); return }
            extensions.installFolder(at: URL(fileURLWithPath: path), confirm: !skip)
            answer(["started": true])
        case "ext-press":
            guard let id = request["id"] as? String else { answer(["error": "ext-press needs an id"]); return }
            extensions.press(id)
            answer(["pressed": true])
        case "ext-enable":
            guard let id = request["id"] as? String else { answer(["error": "ext-enable needs an id"]); return }
            extensions.setEnabled(id, request["on"] as? Bool ?? true)
            answer(["enabled": request["on"] as? Bool ?? true])
        case "ext-answer":
            // In a test run: answer every extension's question yes or no
            // without asking, or go back to asking.
            guard Store.testing else { answer(["error": "only in a test run"]); return }
            switch request["answer"] as? String {
            case "yes": extensions.answerForTests = true
            case "no": extensions.answerForTests = false
            default: extensions.answerForTests = nil
            }
            answer(["answer": request["answer"] as? String ?? "ask", "asked": extensions.asked])
        case "ext-shot":
            // A picture of the extension's popup, while it is open.
            guard let id = request["id"] as? String, ExtensionPopup.shared.extensionID == id,
                  let web = ExtensionPopup.shared.view, let path = request["path"] as? String
            else { answer(["error": "no popup open for that extension"]); return }
            shoot(web, to: URL(fileURLWithPath: path), width: nil, answer)
        case "ext-menu":
            // The list behind the puzzle button, as a picture.
            guard let path = request["path"] as? String, let data = extensionMenuPicture()?.representation(using: .png, properties: [:]) else {
                answer(["error": "ext-menu needs a path"])
                return
            }
            do { try data.write(to: URL(fileURLWithPath: path)); answer(["saved": path]) }
            catch { answer(["error": error.localizedDescription]) }
        case "ext-pin":
            guard let id = request["id"] as? String else { answer(["error": "ext-pin needs an id"]); return }
            extensions.setPinned(id, request["on"] as? Bool ?? true)
            answer(["pinned": request["on"] as? Bool ?? true])
        case "ext-reload":
            guard let id = request["id"] as? String else { answer(["error": "ext-reload needs an id"]); return }
            extensions.reload(id)
            answer(["reloading": true])
        case "ext-remove":
            guard let id = request["id"] as? String else { answer(["error": "ext-remove needs an id"]); return }
            extensions.remove(id)
            answer(["removed": true])
        case "ext-popup":
            // JavaScript in the extension's popup, while it is open.
            guard let id = request["id"] as? String, ExtensionPopup.shared.extensionID == id,
                  let web = ExtensionPopup.shared.view
            else { answer(["error": "no popup open for that extension"]); return }
            web.evaluateJavaScript(request["js"] as? String ?? "document.title") { value, error in
                MainActor.assumeIsolated {
                    if let error { answer(["error": error.localizedDescription]); return }
                    answer(["value": Bench.plain(value)])
                }
            }
        case "ext-page":
            // One of the extension's own pages in a bench tab, where `eval`
            // runs with the extension's APIs.
            guard let id = request["id"] as? String, let context = extensions.contexts[id] else {
                answer(["error": "no such extension loaded"])
                return
            }
            let path = (request["path"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let tab = browser.benchOpen(context.baseURL.appendingPathComponent(path))
            house(tab)
            answer(describe(tab))
        default:
            answer(["error": "unknown"])
        }
    }

    /// The tab a request names, among the ones the bench opened itself. The
    /// bench is how this browser is driven while somebody is using it, and
    /// reading, clicking or sleeping in one of their tabs is not part of
    /// that: a script here is meant for tabs marked with the flask. A
    /// SEARCH_PROBE run has nobody's tabs in it, so there any tab answers,
    /// as for `tap` and `select`: a popup a bench page opened with
    /// `window.open` carries no flask and would be out of reach otherwise.
    private func find(_ request: [String: Any], in browser: Browser) -> Tab? {
        guard let ref = (request["id"] as? String)?.lowercased(), !ref.isEmpty else { return nil }
        return browser.tabs.first { (Store.testing || $0.bench) && $0.id.uuidString.lowercased().hasPrefix(ref) }
    }

    private func missing(_ request: [String: Any]) -> [String: Any] {
        ["error": "no tab “\(request["id"] as? String ?? "")” — see tabs"]
    }

    private func describe(_ tab: Tab) -> [String: Any] {
        [
            "id": Bench.short(tab),
            "url": tab.address?.absoluteString ?? "",
            "title": tab.title,
            "name": tab.name ?? "",
            "loading": tab.loading,
            "hollow": tab.hollow,
            "view": tab.built?.url?.absoluteString ?? "",
            "bench": tab.bench,
            "active": tab.id == browser?.activeID,
            "asleep": tab.asleep,
            "shy": tab.shy,
            "extensions": { if #available(macOS 15.4, *) { return tab.carriesExtensions } else { return false } }(),
        ]
    }

    static func short(_ tab: Tab) -> String {
        String(tab.id.uuidString.prefix(8)).lowercased()
    }

    /// The address field, wherever it is in the window.
    static func addressField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.delegate is AddressField.Coordinator { return field }
        for sub in view.subviews { if let found = addressField(in: sub) { return found } }
        return nil
    }

    /// Milliseconds from `start` to the run loop's next rest — after every
    /// observer that runs before it sleeps, Core Animation's commit included.
    static func whenResting(since start: CFTimeInterval, _ then: @escaping @MainActor (Double) -> Void) {
        var observer: CFRunLoopObserver?
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            let rested = (CACurrentMediaTime() - start) * 1000
            MainActor.assumeIsolated { then(rested) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Once the page has stopped loading, or the time is up.
    private func wait(for tab: Tab, until limit: Date, _ answer: @escaping ([String: Any]) -> Void) {
        if !tab.loading, tab.address != nil, tab.failure == nil || true {
            // A beat for the document's own scripts to settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                var out = describe(tab)
                if let failure = tab.failure { out["failure"] = failure }
                answer(out)
            }
            return
        }
        guard Date() < limit else {
            var out = describe(tab)
            out["timeout"] = true
            answer(out)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.wait(for: tab, until: limit, answer)
        }
    }

    // MARK: - the room off screen

    private var room: NSWindow?

    /// A page nobody is looking at has to be somewhere to be laid out at all.
    /// The stage takes it back the moment you pick its tab, and it comes
    /// here again when the bench next needs it.
    private func house(_ tab: Tab) {
        guard tab.bench, tab.web.window == nil else { return }
        let window = room ?? makeRoom()
        tab.web.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        tab.web.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(tab.web)
    }

    private func makeRoom() -> NSWindow {
        // Off every screen, and never key or main: it exists so that a web
        // view has a window, and for nothing else.
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.hasShadow = false
        window.orderBack(nil)
        room = window
        return window
    }

    private func shoot(_ tab: Tab, to file: URL, width: Double?, _ answer: @escaping ([String: Any]) -> Void) {
        shoot(tab.web, to: file, width: width, answer)
    }

    private func shoot(_ web: WKWebView, to file: URL, width: Double?, _ answer: @escaping ([String: Any]) -> Void) {
        let shot = WKSnapshotConfiguration()
        shot.afterScreenUpdates = true
        if let width { shot.snapshotWidth = NSNumber(value: width) }
        web.takeSnapshot(with: shot) { image, error in
            MainActor.assumeIsolated {
                guard let image, let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:])
                else {
                    answer(["error": error?.localizedDescription ?? "no picture"])
                    return
                }
                do {
                    try png.write(to: file)
                    answer(["path": file.path, "width": rep.pixelsWide, "height": rep.pixelsHigh])
                } catch {
                    answer(["error": error.localizedDescription])
                }
            }
        }
    }

    // MARK: - page-side helpers

    /// A JavaScript value the way JSON can carry it.
    private static func plain(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if JSONSerialization.isValidJSONObject(["v": value]) { return value }
        return String(describing: value)
    }

    /// Where an element's middle is, in the page's own points, scrolled
    /// into view first. A selector, or `text=…` for a button or link by its
    /// words.
    private static func locate(_ selector: String) -> String {
        let sel = (try? JSONSerialization.data(withJSONObject: [selector])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return """
        (function () {
          var s = \(sel), el = null;
          if (s.indexOf('text=') === 0) {
            var want = s.slice(5).trim().toLowerCase();
            el = Array.prototype.find.call(document.querySelectorAll('button, a, [role=button], input[type=submit]'), function (e) {
              return ((e.innerText || e.value || '').trim().toLowerCase()) === want;
            }) || null;
          } else {
            el = document.querySelector(s);
          }
          if (!el) return null;
          el.scrollIntoView({ block: 'center', inline: 'nearest' });
          var r = el.getBoundingClientRect();
          return [r.left + r.width / 2, r.top + r.height / 2];
        })()
        """
    }

    /// Click, type into, or submit the element a selector names. Typing goes
    /// through the field's own setter and fires the events a keystroke
    /// would, the same as the password filler, so frameworks notice.
    private static func act(_ verb: String, selector: String, text: String) -> String {
        let sel = (try? JSONSerialization.data(withJSONObject: [selector])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        let txt = (try? JSONSerialization.data(withJSONObject: [text])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return """
        (function () {
          var el = document.querySelector(\(sel));
          if (!el) return 'nothing matches ' + \(sel);
          if (el.scrollIntoView) el.scrollIntoView({ block: 'center', inline: 'nearest' });
          var verb = '\(verb)';
          if (verb === 'click') { el.focus && el.focus(); el.click(); return 'ok'; }
          if (verb === 'submit') {
            var form = el.tagName === 'FORM' ? el : el.form || el.closest('form');
            if (!form) return 'no form around ' + \(sel);
            if (form.requestSubmit) form.requestSubmit(); else form.submit();
            return 'ok';
          }
          el.focus && el.focus();
          var value = \(txt);
          if (el.isContentEditable) {
            el.textContent = value;
            el.dispatchEvent(new InputEvent('input', { bubbles: true, data: value, inputType: 'insertText' }));
            return 'ok';
          }
          var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
          var setter = Object.getOwnPropertyDescriptor(proto, 'value');
          if (setter && setter.set) setter.set.call(el, value); else el.value = value;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return 'ok';
        })();
        """
    }
}
