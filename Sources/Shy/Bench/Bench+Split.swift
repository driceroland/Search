import AppKit
import AuthenticationServices
import SwiftUI
import WebKit

#if DEBUG
// Split view, driven.
extension Bench {
    func splitCommand(

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
            // Split View is always there now; only "on" is still an answer.
            guard request["on"] as? Bool == true else { answer(["error": "Split View is always on"]); return }
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

        case "age":
            // As if the tab had been left `seconds` ago (see Closing.swift).
            guard let page = tab() ?? browser.parkedTabs.first(where: { Bench.short($0) == request["id"] as? String }),
                  let seconds = request["seconds"] as? Double else {
                answer(["error": "split age needs id and seconds"])
                return
            }
            page.touch(at: Date().addingTimeInterval(-seconds))
            page.letGo = nil
            reply()

        case "name":
            // Named, or its name taken away with none.
            guard let page = tab() else { answer(["error": "split name needs id"]); return }
            page.name = request["name"] as? String
            reply()

        case "tidy":
            browser.closeLeftAlone()
            // Each close waits for the page to say it holds nothing typed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { reply() }

        case "save":
            browser.writeSession(now: true)
            // And pins.json, which goes by the Disk queue: a test reads it
            // the moment this answers, and a busy machine can leave it behind.
            Disk.drain()
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
        case "pick":
            // ⌘-clicks in the column on exactly these tabs, from no selection.
            guard let ids = request["ids"] as? [String] else { answer(["error": "split pick needs ids"]); return }
            let picked = ids.compactMap { find(["id": $0], in: browser) }
            browser.clearTabSelection()
            for page in picked { browser.extendTabSelection(to: page, modifiers: .command) }
            // The first ⌘-click picks the page in front too, as in the column.
            if let front = browser.active, !picked.contains(where: { $0 === front }),
               browser.selectedTabIDs.contains(front.id) {
                browser.extendTabSelection(to: front, modifiers: .command)
            }
            reply()
        case "pairPicked":
            // The tab menu's Open 2 Tabs in Split View, right-clicked on id.
            browser.pairPickedTabs(focus: tab())
            reply()
        case "fill":
            guard let blank = tab(), let page = tab("with") else { answer(["error": "split fill needs id and with"]); return }
            browser.fill(blank, with: page)
            reply()

        default:
            answer(["error": "unknown split action"])
        }
    }

    func splitState(_ browser: Browser) -> [String: Any] {
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
                    // One of Shy's own pages (InternalPages.swift), by its address.
                    "internal": tab.page?.url.absoluteString ?? "",
                    "canBack": tab.canGoBack,
                    "canForward": tab.canGoForward,
                    "built": tab.built != nil,
                    "shy": tab.shy,
                    "bench": tab.bench,
                    "asleep": tab.asleep,
                    "awakeReason": browser.awake(because: tab) ?? "",
                    "staysReason": browser.stays(because: tab) ?? "",
                    // How long it counts as left (Closing.swift), and when
                    // you last looked, for ⌃Tab: letting go moves only the first.
                    "idle": Date().timeIntervalSince(tab.leftSince),
                    "looked": Date().timeIntervalSince(tab.touched),
                    // Which web view holds its page, while it has one: the
                    // same after a pin or an unpin, as nothing was loaded again.
                    "web": tab.built.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue), radix: 16) } ?? "",
                    // Whether its page is in a window, and kept there unseen
                    // for a call (StageView.calls); whether it is on one; and
                    // whether the keys would go to it.
                    "inWindow": tab.built?.window != nil,
                    "heldForCall": tab.built.map { web in (web.superview as? StageView)?.holdsCall(web) == true } ?? false,
                    "onCall": tab.built.map { StageView.onCall($0) } ?? false,
                    "hasKeys": tab.built.map { web in
                        (web.window?.firstResponder as? NSView).map { $0 === web || $0.isDescendant(of: web) } ?? false
                    } ?? false,
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
            "folders": browser.folders.map { ["id": $0.id.uuidString, "folded": $0.folded] as [String: Any] },
            "folderIDs": browser.tabs.map { $0.folder?.uuidString ?? "" },
            "enabled": true,
            "finding": browser.finding,
            "needle": browser.needle,
            "findStatus": browser.findStatus ?? "",
            "pins": browser.tabs.filter { $0.pin != nil }.map { Bench.short($0) },
            // Every pin kept as a row, drawn so or not (Tab.listed).
            "listed": browser.tabs.filter { $0.pin != nil && $0.listed }.map { Bench.short($0) },
            // What ⇧⌘T would bring back, as its menu item says it.
            "reopenTitle": browser.reopenTitle,
            "ghosts": browser.ghosts.count,
            // Which cookie store each pin's tab signs in with.
            "pinStores": Dictionary(uniqueKeysWithValues: browser.tabs.filter { $0.pin != nil }
                .map { (Bench.short($0), $0.store.identifier?.uuidString ?? "default") }),
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
            // Tabs picked in the column (⌘- or ⇧-click), and what Open 2 Tabs
            // in Split View would pair: off while the menu's item is off.
            "selected": browser.tabs.filter { browser.selectedTabIDs.contains($0.id) }.map { Bench.short($0) },
            "pickedPair": browser.pickedPair.map { [Bench.short($0.left), Bench.short($0.right)] } ?? [],
            "pickedPaired": browser.pickedTabsArePaired,
        ]
    }
}
#endif
