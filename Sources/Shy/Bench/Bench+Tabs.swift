import AppKit
import AuthenticationServices
import SwiftUI
import WebKit

#if DEBUG
extension Bench {
    /// Tabs and the agent's pages: opening, going, closing, reading, clicking, typing, windows and shots.
    func tabCommand(_ verb: String, _ request: [String: Any], _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        switch verb {
        case "layouts":
            // Test runs only: every frame the pages on screen take, looked at
            // every few milliseconds and after each pass of the run loop, for
            // `seconds`, each change once with when it came. With `immerse`,
            // a page's full screen is faked in or out first, as the page's own
            // word that it is going or back would (Forms.swift); nothing goes
            // full screen. How many times a change of chrome moves the page
            // (Tests/fullscreen_exit.py).
            guard Store.testing else { answer(["error": "layouts is for test runs"]); return }
            let seconds = min(10, request["seconds"] as? Double ?? 1.5)
            let record = LayoutRecord(browser: browser)
            record.look()
            if let on = request["immerse"] as? Bool {
                guard let tab = request["id"] == nil ? browser.active : find(request, in: browser) else { answer(missing(request)); return }
                tab.immersed = on
            }
            record.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                record.stop()
                answer(["layouts": record.seen])
            }

        case "tabs":
            // A private tab is nobody's business but yours: a test run has none
            // of yours, so there every tab is listed.
            answer(["tabs": browser.tabs.filter { Store.testing || !$0.shy }.map(describe)])

        case "open":
            guard let url = (request["url"] as? String).flatMap(Address.url(from:)) else {
                answer(["error": "open needs a url"])
                return
            }
            // private: a private tab, on a SHY_PROBE run only.
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

        case "shut":
            // The window closed and kept, as the last one is when its close
            // button is pressed with Shy running (Windows.closing), or back.
            // Only on a SHY_PROBE run.
            guard Store.testing else { answer(["error": "shut only works on a --test run"]); return }
            browser.shut = request["on"] as? Bool ?? true
            answer(["shut": browser.shut])

        case "handover":
            // A tab's sign-in handed to the agent's session as the card's
            // Hand Over would (see HandoverCard), without the card. Only on
            // a SHY_PROBE run.
            guard Store.testing else { answer(["error": "handover only works on a --test run"]); return }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            Agent.offer(tab) { url, cookies, storage in
                if let why = Agent.shared.handOver(url, cookies: cookies, storage: storage, acts: request["acts"] as? Bool ?? false,
                                                   asks: request["asks"] as? Bool ?? true,
                                                   minutes: request["minutes"] as? Int ?? 30) {
                    answer(["error": why])
                } else {
                    answer(["cookies": cookies.count, "stored": storage.count, "page": Agent.shared.pages.last?.id ?? ""])
                }
            }

        case "takeback":
            // An agent page's sign-in taken back, as its Take Back Sign-In
            // would. Only on a SHY_PROBE run.
            guard Store.testing else { answer(["error": "takeback only works on a --test run"]); return }
            guard let page = Agent.shared.page(request["id"] as? String) else { answer(["error": "no such agent page"]); return }
            Agent.shared.end(page, "you took it back")
            answer(["over": page.handover?.over ?? ""])

        case "approve":
            // The oldest question in the Agent folder answered, yes or no.
            guard Store.testing else { answer(["error": "approve only works on a --test run"]); return }
            guard let first = Agent.shared.pending.first else { answer(["error": "nothing is waiting"]); return }
            Agent.shared.answer(first, request["yes"] as? Bool ?? false)
            answer(["answered": first.what])

        case "agentpage":
            // An agent page's handover and steps, as the folder shows them.
            guard let page = Agent.shared.page(request["id"] as? String) else { answer(["error": "no such agent page"]); return }
            answer(["over": page.handover?.over ?? "", "live": page.live != nil,
                    "steps": page.steps.map(\.what), "pending": Agent.shared.pending.map(\.what)])

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

        case "openmark":
            // A bookmark opened as the bar opens one. Only on a SHY_PROBE run.
            guard Store.testing else { answer(["error": "openmark only works on a --test run"]); return }
            guard let text = request["url"] as? String, let url = URL(string: text) else { answer(["error": "openmark needs a url"]); return }
            browser.openBookmark(url)
            answer(["active": browser.active?.id.uuidString ?? ""])

        case "pin":
            // Pin a tab, or unpin it with "off". Only on a SHY_PROBE run.
            guard Store.testing else { answer(["error": "pin only works on a --test run"]); return }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            // "listed": pinned as a row, or an existing pin made a row
            // (true) or a square (false).
            // "at": let go there, as the column's drag lets go (PinDrop):
            // among the squares (or the rows, with "listed"), or with "off"
            // among the tabs.
            var taken: Bool?
            if let at = request["at"] as? Int {
                if request["off"] as? Bool == true {
                    taken = browser.unpinDropped(tab, at: at)
                } else {
                    taken = browser.pinDropped(tab, listed: request["listed"] as? Bool ?? false, at: at)
                }
            }
            else if request["off"] as? Bool == true { browser.unpin(tab) }
            else if request["home"] as? Bool == true { browser.goHome(tab) }
            else if request["repin"] as? Bool == true { browser.repin(tab) }
            // (false), as the pin's menu does.
            else if let listed = request["listed"] as? Bool, tab.pin != nil { browser.setListed(tab, listed) }
            else { browser.pin(tab, listed: request["listed"] as? Bool ?? false) }
            answer(["pin": tab.pin ?? "", "listed": tab.listed, "pinned": browser.pinnedCount, "home": tab.home?.absoluteString ?? "",
                    "address": tab.address?.absoluteString ?? "",
                    "taken": taken.map { $0 as Any } ?? NSNull()])

        case "select":
            // Picking a tab takes the window over, which the bench never does
            // to someone using it: only on a SHY_PROBE run.
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

        case "nowplaying":
            // Whether this app is the Mac's Now Playing app, the one the media
            // keys and AirPods taps go to, as WebKit has it for the tab's
            // page (#512). WebKit's own tests ask the same way; a test run
            // only, since it is WebKit's private side.
            guard Store.testing else { answer(["error": "nowplaying only works on a --test run"]); return }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            let ask = NSSelectorFromString("_requestActiveNowPlayingSessionInfo:")
            guard tab.web.responds(to: ask), let imp = tab.web.method(for: ask) else {
                answer(["error": "this WebKit has no Now Playing info"]); return
            }
            typealias Reply = @convention(block) (ObjCBool, ObjCBool, NSString?, Double, Double, Int) -> Void
            typealias Ask = @convention(c) (AnyObject, Selector, Reply) -> Void
            let reply: Reply = { active, registered, title, _, _, _ in
                MainActor.assumeIsolated {
                    answer(["active": active.boolValue, "registered": registered.boolValue, "title": (title as String?) ?? "",
                            "hushing": tab.hushing])
                }
            }
            unsafeBitCast(imp, to: Ask.self)(tab.web, ask, reply)

        case "eval":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            guard let js = request["js"] as? String else { answer(["error": "eval needs js"]); return }
            house(tab)
            // Shy's own world is where its page scripts live (see Web.world).
            if request["world"] as? String == "shy" {
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
            // words. Only on a SHY_PROBE run.
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
                    // "button": "middle" clicks with the middle button.
                    let middle = request["button"] as? String == "middle"
                    let types: [NSEvent.EventType] = middle ? [.otherMouseDown, .otherMouseUp] : [.leftMouseDown, .leftMouseUp]
                    for type in types {
                        guard var event = NSEvent.mouseEvent(
                            with: type, location: spot, modifierFlags: held,
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil,
                            eventNumber: 0, clickCount: 1, pressure: type == types[0] ? 1 : 0
                        ) else { continue }
                        if middle, let raw = event.cgEvent {
                            raw.setIntegerValueField(.mouseEventButtonNumber, value: 2)
                            if let again = NSEvent(cgEvent: raw) { event = again }
                        }
                        switch type {
                        case .leftMouseDown: view.mouseDown(with: event)
                        case .otherMouseDown: view.otherMouseDown(with: event)
                        case .otherMouseUp: view.otherMouseUp(with: event)
                        default: view.mouseUp(with: event)
                        }
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
            // the Nth, or a new one. Only on a SHY_PROBE run.
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

        case "quit":
            // ⌘Q, on a test run: the app ends the way it does for you, the
            // session and windows.json written on the way out.
            guard Store.testing else { answer(["error": "quit only works on a --test run"]); return }
            answer(["quitting": true])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }

        case "windows":
            // The windows, oldest first, and what the tests do to them. Only
            // on a SHY_PROBE run: it opens and closes windows.
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
                        "away": Browsers.isAway(b.window),
                        "space": b.space.name, "tabs": b.tabs.map { $0.address?.absoluteString ?? "" },
                        "pins": b.tabs.filter { $0.pin != nil }.map { $0.pin ?? "" },
                        "frame": b.window.map { NSStringFromRect($0.frame) } ?? "",
                    ]
                }, "closedWindows": Browsers.lastClosedAt != nil, "keptAway": Browsers.keptAway,
                   "littles": LittleWindow.all.map { $0.tab.address?.absoluteString ?? "" }])
            }

        case "middle":
            // The middle button pressed and let go at X Y of a tab's page (its
            // own points from the top left), handed to its view as AppKit
            // would: the page sees trusted mousedown, mouseup and auxclick.
            // Only on a SHY_PROBE run.
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
            // comes up. Only on a SHY_PROBE run.
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
                ?? NSTemporaryDirectory() + "shy-bench-\(Bench.short(tab)).png"
            let width = request["width"] as? Double
            shoot(tab, to: URL(fileURLWithPath: path), width: width, answer)

        default:
            answer(["error": "unknown command “\(verb)”"])
        }
    }
}
#endif
