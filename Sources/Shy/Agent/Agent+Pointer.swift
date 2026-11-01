import AppKit
import Combine
import WebKit

// Steering by the pointer and the keyboard, and asking you first when the handover says so.
extension Agent {
    /// What a key named in typeat sends: its key code and its characters.
    static let keys: [String: (code: UInt16, characters: String)] = [

        "Enter": (36, "\r"), "Tab": (48, "\t"), "Escape": (53, "\u{1b}"), "Backspace": (51, "\u{7f}"),

        "Delete": (117, String(UnicodeScalar(NSDeleteFunctionKey)!)),

        "ArrowUp": (126, String(UnicodeScalar(NSUpArrowFunctionKey)!)),

        "ArrowDown": (125, String(UnicodeScalar(NSDownArrowFunctionKey)!)),

        "ArrowLeft": (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!)),

        "ArrowRight": (124, String(UnicodeScalar(NSRightArrowFunctionKey)!)),

        "Space": (49, " "),
    ]

    /// A point in the latest screenshot's pixels, as the page's own points;
    /// nil when it isn't on the page.
    func point(_ request: [String: Any], on page: Page) -> CGPoint? {
        guard let x = (request["x"] as? NSNumber)?.doubleValue, let y = (request["y"] as? NSNumber)?.doubleValue else { return nil }
        let scale = page.shotScale ?? page.web.window?.backingScaleFactor ?? 2
        let at = CGPoint(x: x / scale, y: y / scale)
        let size = page.web.bounds.size
        guard at.x >= 0, at.y >= 0, at.x < size.width, at.y < size.height else { return nil }
        return at
    }

    /// Nil when the page is as the latest shot showed it — the same
    /// address, size and scroll, and done loading — or why a point from
    /// that shot would land somewhere else now. Not asked without a point.
    func still(_ page: Page, _ needed: Bool, _ then: @escaping (String?) -> Void) {
        guard needed else { return then(nil) }
        guard let seen = page.seen else { return then("take a screenshot first (shy_shot): x and y are its pixels") }
        guard page.web.url == seen.url else { return then("the page went somewhere else since the latest screenshot: take a new one") }
        guard !page.web.isLoading else { return then("the page is still loading: wait for it (shy_wait), then take a new screenshot") }
        let size = page.web.bounds.size
        guard abs(size.width - seen.size.width) < 1, abs(size.height - seen.size.height) < 1 else {
            return then("the page changed size since the latest screenshot (\(Int(seen.size.width))×\(Int(seen.size.height)) then, \(Int(size.width))×\(Int(size.height)) now): take a new one")
        }
        run(Agent.scrolledTo, on: page) { value, _ in
            let at = (value as? [NSNumber])?.map { CGFloat($0.doubleValue) } ?? []
            guard at.count == 2, abs(at[0] - seen.scroll.x) < 1, abs(at[1] - seen.scroll.y) < 1 else {
                return then("the page scrolled since the latest screenshot: take a new one")
            }
            then(nil)
        }
    }

    /// A mouse event at a point of the page, for its own window.
    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, on web: WKWebView) -> NSEvent? {
        guard let window = web.window else { return nil }
        let local = NSPoint(x: point.x, y: web.isFlipped ? point.y : web.bounds.height - point.y)
        return NSEvent.mouseEvent(with: type, location: web.convert(local, to: nil), modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
    }

    /// Moved there and pressed, as a mouse would: the page sees a real
    /// click, hover first. What a click lets a page do that it couldn't
    /// otherwise — a window, a download, a file, the camera — is refused
    /// all the same (see the delegate below), and its clipboard is kept
    /// (`sparing`).
    func press(_ page: Page, _ point: CGPoint) {
        page.cursor = point
        page.presses += 1
        let web = page.web
        if let moved = mouse(.mouseMoved, at: point, on: web) { web.mouseMoved(with: moved) }
        if let down = mouse(.leftMouseDown, at: point, on: web) { web.mouseDown(with: down) }
        if let up = mouse(.leftMouseUp, at: point, on: web) { web.mouseUp(with: up) }
    }

    /// Typed a key at a time into whatever has the focus, then a key.
    func keyboard(_ text: String, then key: String?, on page: Page) {
        let web = page.web
        guard let window = web.window else { return }
        if window.firstResponder !== web { window.makeFirstResponder(web) }
        func send(_ characters: String, code: UInt16) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                   context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                   isARepeat: false, keyCode: code)
                else { continue }
                if type == .keyDown { web.keyDown(with: event) } else { web.keyUp(with: event) }
            }
        }
        for character in text {
            if character == "\n" { send("\r", code: 36) } else { send(String(character), code: 0) }
        }
        if let key, let sent = Agent.keys[key] { send(sent.characters, code: sent.code) }
    }

    /// Your clipboard as it was, whatever the page did with the click or
    /// keys it was given: a real click lets a page write to it, and an
    /// agent's never should.
    func sparing(_ page: Page, _ act: () -> Void) {
        let board = NSPasteboard.general
        let before = board.changeCount
        let kept: [NSPasteboardItem] = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        act()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard board.changeCount != before else { return }
            board.clearContents()
            board.writeObjects(kept)
            page.note("The page wrote to your clipboard; it was put back")
        }
    }

    /// Clicks and typing on a page with your sign-in in it: only what you
    /// allowed, and asked about first unless you said not to — with a look
    /// at the spot, for one at a point.
    /// The sign-in's time is up: taken back now, whatever the timer says.
    func expire(_ page: Page) {
        if let handover = page.live, handover.ends <= Date() { end(page, "its time was up") }
    }

    func permit(_ page: Page, _ what: String, verb: String, at point: CGPoint?,

                        _ answer: @escaping ([String: Any]) -> Void, act: @escaping () -> Void) {
        guard let handover = page.live else { return act() }
        guard handover.acts else {
            page.note("Refused: \(what) (read only)")
            return answer(["error": "this page was handed over read-only: the person allowed reading, not clicking or typing"])
        }
        guard handover.asks else { return act() }
        page.acting = "waiting for you"
        let doing = Agent.doing[verb] ?? "acting"
        // The page you were asked about: a yes is for that page, not one
        // the agent sent the tab on to while you read the question.
        let asked = page.web.url
        let asking = { (picture: NSImage?) in
            if let point { page.cursor = point }
            self.ask(page, handover, what, picture: picture) { yes in
                guard yes else {
                    page.note("You refused: \(what)")
                    return answer(["error": "the person said no to this"])
                }
                self.expire(page)
                guard page.live != nil else { return answer(["error": "the sign-in was taken back while you were asked"]) }
                guard page.web.url == asked else {
                    page.note("Not done: the page changed while you were asked")
                    return answer(["error": "the page changed while the person was asked; ask again"])
                }
                page.acting = doing
                act()
            }
        }
        guard let point else { return asking(nil) }
        let shot = WKSnapshotConfiguration()
        shot.rect = CGRect(x: point.x - 120, y: point.y - 70, width: 240, height: 140)
            .intersection(page.web.bounds)
        page.web.takeSnapshot(with: shot) { image, _ in
            MainActor.assumeIsolated { asking(image) }
        }
    }

    /// Waits for your yes in the folder; no answer in 40 seconds is a no.
    func ask(_ page: Page, _ handover: Handover, _ what: String, picture: NSImage? = nil, _ reply: @escaping (Bool) -> Void) {
        var replied = false
        let id = UUID()
        let once: (Bool) -> Void = { [weak self] yes in
            guard !replied else { return }
            replied = true
            self?.pending.removeAll { $0.id == id }
            reply(yes)
        }
        pending.append(Approval(id: id, page: page.id, site: handover.site, what: what, picture: picture, reply: once))
        NSApp.requestUserAttention(.informationalRequest)
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { once(false) }
    }

    func answer(_ approval: Approval, _ yes: Bool) {
        approval.reply(yes)
    }
}
