import AppKit
import AuthenticationServices
import SwiftUI
import WebKit

#if DEBUG
extension Bench {
    /// Peeks, zoom and wheels, folders and spaces, windows, pictures, films, PDFs, the column and small windows.
    func windowCommand(_ verb: String, _ request: [String: Any], _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        switch verb {
        case "peek":
            // A link's page in the peek panel over the tab in front, as a
            // shift-click on it would open it (see Peek.swift); "close" puts
            // it away. Only on a SHY_PROBE run.
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
            // Reports where the tab is after. Only on a SHY_PROBE run.
            guard Store.testing else { answer(["error": "pull only works on a --test run"]); return }
            guard let tab = browser.active, let web = tab.built, let dx = request["dx"] as? Double
            else { answer(["error": "pull needs a loaded tab and a distance"]); return }
            let steps = max(2, request["steps"] as? Int ?? 10)
            let ms = max(1, request["ms"] as? Double ?? 200)
            let before = tab.address?.absoluteString ?? ""
            // Over the middle of the page. An event made here has no window,
            // so AppKit hands WebKit its screen point as the point in the
            // window: left where it starts, the pointer's, the page saw the
            // scroll only while the pointer happened to be over it. Put where
            // the page's middle is in its window, measured the way AppKit
            // measures a screen point (from the top of the main screen).
            let middle = web.convert(NSPoint(x: web.bounds.midX, y: web.bounds.midY), to: nil)
            let over = CGPoint(x: middle.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - middle.y)
            func send(_ phase: Int64, _ delta: Double) {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(delta), wheel3: 0) else { return }
                cg.location = over
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

        case "magnify":
            // The trackpad's pinch, as WebKit ends it: the page's scale set
            // around a point (in the view, from its top left), or read back
            // with no scale given. Only on a SHY_PROBE run.
            guard Store.testing else { answer(["error": "magnify only works on a --test run"]); return }
            guard let tab = find(request, in: browser), let web = tab.built else { answer(missing(request)); return }
            if let scale = request["scale"] as? Double {
                let x = request["x"] as? Double ?? Double(web.bounds.midX)
                let y = request["y"] as? Double ?? Double(web.bounds.midY)
                web.setMagnification(CGFloat(scale), centeredAt: NSPoint(x: x, y: web.isFlipped ? y : Double(web.bounds.height) - y))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                answer(["magnification": Double(web.magnification), "zoom": Double(web.pageZoom),
                        "size": [Double(web.bounds.width), Double(web.bounds.height)]])
            }

        case "wheel":
            // Two fingers on the trackpad over the page, any way: DX, DY
            // points in STEPS events over MS milliseconds, with a trackpad's
            // phases and, if asked, a glide after. Only on a SHY_PROBE run.
            guard Store.testing else { answer(["error": "wheel only works on a --test run"]); return }
            guard let tab = find(request, in: browser), let web = tab.built else { answer(missing(request)); return }
            let dx = request["dx"] as? Double ?? 0, dy = request["dy"] as? Double ?? 0
            let steps = max(2, request["steps"] as? Int ?? 10)
            let ms = max(1, request["ms"] as? Double ?? 200)
            let glide = request["glide"] as? Int ?? 0
            let middle = web.convert(NSPoint(x: web.bounds.midX, y: web.bounds.midY), to: nil)
            let over = CGPoint(x: middle.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - middle.y)
            func send(_ phase: Int64, _ momentum: Int64, _ x: Double, _ y: Double) {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(y), wheel2: Int32(x), wheel3: 0) else { return }
                cg.location = over
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
                cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: y)
                cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: x)
                cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(y))
                cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(x))
                if let event = NSEvent(cgEvent: cg) { web.scrollWheel(with: event) }
            }
            send(128, 0, 0, 0)
            send(1, 0, 0, 0)
            let each = ms / 1000 / Double(steps)
            for n in 1...steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + each * Double(n)) {
                    send(2, 0, dx / Double(steps), dy / Double(steps))
                    if n == steps { send(4, 0, 0, 0) }
                }
            }
            for n in 0..<glide {
                DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000 + 0.016 * Double(n + 1)) {
                    let k = pow(0.85, Double(n + 1))
                    send(0, n == 0 ? 1 : (n == glide - 1 ? 3 : 2), dx / Double(steps) * k, dy / Double(steps) * k)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000 + 0.016 * Double(glide) + 0.5) {
                answer(["ok": true])
            }

        case "place":
            // A tab put at another place in the row, as a drag would.
            guard let id = request["id"] as? String, let to = request["to"] as? Int,
                  let tab = browser.tabs.first(where: { Bench.short($0) == id && (Store.testing || $0.bench) })
            else { answer(["error": "place needs a tab id and an index"]); return }
            browser.move(tab, to: to)
            answer(["at": browser.tabs.firstIndex { $0.id == tab.id } ?? -1])

        case "folder":
            // Folders, as their menus make and change them (Folders.swift):
            // one made ("new", in "parent" by name), a tab into one by name
            // or out ("name" "none"), one folded or opened ("fold"), renamed
            // ("rename") or deleted ("delete"). Test runs only: it
            // rearranges your tabs.
            guard Store.testing else { answer(["error": "folder only works on a --test run"]); return }
            let named = request["name"] as? String ?? ""
            let folder = browser.folders.first { $0.name == named || !named.isEmpty && $0.id.uuidString.lowercased().hasPrefix(named.lowercased()) }
            if request["new"] as? Bool == true {
                let parent = (request["parent"] as? String).flatMap { name in browser.folders.first { $0.name == name }?.id }
                guard let made = browser.newFolder(in: parent, named: named.isEmpty ? "Folder" : named, editing: false) else {
                    answer(["error": "no folder made there"]); return
                }
                if let id = request["id"] as? String, let tab = browser.tabs.first(where: { Bench.short($0) == id }) {
                    browser.move(tab, toFolder: made)
                }
            } else if let id = request["id"] as? String {
                guard let tab = browser.tabs.first(where: { Bench.short($0) == id }) else { answer(["error": "no tab “\(id)” — see tabs"]); return }
                if named == "none" {
                    browser.move(tab, toFolder: nil)
                } else if let folder {
                    browser.move(tab, toFolder: folder.id, at: request["at"] as? Int)
                } else {
                    answer(["error": "no folder “\(named)”"]); return
                }
            } else if request["fold"] as? Bool == true {
                guard let folder else { answer(["error": "no folder “\(named)”"]); return }
                browser.toggleFolder(folder.id)
            } else if let name = request["rename"] as? String {
                guard let folder else { answer(["error": "no folder “\(named)”"]); return }
                browser.renameFolder(folder.id, to: name)
            } else if request["delete"] as? Bool == true {
                guard let folder else { answer(["error": "no folder “\(named)”"]); return }
                browser.deleteFolder(folder.id)
            }
            answer(["folders": browser.folders.map { folder in
                ["id": String(folder.id.uuidString.prefix(8)).lowercased(), "name": folder.name, "folded": folder.folded,
                 "parent": folder.parent.flatMap { id in browser.folders.first { $0.id == id }?.name } ?? "",
                 "tabs": browser.tabs.filter { $0.pin != nil && $0.folder == folder.id }.map(Bench.short)] as [String: Any]
            }, "lines": browser.folderLines.map(Bench.line)])

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
            guard let item = items.first(where: { $0.title == "Shy" }), let action = item.action else {
                answer(["error": "no Shy item in the Window menu", "items": items.map(\.title)])
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
            if request["action"] as? String == "select", find(request, in: browser) == nil {
                answer(missing(request)); return
            }
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
            case "select": if let tab = find(request, in: browser) { browser.select(tab) }
            default: break
            }

        case "pdf":
            // The page on screen as File › Export as PDF… makes it, without
            // a save panel. A test path only: a real browser never lets the
            // bench write a file chosen behind its person's back.
            guard Store.testing else { answer(["error": "pdf only works on a --test run"]); return }
            guard let path = request["path"] as? String, !path.isEmpty else {
                answer(["error": "pdf needs a path"])
                return
            }
            guard let tab = browser.active else { answer(["error": "page wasn't exported"]); return }
            let file = URL(fileURLWithPath: path)
            browser.exportPDF(tab, to: file) { worked in
                answer(worked ? ["saved": file.path] : ["error": "page wasn't exported"])
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
            let size = NSSize(width: width, height: 500)
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
            case "state": break
            case "look": break
            default:
                guard let text = request["what"] as? String, let url = URL(string: text) else { answer(["error": "little needs a url, keep or close"]); return }
                LittleWindow.show(url, for: browser, front: false)
            }
            // Its own switcher (⌃Tab in a small window): the moons by
            // address, the planet's tabs as the bench names them.
            let sw = LittleWindow.switcher
            func address(_ id: Tab.ID?) -> String {
                guard let id else { return "" }
                if let little = LittleWindow.holding(id) { return little.tab.address?.absoluteString ?? "" }
                return browser.tabs.first { $0.id == id }.map { Bench.short($0) } ?? ""
            }
            answer([
                "switcher": [
                    "visible": sw.visible, "selected": address(sw.selectedID),
                    "candidates": sw.candidates.map { address($0) },
                    "moons": sw.moons.map { address($0) },
                ] as [String: Any],
                "screens": LittleWindow.all.map { $0.tab.screens ?? 0 },
                "activeID": browser.activeID.map { String($0.uuidString.prefix(8)).lowercased() } ?? "",
                "fronted": address(LittleWindow.fronted),
                "littles": LittleWindow.all.map { $0.tab.address?.absoluteString ?? "" },
                "said": LittleWindow.all.last?.said ?? "",
                "zoom": LittleWindow.all.last?.tab.built.map { Double($0.pageZoom) } ?? 0,
                "failures": LittleWindow.all.map { $0.tab.failure ?? "" },
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

        case "player":
            // A host whose videos go into picture in picture by themselves,
            // as a film site's do (Players). Test runs only.
            guard Store.testing else { answer(["error": "player only works on a --test run"]); return }
            guard let host = request["host"] as? String else { answer(["error": "player needs a host"]); return }
            Players.benchHosts.insert(host)
            answer(["players": Players.benchHosts.sorted()])

        case "space":
            // The spaces, and switching between them, for a test of what a
            // space keeps apart. Test runs only: it moves your tabs about.
            guard Store.testing else { answer(["error": "space only works on a --test run"]); return }
            switch request["action"] as? String ?? "" {
            case "new": browser.addSpace(named: request["name"] as? String ?? "Test", sharesSignIns: request["fresh"] as? Bool != true)
            case "go": browser.switchSpace(index: (request["index"] as? Int ?? 1) - 1)
            case "profile":
                // The space on screen into a profile of its own, made now.
                let made = Profiles.shared.add(named: request["name"] as? String ?? "Test")
                browser.setProfile(made.id, of: browser.spaceID)
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
                "on": true,
                "current": browser.space.name,
                "spaces": browser.spaces.map { ["name": $0.name, "id": $0.id.uuidString, "downloads": $0.downloads ?? "", "shared": $0.sharesSignIns == true] },
                "parked": browser.parked.map { [$0.key.uuidString: $0.value.tabs.count] },
                "tabs": browser.tabs.count,
                "making": browser.makingSpace,
                "swipe": Double(browser.spaceSwipe),
                // Each space off screen as a swipe draws it passing by
                // (Folders.lines): its folders' lines, folded or not, and
                // its tabs.
                "drawn": Dictionary(uniqueKeysWithValues: browser.parked.map { id, row in
                    let lines = Folders.lines(Pins.folders(id), pins: row.tabs.filter { $0.pin != nil }, front: row.front)
                    return (browser.spaces.first { $0.id == id }?.name ?? id.uuidString, [
                        "lines": lines.map(Bench.line),
                        "loose": row.loose.map(Bench.short),
                        "active": row.active.map { id in row.tabs.first { $0.id == id }.map(Bench.short) ?? "" } ?? "",
                    ] as [String: Any])
                }),
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

        default:
            answer(["error": "unknown command “\(verb)”"])
        }
    }
}
#endif
