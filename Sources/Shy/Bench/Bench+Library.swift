import AppKit
import AuthenticationServices
import SwiftUI
import WebKit

#if DEBUG
extension Bench {
    /// Suggestions, site search, bookmarks, imports, passwords, history, menus and the text a page is typed into.
    func libraryCommand(_ verb: String, _ request: [String: Any], _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        switch verb {
        case "suggest":
            // The engine's suggestions under the field (EngineSuggest.swift):
            // the rows, how many questions went out, were let go of or were
            // too slow, and a row taken as a click takes it. Only on a
            // SHY_PROBE run.
            guard Store.testing else { answer(["error": "suggest only works on a --test run"]); return }
            func kind(_ offer: Suggestion) -> String {
                switch offer.kind {
                case .suggested: "suggested"
                case .search: "search"
                case .open: "open"
                case .visited: "visited"
                case .known: "known"
                case .command: "command"
                }
            }
            func state(_ extra: [String: Any] = [:]) -> [String: Any] {
                var out: [String: Any] = [
                    "typed": browser.typed, "editing": browser.editing,
                    "offers": browser.offers.map { [$0.key, kind($0), $0.url.absoluteString] },
                    "asked": browser.suggester.asked, "cancelled": browser.suggester.cancelled,
                    "tooSlow": browser.suggester.tooSlow,
                    "on": browser.prefs.engineSuggests, "shy": browser.active?.shy ?? false,
                    "address": browser.active?.address?.absoluteString ?? "",
                    "pending": browser.active?.pending?.absoluteString ?? "",
                ]
                out.merge(extra) { _, new in new }
                return out
            }
            if let on = request["on"] as? Bool { browser.prefs.engineSuggests = on }
            switch request["action"] as? String ?? "state" {
            case "take":
                let index = request["index"] as? Int ?? 0
                guard browser.offers.indices.contains(index) else { answer(state(["error": "no row \(index)"])); return }
                browser.take(browser.offers[index])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { answer(state()) }
            case "walk":
                browser.walk(request["step"] as? Int ?? 1)
                answer(state(["picked": browser.picked ?? -1, "completed": browser.completed]))
            case "go":
                browser.submit()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { answer(state()) }
            case "esc": browser.dismiss(); answer(state())
            case "sendable":
                answer(["sendable": EngineSuggest.sendable(request["text"] as? String ?? "")])
            default: answer(state())
            }

        case "sitesearch":
            // Search a site from the address field (SiteSearch.swift): what
            // it offers and holds, Tab, ⌫ in an empty field, Esc, Return,
            // and the sites it has learned. Only on a SHY_PROBE run.
            guard Store.testing else { answer(["error": "sitesearch only works on a --test run"]); return }
            func state(_ extra: [String: Any] = [:]) -> [String: Any] {
                var out: [String: Any] = [
                    "offer": browser.siteOffer?.name ?? "", "chip": browser.siteChip?.name ?? "",
                    "typed": browser.typed, "offers": browser.offers.map { [$0.key, $0.url.absoluteString] },
                    "editing": browser.editing, "learned": SiteSearch.learned(in: browser.profileID).map { [$0.name, $0.host, $0.template] },
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
                SiteSearch.learn(from: page, description: description, in: browser.profileID)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { answer(state()) }
            case "adopt":
                // A learned site kept as learn keeps one, past the fetch: the
                // name a description gives itself is never read.
                SiteSearch.adopt(host: request["host"] as? String ?? "", template: request["template"] as? String ?? "", in: browser.profileID)
                answer(state())
            case "forget": SiteSearch.forget(in: browser.profileID); answer(state())
            default: answer(state())
            }

        case "bookmark":
            // A bookmark picked from the button's list, through the same
            // call the list makes: how long until WebKit is loading it, and
            // until the run loop rests. Only on a SHY_PROBE run.
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

        case "marks":
            // Each bookmark wherever it is shown, nothing drawn on a screen:
            // the bar's buttons laid out off every screen, with their size;
            // each of the bar's folders as the menu it opens, and the menu
            // bar's Bookmarks menu, every folder in them opened; and the
            // button's list, row by row — each with what it reads and
            // whether it wears the site's icon or a letter in its place.
            guard Store.testing else { answer(["error": "marks only works on a --test run"]); return }
            // "rename": [url, name] — typed into the ⇧⌘B card's Name field.
            if let pair = request["rename"] as? [String], pair.count == 2,
               let url = URL(string: pair[0]), let kept = browser.bookmarks.bookmark(for: url) {
                BookmarkCard.rename(kept.id, pair[1], in: browser.bookmarks)
            }
            func line(_ depth: Int, _ item: NSMenuItem) -> [String: Any] {
                ["depth": depth, "title": item.title, "folder": item.submenu != nil, "image": item.image != nil]
            }
            let bar = browser.bookmarks.roots.map { node -> [String: Any] in
                ["label": node.label, "title": node.title, "unnamed": node.unnamed]
            }
            let folders = browser.bookmarks.roots.filter(\.isFolder).map { folder -> [String: Any] in
                ["folder": folder.title, "items": BookmarkMenu.shared.walk(folder).map { line($0.depth, $0.item) }]
            }
            var menu: [[String: Any]] = []
            if let main = NSApp.mainMenu?.items.first(where: { $0.title == "Bookmarks" })?.submenu {
                main.delegate?.menuNeedsUpdate?(main)
                func down(_ items: [NSMenuItem], _ depth: Int) {
                    for item in items where item.tag == 0x5EAC && !item.isSeparatorItem {
                        menu.append(line(depth, item))
                        if let sub = item.submenu {
                            sub.delegate?.menuNeedsUpdate?(sub)
                            down(sub.items, depth + 1)
                        }
                    }
                }
                down(main.items, 0)
            }
            func rows(_ nodes: [Bookmark], _ depth: Int) -> [[String: Any]] {
                nodes.flatMap { node -> [[String: Any]] in
                    [["depth": depth, "label": node.label, "folder": node.isFolder,
                      "icon": !node.isFolder && Favicons.of(browser.profileID).cached(for: node.address) != nil]] + rows(node.children ?? [], depth + 1)
                }
            }
            // "path": the button's list drawn there, every folder open, in
            // the light, off every screen.
            if let path = request["path"] as? String {
                let all = Set(Bookmarks.folders(browser.bookmarks.roots).map(\.node.id))
                let host = NSHostingView(rootView: BookmarkOutline(bookmarks: browser.bookmarks, expanded: .constant(all), open: { _ in }, openInNewTab: { _ in })
                    .padding(6)
                    .frame(width: 280)
                    .background(Palette.ground))
                host.appearance = NSAppearance(named: .aqua)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                if let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: picture)
                    try? picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
            answer(["bar": bar, "folders": folders, "menu": menu, "list": rows(browser.bookmarks.roots, 0)])

        case "import-file":
            // A file another browser exported, through the same call the
            // File… buttons make after their chooser. Only on a SHY_PROBE run.
            guard Store.testing else { answer(["error": "import-file only works on a --test run"]); return }
            guard let path = request["path"] as? String else { answer(["error": "import-file needs a path"]); return }
            Task { @MainActor in
                let took = await browser.takeFile(URL(fileURLWithPath: path))
                answer(["said": took.said, "bookmarks": took.bookmarks, "already": took.already, "places": took.places,
                        "kept": took.kept, "skipped": took.skipped, "cancelled": took.cancelled,
                        "total": browser.bookmarks.count, "top": browser.bookmarks.roots.map(\.title), "saved": browser.saved.count])
            }

        case "remove-folder":
            // The bookmarks list's Remove on a top-level folder, question and
            // all: the real sheet, which `press` with "sheet" answers. Only on
            // a SHY_PROBE run.
            guard Store.testing else { answer(["error": "remove-folder only works on a --test run"]); return }
            guard let title = request["title"] as? String,
                  let folder = browser.bookmarks.roots.first(where: { $0.isFolder && $0.title == title })
            else { answer(["error": "no top-level folder by that title"]); return }
            browser.bookmarks.askRemove(folder)
            answer(["asked": title])
        case "passwords":
            // The passwords panel's list, narrowed as its search box would
            // narrow it, and with "remove" its Remove All… / Remove N…, which
            // `ui confirm` answers. Only on a SHY_PROBE run: it takes
            // passwords out of the keychain (the test world's own, by label).
            guard Store.testing else { answer(["error": "passwords only works on a --test run"]); return }
            if let filter = request["filter"] as? String { browser.hunting = filter }
            browser.relist()
            if request["remove"] as? Bool == true { browser.forgetShown() }
            // Answered once the removals, off the main thread, are done.
            func settled() {
                guard !browser.forgetting else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { settled() }
                    return
                }
                answer(["count": browser.saved.count, "shown": browser.shownSites.reduce(0) { $0 + $1.logins.count },
                        "announced": browser.announcement ?? ""])
            }
            settled()

        case "history":
            // History on a --test run: "take" puts an address in as an import
            // would, since a bench tab's visits never enter it; "forget" drops
            // one as the panel's cross does. Answers with every address kept.
            guard Store.testing else { answer(["error": "history only works on a --test run"]); return }
            if let text = request["take"] as? String, let url = Address.url(from: text) {
                browser.history.take(url, title: text, count: 1, last: Date())
                browser.history.settle()
            }
            if let text = request["forget"] as? String, let url = Address.url(from: text) {
                browser.history.forget(History.identity(for: url))
            }
            answer(["history": browser.history.everything().map(\.url.absoluteString)])

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

        case "tab-type":
            // The field in the tab, on the tab in front: the edit begun as a
            // click on it does, what is given typed into it key by key as the
            // keyboard would, then "keys" (down, up, return, delete) pressed.
            // What the field and its list are left showing. Test runs only.
            guard Store.testing else { answer(["error": "tab-type only works on a --test run"]); return }
            guard let tab = browser.active else { answer(["error": "no tab"]); return }
            if browser.editingTab != tab.id { browser.beginTabEdit(tab) }
            let text = request["text"] as? String ?? ""
            let keys = request["keys"] as? [String] ?? []
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let editor = browser.window?.firstResponder as? NSTextView,
                      let field = editor.delegate as? NSTextField else { answer(["error": "the field isn't focused"]); return }
                if request["clear"] as? Bool == true { editor.selectAll(nil); editor.deleteBackward(nil) }
                for ch in text { editor.insertText(String(ch), replacementRange: editor.selectedRange()) }
                for key in keys {
                    switch key {
                    case "down": editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
                    case "up": editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
                    case "return": editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                    case "delete": editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
                    default: break
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let selected = editor.selectedRange()
                    var shot = ""
                    if let path = request["picture"] as? String, TabOffersPanel.picture(to: path) { shot = path }
                    answer(["field": field.stringValue, "selected": [selected.location, selected.length],
                            "offers": browser.tabOffers.map { "\($0.key) | \($0.url.absoluteString)" },
                            "picked": browser.tabPicked ?? -1, "listShown": TabOffersPanel.isShown,
                            "editing": browser.editingTab != nil, "draft": browser.tabDraft,
                            "active": browser.active?.address?.absoluteString ?? "", "picture": shot])
                }
            }

        case "menus":
            // Every menu of the menu bar, by title, after SwiftUI has filled
            // it. Reads only.
            guard Store.testing else { answer(["error": "menus only works on a --test run"]); return }
            var menus: [String: [String]] = [:]
            for item in NSApp.mainMenu?.items ?? [] {
                guard let menu = item.submenu else { continue }
                menu.delegate?.menuNeedsUpdate?(menu)
                menus[item.title] = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title)
            }
            answer(["menus": menus,
                    "settingsPages": SettingsPanel.Page.allCases.map(\.rawValue),
                    "settingsPage": browser.settingsPage.rawValue])

        case "textcheck":
            // Text replacement, smart quotes and smart dashes: what the Mac
            // says, what the page's view says, and Edit › Substitutions as it
            // would open, with its ticks. toggle NAME: the menu's own action,
            // which writes WebKit's default in the app's standard domain —
            // the real Shy's, for a probe of the real app — so only in a
            // copy under a bundle id of its own (Tests/text_replacement.py).
            guard Store.testing else { answer(["error": "textcheck only works on a --test run"]); return }
            let web = find(request, in: browser)?.built ?? browser.active?.built
            if let name = request["toggle"] as? String {
                guard Store.ownContainer else {
                    answer(["error": "textcheck toggle only works in a copy under its own bundle id — it would switch the real Shy's setting"])
                    return
                }
                guard let kind = Substitution(rawValue: name) else { answer(["error": "toggle quotes|dashes|replacement"]); return }
                browser.toggleSubstitution(kind, in: web)
            }
            // The menu bar is drawn again a moment after the browser changes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                var mac: [String: Bool] = [:], page: [String: Bool] = [:], kept: [String: Any] = [:]
                let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
                for kind in Substitution.allCases {
                    mac[kind.rawValue] = kind.mac
                    page[kind.rawValue] = kind.isOn(in: web)
                    kept[kind.rawValue] = domain[kind.key] ?? NSNull()
                }
                var items: [[String: Any]] = []
                if let edit = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu {
                    edit.delegate?.menuNeedsUpdate?(edit)
                    if let sub = edit.items.first(where: { $0.title == "Substitutions" })?.submenu {
                        sub.delegate?.menuNeedsUpdate?(sub)
                        items = sub.items.filter { !$0.isSeparatorItem && !$0.isHidden }
                            .map { ["title": $0.title, "on": $0.state == .on] }
                    }
                }
                answer(["mac": mac, "page": page, "kept": kept, "menu": items, "web": web != nil])
            }

        case "menu":
            // The Bookmarks menu as it is about to open: the menu bar
            // told it is being tracked, SwiftUI's own update run on it, its
            // first folder opened — then what each holds. Only on a
            // SHY_PROBE run; nothing is drawn.
            guard Store.testing else { answer(["error": "menu only works on a --test run"]); return }
            guard let main = NSApp.mainMenu, let menu = main.items.first(where: { $0.title == "Bookmarks" })?.submenu
            else { answer(["error": "no Bookmarks menu"]); return }
            // "peek": only what is in it now, nothing opened or filled — to
            // see what an update while it is open left of the bookmarks.
            // "shown"/"hidden": the menu told it opened or closed, as tracking would.
            if request["shown"] as? Bool == true {
                NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: main)
                menu.delegate?.menuWillOpen?(menu)
            }
            if request["swiftui"] as? Bool == true { BookmarkMenu.shared.swiftUIUpdate() }
            if request["hidden"] as? Bool == true {
                menu.delegate?.menuDidClose?(menu)
                NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: main)
            }
            if request["peek"] as? Bool == true {
                answer(["ours": BookmarkMenu.shared.count, "items": menu.items.count])
                return
            }
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
            // Reports what Shy did and what the page saw. Only on a
            // SHY_PROBE run.
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
            var firstPass = "shy"
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

        default:
            answer(["error": "unknown command “\(verb)”"])
        }
    }
}
#endif
