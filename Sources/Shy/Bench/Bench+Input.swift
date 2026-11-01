import AppKit
import AuthenticationServices
import SwiftUI
import WebKit

#if DEBUG
extension Bench {
    /// The developer bar, probes, keys and the pointer, the field, the tab switcher and recording.
    func inputCommand(_ verb: String, _ request: [String: Any], _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        switch verb {
        case "developer":
            // Developer Mode's bar in the window, as its field and buttons
            // drive it: "type" puts text in the field, "enter" and "escape"
            // are the two keys, "hard" its reload, "source" its source tab.
            guard let tab = browser.active else { answer(["error": "no tab in front"]); return }
            let window = ObjectIdentifier(browser)
            var out: [String: Any] = [:]
            if let text = request["type"] as? String { DevTools.shared.drafts[window] = text }
            if request["enter"] as? Bool == true {
                let went = DevTools.go(DevTools.shared.drafts[window] ?? DeveloperBar.address(of: tab), in: tab)
                if went { DevTools.shared.drafts[window] = nil }
                out["went"] = went
            }
            if request["escape"] as? Bool == true { DevTools.shared.drafts[window] = nil }
            if request["hard"] as? Bool == true { tab.reload(fromOrigin: true) }
            if request["source"] as? Bool == true { DevTools.viewSource(of: tab, in: browser) }
            let report = DevTools.shared.report(for: tab)
            out["field"] = DevTools.shared.drafts[window] ?? DeveloperBar.address(of: tab)
            out["status"] = report?.status ?? NSNull()
            out["milliseconds"] = report?.milliseconds ?? NSNull()
            out["errors"] = report?.errors ?? NSNull()
            answer(out)

        case "probe":
            // The state of the window itself, for the bug that is not in a
            // page: which panels are up, whether something modal has the
            // app, and every window the app owns.
            var out: [String: Any] = [
                "settings": browser.tuning,
                "passwords": browser.managing,
                // A question hanging from the window (Ask), still unanswered.
                "sheet": browser.window?.attachedSheet != nil,
                // The button of that question that Return presses.
                "sheetReturn": browser.window?.attachedSheet?.defaultButtonCell?.title ?? "",
                "history": browser.recalling,
                "downloads": browser.hoarding,
                "bookmarks": browser.bookmarking,
                // The dropdown off the button, the ⇧⌘B card in it, and how
                // many are kept, for every window alike.
                "bookmarksOpen": browser.bookmarksOpen,
                "bookmarkCard": browser.bookmarkCard != nil,
                "bookmarkCount": browser.bookmarks.count,
                "field": browser.editing,
                "suggesting": browser.suggesting != nil,
                "offering": browser.offering != nil,
                "modal": NSApp.modalWindow.map { "\(type(of: $0)) “\($0.title)”" } ?? "",
                "look": browser.prefs.look.rawValue,
                // Developer Mode, and whether its bar is on screen.
                "developer": browser.active.map { DevTools.shared.isOn($0) } ?? false,
                "developerBar": DeveloperBar.shown ?? NSNull(),
                "sidebar": true,
                "sidePosition": browser.prefs.sidePosition.rawValue,
                "sideWidth": Double(browser.prefs.sideWidth),
                "appearance": NSApp.appearance?.name.rawValue ?? "system",
                "key": NSApp.keyWindow.map { "\(type(of: $0)) “\($0.title)”" } ?? "",
                // What the keyboard goes to in the key window, or the browser's: a find field,
                // a page, or a button it shouldn't be.
                "responder": (NSApp.keyWindow ?? Links.window)?.firstResponder.map { "\(type(of: $0))" } ?? "",
            ]
            // Whether that is the address field's own editor: a find field or
            // a tab's title being renamed is an NSTextView too.
            if let window = browser.window ?? Links.window, let editor = window.firstResponder as? NSTextView {
                out["responderIsAddress"] = Bench.addressField(in: window.contentView)?.currentEditor() === editor
            } else {
                out["responderIsAddress"] = false
            }
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
            out["peekFrom"] = browser.peekFrom?.uuidString ?? ""
            // The size the peek's page is drawn at (see Tab.applyRememberedZoom).
            out["peekZoom"] = Double(browser.peekTab?.built?.pageZoom ?? 0)
            out["fetching"] = ["showing": browser.fetches.showing, "fraction": browser.fetches.fraction ?? -1, "done": browser.fetches.done]
            // Where the peek's page sits in the window, from its top-left corner, in points.
            if let web = browser.peekTab?.built, let window = web.window {
                let r = web.convert(web.bounds, to: nil)
                out["peekFrame"] = [Int(r.minX), Int(window.frame.height - r.maxY), Int(r.width), Int(r.height)]
            }
            out["folded"] = browser.folded
            out["peeking"] = browser.peeking
            // The page as a card (see Browser.asCards), and what it is made of.
            out["cards"] = ["switch": browser.prefs.cards, "fullScreen": browser.fullScreen, "on": browser.asCards,
                            "windowFullScreen": (browser.window ?? Links.window)?.styleMask.contains(.fullScreen) ?? false]
            out["lightsHidden"] = Fold.titlebar?.isHidden ?? false
            out["siteCard"] = SiteCardPanel.isShown
            // "Press Esc again to leave full screen", up over a page filling
            // the screen (Settings › General › Press Esc twice to leave full
            // screen).
            out["escapeReminder"] = FullScreenEscape.shared.showing
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
            // `key` goes straight to a page instead. Only on a SHY_PROBE run.
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
            // "window": "little", in the newest small window instead.
            // "sheet": to the question hanging from the window, as a key
            // typed while it is up goes to it.
            let number = request["window"] as? String == "little" || request["little"] as? Bool == true
                ? LittleWindow.all.last?.windowNumber ?? 0
                : (request["sheet"] as? Bool == true ? browser.window?.attachedSheet : nil)?.windowNumber
                    ?? (browser.window ?? Links.window)?.windowNumber ?? 0
            // "letgo": the modifiers let go of, as a flags change with
            // none left, after the press.
            let types: [NSEvent.EventType] = request["letgo"] as? Bool == true
                ? [.keyDown, .keyUp, .flagsChanged] : [.keyDown, .keyUp]
            for type in types {
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: type == .flagsChanged ? [] : flags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: number, context: nil,
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
            // Only on a SHY_PROBE run: it types into a page.
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
            // bar. It moves the window, so only on a SHY_PROBE run.
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

        case "hoversweep":
            // The pointer taken down the column's rows and back, one row a
            // frame, for what each crossing costs: how many rows were built
            // again, and how long each pass of the main run loop took
            // meanwhile, from waking to going back to sleep (the event,
            // SwiftUI's update, layout, Core Animation's commit). A hidden
            // probe's window gets no pointer, so each step calls the rows'
            // own hover answers, the one left and then the one entered, as
            // AppKit hands them over in one pass. Test runs only.
            guard Store.testing else { answer(["error": "hoversweep is for test runs"]); return }
            guard let window = browser.window ?? Links.window else {
                answer(["error": "hoversweep needs a window"])
                return
            }
            let prefs = browser.prefs
            // The rows on screen, top to bottom.
            let fit = Int((Double(window.frame.height) - Double(Metrics.strip) - 60) / (Double(prefs.sideRow) + 2))
            let order = browser.displayedTabs.map(\.id).filter { Bench.hoverRows[$0] != nil }
            let rows = max(1, min(request["rows"] as? Int ?? fit, fit, order.count))
            let interval = request["interval"] as? Double ?? 1.0 / 60
            let ids = Array(order.prefix(rows))
            let path = ids + ids.reversed().dropFirst()
            var under: Tab.ID?
            func send(_ id: Tab.ID?) {
                if let under, under != id { Bench.hoverRows[under]?(false) }
                if let id, id != under { Bench.hoverRows[id]?(true) }
                under = id
            }
            let clock = LoopClock()
            Bench.bodies = [:]
            clock.start()
            func walk(_ n: Int) {
                guard n < path.count else {
                    send(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        clock.stop()
                        let crossings = path.count
                        answer([
                            "rows": rows, "crossings": crossings, "tabs": browser.tabs.count,
                            "bodies": Bench.bodies,
                            "crossingMs": LoopClock.summary(clock.marked),
                            "otherMs": LoopClock.summary(clock.unmarked),
                        ])
                    }
                    return
                }
                clock.mark()
                send(path[n])
                DispatchQueue.main.asyncAfter(deadline: .now() + interval) { walk(n + 1) }
            }
            walk(0)

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
            // and Core Animation's commit included. Only on a SHY_PROBE run.
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
                        // Its height too: a long address wraps and grows it.
                        var out: [String: Any] = ["field": field.stringValue, "typed": browser.typed, "offers": browser.offers.map(\.key), "ms": times, "height": Double(field.frame.height)]
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
            // A moon (a small window's tab) by its address.
            func short(_ id: Tab.ID?) -> String {
                guard let id else { return "" }
                guard let tab = browser.tabs.first(where: { $0.id == id }) else {
                    return LittleWindow.holding(id)?.tab.address?.absoluteString ?? ""
                }
                return Bench.short(tab)
            }
            func box(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { Double($0) } }
            answer([
                "visible": sw.visible, "selected": short(sw.selectedID),
                "candidates": sw.candidates.map { short($0) },
                "moons": sw.moons.map { LittleWindow.holding($0)?.tab.address?.absoluteString ?? "" },
                "muted": (browser.tabs + LittleWindow.all.map(\.tab)).filter(\.muted).map { short($0.id) },
                "panel": box(sw.panelFrame),
                "cards": Dictionary(sw.cardFrames.map { (short($0.key), box($0.value)) }, uniquingKeysWith: { a, _ in a }),
                "active": short(browser.activeID),
            ])

        case "recording":
            // The recording pill (RecordingIndicator.swift): lines put up as
            // ExtensionCapture would, a page lent to it, what it shows, and a
            // picture of it drawn off every screen. A test run never puts
            // the pill itself on a screen. Only on a SHY_PROBE run.
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

        default:
            answer(["error": "unknown command “\(verb)”"])
        }
    }
}
#endif
