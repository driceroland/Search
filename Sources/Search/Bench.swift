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

    // MARK: - who switched it on

    /// Whether the bench was switched on in Settings, by you. The setting
    /// itself lives in the defaults, which any program you run can write; on
    /// its own it opens nothing. The switch also leaves a mark in the
    /// keychain — its data protection half, where only apps signed as Search
    /// with its profile can read or write, under the app's own access group —
    /// and without the mark the setting is put back to off at launch, with a
    /// word about it. Test runs keep the setting alone: their worlds hold
    /// nothing of yours, and scripts set them up with a defaults write.
    @MainActor
    enum Consent {
        private static var query: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecUseDataProtectionKeychain as String: true,
             kSecAttrService as String: "com.officecommun.search.bench",
             kSecAttrAccount as String: Store.world.map { "consent (\($0))" } ?? "consent"]
        }

        /// The mark is there — or there is nowhere to keep one: a copy built
        /// without Search's provisioning profile has no access group, and
        /// keeps the switch as it always was.
        static var given: Bool {
            var asked = query
            asked[kSecReturnAttributes as String] = true
            let status = SecItemCopyMatching(asked as CFDictionary, nil)
            return status == errSecSuccess || status == errSecMissingEntitlement
        }

        static func grant() {
            var item = query
            item[kSecValueData as String] = Data("on".utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            if status != errSecSuccess, status != errSecDuplicateItem, status != errSecMissingEntitlement {
                NSLog("Bench: the switch left no mark (%d)", status)
            }
        }

        static func revoke() {
            SecItemDelete(query as CFDictionary)
        }
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
            var answer = answer
            // The socket's queue is the main one.
            let caught = MainActor.assumeIsolated { Bench.caught }
            if !caught.isEmpty { answer["onScreen"] = caught }
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
        case "tabs":
            // A private tab is nobody's business but yours: a test run has none
            // of yours, so there every tab is listed.
            answer(["tabs": browser.tabs.filter { Store.testing || !$0.shy }.map(describe)])

        case "open":
            guard let url = (request["url"] as? String).flatMap(Address.url(from:)) else {
                answer(["error": "open needs a url"])
                return
            }
            // private: a private tab, on a SEARCH_PROBE run only.
            let shy = request["private"] as? Bool == true
            guard !shy || Store.testing else { answer(["error": "open private only works on a --test run"]); return }
            let tab = browser.benchOpen(url, shy: shy)
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

        case "pin":
            // Pin a tab, or unpin it with "off". Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "pin only works on a --test run"]); return }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            // "listed": pinned as a row, or an existing pin made a row
            // (true) or a square (false).
            if request["off"] as? Bool == true { browser.unpin(tab) }
            else if request["home"] as? Bool == true { browser.goHome(tab) }
            else if let listed = request["listed"] as? Bool, tab.pin != nil { browser.setListed(tab, listed) }
            else { browser.pin(tab, listed: request["listed"] as? Bool ?? false) }
            answer(["pin": tab.pin ?? "", "listed": tab.listed, "pinned": browser.pinnedCount, "home": tab.home?.absoluteString ?? "",
                    "address": tab.address?.absoluteString ?? "", "editingLetter": browser.editingPin == tab.id])

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
            // Search's own world is where its page scripts live (see Web.world).
            if request["world"] as? String == "search" {
                tab.web.evaluateJavaScript(js, in: nil, in: Web.world) { result in
                    switch result {
                    case .success(let value): answer(["value": Bench.plain(value)])
                    case .failure(let error): answer(["error": error.localizedDescription])
                    }
                }
                return
            }
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
                    // Held while clicking: "shift", "cmd", "opt".
                    var held: NSEvent.ModifierFlags = []
                    for name in request["mods"] as? [String] ?? [] {
                        if name == "shift" { held.insert(.shift) }
                        if name == "cmd" { held.insert(.command) }
                        if name == "opt" { held.insert(.option) }
                    }
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        guard let event = NSEvent.mouseEvent(
                            with: type, location: spot, modifierFlags: held,
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

        case "towindow":
            // A tab to another window, as its menu's Move to Window does: to
            // the Nth, or a new one. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "towindow only works on a --test run"]); return }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            if let at = request["at"] as? [Double], at.count == 2 {
                // Let go at a point of the screen, as a drag out of the row.
                let taken = browser.dragOut(tab, at: NSPoint(x: at[0], y: at[1]))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { answer(["taken": taken, "windows": Browsers.all.count]) }
                return
            }
            let n = request["to"] as? Int
            let target = n.flatMap { Browsers.all.indices.contains($0 - 1) ? Browsers.all[$0 - 1] : nil }
            if n != nil, target == nil { answer(["error": "no window \(n ?? 0)"]); return }
            browser.moveToWindow(tab, target)
            answer(["windows": Browsers.all.count])

        case "news":
            // The card after an update (see WhatsNew.swift), drawn off screen
            // to a PNG — the newest release's, whatever this build's version —
            // or every version's notes; "on" shows the card in the window.
            guard Store.testing else { answer(["error": "news only works on a --test run"]); return }
            guard let release = WhatsNew.releases.first else { answer(["error": "no release has a card"]); return }
            if request["on"] as? Bool == true {
                browser.newsShowing = true
                answer(["showing": true])
                return
            }
            guard let path = request["path"] as? String else { answer(["error": "news needs a path"]); return }
            let root: AnyView = request["notes"] as? Bool == true
                ? AnyView(ReleaseNotesPanel {}.padding(40).background(Palette.ground))
                : AnyView(WhatsNewCard(release: release, prefs: browser.prefs, close: {}, notes: {}).padding(40).background(Palette.ground))
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSApp.effectiveAppearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { answer(["error": "nothing drawn"]); return }
                host.cacheDisplay(in: host.bounds, to: picture)
                do {
                    try picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    answer(["saved": path, "size": [Int(host.bounds.width), Int(host.bounds.height)]])
                } catch { answer(["error": error.localizedDescription]) }
                window.contentView = nil
            }

        case "quit":
            // ⌘Q, on a test run: the app ends the way it does for you, the
            // session and windows.json written on the way out.
            guard Store.testing else { answer(["error": "quit only works on a --test run"]); return }
            answer(["quitting": true])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }

        case "windows":
            // The windows, oldest first, and what the tests do to them. Only
            // on a SEARCH_PROBE run: it opens and closes windows.
            guard Store.testing else { answer(["error": "windows only works on a --test run"]); return }
            let n = (request["n"] as? Int).map { $0 - 1 }
            switch request["action"] as? String {
            case "new": Browsers.newWindow()
            case "close":
                guard let n, Browsers.all.indices.contains(n) else { answer(["error": "no window \((n ?? -1) + 1)"]); return }
                Browsers.all[n].window?.close()
            case "reopen": _ = Browsers.reopenWindow()
            case "front":
                // The Nth window as if it had come to the front; a hidden
                // probe's windows never become key on their own.
                guard let n, Browsers.all.indices.contains(n) else { answer(["error": "no window \((n ?? -1) + 1)"]); return }
                Browsers.becameKey(Browsers.all[n])
            case "link":
                // A link from another app, the way macOS hands it over.
                guard let text = request["url"] as? String, let url = URL(string: text) else { answer(["error": "link needs a url"]); return }
                Links.arrived(url)
            case "frame":
                guard let n, Browsers.all.indices.contains(n), let f = request["frame"] as? [Double], f.count == 4 else { answer(["error": "frame needs N X Y W H"]); return }
                Browsers.all[n].window?.setFrame(NSRect(x: f[0], y: f[1], width: f[2], height: f[3]), display: false)
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                answer(["windows": Browsers.all.enumerated().map { index, b -> [String: Any] in
                    [
                        "n": index + 1, "front": b === Browsers.front, "scene": b.inScene,
                        "shown": b.window?.isVisible ?? false, "files": b.usesFiles,
                        "space": b.space.name, "tabs": b.tabs.map { $0.address?.absoluteString ?? "" },
                        "pins": b.tabs.filter { $0.pin != nil }.map { $0.pin ?? "" },
                        "frame": b.window.map { NSStringFromRect($0.frame) } ?? "",
                    ]
                }, "closedWindows": Browsers.lastClosedAt != nil])
            }

        case "middle":
            // The middle button pressed and let go at X Y of a tab's page (its
            // own points from the top left), handed to its view as AppKit
            // would: the page sees trusted mousedown, mouseup and auxclick.
            // Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "middle only works on a --test run"]); return }
            guard let tab = find(request, in: browser), let x = request["x"] as? Double, let y = request["y"] as? Double
            else { answer(missing(request)); return }
            house(tab)
            let web = tab.web
            let before = browser.tabs.count
            let inView = NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y)
            let point = web.convert(inView, to: nil)
            for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: web.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .otherMouseDown ? 1 : 0
                ) else { continue }
                // A made event is button 0; the middle is 2, set on its CG form.
                guard let cg = event.cgEvent else { continue }
                cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
                let middle = NSEvent(cgEvent: cg) ?? event
                if type == .otherMouseDown { web.otherMouseDown(with: middle) } else { web.otherMouseUp(with: middle) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                answer(["tabsBefore": before, "tabsAfter": browser.tabs.count])
            }

        case "linkmenu":
            // A right-click at X Y of a tab's page (its own points from the
            // top left), and the item named "pick" chosen from the menu that
            // comes up. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "linkmenu only works on a --test run"]); return }
            guard let tab = find(request, in: browser), let x = request["x"] as? Double, let y = request["y"] as? Double,
                  let pick = request["pick"] as? String
            else { answer(missing(request)); return }
            house(tab)
            let web = tab.web
            let inView = NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y)
            let point = web.convert(inView, to: nil)
            PageView.picking = pick
            for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: web.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .rightMouseDown ? 1 : 0
                ) else { continue }
                if type == .rightMouseDown { web.rightMouseDown(with: event) } else { web.rightMouseUp(with: event) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                PageView.picking = nil
                answer([
                    "tabs": browser.tabs.map { Bench.short($0) },
                    "urls": browser.tabs.map { $0.address?.absoluteString ?? "" },
                    "active": browser.activeID.flatMap { id in browser.tabs.first { $0.id == id } }.map { Bench.short($0) } ?? "",
                ])
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
                // The dropdown off the button, the ⇧⌘B card in it, and how
                // many are kept, for every window alike.
                "bookmarksOpen": browser.bookmarksOpen,
                "bookmarkCard": browser.bookmarkCard != nil,
                "bookmarkCount": browser.bookmarks.count,
                "import": browser.bringingIn != nil,
                "field": browser.editing,
                "suggesting": browser.suggesting != nil,
                "offering": browser.offering != nil,
                "modal": NSApp.modalWindow.map { "\(type(of: $0)) “\($0.title)”" } ?? "",
                "look": browser.prefs.look.rawValue,
                "sidebar": browser.prefs.sidebar,
                "sidePosition": browser.prefs.sidePosition.rawValue,
                "sideWidth": Double(browser.prefs.sideWidth),
                "appearance": NSApp.appearance?.name.rawValue ?? "system",
                "key": NSApp.keyWindow.map { "\(type(of: $0)) “\($0.title)”" } ?? "",
                // What the keyboard goes to in the key window, or the browser's: a find field,
                // a page, or a button it shouldn't be.
                "responder": (NSApp.keyWindow ?? Links.window)?.firstResponder.map { "\(type(of: $0))" } ?? "",
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
            if let window = browser.window ?? Links.window { out["lights"] = Bench.lights(of: window) }
            if let tab = browser.active, let web = tab.built, let window = browser.window ?? Links.window, web.window === window {
                let frame = web.convert(web.bounds, to: nil)
                out["activePageFrame"] = [
                    Int(frame.minX), Int(window.frame.height - frame.maxY),
                    Int(frame.width), Int(frame.height),
                ]
            }
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
            out["peek"] = browser.peekTab?.address?.absoluteString ?? ""
            out["fetching"] = ["showing": browser.fetches.showing, "fraction": browser.fetches.fraction ?? -1, "done": browser.fetches.done]
            // Where the peek's page sits in the window, from its top-left corner, in points.
            if let web = browser.peekTab?.built, let window = web.window {
                let r = web.convert(web.bounds, to: nil)
                out["peekFrame"] = [Int(r.minX), Int(window.frame.height - r.maxY), Int(r.width), Int(r.height)]
            }
            out["folded"] = browser.folded
            out["peeking"] = browser.peeking
            out["sideHides"] = browser.prefs.sideHides
            out["lightsHidden"] = Fold.titlebar?.isHidden ?? false
            out["siteCard"] = SiteCardPanel.isShown
            // Whether this Mac lets the browser use its passkeys at all — the
            // one-time permission macOS asks a browser other than Safari for.
            switch ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials {
            case .authorized: out["passkeyAccess"] = "authorized"
            case .denied: out["passkeyAccess"] = "denied"
            default: out["passkeyAccess"] = "notDetermined"
            }
            out["dialogs"] = Dialogs.askedInTest
            out["asking"] = browser.asking.map { "\($0.host) \($0.wants)" + ($0.once ? " once" : "") + ($0.keeps ? "" : " unkept") } ?? ""
            out["locationAnswered"] = Browser.locationAnswered ?? ""
            out["passkeyAsks"] = Passkeys.asked
            out["handedOff"] = Browser.handedOff
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
                    windowNumber: (browser.window ?? Links.window)?.windowNumber ?? 0, context: nil,
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
            guard let window = browser.window ?? Links.window,
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
            guard let window = browser.window ?? Links.window, let x = request["x"] as? Double, let y = request["y"] as? Double,
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
                guard let field = Bench.addressField(in: (browser.window ?? Links.window)?.contentView),
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

        case "switcher":
            // The ⌃Tab switcher as it stands: up or not, the pick, and where
            // the panel and each card are in the window (top-left points).
            let sw = browser.tabSwitcher
            func short(_ id: Tab.ID?) -> String {
                guard let id, let tab = browser.tabs.first(where: { $0.id == id }) else { return "" }
                return Bench.short(tab)
            }
            func box(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { Double($0) } }
            answer([
                "visible": sw.visible, "selected": short(sw.selectedID),
                "candidates": sw.candidates.map { short($0) },
                "panel": box(sw.panelFrame),
                "cards": Dictionary(sw.cardFrames.map { (short($0.key), box($0.value)) }, uniquingKeysWith: { a, _ in a }),
                "active": short(browser.activeID),
            ])

        case "recording":
            // The recording pill (RecordingIndicator.swift): lines put up as
            // ExtensionCapture would, a page lent to it, what it shows, and a
            // picture of it drawn off every screen. A test run never puts
            // the pill itself on a screen. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "recording only works on a --test run"]); return }
            let pill = RecordingIndicator.shared
            func state(_ extra: [String: Any] = [:]) -> [String: Any] {
                var out: [String: Any] = [
                    "lines": pill.lines.map { [$0.id, $0.name, $0.what] },
                    "recordingTabs": browser.tabs.filter(\.recording).map { Bench.short($0) },
                    "onScreen": NSApp.windows.contains { $0 is NSPanel && $0.isVisible && $0.contentView?.subviews.contains { $0 is NSHostingView<PillView> } == true },
                ]
                out.merge(extra) { _, new in new }
                return out
            }
            switch request["action"] as? String ?? "state" {
            case "show":
                let names = request["names"] as? [String] ?? ["Loom"]
                let what = request["what"] as? String ?? "is recording your screen"
                let page = find(request, in: browser)?.built
                pill.update(names.map { RecordingLine(id: $0.lowercased(), name: $0, what: what) }, pages: page.map { [$0] } ?? [])
                answer(state())
            case "stop":
                var stopped = ""
                pill.onStop = { stopped = $0 }
                pill.stop(request["name"] as? String ?? "")
                answer(state(["stopped": stopped]))
            case "clear": pill.update([]); answer(state())
            case "host", "release":
                guard let tab = find(request, in: browser), let web = tab.built else { answer(missing(request)); return }
                // Where the page was before it was lent, to check it comes back there.
                if request["action"] as? String == "host" {
                    Bench.lentFrom[ObjectIdentifier(web)] = web.superview.map { WeakView($0) } ?? WeakView(nil)
                    pill.host(web)
                } else {
                    pill.release(web)
                }
                let home = Bench.lentFrom[ObjectIdentifier(web)]?.view
                answer(state(["hosted": pill.hosts(web), "backHome": web.superview === home]))
            case "picture":
                guard let path = request["path"] as? String, let rep = pill.picture(dark: request["dark"] as? Bool == true),
                      let data = rep.representation(using: .png, properties: [:]) else { answer(["error": "no picture"]); return }
                try? data.write(to: URL(fileURLWithPath: path))
                answer(state(["saved": path]))
            default: answer(state())
            }

        case "sitesearch":
            // Search a site from the address field (SiteSearch.swift): what
            // it offers and holds, Tab, ⌫ in an empty field, Esc, Return,
            // and the sites it has learned. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "sitesearch only works on a --test run"]); return }
            func state(_ extra: [String: Any] = [:]) -> [String: Any] {
                var out: [String: Any] = [
                    "offer": browser.siteOffer?.name ?? "", "chip": browser.siteChip?.name ?? "",
                    "typed": browser.typed, "offers": browser.offers.map { [$0.key, $0.url.absoluteString] },
                    "editing": browser.editing, "learned": SiteSearch.learned.map { [$0.name, $0.host, $0.template] },
                    "address": browser.active?.address?.absoluteString ?? "",
                ]
                out.merge(extra) { _, new in new }
                return out
            }
            switch request["action"] as? String ?? "state" {
            case "tab": answer(state(["took": browser.lockSiteOffer()]))
            case "delete":
                guard let field = Bench.addressField(in: (browser.window ?? Links.window)?.contentView),
                      let editor = field.currentEditor() as? NSTextView else { answer(["error": "no field editor"]); return }
                editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
                answer(state())
            case "esc": browser.dismiss(); answer(state())
            case "go":
                browser.submit()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { answer(state(["pending": browser.active?.pending?.absoluteString ?? ""])) }
            case "learn":
                guard let page = (request["page"] as? String).flatMap(URL.init(string:)),
                      let description = (request["description"] as? String).flatMap(URL.init(string:)) else {
                    answer(["error": "sitesearch learn needs page and description"]); return
                }
                SiteSearch.learn(from: page, description: description)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { answer(state()) }
            case "adopt":
                // A learned site kept as learn keeps one, past the fetch: the
                // name a description gives itself is never read.
                SiteSearch.adopt(host: request["host"] as? String ?? "", template: request["template"] as? String ?? "")
                answer(state())
            case "forget": SiteSearch.forget(); answer(state())
            default: answer(state())
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

        case "dropdown":
            // The bookmark button's list, laid out off every screen, never in
            // a popover: its height as it opens, the list's part of it, and
            // how tall the tree is with every folder open.
            let dropdown = BookmarksDropdown(browser: browser, bookmarks: browser.bookmarks)
            let whole = NSHostingView(rootView: dropdown).fittingSize
            let all = Set(Bookmarks.folders(browser.bookmarks.roots).map(\.node.id))
            let outline = BookmarkOutline(bookmarks: browser.bookmarks, expanded: .constant(all), open: { _ in }, openInNewTab: { _ in })
                .padding(6)
                .frame(width: 280)
            // As it opens, folders closed: what the list was once sized by.
            let closed = BookmarkOutline(bookmarks: browser.bookmarks, expanded: .constant([]), open: { _ in }, openInNewTab: { _ in })
                .padding(6)
                .frame(width: 280)
            // And as it opens now, with what opens with it.
            let opening = BookmarksDropdown.opening(browser.bookmarks.roots)
            let shown = BookmarkOutline(bookmarks: browser.bookmarks, expanded: .constant(opening), open: { _ in }, openInNewTab: { _ in })
                .padding(6)
                .frame(width: 280)
            answer(["height": Double(whole.height), "width": Double(whole.width), "list": Double(dropdown.listHeight),
                    "allOpen": Double(NSHostingView(rootView: outline).fittingSize.height),
                    "closed": Double(NSHostingView(rootView: closed).fittingSize.height),
                    "shown": Double(NSHostingView(rootView: shown).fittingSize.height),
                    "opening": opening.count])

        case "import":
            // Another browser's passwords, bookmarks and history, brought in
            // through the same calls the Welcome and the panels make. Only on
            // a SEARCH_PROBE run, which reads made-up profiles from its own
            // folder's Import/ (see Chromium.base), never a real browser.
            guard Store.testing else { answer(["error": "import only works on a --test run"]); return }
            let found = ImportSource.installed()
            guard let source = found.first(where: { $0.name == request["from"] as? String }) else {
                answer(["found": found.map(\.name)])
                return
            }
            // The profile used most recently unless another is named, by its
            // folder or the name the browser gives it; "all" for every one.
            let profile: String?
            switch request["profile"] as? String {
            case nil: profile = source.usual
            case "all": profile = nil
            case let name?:
                guard let match = source.profiles.first(where: { $0.id == name || $0.name == name }) else {
                    answer(["error": "no profile “\(name)” in \(source.name)", "profiles": source.profiles.map(\.id)])
                    return
                }
                profile = match.id
            }
            let what = request["what"] as? [String] ?? []
            var out: [String: Any] = ["found": found.map(\.name), "profiles": source.profiles.map(\.id),
                                      "profile": profile ?? "all"]
            if what.contains("bookmarks") {
                let (added, already, kept) = browser.takeBookmarks(from: source, profile: profile, replacing: request["replace"] as? Bool == true)
                out["bookmarks"] = ["added": added, "already": already, "kept": kept, "total": browser.bookmarks.count,
                                    "top": browser.bookmarks.roots.map(\.title)]
            }
            if what.contains("history") {
                let places = source.places(profile: profile)
                for place in places { browser.history.take(place.url, title: place.title, count: place.count, last: place.last) }
                browser.history.settle()
                out["places"] = places.count
                ImportRecords.note(source.name, places: places.count)
            }
            if what.contains("passwords") {
                let outcome = Result { try source.read(profile: profile) }
                switch outcome {
                case .success(let read): out["read"] = read.logins.count; out["skipped"] = read.skipped
                case .failure(let error): out["error"] = "\(error)"
                }
                browser.took(outcome, from: source.name)
                out["saved"] = browser.saved.count
            }
            if what.contains("spaces") {
                if let sidebar = source.arcSidebar(profile: profile) {
                    let (spaces, pins, tabs) = browser.takeArc(sidebar, from: source, profile: profile)
                    ImportRecords.note(source.name, spaces: spaces, pinned: pins + tabs)
                    out["arc"] = ["spaces": spaces, "pins": pins, "tabs": tabs,
                                  "names": browser.spaces.map(\.name), "usesSpaces": browser.prefs.usesSpaces]
                } else {
                    out["arc"] = "no Arc sidebar"
                }
            }
            // What is now recorded from it, as the sheet shows it.
            if let record = ImportRecords.of(source.name) {
                out["record"] = ["bookmarks": record.bookmarks, "places": record.places, "passwords": record.passwords,
                                 "ids": record.bookmarkIDs.count]
            }
            answer(out)

        case "import-preview":
            // What the sheet counts as it opens, for every browser found:
            // its profiles, the one used most recently, and what that one
            // and all of them hold — through the same call the sheet makes,
            // which never asks for a key. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "import-preview only works on a --test run"]); return }
            let asked = Chromium.keyAsks
            func counts(_ preview: ImportSource.Preview) -> [String: Any] {
                ["bookmarks": preview.bookmarks, "places": preview.places, "passwords": preview.passwords,
                 "extensions": preview.extensions]
            }
            let found = ImportSource.installed().map { source -> [String: Any] in
                let usual = source.usual
                return ["name": source.name,
                        "profiles": source.profiles.map { ["id": $0.id, "name": $0.name] },
                        "default": usual ?? "",
                        "counts": counts(source.preview(profile: usual)),
                        "all": counts(source.preview(profile: nil))]
            }
            // keyAsked: by this count; keyAskedEver: by anything since launch,
            // the sheet opening included.
            answer(["browsers": found, "safari": ImportSource.safari, "keyAsked": Chromium.keyAsks - asked,
                    "keyAskedEver": Chromium.keyAsks])

        case "import-file":
            // A file another browser exported, through the same call the
            // File… buttons make after their chooser. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "import-file only works on a --test run"]); return }
            guard let path = request["path"] as? String else { answer(["error": "import-file needs a path"]); return }
            Task { @MainActor in
                let took = await browser.takeFile(URL(fileURLWithPath: path))
                answer(["said": took.said, "bookmarks": took.bookmarks, "already": took.already, "places": took.places,
                        "kept": took.kept, "skipped": took.skipped, "cancelled": took.cancelled,
                        "total": browser.bookmarks.count, "top": browser.bookmarks.roots.map(\.title), "saved": browser.saved.count])
            }

        case "import-file-start":
            guard Store.testing else { answer(["error": "import-file only works on a --test run"]); return }
            guard let path = request["path"] as? String else { answer(["error": "import-file needs a path"]); return }
            guard browser.fileImport == nil else { answer(["error": "import already running"]); return }
            Task { @MainActor in _ = await browser.takeFile(URL(fileURLWithPath: path)) }
            answer(["started": true])

        case "import-file-status":
            guard Store.testing else { answer(["error": "import-file only works on a --test run"]); return }
            if let job = browser.fileImport {
                answer(["running": true, "filename": job.filename, "message": job.message,
                        "completed": job.completed, "total": job.total ?? -1, "cancelling": job.cancelling])
            } else { answer(["running": false]) }

        case "import-file-cancel":
            guard Store.testing else { answer(["error": "import-file only works on a --test run"]); return }
            browser.cancelFileImport()
            answer(["cancelling": browser.fileImport?.cancelling ?? false])

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
                    "firstFolderImages": folder?.items.prefix(4).map { $0.image != nil } ?? [],
                    "active": browser.active?.address?.absoluteString ?? ""])

        case "keyeq":
            // A ⌘ shortcut pressed while the page has the keyboard, put
            // through the app's key handling and then to the page's view, as
            // AppKit does with a key window — which a hidden probe hasn't.
            // Reports what Search did and what the page saw. Only on a
            // SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "keyeq only works on a --test run"]); return }
            guard let tab = browser.active, let web = tab.built, let window = web.window,
                  let chars = request["chars"] as? String, let code = request["code"] as? Int
            else { answer(["error": "keyeq needs a loaded tab, the characters and the key code"]); return }
            var flags: NSEvent.ModifierFlags = [.command]
            if (request["mods"] as? [String] ?? []).contains("shift") { flags.insert(.shift) }
            window.makeFirstResponder(web)
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code)
            ) else { answer(["error": "no event"]); return }
            let before = (finding: browser.finding, summoning: browser.editing, folded: browser.folded)
            var firstPass = "search"
            if ContentView.keyHooks[ObjectIdentifier(browser)]?(event) != nil {
                firstPass = "page"
                _ = web.performKeyEquivalent(with: event)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                web.evaluateJavaScript("JSON.stringify(window.__keys || [])") { seen, _ in
                    MainActor.assumeIsolated {
                        answer(["firstPass": firstPass, "pageSaw": seen as? String ?? "",
                                "finding": [before.finding, browser.finding], "fieldUp": [before.summoning, browser.editing],
                                "folded": [before.folded, browser.folded]])
                    }
                }
            }

        case "image-data":
            // What Copy Image would put on the pasteboard, without putting it
            // there: the picture at an address, read as the menu reads it.
            guard Store.testing else { answer(["error": "image-data only works on a --test run"]); return }
            guard let tab = (request["id"] as? String).flatMap({ id in browser.tabs.first { $0.id.uuidString.lowercased().hasPrefix(id) } }) ?? browser.active,
                  let text = request["url"] as? String, let url = URL(string: text)
            else { answer(["error": "image-data needs a url"]); return }
            Task {
                let data = await browser.imageData(at: url, in: tab)
                let image = data.flatMap { NSImage(data: $0) }
                answer(["bytes": data?.count ?? 0, "image": image.map { [Int($0.size.width), Int($0.size.height)] } ?? []])
            }

        case "find":
            // Find on Page as typed into its bar, then Next or Previous
            // pressed, and what the bar says once the page has answered.
            guard Store.testing else { answer(["error": "find only works on a --test run"]); return }
            let start = Date()
            browser.finding = true
            browser.matchCase = request["case"] as? Bool ?? false
            browser.wholeWords = request["words"] as? Bool ?? false
            // The same words again would count as Next, as they do in the bar.
            let text = request["text"] as? String ?? ""
            if browser.needle != text { browser.needle = text }
            for _ in 0..<(request["next"] as? Int ?? 0) { browser.look(forward: true) }
            for _ in 0..<(request["back"] as? Int ?? 0) { browser.look(forward: false) }
            func settled(_ tries: Int) {
                let status = browser.findStatus
                if (status != nil && !browser.findBusy) || tries > 200 {
                    answer(["status": status ?? "", "ms": Int(Date().timeIntervalSince(start) * 1000)])
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { settled(tries + 1) }
            }
            settled(0)
        case "visible":
            // Refused: it lent the tab to a window of its own, off every
            // screen, so that WebKit would count the page as seen. No bench
            // verb makes a window for now, off screen or not, after windows
            // reached a screen during test runs; what needs a page to be
            // seen is checked on a release candidate instead.
            answer(["error": "visible is switched off: it made a window, and no bench verb makes one for now — check this on a release candidate"])

        case "ai":
            // The AI add-on's requests against a stand-in on this Mac: "mock"
            // points every provider at it, "key" keeps a made-up key for the
            // run (in memory), "ask" sends one question and gives back the
            // whole answer or the error. Only on a SEARCH_PROBE run, and only
            // ever to the loopback address.
            guard Store.testing else { answer(["error": "ai only works on a --test run"]); return }
            switch request["action"] as? String {
            case "mock":
                guard let url = (request["url"] as? String).flatMap(URL.init(string:)),
                      ["127.0.0.1", "localhost", "::1"].contains(url.host() ?? "")
                else { answer(["error": "ai mock needs an address on this Mac"]); return }
                AIProvider.mock = url
                answer(["mock": url.absoluteString])
            case "key":
                guard let provider = (request["provider"] as? String).flatMap(AIProvider.init(rawValue:)),
                      let key = request["key"] as? String
                else { answer(["error": "ai key PROVIDER KEY"]); return }
                let saved = AIKeys.save(key, for: provider)
                answer(["saved": "\(saved)", "hint": AIKeys.hint(for: provider) ?? ""])
            case "ask":
                guard let provider = (request["provider"] as? String).flatMap(AIProvider.init(rawValue:)) else {
                    answer(["error": "ai ask PROVIDER MODEL TEXT"]); return
                }
                let model = request["model"] as? String ?? provider.defaultModel
                let stream = AIClient.shared.stream(provider, model: model, system: "You are a test.",
                                                    messages: [AIMessage(role: .user, text: request["text"] as? String ?? "")],
                                                    key: AIKeys.key(for: provider))
                Task { @MainActor in
                    var text = "", pieces = 0
                    do {
                        for try await piece in stream { text += piece; pieces += 1 }
                        answer(["text": text, "pieces": pieces])
                    } catch {
                        answer(["error": error.localizedDescription, "text": text])
                    }
                }
            case "signin":
                // OpenRouter's sign-in, against the stand-in: the tab it opens,
                // and a moment later whether a key is kept.
                AISignIn.start(in: browser)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    answer(["kept": AIKeys.hint(for: .openRouter) ?? "", "waiting": AISignIn.waiting, "tabs": browser.tabs.count])
                }
            case "engine":
                // A test run's engine (engine.sh, signed ad-hoc) and a folder
                // of models shared between test worlds; then the state.
                if let path = request["path"] as? String {
                    AIEngine.shared.stop()
                    AIEngine.testEngine = URL(fileURLWithPath: path)
                }
                if let models = request["models"] as? String { AIEngine.testModels = URL(fileURLWithPath: models, isDirectory: true) }
                AIEngine.shared.refreshState()
                let running = AIEngine.shared.running
                answer(["state": "\(AIEngine.shared.state)", "available": AIEngine.shared.available,
                        "trusted": AIEngine.testEngine.map { AIEngine.trusted($0) } ?? false,
                        "pid": Int(running.pid), "ready": running.ready])
            case "use":
                // The add-on on, answered by this provider (and model).
                guard let provider = (request["provider"] as? String).flatMap(AIProvider.init(rawValue:)) else {
                    answer(["error": "ai use PROVIDER [MODEL]"]); return
                }
                browser.prefs.ai = true
                browser.prefs.aiProvider = provider
                if let model = request["model"] as? String { browser.prefs.setAIModel(model, for: provider) }
                answer(["provider": provider.rawValue, "model": browser.prefs.aiModel(for: provider)])
            case "summarize", "question":
                // The menu's Summarize Page or Ask About This Page… on a tab,
                // then — for a question — the question typed and sent.
                guard let tab = find(request, in: browser) else { answer(missing(request)); return }
                browser.select(tab)
                if request["action"] as? String == "summarize" { browser.summarizePage() } else { browser.askAboutPage() }
                if let text = request["text"] as? String {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        browser.assisting?.draft = text
                        browser.assisting?.submit()
                    }
                }
                answer(["open": browser.assisting != nil])
            case "agree":
                browser.assisting?.agree()
                answer(["open": browser.assisting != nil])
            case "state":
                guard let assistant = browser.assisting else { answer(["open": false]); return }
                answer([
                    "open": true, "reading": assistant.reading, "notice": assistant.notice ?? "", "trouble": assistant.trouble ?? "",
                    "addressed": assistant.addressed,
                    "place": assistant.place,
                    "turns": assistant.turns.map { ["question": $0.question ?? "", "answer": $0.answer, "done": $0.done,
                                                     "failed": $0.failed ?? "", "strays": $0.strays] as [String: Any] },
                ])
            case "picture":
                // The panel as it stands, and Settings › AI, drawn off screen
                // to PNGs — no window.
                guard let path = request["path"] as? String else { answer(["error": "ai picture PATH"]); return }
                var made: [String] = []
                func draw<V: View>(_ view: V, _ file: String) {
                    let renderer = ImageRenderer(content: view.padding(20).background(Palette.wash))
                    renderer.scale = 2
                    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                    let url = URL(fileURLWithPath: path).appendingPathComponent(file)
                    if (try? png.write(to: url)) != nil { made.append(url.path) }
                }
                if let assistant = browser.assisting { draw(AssistantPanel(browser: browser, assistant: assistant, drawn: true), "ai-panel.png") }
                draw(AISettings(browser: browser, prefs: browser.prefs, drawn: true).frame(width: 440), "ai-settings.png")
                answer(["made": made])
            case "read":
                // What of the page would go to the model, and nothing sent.
                guard let tab = find(request, in: browser) else { answer(missing(request)); return }
                Task { @MainActor in
                    guard let read = await AIPage.read(tab) else { answer(["error": "nothing to read"]); return }
                    Bench.aiRead = read
                    answer(["title": read.title, "text": read.text, "links": read.links.count, "cut": read.cut])
                }
            case "check":
                // The last page read, and an answer checked against it.
                guard let read = Bench.aiRead, let text = request["text"] as? String else {
                    answer(["error": "ai read a page first, then ai check TEXT"]); return
                }
                answer(["strays": AIPage.strays(in: text, from: read)])
            default:
                answer(["error": "ai mock URL | key PROVIDER KEY | ask PROVIDER MODEL TEXT | read ID | check TEXT"])
            }

        case "notifications":
            // What a test run would have posted, and every site's answer.
            guard Store.testing else { answer(["error": "notifications only works on a --test run"]); return }
            answer(["recorded": SiteNotifications.shared.recorded, "choices": SiteNotifications.choices,
                    "asking": browser.asking.map { "\($0.host) \($0.wants)" } ?? ""])

        case "answer":
            // The card of a page asking for the camera, microphone or your
            // location: once, always or no. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "answer only works on a --test run"]); return }
            switch request["with"] as? String {
            case "once": browser.allowCaptureOnce()
            case "always": browser.allowCapture()
            case "no": browser.denyCapture()
            default: answer(["error": "answer once|always|no"]); return
            }
            answer(["asking": browser.asking.map { "\($0.host) \($0.wants)" } ?? "", "locationAnswered": Browser.locationAnswered ?? ""])

        case "accounts":
            // The list under the sign-in box the caret is in — passkeys, then
            // passwords — and, with "pick", a click on its row by number,
            // counted from 0. Only on a SEARCH_PROBE run: it would sign in.
            guard Store.testing else { answer(["error": "accounts only works on a --test run"]); return }
            guard let list = browser.suggesting else { answer(["shown": false]); return }
            let rows = list.passkeys.map { ["passkey": $0.name] } + list.logins.map { ["login": $0.user] }
            if let pick = request["pick"] as? Int {
                guard rows.indices.contains(pick) else { answer(["error": "no row \(pick)"]); return }
                if pick < list.passkeys.count { browser.choose(list.passkeys[pick]) } else { browser.choose(list.logins[pick - list.passkeys.count]) }
            }
            answer(["shown": true, "rows": rows, "spot": [list.spot.minX, list.spot.minY, list.spot.width, list.spot.height]])

        case "fill":
            // What the window spends on the page scrolling: the page's report
            // of where it is, STEPS times, 8 ms apart, each timed until the
            // run loop rests again — SwiftUI's update and Core Animation's
            // commit included. For the reading fill and what watches the tab.
            guard Store.testing else { answer(["error": "fill only works on a --test run"]); return }
            guard let tab = browser.active else { answer(["error": "no tab"]); return }
            let steps = request["steps"] as? Int ?? 200
            var times: [Double] = []
            @MainActor func step(_ n: Int) {
                guard n < steps else {
                    let sorted = times.sorted()
                    answer(["steps": steps, "median": sorted[sorted.count / 2], "p90": sorted[sorted.count * 9 / 10],
                            "total": times.reduce(0, +), "reading": tab.reading])
                    return
                }
                let start = CACurrentMediaTime()
                // Down and back, half a percent at a time.
                let at = Double(n % 200 < 100 ? n % 100 : 100 - n % 100) / 100
                tab.scrolled(to: at * 4000, of: 4000)
                Bench.whenResting(since: start) { ms in
                    times.append(ms)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { step(n + 1) }
                }
            }
            step(0)

        case "peek":
            // A link's page in the peek panel over the tab in front, as a
            // shift-click on it would open it (see Peek.swift); "close" puts
            // it away. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "peek only works on a --test run"]); return }
            if request["url"] as? String == "close" {
                browser.closePeek()
                answer(["peek": ""])
                return
            }
            guard let tab = browser.active, let text = request["url"] as? String, let url = URL(string: text)
            else { answer(["error": "peek needs a tab in front and an address"]); return }
            browser.peek(url, from: tab)
            answer(["peek": url.absoluteString])

        case "pull":
            // Two fingers sideways over the page: DX points in STEPS scroll
            // events spread over MS milliseconds, with a trackpad's phases,
            // handed to the page's view — for the swipe back and forward.
            // Reports where the tab is after. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "pull only works on a --test run"]); return }
            guard let tab = browser.active, let web = tab.built, let dx = request["dx"] as? Double
            else { answer(["error": "pull needs a loaded tab and a distance"]); return }
            let steps = max(2, request["steps"] as? Int ?? 10)
            let ms = max(1, request["ms"] as? Double ?? 200)
            let before = tab.address?.absoluteString ?? ""
            func send(_ phase: Int64, _ delta: Double) {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(delta), wheel3: 0) else { return }
                cg.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1) // kCGScrollWheelEventIsContinuous
                cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: phase) // kCGScrollWheelEventScrollPhase
                cg.setIntegerValueField(CGEventField(rawValue: 97)!, value: Int64(delta)) // kCGScrollWheelEventPointDeltaAxis2
                if let event = NSEvent(cgEvent: cg) { web.scrollWheel(with: event) }
            }
            send(1, 0)
            for n in 1...steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000 * Double(n) / Double(steps)) {
                    send(2, dx / Double(steps))
                    if n == steps { send(4, 0) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000 + 1.2) {
                answer(["before": before, "after": tab.address?.absoluteString ?? ""])
            }

        case "place":
            // A tab put at another place in the row, as a drag would.
            guard let id = request["id"] as? String, let to = request["to"] as? Int,
                  let tab = browser.tabs.first(where: { Bench.short($0) == id && (Store.testing || $0.bench) })
            else { answer(["error": "place needs a tab id and an index"]); return }
            browser.move(tab, to: to)
            answer(["at": browser.tabs.firstIndex { $0.id == tab.id } ?? -1])

        case "group":
            // Tab groups, as their menus make and change them (TabGroups.swift):
            // a tab into a new group or an existing one, or out; a group
            // folded or opened. Test runs only: it rearranges your tabs.
            guard Store.testing else { answer(["error": "group only works on a --test run"]); return }
            let named = request["name"] as? String ?? ""
            let group = browser.tabGroups.first { $0.name == named || $0.id.uuidString.lowercased().hasPrefix(named.lowercased()) && !named.isEmpty }
            if let id = request["id"] as? String {
                guard let tab = browser.tabs.first(where: { Bench.short($0) == id }) else { answer(["error": "no tab “\(id)” — see tabs"]); return }
                if request["new"] as? Bool == true {
                    let made = browser.addTabGroup(containing: tab)
                    if !named.isEmpty { browser.renameTabGroup(made, to: named) }
                    browser.editingGroupID = nil
                } else if named == "none" {
                    browser.move(tab, toGroup: nil)
                } else if let group {
                    browser.move(tab, toGroup: group.id)
                } else {
                    answer(["error": "no group “\(named)”"]); return
                }
            } else if request["fold"] as? Bool == true {
                guard let group else { answer(["error": "no group “\(named)”"]); return }
                browser.toggleTabGroup(group.id)
            } else if request["close"] as? Bool == true {
                guard let group else { answer(["error": "no group “\(named)”"]); return }
                browser.closeTabGroup(group.id)
            }
            answer(["on": browser.prefs.usesTabGroups, "groups": browser.tabGroups.map { group in
                ["id": String(group.id.uuidString.prefix(8)).lowercased(), "name": group.name, "collapsed": group.collapsed,
                 "tabs": browser.tabs(in: group.id).map(Bench.short)] as [String: Any]
            }])

        case "tospace":
            // Move to Space from a tab's menu, to the Nth space. Test runs only.
            guard Store.testing else { answer(["error": "tospace only works on a --test run"]); return }
            guard let id = request["id"] as? String, let index = request["index"] as? Int,
                  let tab = browser.tabs.first(where: { Bench.short($0) == id }),
                  browser.spaces.indices.contains(index - 1)
            else { answer(["error": "tospace needs a tab id and a space number"]); return }
            browser.move(tab, toSpace: browser.spaces[index - 1].id)
            answer(["space": browser.spaces[index - 1].name, "tabs": browser.tabs.map(Bench.short)])

        case "window":
            // The browser's window, when a probe started hidden came up
            // without one: the Window menu's own item for it.
            guard Store.testing else { answer(["error": "window only works on a --test run"]); return }
            if (browser.window ?? Links.window)?.contentView != nil, NSApp.windows.contains(where: { $0 === (browser.window ?? Links.window) }) {
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
            guard Store.testing, let window = browser.window ?? Links.window else { answer(["error": "pages only works on a --test run"]); return }
            func onScreen(_ w: NSWindow) -> Bool { NSScreen.screens.contains { $0.frame.intersects(w.frame) } }
            if request["on"] as? Bool == true {
                _ = room ?? makeRoom()
                window.orderOut(nil)
                for other in NSApp.windows where other !== room && onScreen(other) { other.orderOut(nil) }
                Bench.pagesShown = true
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
                Bench.pagesShown = false
                window.orderFront(nil)
                answer(["pages": false])
            }

        case "picture":
            // The whole window as a picture — the app's own drawing, with each
            // page on screen put in as WebKit pictures it — from a probe
            // started hidden, so nothing shows on anybody's screen. For the
            // images on the site.
            guard Store.testing else { answer(["error": "picture only works on a --test run"]); return }
            guard let window = browser.window ?? Links.window, let frame = window.contentView?.superview,
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

        case "float":
            // The floating window's gestures, handed to it as a trackpad, a
            // wheel or a click would, on screens made up far off the real
            // ones: where a flick, a pull at a side, a dock and a click on
            // the sliver leave it. Test runs only, with the window off every
            // screen (after `film float`), and nothing shown.
            guard Store.testing else { answer(["error": "float only works on a --test run"]); return }
            guard Float.benchAway != nil,
                  let panel = NSApp.windows.first(where: { "\(type(of: $0))" == "Panel" && $0.isVisible }),
                  let controls = panel.contentView?.subviews.first(where: { "\(type(of: $0))" == "Controls" })
            else { answer(["error": "float needs the floating window up, off screen (film float first)"]); return }
            let screen = NSRect(x: -30000, y: -30000, width: 1440, height: 900)
            if Float.benchScreens == nil { Float.benchScreens = [screen] }
            func state() -> [String: Any] {
                let f = panel.frame
                let first = Float.benchScreens?.first ?? screen
                let made: [[Int]] = (Float.benchScreens ?? []).map { made in
                    [Int(made.minX - first.minX), Int(made.minY - first.minY), Int(made.width), Int(made.height)]
                }
                let x = Int((f.minX - first.minX).rounded()), y = Int((f.minY - first.minY).rounded())
                let shown = Int((f.intersection(first).width / f.width * 100).rounded())
                return ["x": x, "y": y, "width": Int(f.width), "height": Int(f.height), "screens": made, "shown": shown]
            }
            // Where it goes on its way, every few milliseconds for a second
            // and a bit: how far out it swings, and where it comes to rest.
            func follow(_ done: @escaping ([String: Any]) -> Void) {
                let first = Float.benchScreens?.first ?? screen
                var xs: [Int] = []
                func look(_ left: Int) {
                    xs.append(Int((panel.frame.minX - first.minX).rounded()))
                    guard left > 0 else {
                        var out = state()
                        out["path"] = xs.enumerated().filter { $0.offset % 4 == 0 }.map(\.element)
                        out["least"] = xs.min() ?? 0
                        out["most"] = xs.max() ?? 0
                        done(out)
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { look(left - 1) }
                }
                look(130)
            }
            // A scroll event whose fingers went `way` on screen, as the
            // window reads it, whatever the Mac's scrolling direction.
            func scroll(_ way: CGVector, phase: Int64, continuous: Bool) -> NSEvent? {
                func make(_ dx: Double, _ dy: Double) -> NSEvent? {
                    guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: continuous ? .pixel : .line, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0)
                    else { return nil }
                    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
                    if continuous {
                        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
                        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
                    } else {
                        cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(dy))
                        cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(dx))
                    }
                    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                    return NSEvent(cgEvent: cg)
                }
                guard let probe = make(1, 1) else { return nil }
                let sign: CGFloat = probe.isDirectionInvertedFromDevice ? 1 : -1
                let perX = sign * probe.scrollingDeltaX, perY = -sign * probe.scrollingDeltaY
                guard perX != 0, perY != 0 else { return nil }
                return make(Double(way.dx / perX), Double(way.dy / perY))
            }
            let args = request["args"] as? [Double] ?? []
            switch request["action"] as? String {
            case "screens":
                // One made-up screen, or two side by side.
                Float.benchScreens = request["two"] as? Bool == true
                    ? [screen, screen.offsetBy(dx: screen.width, dy: 0)] : [screen]
                answer(state())
            case "place":
                guard args.count == 2 else { answer(["error": "float place X Y"]); return }
                let first = Float.benchScreens?.first ?? screen
                panel.setFrameOrigin(NSPoint(x: first.minX + args[0], y: first.minY + args[1]))
                answer(state())
            case "swipe":
                // Fingers down, DX, DY on screen in STEPS moves MS apart, up.
                guard args.count >= 2 else { answer(["error": "float swipe DX DY [STEPS] [MS]"]); return }
                let steps = max(1, Int(args.count > 2 ? args[2] : 10))
                let gap = (args.count > 3 ? args[3] : 16) / 1000
                let step = CGVector(dx: args[0] / Double(steps), dy: args[1] / Double(steps))
                if let down = scroll(.zero, phase: 1, continuous: true) { controls.scrollWheel(with: down) }
                func move(_ n: Int) {
                    guard n < steps else {
                        if let up = scroll(.zero, phase: 4, continuous: true) { controls.scrollWheel(with: up) }
                        follow { answer($0) }
                        return
                    }
                    if let e = scroll(step, phase: 2, continuous: true) { controls.scrollWheel(with: e) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + gap) { move(n + 1) }
                }
                move(0)
            case "wheel":
                guard args.count == 2, let e = scroll(CGVector(dx: args[0], dy: args[1]), phase: 0, continuous: false)
                else { answer(["error": "float wheel DX DY"]); return }
                controls.scrollWheel(with: e)
                follow { answer($0) }
            case "click":
                let middle = NSPoint(x: panel.frame.width / 2, y: panel.frame.height / 2)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let e = NSEvent.mouseEvent(with: type, location: middle, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                     pressure: type == .leftMouseUp ? 0 : 1) else { continue }
                    if type == .leftMouseDown { controls.mouseDown(with: e) } else { controls.mouseUp(with: e) }
                }
                follow { answer($0) }
            default:
                answer(state())
            }

        case "film" where ["float", "land"].contains(request["action"] as? String ?? ""):
            // The video going out into its floating window, or back into its
            // tab (#257), recorded by the page itself on every frame it
            // draws: the size it is laid out at, the video's box in it, and
            // whether everything else is out of the way. Beside it, how much
            // of the view it is in the video fills.
            //
            // Only from a probe started hidden, and it stays hidden. The
            // little window opens off every screen, and the tab's stage is
            // lent to a borderless window off every screen for the filming;
            // those two are left out of the hiding, so WebKit draws the page
            // in them as it would for a person. (Showing the app instead,
            // with the browser's window moved off the screens, put that
            // window back on one: a titled window is put on a screen as it
            // is shown.)
            guard Store.testing else { answer(["error": "film only works on a --test run"]); return }
            guard NSApp.isHidden else { answer(["error": "film float needs a probe started hidden"]); return }
            guard let window = Links.window, let path = request["path"] as? String, !path.isEmpty
            else { answer(["error": "film float needs the browser's window (bench window) and a path"]); return }
            let out = request["action"] as? String == "float"
            let floated = browser.floating.flatMap { id in browser.tabs.first { $0.id == id } }
            guard let tab = out ? browser.active : floated, out != browser.floater.showing
            else { answer(["error": out ? "already floating, or no tab" : "nothing is floating"]); return }
            func stages(in view: NSView) -> [StageView] {
                (view as? StageView).map { [$0] } ?? view.subviews.flatMap(stages)
            }
            guard let root = window.contentView,
                  let stage = stages(in: root).filter({ !$0.isHiddenOrHasHiddenAncestor })
                      .max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }),
                  let home = stage.superview
            else { answer(["error": "no stage in the window"]); return }
            let seconds = min(4, max(0.1, request["seconds"] as? Double ?? 1))
            Float.benchAway = NSPoint(x: -20000, y: -20000)
            let hall = self.hall ?? {
                let hall = NSWindow(contentRect: NSRect(x: -20000, y: -22000, width: 100, height: 100),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
                hall.isReleasedWhenClosed = false
                hall.isExcludedFromWindowsMenu = true
                hall.collectionBehavior = [.transient, .ignoresCycle, .stationary]
                hall.hasShadow = false
                // Left out of the hiding. It also keeps AppKit from taking
                // the little window, closing, for the last one and quitting.
                hall.canHide = false
                self.hall = hall
                return hall
            }()
            hall.setFrame(NSRect(x: -20000, y: -22000, width: stage.frame.width, height: stage.frame.height), display: false)
            hall.orderBack(nil)
            let place = stage.frame
            let after = home.subviews.firstIndex(of: stage).flatMap { home.subviews.indices.contains($0 + 1) ? home.subviews[$0 + 1] : nil }
            stage.removeFromSuperview()
            stage.frame = NSRect(origin: .zero, size: place.size)
            hall.contentView?.addSubview(stage)
            func giveBack() {
                stage.removeFromSuperview()
                stage.frame = place
                if let after, after.superview === home {
                    home.addSubview(stage, positioned: .below, relativeTo: after)
                } else {
                    home.addSubview(stage)
                }
            }
            // A window off every screen counts as covered, and WebKit draws
            // nothing it thinks nobody sees.
            let web = tab.web
            let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
            if web.responds(to: occlusion) {
                typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(web.method(for: occlusion), to: Setter.self)(web, occlusion, false)
            }
            let record = """
            (function () {
              var log = window.__benchFilm = [], t0 = performance.now();
              function look() {
                var v = document.querySelector('[data-office-float]');
                if (!v) {
                  var all = document.querySelectorAll('video'), most = -1;
                  for (var i = 0; i < all.length; i++) {
                    var b = all[i].getBoundingClientRect();
                    if (b.width * b.height > most) { most = b.width * b.height; v = all[i]; }
                  }
                }
                var on = document.documentElement.classList.contains('office-floating') ? 1 : 0;
                var r = v ? v.getBoundingClientRect() : { left: 0, top: 0, width: 0, height: 0 };
                log.push([Math.round(performance.now() - t0), innerWidth, innerHeight, r.left, r.top, r.width, r.height,
                          v ? v.videoWidth : 0, v ? v.videoHeight : 0, on,
                          v && !v.paused ? 1 : 0, document.visibilityState === 'visible' ? 1 : 0]);
              }
              // And each time the float's class comes or goes, the size the
              // page had then.
              var turns = window.__benchTurns = [];
              new MutationObserver(function () {
                var on = document.documentElement.classList.contains('office-floating') ? 1 : 0;
                if (!turns.length || turns[turns.length - 1][3] !== on)
                  turns.push([Math.round(performance.now() - t0), innerWidth, innerHeight, on]);
              }).observe(document.documentElement, { attributes: true, attributeFilter: ['class'] });
              // Looked at just after each frame is drawn, whatever order the
              // frame's own callbacks — a landing's among them — ran in.
              var drawn = new MessageChannel();
              drawn.port1.onmessage = function () {
                look();
                if (performance.now() - t0 < \(Int(seconds * 1000))) requestAnimationFrame(frame);
              };
              function frame() { drawn.port2.postMessage(0); }
              requestAnimationFrame(frame);
              return true;
            })();
            """
            // Where the page is, from this side, every few hundredths.
            var hosts: [[String: Any]] = []
            var started = CACurrentMediaTime()
            // Every size the web view is given on the way, however briefly:
            // each one is a layout WebKit is asked for.
            var sizes: [[Int]] = []
            web.postsFrameChangedNotifications = true
            let resized = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: web, queue: nil) { _ in
                MainActor.assumeIsolated {
                    let size = web.frame.size
                    if sizes.last.map({ $0[1] != Int(size.width) || $0[2] != Int(size.height) }) ?? true {
                        sizes.append([Int((CACurrentMediaTime() - started) * 1000), Int(size.width), Int(size.height)])
                    }
                }
            }
            func watch() {
                let showing = NSApp.windows.filter { w in w.isVisible && NSScreen.screens.contains { $0.frame.intersects(w.frame) } }
                if !showing.isEmpty { NSApp.hide(nil) }
                let view = web.bounds.size
                hosts.append(["t": Int((CACurrentMediaTime() - started) * 1000),
                              "in": web.window === hall ? "tab" : web.window == nil ? "none" : "float",
                              "view": [Int(view.width), Int(view.height)], "showing": showing.map { "\(type(of: $0))" }])
                guard CACurrentMediaTime() - started < seconds else { return finish(view) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { watch() }
            }
            func finish(_ view: NSSize) {
                NotificationCenter.default.removeObserver(resized)
                web.evaluateInSearch("[window.__benchFilm, window.__benchTurns]") { found in
                    MainActor.assumeIsolated {
                        giveBack()
                        let both = found as? [Any] ?? []
                        let rows = (both.first as? [[Any]] ?? []).map { $0.map { ($0 as? NSNumber)?.doubleValue ?? 0 } }
                        let turns = (both.last as? [[Any]] ?? []).map { $0.map { ($0 as? NSNumber)?.intValue ?? 0 } }
                        let fill = { (part: CGFloat, whole: CGFloat) in whole > 0 ? (part / whole * 1000).rounded() / 1000 : 0 }
                        let frames: [[String: Any]] = rows.filter { $0.count == 12 }.map { n in
                            // The picture inside the video's box, fitted as
                            // `contain` fits it, cut to what both the page
                            // and the view it ends up in show.
                            var picture = NSRect(x: n[3], y: n[4], width: n[5], height: n[6])
                            if n[7] > 0, n[8] > 0, n[5] > 0, n[6] > 0 {
                                let scale = min(n[5] / n[7], n[6] / n[8])
                                picture = NSRect(x: n[3] + (n[5] - n[7] * scale) / 2, y: n[4] + (n[6] - n[8] * scale) / 2,
                                                 width: n[7] * scale, height: n[8] * scale)
                            }
                            let seen = picture.intersection(NSRect(x: 0, y: 0, width: min(n[1], view.width), height: min(n[2], view.height)))
                            return ["t": Int(n[0]), "page": [Int(n[1]), Int(n[2])], "video": [Int(n[5].rounded()), Int(n[6].rounded())],
                                    "isolated": n[9] == 1, "playing": n[10] == 1, "seen": n[11] == 1,
                                    "fill": seen.isNull ? [0, 0] : [fill(seen.width, view.width), fill(seen.height, view.height)]]
                        }
                        let result: [String: Any] = ["view": [Int(view.width), Int(view.height)], "frames": frames, "hosts": hosts,
                                                     "sizes": sizes, "turns": turns]
                        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]) {
                            try? data.write(to: URL(fileURLWithPath: path + ".json"))
                        }
                        answer(["frames": frames.count, "saved": path + ".json"])
                    }
                }
            }
            // A video paused while its page was out of sight — WebKit stops
            // a muted one nobody can see — started again, now that it can
            // be seen: in the page's own world, through its player where it
            // has one (YouTube's pauses a video started behind its back).
            // Then the page draws a few frames where it is, and moves.
            let start = """
            (function () {
              var v = document.querySelector('video'), p = document.getElementById('movie_player');
              if (!\(out) || !v || !v.paused) return 0;
              v.muted = true;
              if (p && p.playVideo) { if (p.mute) p.mute(); p.playVideo(); } else v.play();
              return 1;
            })();
            """
            web.evaluateJavaScript(start) { restarted, _ in
                MainActor.assumeIsolated {
                    DispatchQueue.main.asyncAfter(deadline: .now() + ((restarted as? Int) == 1 ? 1 : 0)) {
                        web.evaluateInSearch(record) { _ in
                            MainActor.assumeIsolated {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    started = CACurrentMediaTime()
                                    watch()
                                    browser.toggleFloat()
                                }
                            }
                        }
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
            guard let window = browser.window ?? Links.window, let frame = window.contentView?.superview,
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

        case "update":
            // The updater, for a test run pointed at its own feed: `check`
            // is the menu's Check for Updates…, `disk` the Download button.
            guard Store.testing else { answer(["error": "update only works on a --test run"]); return }
            let updater = Updater.shared
            switch request["action"] as? String {
            case "check": updater.checkByHand()
            case "disk": updater.openDisk()
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                answer(["stage": String(describing: updater.stage), "checking": updater.checking,
                        "disk": Updater.diskVerdict, "fetchingDisk": updater.fetchingDisk])
            }

        case "consent":
            // The mark the Settings switch leaves (see Consent), in this test
            // world's own account: given, then granted or revoked if asked.
            guard Store.testing else { answer(["error": "consent only works on a --test run"]); return }
            let before = Consent.given
            switch request["action"] as? String {
            case "grant": Consent.grant()
            case "revoke": Consent.revoke()
            default: break
            }
            answer(["before": before, "after": Consent.given])

        case "fold":
            // The strip or the column as it comes out over the page once
            // folded (see Fold.swift), drawn off screen over red: whatever of
            // the page would show through it shows red. `picture` can't say —
            // it lays the page's own picture over everything drawn above it.
            guard Store.testing else { answer(["error": "fold only works on a --test run"]); return }
            guard let path = request["path"] as? String else { answer(["error": "fold needs a path"]); return }
            guard browser.folded, browser.peeking else { answer(["error": "fold and peek first: ui folded on, ui peek on"]); return }
            let width = request["width"] as? Double ?? 1100
            let size = NSSize(width: width, height: browser.prefs.sidebar ? 500 : 120)
            let host = NSHostingView(rootView: ZStack(alignment: .topLeading) {
                Color.red
                Fold(browser: browser, prefs: browser.prefs)
            }.frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSApp.effectiveAppearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { answer(["error": "nothing drawn"]); return }
                host.cacheDisplay(in: host.bounds, to: picture)
                do {
                    try picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    answer(["saved": path])
                } catch { answer(["error": error.localizedDescription]) }
                window.contentView = nil
            }

        case "little":
            // A small window for a link, made without being shown (see
            // Little.swift); then kept into the row, or closed.
            switch request["what"] as? String ?? "" {
            case "keep": LittleWindow.all.last?.keep()
            case "close": LittleWindow.all.last?.close()
            default:
                guard let text = request["what"] as? String, let url = URL(string: text) else { answer(["error": "little needs a url, keep or close"]); return }
                LittleWindow.show(url, for: browser, front: false)
            }
            answer([
                "littles": LittleWindow.all.map { $0.tab.address?.absoluteString ?? "" },
                "tabs": browser.tabs.map { ($0.pin != nil ? "PIN " : "") + ($0.address?.host() ?? "blank") },
                "active": browser.active?.address?.host() ?? "",
            ])

        case "site":
            // The site card for the tab on screen, or one step in on its
            // connection, drawn off screen (see SiteCard.swift).
            guard Store.testing else { answer(["error": "site only works on a --test run — it would picture your tab"]); return }
            guard let path = request["path"] as? String else { answer(["error": "site needs a path"]); return }
            guard let tab = browser.active, !tab.isBlank else { answer(["error": "no page on screen"]); return }
            let deeper = request["security"] as? Bool == true
            // On the ground: off screen there is no glass to stand on.
            let host = NSHostingView(rootView: AnyView(SiteCard(browser: browser, tab: tab, deeper: deeper) {}.fixedSize().background(Palette.ground)))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSApp.effectiveAppearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
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
            guard Store.testing else { answer(["error": "column only works on a --test run — it would picture your tabs"]); return }
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

        case "split":
            splitCommand(request, browser: browser, answer)

        case "ui":
            // Open or close the app's own panels, to reproduce what a person
            // did without a person.
            if let on = request["settings"] as? Bool { browser.tuning = on }
            if let on = request["passwords"] as? Bool, Store.testing { browser.managing = on }
            if let on = request["welcome"] as? Bool { browser.welcoming = on }
            if let on = request["history"] as? Bool { browser.recalling = on }
            if let on = request["downloads"] as? Bool { browser.hoarding = on }
            if let on = request["bookmarks"] as? Bool { browser.bookmarking = on }
            // The Bring things over sheet: on, off, on at a browser by name,
            // or on for the extensions alone, as Settings › Extensions opens it.
            if let text = request["import"] as? String {
                browser.bringingExtensions = text == "extensions"
                browser.bringingIn = ["off", "false", "0", "no"].contains(text) ? nil
                    : ["on", "true", "1", "yes", "extensions"].contains(text) ? "" : text
            }
            if let on = request["hidden"] as? Bool { browser.reviewing = on }
            if let look = (request["look"] as? String).flatMap(Look.init) { browser.prefs.look = look }
            if let side = request["side"] as? String {
                guard let position = SidebarPosition(rawValue: side) else {
                    answer(["error": "side needs left or right"])
                    return
                }
                browser.prefs.sidePosition = position
            }
            if let on = request["pages120"] as? Bool { browser.prefs.fastPages = on }
            if let on = request["sidebar"] as? Bool { browser.prefs.sidebar = on }
            if let on = request["spaces"] as? Bool { browser.prefs.usesSpaces = on }
            if let on = request["hides"] as? Bool { browser.prefs.sideHides = on }
            if let on = request["folded"] as? Bool { browser.folded = on }
            // The window's own full screen as the chrome sees it, without
            // the window going there: a test run never takes the screen.
            if let on = request["fullscreen"] as? Bool, Store.testing { browser.fullScreen = on }
            if let on = request["peek"] as? Bool { browser.peeking = on }
            // A peek at a link (Peek.swift): its two buttons.
            if let what = request["peeklink"] as? String {
                if what == "keep" { browser.keepPeek() }
                else if what == "beside" { browser.keepPeek(beside: true) }
                else { browser.closePeek() }
            }
            // The address of the tab on screen being edited in the tab, with
            // this typed, and that edit let go of by a click elsewhere.
            if let text = request["edittab"] as? String, let tab = browser.active {
                browser.beginTabEdit(tab)
                browser.tabDraft = text
            }
            if request["finishedit"] as? Bool == true { browser.finishTabEdit() }
            if #available(macOS 15.4, *), let on = request["extensions"] as? Bool { Extensions.shared.menuOpen = on }
            answer(["ok": true])

        case "extensions", "ext-add", "ext-folder", "ext-press", "ext-remove", "ext-reload", "ext-page", "ext-popup", "ext-menu", "ext-pin", "ext-shot", "ext-answer", "ext-enable", "capture", "capture-stop":
            guard #available(macOS 15.4, *) else {
                answer(["error": "extensions need macOS 15.4"])
                return
            }
            extensionCommand(verb, request, browser: browser, answer)

        default:
            answer(["error": "unknown command “\(verb)”", "commands": [
                "tabs", "open", "go", "close", "wait", "sleep", "select", "text", "eval", "click", "type", "submit", "shot", "probe", "key", "resize", "hit", "film", "float", "window", "pages", "picture", "place", "group", "tospace", "field", "bookmark", "menu", "keyeq", "fill", "pin", "middle", "windows", "quit", "towindow", "news", "pull", "space", "split", "strip", "column", "fold", "consent", "update", "site", "little", "ui", "import", "import-preview", "import-file", "import-file-start", "import-file-status", "import-file-cancel", "accounts", "find", "answer", "visible", "ai", "notifications",
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
    private weak var pressed: NSView?

    private func splitCommand(
        _ request: [String: Any],
        browser: Browser,
        _ answer: @escaping ([String: Any]) -> Void
    ) {
        guard Store.testing else {
            answer(["error": "split only works on a --test run"])
            return
        }

        func reply(_ extra: [String: Any] = [:]) {
            answer(splitState(browser).merging(extra) { _, new in new })
        }
        func tab(_ field: String = "id") -> Tab? {
            guard let id = request[field] as? String else { return nil }
            return find(["id": id], in: browser)
        }

        switch request["action"] as? String ?? "state" {
        case "state":
            reply()

        case "enabled":
            guard let on = request["on"] as? Bool else { answer(["error": "split enabled needs on"]); return }
            browser.prefs.splitView = on
            reply()

        case "group":
            guard let page = tab() else { answer(["error": "split group needs id"]); return }
            if let id = (request["group"] as? String).flatMap(UUID.init) {
                browser.move(page, toGroup: id)
            } else if request["group"] as? String == "none" {
                browser.move(page, toGroup: nil)
            } else {
                _ = browser.addTabGroup(containing: page)
            }
            reply()

        case "collapse":
            guard let id = (request["group"] as? String).flatMap(UUID.init) else {
                answer(["error": "split collapse needs group UUID"]); return
            }
            browser.toggleTabGroup(id)
            reply()

        case "step":
            browser.step(request["direction"] as? Int ?? 1)
            reply()

        case "moveSpace":
            guard let page = tab(), let id = (request["spaceID"] as? String).flatMap(UUID.init) else {
                answer(["error": "split moveSpace needs id and spaceID"]); return
            }
            browser.move(page, toSpace: id) { reply() }

        case "moveWindow":
            guard let page = tab() else { answer(["error": "split moveWindow needs id"]); return }
            let target = (request["targetWindow"] as? Int).flatMap { n in
                Browsers.all.indices.contains(n - 1) ? Browsers.all[n - 1] : nil
            }
            browser.moveToWindow(page, target)
            reply(["windows": Browsers.all.count])

        case "rows":
            reply(["rows": browser.allRows().mapValues { row in
                ["tabs": row.tabs.count, "splits": row.splits.count, "active": row.active] as [String: Any]
            }])

        case "mouse":
            guard let window = browser.window,
                  let points = request["points"] as? [[Double]], !points.isEmpty,
                  points.allSatisfy({ $0.count == 2 }) else {
                answer(["error": "split mouse needs two or more [x,y] window points"]); return
            }
            // "hold": the button stays down after the last point; "resume":
            // it was already down, so the first point is a drag — a drag in
            // two calls, looked at in between. "clicks": 2 for a double-click.
            let hold = request["hold"] as? Bool == true
            let resume = request["resume"] as? Bool == true
            let clicks = request["clicks"] as? Int ?? 1
            let direct = request["to"] as? String == "view"
            for (index, coordinates) in points.enumerated() {
                let type: NSEvent.EventType = index == 0 && !resume ? .leftMouseDown
                    : index == points.count - 1 && !hold ? .leftMouseUp : .leftMouseDragged
                let point = NSPoint(x: coordinates[0], y: Double(window.frame.height) - coordinates[1])
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: index, clickCount: clicks,
                    pressure: type == .leftMouseUp ? 0 : 1
                ) else { continue }
                // Through the app, as a hand's arrive, one turn of the run
                // loop apart: its monitors see them, though a hidden window
                // hands them to no view. "view": straight to the view under
                // the press instead, as `tap` does, for what the view itself
                // does with them.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 * Double(index)) {
                    guard direct else { NSApp.sendEvent(event); return }
                    if type == .leftMouseDown {
                        let root = window.contentView?.superview
                        self.pressed = root.flatMap { $0.hitTest($0.convert(point, from: nil)) }
                    }
                    switch type {
                    case .leftMouseDown: self.pressed?.mouseDown(with: event)
                    case .leftMouseDragged: self.pressed?.mouseDragged(with: event)
                    default: self.pressed?.mouseUp(with: event)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 * Double(points.count) + 0.4) { reply() }

        case "open":
            guard let url = (request["url"] as? String).flatMap(URL.init(string:)) else {
                answer(["error": "split open needs a URL"])
                return
            }
            let source = request["from"] == nil ? browser.active : tab("from")
            let page = browser.open(url, foreground: request["foreground"] as? Bool ?? true,
                                    atEnd: request["atEnd"] as? Bool ?? false, from: source)
            reply(["resultID": Bench.short(page)])

        case "private":
            browser.newShyTab()
            reply()

        case "bench":
            guard let url = (request["url"] as? String).flatMap(URL.init(string:)) else {
                answer(["error": "split bench needs a URL"])
                return
            }
            let page = browser.benchOpen(url)
            house(page)
            reply(["resultID": Bench.short(page)])

        case "start":
            browser.startSplit()
            reply()

        case "pair":
            guard let dragged = tab(), let target = tab("with") else {
                answer(["error": "split pair needs id and with"])
                return
            }
            let side = request["side"] as? String ?? "left"
            guard side == "left" || side == "right" else {
                answer(["error": "split pair side must be left or right"])
                return
            }
            browser.pair(dragged, with: target, onLeft: side == "left")
            reply()

        case "focus", "select":
            guard let page = tab() else { answer(["error": "split focus needs id"]); return }
            if request["action"] as? String == "select" { browser.select(page) }
            else { browser.focusPane(page) }
            reply()

        case "detach":
            guard let page = tab() else { answer(["error": "split detach needs id"]); return }
            browser.detachSplit(page)
            reply()

        case "fraction":
            guard let pair = request["split"] as? String,
                  let id = UUID(uuidString: pair),
                  let fraction = request["fraction"] as? Double
            else { answer(["error": "split fraction needs split UUID and fraction"]); return }
            browser.setSplitFraction(id, fraction: fraction)
            reply()

        case "close":
            guard let page = tab() else { answer(["error": "split close needs id"]); return }
            browser.close(page)
            reply()

        case "newTab":
            browser.newTab()
            reply()

        case "reopen":
            browser.reopen()
            reply()

        case "insert":
            guard let url = (request["url"] as? String).flatMap(URL.init(string:)),
                  let index = request["index"] as? Int
            else { answer(["error": "split insert needs URL and index"]); return }
            let page = Tab()
            browser.prepare(page)
            browser.insert(page, at: index)
            page.go(to: url)
            reply(["resultID": Bench.short(page)])

        case "move":
            guard let page = tab(), let index = request["to"] as? Int else {
                answer(["error": "split move needs id and to"])
                return
            }
            browser.move(page, to: index)
            reply()

        case "drop":
            guard let page = tab() else { answer(["error": "split drop needs id"]); return }
            browser.dropTabIntoStrip(page, before: tab("before"))
            reply()

        case "clear":
            // The line's Clear, with the pinned rows on (Browser.clearTabs).
            browser.clearTabs()
            reply()

        case "space":
            switch request["spaceAction"] as? String {
            case "new": browser.addSpace(named: request["name"] as? String ?? "Split test")
            case "go":
                guard let id = (request["spaceID"] as? String).flatMap(UUID.init) else {
                    answer(["error": "split space go needs a UUID"])
                    return
                }
                browser.switchSpace(to: id)
            default:
                answer(["error": "split space action must be new or go"])
                return
            }
            reply()

        case "sleep":
            guard let page = tab() else { answer(["error": "split sleep needs id"]); return }
            browser.sleep(page) { result in reply(["sleepResult": result]) }

        case "save":
            browser.writeSession(now: true)
            reply()

        case "closeOthers":
            guard let page = tab() else { answer(["error": "split closeOthers needs id"]); return }
            browser.closeOthers(but: page)
            reply()
        case "keys":
            // The keys handed to a page's view, as the key-view loop would.
            guard let page = tab(), let web = page.built, let window = web.window else {
                answer(["error": "split keys needs the id of a page on screen"]); return
            }
            window.makeFirstResponder(web)
            reply()
        case "motion":
            // The pictures moving on the stage now (see PaneStage.animate).
            func stage(in view: NSView) -> PaneStage? {
                if let stage = view as? PaneStage { return stage }
                for sub in view.subviews { if let found = stage(in: sub) { return found } }
                return nil
            }
            guard let root = browser.window?.contentView?.superview, let found = stage(in: root) else {
                answer(["error": "no split stage in this window"]); return
            }
            reply(["motion": found.motionNow])
        case "pose":
            // A card as a page's question would put up, with no page waiting
            // on it: a page that asks is held by WebKit until it is answered,
            // and a picture of the window would wait on it too.
            guard let page = tab() else { answer(["error": "split pose needs id"]); return }
            browser.paneQuestions.append(PaneQuestion(
                tab: page.id, host: request["host"] as? String ?? "example.com",
                message: request["message"] as? String ?? "", kind: .confirm, reply: { _, _ in }
            ))
            reply()
        case "answer":
            // The first question the page asked, answered as its card would.
            guard let page = tab(), let question = browser.paneQuestions.first(where: { $0.tab == page.id }) else {
                answer(["error": "split answer needs the id of a page with a question"]); return
            }
            browser.answer(question, ok: request["ok"] as? Bool ?? true, text: request["text"] as? String)
            reply()
        case "swap": browser.swapSplit(); reply()
        case "even": browser.evenSplit(); reply()
        case "closeBoth": browser.closeSplit(); reply()
        case "dismiss": browser.dismiss(); reply()
        case "side":
            browser.focusPane(onLeft: request["left"] as? Bool ?? true)
            reply()
        case "openIn":
            guard let page = tab() else { answer(["error": "split openIn needs id"]); return }
            browser.openInSplit(page)
            reply()
        case "fill":
            guard let blank = tab(), let page = tab("with") else { answer(["error": "split fill needs id and with"]); return }
            browser.fill(blank, with: page)
            reply()

        default:
            answer(["error": "unknown split action"])
        }
    }

    private func splitState(_ browser: Browser) -> [String: Any] {
        func short(_ id: UUID?) -> Any {
            guard let id, let tab = browser.tabs.first(where: { $0.id == id }) else { return NSNull() }
            return Bench.short(tab)
        }
        return [
            "tabs": browser.tabs.map { tab in
                [
                    "id": Bench.short(tab),
                    "title": tab.title,
                    "url": tab.address?.absoluteString ?? "",
                    "blank": tab.isBlank,
                    "shy": tab.shy,
                    "bench": tab.bench,
                    "asleep": tab.asleep,
                    "awakeReason": browser.awake(because: tab) ?? "",
                ] as [String: Any]
            },
            "splits": browser.splits.map { pair in
                [
                    "id": pair.id.uuidString,
                    "left": short(pair.left),
                    "right": short(pair.right),
                    "fraction": pair.fraction,
                    "tabs": pair.tabs.map { short($0) },
                    "sizes": pair.sizes,
                    "axis": pair.axis.rawValue,
                    "focused": short(pair.focused),
                ] as [String: Any]
            },
            "activeID": short(browser.activeID),
            "displayedIDs": browser.displayedTabs.map { Bench.short($0) },
            "visibleIDs": browser.tabs.filter { browser.visibleTabIDs.contains($0.id) }.map { Bench.short($0) },
            "shownIDs": browser.shownTabs.map { Bench.short($0) },
            "groups": browser.tabGroups.map { ["id": $0.id.uuidString, "collapsed": $0.collapsed] as [String: Any] },
            "groupIDs": browser.tabs.map { $0.groupID?.uuidString ?? "" },
            "enabled": browser.prefs.splitView,
            "finding": browser.finding,
            "needle": browser.needle,
            "findStatus": browser.findStatus ?? "",
            "pins": browser.tabs.filter { $0.pin != nil }.map { Bench.short($0) },
            // Every pin kept as a row, drawn so or not (Tab.listed).
            "listed": browser.tabs.filter { $0.pin != nil && $0.listed }.map { Bench.short($0) },
            // What ⇧⌘T would bring back, as its menu item says it.
            "reopenTitle": browser.reopenTitle,
            "ghosts": browser.ghosts.count,
            // What pages of the pair asked, oldest first (see PaneQuestion).
            "questions": browser.paneQuestions.map { question in
                ["tab": short(question.tab), "host": question.host, "message": question.message,
                 "kind": { switch question.kind { case .alert: "alert"; case .confirm: "confirm"; case .prompt: "prompt" } }()]
            },
            "held": browser.heldDialogs.mapValues(\.count).reduce(into: [String: Int]()) { out, entry in
                if let tab = browser.tabs.first(where: { $0.id == entry.key }) { out[Bench.short(tab)] = entry.value }
            },
            "paneFrames": browser.tabs.compactMap { tab -> [String: Any]? in
                guard let web = tab.built, let window = browser.window, web.window === window else { return nil }
                let frame = web.convert(web.bounds, to: nil)
                return ["id": Bench.short(tab), "x": Double(frame.minX),
                        "y": Double(window.frame.height - frame.maxY),
                        "width": Double(frame.width), "height": Double(frame.height)]
            },
            "spaceID": browser.spaceID.uuidString,
            "spaceIDs": browser.spaces.map { $0.id.uuidString },
        ]
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
        case "capture":
            // Extensions' screen recording: ids given, what is recording, who
            // may, and the last request with its answer.
            answer(ExtensionCapture.shared.state)
        case "capture-stop":
            guard let id = request["id"] as? String else { answer(["error": "capture-stop needs an id"]); return }
            ExtensionCapture.shared.stop(id)
            answer(["stopping": id])
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
            "page": tab.pageAddress?.absoluteString ?? "",
            "title": tab.title,
            "name": tab.name ?? "",
            // The group it is in, by name, whether or not groups are on.
            "group": browser?.group(of: tab).flatMap { id in browser?.tabGroups.first { $0.id == id }?.name } ?? "",
            "loading": tab.loading,
            "hollow": tab.hollow,
            "view": tab.built?.url?.absoluteString ?? "",
            "bench": tab.bench,
            "active": tab.id == browser?.activeID,
            "asleep": tab.asleep,
            "shy": tab.shy,
            "noisy": tab.noisy,
            "muted": tab.muted,
            "extensions": { if #available(macOS 15.4, *) { return tab.carriesExtensions } else { return false } }(),
            // The page's WebKit process, for measuring what it holds.
            "process": tab.built.flatMap { $0.value(forKey: "_webProcessIdentifier") as? Int } ?? 0,
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

    // MARK: - nothing on a screen

    /// Set once `pages on` has shown a hidden probe again, so WebKit paints
    /// its pages: from then on the app is no longer hidden, and a window
    /// ordered in would come onto the screen.
    static var pagesShown = false
    /// Windows a test run let onto a screen. Every answer names them from
    /// then on, and ./bench fails: a test must never show a window there.
    private(set) static var caught: [String] = []
    private static var watching: [NSObjectProtocol] = []

    static func onScreen(_ window: NSWindow) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    /// A window about to be ordered in during a test run with pages shown
    /// (Windows.open, Windows.show): the app hidden again first, so it
    /// waits unseen. Moving it off the screen isn't enough — AppKit pulls a
    /// titled window back onto one as it comes in. `pages on` again puts
    /// every window away before it shows the app.
    static func keepOff(_ window: NSWindow) {
        guard Store.testing, pagesShown else { return }
        NSApp.hide(nil)
        pagesShown = false
    }

    /// Any other window that comes onto a screen in a test run — a sheet, a
    /// panel, one made by a path nobody thought of: taken off at once and
    /// named in every answer.
    static func watchScreens() {
        guard watching.isEmpty else { return }
        // The app itself shown or brought forward by anything but `pages on`
        // (which never activates it): hidden again at once.
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didUnhideNotification] {
            watching.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    if note.name == NSApplication.didUnhideNotification, pagesShown { return }
                    caught.append("the app \(note.name == NSApplication.didUnhideNotification ? "shown" : "brought forward")")
                    NSApp.hide(nil)
                    pagesShown = false
                }
            })
        }
        watching.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, window.isVisible,
                      window.occlusionState.contains(.visible), onScreen(window) else { return }
                caught.append("\(type(of: window)) “\(window.title)” at \(NSStringFromRect(window.frame))")
                NSApp.hide(nil)
                pagesShown = false
            }
        })
    }
    /// Where `film float` lends the tab's stage, off every screen.
    private var hall: NSWindow?

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

    /// The last page `ai read` read, for `ai check`.
    static var aiRead: AIPage.Read?

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
