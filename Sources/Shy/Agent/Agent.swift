import AppKit
import Combine
import WebKit

// Agents' pages: what an AI agent on this Mac — any MCP client: Claude
// Code, Cursor, Codex and the like — can open and read through shy-mcp,
// the small program beside the app (Sources/ShyMCP), which speaks MCP on its standard
// input and output and passes each call to this over agent.sock.
//
// Off unless switched on in Settings › Agents. What a page you never chose
// can ask of an agent, it can ask of these pages, so they hold as little as
// a page can:
//
// - none of your tabs: these are web views of their own, not tabs. Nothing
//   here can reach a tab of yours, its sign-ins or its history;
// - each page its own private store, gone with the page: no cookies of
//   yours, nothing kept;
// - none of Shy's own page scripts and no extensions: nothing fills in a
//   password, offers a passkey or reads the page on an extension's behalf;
// - http and https only, typed in or followed; a page can't open a window,
//   download, upload a file, use the camera, the microphone or where you
//   are, and its alerts are answered "no" without a word;
// - no script of the agent's own: it reads the page's text, takes a picture
//   of it, clicks and types into what a selector names, nothing else.
//
// Together they are the agent's session: the Agent folder at the top of the
// column, in every space, shows them (AgentSide.swift), and a page picked
// there is shown in the window, to watch or to use yourself. Off show, they
// live in a window of their own off every screen, so a picture of one is a
// picture of something, and never take a window from you.
//
// The one way anything of yours gets in is a handover (see `handOver`), and
// only from your right-click: a copy of one site's sign-in, in a page of
// the session's own, locked to that site, for a time you chose, read-only
// unless you said otherwise, every click asked about unless you said
// otherwise, and every step written down.

@MainActor
final class Agent: NSObject, ObservableObject {
    static let shared = Agent()

    /// Beside the bench's, in the app's own folder.
    static var socket: URL { Store.file("agent.sock") }
    /// Pages open at once, at most.
    static let most = 8
    /// The longest a page's text can be, in characters.
    static let longest = 100_000

    private var server: LocalSocket?
    private(set) var running = false
    /// Its pages, newest last: the Agent folder's rows.
    @Published var pages: [Page] = []
    /// What the agent last called itself (MCP's clientInfo, from shy-mcp).
    @Published private(set) var client: String?
    /// Questions for you: a click or typing on a handed-over page, waiting.
    @Published var pending: [Approval] = []
    /// The folder shown as its header alone.
    @Published var folded = false
    var room: NSWindow?

    /// What can be taken away from agents in Settings › Agents, and the
    /// calls each covers. Waiting, listing and closing its own pages stay.
    enum Ability: String, CaseIterable, Identifiable {
        case open, read, picture, click, type
        var id: String { rawValue }
        var calls: Set<String> {
            switch self {
            case .open: return ["open", "go"]
            case .read: return ["text", "scroll"]
            case .picture: return ["shot"]
            case .click: return ["click", "clickat"]
            case .type: return ["type", "typeat"]
            }
        }
        var title: String {
            switch self {
            case .open: return "Open pages"
            case .read: return "Read a page's text"
            case .picture: return "Take screenshots"
            case .click: return "Click"
            case .type: return "Type into fields"
            }
        }
        var detail: String {
            switch self {
            case .open: return "Only http and https addresses"
            case .read: return "Title, address and visible text"
            case .picture: return "Of what the page shows"
            case .click: return "Buttons, links and labels, or a point on the page"
            case .type: return "Into fields and editable text"
            }
        }
    }

    /// The calls Settings lets through now.
    static var allowed: Set<String> {
        let denied = Shared.prefs.agentDenied
        let taken = Ability.allCases.filter { denied.contains($0.rawValue) }.flatMap(\.calls)
        return Set(["open", "go", "text", "shot", "click", "type", "clickat", "typeat", "scroll", "wait", "close", "list", "tools"]).subtracting(taken)
    }

    /// The world an agent's clicks and typing run in, apart from the page's
    /// own scripts, which can neither see nor change them.
    static let world = WKContentWorld.world(name: "shy-agent")

    /// One of your tabs' sign-ins, copied into a page of the session's own.
    struct Handover {
        /// The site it is locked to: the registrable domain, "google.com".
        let site: String
        /// The page's host when it was handed over, "mail.google.com".
        let host: String
        let cookies: Int
        /// Items of its page's localStorage and sessionStorage copied.
        var stored = 0
        /// Clicks and typing allowed at all; read-only otherwise.
        let acts: Bool
        /// Each click and each typing asked about first.
        let asks: Bool
        let ends: Date
        /// Why the copied sign-in is gone, once it is.
        var over: String?
    }

    /// One step an agent took on a page, for you to look back over.
    struct Step: Identifiable {
        let id = UUID()
        let at = Date()
        let what: String
    }

    /// A click or typing on a handed-over page, waiting for your yes.
    struct Approval: Identifiable {
        var id = UUID()
        let page: String
        let site: String
        let what: String
        /// Around the point a click or typing at a point would land on.
        var picture: NSImage?
        let reply: (Bool) -> Void
    }

    @MainActor
    final class Page: ObservableObject, Identifiable {
        let id: String
        let web: WKWebView
        /// When an agent last asked anything of it (see `tidy`).
        var used = Date()
        @Published var title = ""
        @Published var address: URL?
        /// What the agent is doing to it right now, in a word: "clicking".
        @Published var acting: String?
        @Published var steps: [Step] = []
        @Published var handover: Handover?
        /// The origin its copied storage is put into, until the first page
        /// there has loaded with it: after that the page's storage is its
        /// own, and a reload doesn't write the copy over it again.
        var seeding: String?
        /// Where the agent's pointer is on the page, in the page's points,
        /// and how many times it has pressed, for the cursor drawn over it.
        @Published var cursor: CGPoint?
        @Published var presses = 0
        /// Screenshot pixels to the page's points, from the latest shot.
        var shotScale: CGFloat?
        /// The page as the latest shot showed it: a point from that shot
        /// means something only while the page still is.
        var seen: (size: CGSize, scroll: CGPoint, url: URL?)?
        private var watching: [NSKeyValueObservation] = []

        init(id: String, web: WKWebView) {
            self.id = id
            self.web = web
            watching = [
                web.observe(\.title, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.title = self?.web.title ?? "" }
                },
                web.observe(\.url, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.address = self?.web.url }
                },
            ]
        }

        /// Its handover, while the copied sign-in is still in it.
        var live: Handover? { handover.flatMap { $0.over == nil ? $0 : nil } }

        func note(_ what: String) {
            steps.append(Step(what: what))
            if steps.count > 200 { steps.removeFirst(steps.count - 200) }
        }
    }

    /// A page no agent has asked anything of for this long is closed: what
    /// it runs, it runs from your Mac.
    static let idle: TimeInterval = 10 * 60
    private var tidying: Timer?

    /// What each call is doing, as the folder says it.
    static let doing = ["open": "opening", "go": "going", "text": "reading", "shot": "looking",
                                "click": "clicking", "type": "typing", "clickat": "clicking", "typeat": "typing",
                                "scroll": "scrolling", "wait": "waiting"]

    /// The page being acted on, and what to, for the folder's header.
    var busy: (page: Page, doing: String)? {
        pages.last { $0.acting != nil }.map { ($0, $0.acting ?? "") }
    }

    // MARK: - starting and stopping

    func start() {
        guard !running else { return }
        let server = LocalSocket(at: Agent.socket) { [weak self] request, answer in
            self?.handle(request, answer)
        }
        guard server.start() else { return }
        self.server = server
        running = true
        tidying = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { Agent.shared.tidy() }
        }
    }

    private func tidy() {
        let stale = pages.filter { Date().timeIntervalSince($0.used) > Agent.idle }
        stale.forEach(close)
        for page in pages {
            if let handover = page.live, handover.ends <= Date() { end(page, "its time was up") }
        }
    }

    func stop() {
        guard running else { return }
        server?.stop()
        server = nil
        tidying?.invalidate()
        tidying = nil
        running = false
        closeAll()
    }

    /// The session over: every page closed, and with each its store.
    func closeAll() {
        pages.forEach(drop)
        pages = []
        pending.forEach { $0.reply(false) }
        pending = []
        client = nil
    }

    func close(_ page: Page) {
        pending.filter { $0.page == page.id }.forEach { $0.reply(false) }
        pending.removeAll { $0.page == page.id }
        drop(page)
        pages.removeAll { $0 === page }
        if pages.isEmpty { client = nil }
    }

    func page(_ id: String?) -> Page? {
        id.flatMap { id in pages.first { $0.id == id } }
    }

    // MARK: - the calls

    private func handle(_ request: [String: Any], _ given: @escaping ([String: Any]) -> Void) {
        // One answer, and always one, however a page behaves.
        var answered = false
        var acted: Page?
        let answer: ([String: Any]) -> Void = { reply in
            guard !answered else { return }
            answered = true
            acted?.acting = nil
            given(reply)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { answer(["error": "no answer within 45 s"]) }

        let verb = request["do"] as? String ?? ""
        guard Agent.allowed.contains(verb) else {
            return answer(["error": "“\(verb)” is turned off in Shy's Settings › Agents"])
        }
        if let name = request["client"] as? String {
            let plain = String(name.filter { $0.isLetter || $0.isNumber || " -_.".contains($0) }.prefix(40))
            if !plain.isEmpty, client != plain { client = plain }
        }
        // What shy-mcp offers the agent: only what is allowed now.
        if verb == "tools" {
            return answer(["allowed": Agent.allowed.sorted()])
        }
        if verb == "open" {
            guard let url = Agent.web(request["url"]) else { return answer(["error": "open needs an http or https address"]) }
            guard pages.count < Agent.most else {
                return answer(["error": "\(Agent.most) pages are open — close one first"])
            }
            let page = make()
            acted = page
            page.acting = "opening"
            page.note("Opened \(url.host() ?? url.absoluteString)")
            page.web.load(URLRequest(url: url))
            return settle(page, within: 15, answer)
        }
        if verb == "list" {
            return answer(["pages": pages.map(describe)])
        }
        if verb == "close", request["id"] as? String == "all" {
            let count = pages.count
            closeAll()
            return answer(["closed": count])
        }
        guard let page = page(request["id"] as? String) else {
            return answer(["error": "no page “\(request["id"] as? String ?? "")” — open one, or list them"])
        }
        // A handover's time is checked on every call, not only by the timer:
        // a timer waits out a sleeping Mac and App Nap, and the sign-in
        // would outlive the time you gave it until it fired.
        expire(page)
        page.used = Date()
        drawn(page)
        if let words = Agent.doing[verb] {
            acted = page
            page.acting = words
        }
        switch verb {
        case "go":
            guard let url = Agent.web(request["url"]) else { return answer(["error": "go needs an http or https address"]) }
            // On a handover that asks before each click, going somewhere is
            // asked about too: an address on the site can act as much as a
            // click can (sign out, confirm, unsubscribe). Read-only goes,
            // since reading a site means going through it; off the site the
            // sign-in is taken back first (see decidePolicyFor).
            let what = "Go to \(url.host() ?? "")\(url.path())"
            let go = {
                page.note("Went to \(url.host() ?? "")\(url.path())")
                page.web.load(URLRequest(url: url))
                self.settle(page, within: 15, answer)
            }
            guard let handover = page.live else { return go() }
            // Off the site, the agent's own going takes the sign-in back first
            // and then goes; a page that sends itself off the site is stopped
            // instead (see decidePolicyFor).
            let host = url.host()?.lowercased() ?? ""
            if Vault.registrable(host) != handover.site {
                return end(page, "the agent left \(handover.site) for \(host)") { go() }
            }
            if handover.acts, handover.asks { permit(page, what, verb: verb, at: nil, answer, act: go) } else { go() }

        case "wait":
            let seconds = min(30, max(0, (request["seconds"] as? Double) ?? 10))
            settle(page, within: seconds, answer)

        case "text":
            page.note("Read the page")
            run(Agent.reading, on: page) { value, trouble in
                if let trouble { return answer(["error": trouble]) }
                guard var text = value as? String else { return answer(["error": "the page has no text to read"]) }
                var cut = false
                if text.count > Agent.longest { text = String(text.prefix(Agent.longest)); cut = true }
                var said = self.describe(page)
                said["text"] = text
                said["truncated"] = cut
                answer(said)
            }

        case "shot":
            page.note("Took a screenshot")
            let shot = WKSnapshotConfiguration()
            shot.afterScreenUpdates = true
            page.web.takeSnapshot(with: shot) { image, _ in
                MainActor.assumeIsolated {
                    guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                          let png = bitmap.representation(using: .png, properties: [:])
                    else { return answer(["error": "nothing drawn yet"]) }
                    if page.web.bounds.width > 0 { page.shotScale = CGFloat(bitmap.pixelsWide) / page.web.bounds.width }
                    let size = page.web.bounds.size, url = page.web.url
                    self.run(Agent.scrolledTo, on: page) { value, _ in
                        let at = (value as? [NSNumber])?.map { CGFloat($0.doubleValue) } ?? []
                        page.seen = (size, at.count == 2 ? CGPoint(x: at[0], y: at[1]) : .zero, url)
                        answer(["png": png.base64EncodedString(), "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh])
                    }
                }
            }

        case "click", "type":
            guard let selector = request["selector"] as? String, !selector.isEmpty, selector.count <= 1000 else {
                return answer(["error": "\(verb) needs a selector"])
            }
            let text = request["text"] as? String ?? ""
            guard verb == "click" || text.count <= 10_000 else { return answer(["error": "that is a lot to type"]) }
            let what = verb == "click"
                ? "Click \(Agent.quoted(selector))"
                : "Type \(Agent.quoted(text)) into \(Agent.quoted(selector))"
            permit(page, what, verb: verb, at: nil, answer) {
                page.note(what)
                self.run(verb == "click" ? Agent.clicking : Agent.typing, on: page, ["selector": selector, "text": text]) { value, trouble in
                    let said = trouble ?? value as? String ?? "the page didn't answer"
                    answer(said == "ok" ? ["ok": true] : ["error": said])
                }
            }

        case "clickat", "typeat":
            // A point on the latest screenshot, pressed as a mouse would,
            // and typing as a keyboard would — into what is there now.
            let text = request["text"] as? String ?? ""
            let key = request["key"] as? String
            guard text.count <= 10_000 else { return answer(["error": "that is a lot to type"]) }
            if let key, Agent.keys[key] == nil {
                return answer(["error": "no key “\(key)”: one of \(Agent.keys.keys.sorted().joined(separator: ", "))"])
            }
            guard verb == "clickat" || !text.isEmpty || key != nil else { return answer(["error": "typeat needs text or a key"]) }
            let at = point(request, on: page)
            if verb == "clickat" || request["x"] != nil || request["y"] != nil {
                guard at != nil else { return answer(["error": "x and y must be a point on the page, in the latest screenshot's pixels"]) }
            }
            let place = at.map { " at \(Int(($0.x * (page.shotScale ?? 1)).rounded())), \(Int(($0.y * (page.shotScale ?? 1)).rounded()))" } ?? ""
            let what = verb == "clickat"
                ? "Click\(place)"
                : "Type \(text.isEmpty ? "" : Agent.quoted(text) + " ")\(key.map { "then \($0) " } ?? "")\(place.isEmpty ? "where the page has focus" : place.trimmingCharacters(in: .whitespaces))"
            permit(page, what, verb: verb, at: at, answer) {
                self.still(page, at != nil) { trouble in
                    if let trouble { return answer(["error": trouble]) }
                    page.note(what)
                    self.sparing(page) {
                        if let at { self.press(page, at) }
                        if verb == "typeat" { self.keyboard(text, then: key, on: page) }
                    }
                    // A moment for the page to take it in.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { answer(["ok": true]) }
                }
            }

        case "scroll":
            let dy = min(20_000, max(-20_000, request["dy"] as? Double ?? 600))
            let dx = min(20_000, max(-20_000, request["dx"] as? Double ?? 0))
            let at = point(request, on: page)
            if request["x"] != nil || request["y"] != nil, at == nil {
                return answer(["error": "x and y must be a point on the page, in the latest screenshot's pixels"])
            }
            still(page, at != nil) { trouble in
                if let trouble { return answer(["error": trouble]) }
                if let at { page.cursor = at }
                page.note("Scrolled \(dy >= 0 ? "down" : "up") \(Int(abs(dy)))")
                var arguments: [String: Any] = ["dx": dx, "dy": dy]
                if let at { arguments["x"] = at.x; arguments["y"] = at.y }
                self.run(Agent.scrolling, on: page, arguments) { value, trouble in
                    let said = trouble ?? value as? String ?? "the page didn't answer"
                    answer(said == "ok" ? self.describe(page) : ["error": said])
                }
            }

        case "close":
            close(page)
            answer(["closed": 1])

        default:
            answer(["error": "unknown call “\(verb)”"])
        }
    }

    /// Short enough for a line in the folder, and plainly someone's words.
    static func quoted(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return "“" + (flat.count > 60 ? String(flat.prefix(59)) + "…" : flat) + "”"
    }

    /// An http or https address with a host, and nothing else: no file on
    /// this Mac, no page of Shy's own, no other app's scheme.
    static func web(_ value: Any?) -> URL? {
        guard let text = value as? String, text.count <= 8192,
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    private func describe(_ page: Page) -> [String: Any] {
        var said: [String: Any] = ["id": page.id, "url": page.web.url?.absoluteString ?? "", "title": page.web.title ?? "",
                                   "loading": page.web.isLoading]
        if let handover = page.handover {
            said["handedOver"] = handover.over == nil
                ? (handover.acts ? (handover.asks ? "signed in to \(handover.site); each click and typing is asked about" : "signed in to \(handover.site)") : "signed in to \(handover.site), read-only")
                : "the sign-in to \(handover.site) was taken back: \(handover.over ?? "")"
        }
        return said
    }

    /// Answered once the page has stopped loading, or when the time is up.
    private func settle(_ page: Page, within seconds: Double, _ answer: @escaping ([String: Any]) -> Void) {
        let until = Date().addingTimeInterval(seconds)
        func look() {
            guard pages.contains(where: { $0 === page }) else { return answer(["error": "the page was closed"]) }
            if !page.web.isLoading || Date() >= until { return answer(describe(page)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { look() }
        }
        // A turn first: a load just asked for hasn't started yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { look() }
    }

    /// Run without a user gesture. WebKit's public way runs a script as
    /// though the page had been clicked, and an agent's click would then
    /// let the page do what only a person's click allows: write to your
    /// clipboard, play sound, open a system sheet. WebKit's own variant
    /// without one is asked for by name; without it nothing is run.
    func run(_ script: String, on page: Page, _ arguments: [String: Any] = [:], then: @escaping (Any?, String?) -> Void) {
        typealias Done = @convention(block) (Any?, NSError?) -> Void
        typealias Call = @convention(c) (AnyObject, Selector, NSString, NSDictionary, WKFrameInfo?, WKContentWorld, ObjCBool, Done) -> Void
        let call = NSSelectorFromString("_callAsyncJavaScript:arguments:inFrame:inContentWorld:withUserGesture:completionHandler:")
        guard page.web.responds(to: call), let imp = page.web.method(for: call) else {
            return then(nil, "this version of macOS can't act on a page without a click of its own")
        }
        let done: Done = { value, error in
            MainActor.assumeIsolated { then(value, error?.localizedDescription) }
        }
        unsafeBitCast(imp, to: Call.self)(page.web, call, script as NSString, arguments as NSDictionary, nil, Agent.world, false, done)
    }
}
