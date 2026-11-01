import AppKit
import AuthenticationServices
import SwiftUI
import WebKit

#if DEBUG
extension Bench {
    /// Split view, the interface's switches, the side panel and pop-ups.
    func interfaceCommand(_ verb: String, _ request: [String: Any], _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        switch verb {
        case "split":
            splitCommand(request, browser: browser, answer)

        case "ui":
            // Open or close the app's own panels, to reproduce what a person
            // did without a person.
            if let on = request["settings"] as? Bool { browser.tuning = on }
            if let on = request["passwords"] as? Bool, Store.testing { browser.managing = on }
            if let on = request["history"] as? Bool { browser.recalling = on }
            if let on = request["downloads"] as? Bool { browser.hoarding = on }
            if let on = request["bookmarks"] as? Bool { browser.bookmarking = on }
            // Shy's own pages (InternalPages.swift): one shown by its
            // address as a link would open it, one reached from the page in
            // front as its own buttons do, and an address typed on the tab
            // in front.
            if let text = request["show"] as? String, let url = URL(string: text) { _ = browser.open(url, foreground: true) }
            if let text = request["lead"] as? String, let kind = InternalPage.Kind(rawValue: text) { browser.lead(to: InternalPage(kind)) }
            if let text = request["go"] as? String, let url = URL(string: text) { browser.active?.go(to: url) }
            if let on = request["hidden"] as? Bool { browser.reviewing = on }
            if let look = (request["look"] as? String).flatMap(Look.init) { browser.prefs.look = look }
            if let side = request["side"] as? String {
                guard let position = SidebarPosition(rawValue: side) else {
                    answer(["error": "side needs left or right"])
                    return
                }
                browser.prefs.sidePosition = position
            }
            if let mode = (request["pages120"] as? String).flatMap(FastPages.init) { browser.prefs.fastPages = mode }
            // Swipe between pages, standing in for the Mac's own setting.
            if let on = request["swipepages"] as? Bool, Store.testing { Swipe.testing = on }
            // Ask.sure answered without a sheet: yes or no to every question
            // from now on, until "ask".
            if let yes = request["confirm"] as? Bool, Store.testing { Ask.testing = yes }
            // "ask": the real question again, as a person gets it.
            if request["confirm"] as? String == "ask" { Ask.testing = nil }
            if let on = request["cards"] as? Bool { browser.prefs.cards = on }
            if let on = request["address"] as? Bool { browser.prefs.showsAddress = on }
            // Developer Mode for the tab in front, as its right-click menu turns it.
            if let on = request["developer"] as? Bool, let tab = browser.active { DevTools.shared.set(tab, on: on) }
            // Settings › Videos wait for a click, moved as its switch moves it.
            if let on = request["waits"] as? Bool, Store.testing { browser.prefs.waitsForPlay = on }
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

        case "sidepanel":
            // The side panel (SidePanel.swift): what is in it, and, in a test
            // run, JavaScript in its extension page, or closing it.
            let web = SidePanelPages.shared.web(in: browser)
            var content: [String: Any] = ["kind": "none"]
            switch browser.sidePanel {
            case .page(let id, let url, let tab): content = ["kind": "page", "extension": id, "url": url.absoluteString, "tab": tab.map { $0.uuidString } ?? ""]
            case .site(let url, let profile): content = ["kind": "site", "url": url.absoluteString, "profile": profile.uuidString,
                                                       "store": web.map { $0.configuration.websiteDataStore.isPersistent } ?? false,
                                                       "sameStore": web.map { $0.configuration.websiteDataStore === Spaces.store(for: browser.spaceID) } ?? false,
                                                       "inspectable": web.map { if #available(macOS 13.3, *) { return $0.isInspectable } else { return false } } ?? false,
                                                       "developerExtras": web.flatMap { $0.configuration.preferences.value(forKey: "developerExtrasEnabled") as? Bool } ?? false]
                .merging(SidePanelPages.shared.siteReport(in: browser)) { a, _ in a }
            case nil: break
            }
            // Where the panel's page and every page sit in the window, from
            // its top-left corner, in points: [x, y, width, height].
            func spot(_ view: NSView?) -> [Int] {
                guard let view, let window = view.window else { return [] }
                let r = view.convert(view.bounds, to: nil)
                return [Int(r.minX), Int(window.frame.height - r.maxY), Int(r.width), Int(r.height)]
            }
            func webs(in view: NSView?) -> [WKWebView] {
                guard let view else { return [] }
                if let web = view as? WKWebView { return [web] }
                return view.subviews.flatMap(webs)
            }
            let all = webs(in: (browser.window ?? Links.window)?.contentView)
            var state: [String: Any] = ["shown": browser.sidePanelShown, "held": browser.sidePanelHeld,
                                        "content": content, "width": Double(browser.prefs.sidePanelWidth),
                                        "page": web?.url?.absoluteString ?? "", "title": web?.title ?? "", "loading": web?.isLoading ?? false,
                                        "opensWindows": web?.configuration.preferences.javaScriptCanOpenWindowsAutomatically ?? false]
            state["frame"] = spot(web)
            state["pages"] = all.filter { $0 !== web }.map(spot)
            state["cards"] = browser.asCards
            state["windowWidth"] = Int((browser.window ?? Links.window)?.frame.width ?? 0)
            state["tabs"] = browser.tabs.count
            switch request["action"] as? String ?? "state" {
            case "eval":
                guard Store.testing else { answer(["error": "sidepanel eval only works on a --test run"]); return }
                guard let web, let js = request["js"] as? String else { answer(["error": "no panel page"]); return }
                web.evaluateJavaScript(js) { value, error in
                    if let error { answer(["error": error.localizedDescription]) } else { answer(["value": Bench.plain(value)]) }
                }
            case "touch":
                // A real click in the panel's page, as the event watcher
                // records one (Extensions.touched). Test runs only.
                guard Store.testing else { answer(["error": "sidepanel touch only works on a --test run"]); return }
                if #available(macOS 15.4, *), case .page(let id, _, _) = browser.sidePanel { Extensions.touched[id] = Date() }
                answer(state)
            case "close":
                guard Store.testing else { answer(["error": "sidepanel close only works on a --test run"]); return }
                browser.closeSidePanel()
                answer(["shown": browser.sidePanelShown])
            case "site":
                // A website into the panel, as View › Side Panel puts one
                // there (or the tab's menu, with "tab"). Test runs only.
                guard Store.testing else { answer(["error": "sidepanel site only works on a --test run"]); return }
                if let id = request["tab"] as? String, let tab = browser.tabs.first(where: { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }) {
                    browser.openInSidePanel(tab)
                } else if let url = (request["url"] as? String).flatMap(URL.init(string:)) {
                    browser.showSiteInPanel(url)
                }
                answer(["shown": browser.sidePanelShown])
            case "crash":
                // The panel's website told its process is gone, as WebKit
                // tells a crash. Test runs only.
                guard Store.testing else { answer(["error": "sidepanel crash only works on a --test run"]); return }
                SidePanelPages.shared.siteCrashed(in: browser)
                answer(SidePanelPages.shared.siteReport(in: browser))
            case "totab":
                guard Store.testing else { answer(["error": "sidepanel totab only works on a --test run"]); return }
                browser.sitePanelToTab()
                answer(["shown": browser.sidePanelShown, "tabs": browser.tabs.count])
            default:
                answer(state)
            }

        case "popups":
            // The windows a tab's page was refused, as its sign offers them
            // (BlockedPopups.swift), and the sites allowed. open (newest is
            // 0), allow and remove do what the sign and Settings › Privacy
            // do: test runs only, they open tabs and change settings.
            let action = request["action"] as? String ?? "state"
            guard Store.testing || ["state", "sites"].contains(action) else {
                answer(["error": "popups \(action) only works on a --test run"]); return
            }
            let sites: () -> [String: Any] = { ["allowed": browser.prefs.popupSites(in: browser.profileID).sorted()] }
            if action == "sites" { answer(sites()); return }
            if action == "remove" {
                guard let site = request["site"] as? String else { answer(["error": "popups remove needs a site"]); return }
                browser.prefs.setPopupSites(browser.prefs.popupSites(in: browser.profileID).subtracting([site]), in: browser.profileID)
                answer(sites()); return
            }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            let state: () -> [String: Any] = {
                [
                    "blocked": tab.blockedPopups.map { $0.url?.absoluteString ?? "" },
                    "openable": tab.blockedPopups.map { BlockedPopups.openable($0.url) != nil },
                    "sign": !tab.blockedPopups.isEmpty,
                    "site": BlockedPopups.site(of: tab.pageAddress) ?? "",
                    "allowed": browser.prefs.popupSites(in: browser.profileID).sorted(),
                    "tabAllowed": tab.popupSites.sorted(),
                ]
            }
            switch action {
            case "state": answer(state())
            case "open":
                let index = request["index"] as? Int ?? 0
                let newest = Array(tab.blockedPopups.reversed())
                guard newest.indices.contains(index) else { answer(["error": "no blocked pop-up \(index)"]); return }
                let opened = browser.openBlocked(newest[index], from: tab)
                var reply = state()
                if let opened {
                    reply["opened"] = describe(opened)
                    reply["openedOpener"] = opened.opener?.uuidString ?? ""
                }
                answer(reply)
            case "allow":
                browser.allowPopups(from: tab)
                answer(state())
            default:
                answer(["error": "popups state|open|allow|remove|sites"])
            }

        default:
            answer(["error": "unknown command “\(verb)”"])
        }
    }
}
#endif
