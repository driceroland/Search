import AppKit
import OSLog
import WebKit

// A coding agent on this Mac — Claude Code, Codex — using the window you
// already have open, when you let it.
//
// Off unless switched on in Settings › About › Developer, and the switch
// leaves a mark in the keychain as the bench's does (SwitchMark): a setting
// some other program wrote is put back to off at launch. On, Search listens
// on a Unix socket, Agent/agent.sock in its own folder: the folder 0700 and
// this user's, the socket 0600, and the other end checked for the same uid
// before a byte is read. Never on the network. `search-mcp` at the root of
// the repository is the client an agent runs.
//
// Each connection asks first. Its first line says who it is, and the window
// shows "<name> wants to use Search" with Allow and Don't Allow; nothing
// else it sends is looked at until you answer, and only a mouse click in
// that window answers. Allowed, it lasts as long as that connection does,
// or until Stop on the pill the window shows for as long as it is
// connected, or its window closes. Nothing is remembered: the next
// connection asks again. One agent at a time; after Don't Allow, Stop, or
// a question left unanswered, nobody asks again for a few seconds, so a
// client can't bury you in questions.
//
// It works in tabs of its own: opened at the end of your row, marked, never
// selected for you, never in your session, never a script's (the bench's).
// Your own tabs it can list and read only if you ticked "Let it see my open
// tabs", and it never clicks, types or goes anywhere in them, and waits on
// nothing in them but their address and title. Private tabs it never sees.
//
// What it can do is the list of verbs below, each checked here, not in the
// client: no script or CSS of its own runs in a page, only Search's
// (PageScripts), in Search's own world. Values of password, card and
// one-time-code fields never leave the page — those it fills itself, and
// any box seen as a password, stay secret for good — and pictures black out
// those, every frame, and whatever can't be read. Secret-looking values are
// taken out of the addresses it is given. No cookies, no storage, nothing
// from the keychain, no camera, microphone, screen, location or
// notifications, and no offer to save a password it signed in with. No
// files chosen, no downloads, and no address but http and https: not
// Search's own pages, Settings, extensions or file://, and no link handed
// to another app. Keys and clicks go to its page's view, never through the
// app, so none of Search's shortcuts hears them, and ⌘ and ctrl-letters
// are refused. Requests are paced to something like a person's speed, each
// step checks it is still allowed, and each is written to the unified log,
// category "Agent", without what the page says.
//
// Out of scope: another process this user trusted with Accessibility and
// input control can make up mouse events that look like a hand's.

// MARK: - consent

/// Where one connection stands with you. Plain, so its rules can be tested
/// without a socket or a window.
struct AgentConsent: Equatable {
    enum State: Equatable {
        /// Connected, and not yet said who it is.
        case connected
        /// The question is up.
        case asking
        case allowed
        case refused
        /// Stopped, gone, or the setting turned off. Nothing comes back from here.
        case ended
    }

    enum Verdict: Equatable {
        case go
        /// Held until you answer.
        case wait
        case refuse(String)
    }

    enum Use { case read, drive }

    private(set) var state: State = .connected
    /// "Let it see my open tabs", ticked when it was allowed.
    private(set) var seesTabs = false

    /// It said who it is: the question goes up. Once.
    @discardableResult
    mutating func hello() -> Bool {
        guard state == .connected else { return false }
        state = .asking
        return true
    }

    /// Your answer. Only to a question that is up.
    mutating func answer(allow: Bool, seesTabs: Bool) {
        guard state == .asking else { return }
        state = allow ? .allowed : .refused
        self.seesTabs = allow && seesTabs
    }

    mutating func end() {
        state = .ended
        seesTabs = false
    }

    /// What a request may do now.
    func verdict(for verb: String) -> Verdict {
        switch state {
        case .connected: return verb == "hello" ? .go : .refuse("hello_first")
        case .asking: return .wait
        case .allowed: return verb == "hello" ? .refuse("said_hello") : .go
        case .refused: return .refuse("not_allowed")
        case .ended: return .refuse("stopped")
        }
    }

    /// A tab of its own it may read and drive; one of yours only read, and
    /// only if you said so.
    func may(_ use: Use, own: Bool) -> Bool {
        guard state == .allowed else { return false }
        return own || (use == .read && seesTabs)
    }
}

// MARK: - rules

/// What an agent may be given, and where it may go: plain functions, tested
/// on their own (AgentControlTests).
@MainActor
enum AgentRules {
    /// An address to open or go to: http or https, with a host, and no
    /// name or password in it. A bare host is taken as https.
    static func address(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }) else { return nil }
        var url = URL(string: trimmed)
        if url?.scheme == nil || url?.host == nil, !trimmed.contains(":") {
            url = URL(string: "https://" + trimmed)
        }
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// Whether a page in an agent's tab may go somewhere by itself — a link,
    /// a redirect, a script. The web, and the blank and generated pages the
    /// web makes; never Search's own pages, an extension's, a file, or a
    /// scheme some other app would be handed.
    static func mayLoad(_ url: URL) -> Bool {
        ["http", "https", "about", "blob", "data"].contains(url.scheme?.lowercased() ?? "")
    }

    /// A key to press: "Enter", "Tab", "Escape", "Backspace", "Delete", the
    /// arrows, "Home", "End", "PageUp", "PageDown", "Space", or one
    /// character, after "shift+" or "alt+"; "ctrl+" only before a named key.
    /// Never ⌘: with it, a key is a command — copy, paste, close — and those
    /// are yours. Never ctrl and a character: Cocoa's Emacs keys (ctrl+k,
    /// ctrl+y) cut and yank text, which could carry a password's into a
    /// field that can be read.
    static func key(_ spec: String) -> (code: UInt16, characters: String, flags: NSEvent.ModifierFlags)? {
        var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "shift++" is shift and the plus key.
        if spec.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["+"] }
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for part in parts {
            switch part.lowercased() {
            case "shift": flags.insert(.shift)
            case "alt", "opt", "option": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default: return nil
            }
        }
        func function(_ code: Int) -> String { String(Character(UnicodeScalar(UInt32(code))!)) }
        let named: [String: (UInt16, String)] = [
            "enter": (36, "\r"), "return": (36, "\r"), "tab": (48, "\t"), "escape": (53, "\u{1b}"),
            "esc": (53, "\u{1b}"), "backspace": (51, "\u{7f}"), "delete": (117, function(NSDeleteFunctionKey)),
            "arrowup": (126, function(NSUpArrowFunctionKey)), "arrowdown": (125, function(NSDownArrowFunctionKey)),
            "arrowleft": (123, function(NSLeftArrowFunctionKey)), "arrowright": (124, function(NSRightArrowFunctionKey)),
            "home": (115, function(NSHomeFunctionKey)), "end": (119, function(NSEndFunctionKey)),
            "pageup": (116, function(NSPageUpFunctionKey)), "pagedown": (121, function(NSPageDownFunctionKey)),
            "space": (49, " "),
        ]
        if let (code, characters) = named[last.lowercased()] {
            if [123, 124, 125, 126, 115, 119, 116, 121, 117].contains(code) { flags.insert(.function) }
            return (code, characters, flags)
        }
        guard last.count == 1, let character = last.first, !character.isNewline, !flags.contains(.control) else { return nil }
        return (Bench.keyCode(for: character), last, flags)
    }

    /// What wait_for waits on: text in the page, a control by role and
    /// name, the address or the title. Never a CSS selector: attribute
    /// selectors (escaped any way CSS allows), :placeholder-shown, :invalid
    /// or :autofill can each be made to answer what a field holds, a letter
    /// at a time. On one of your tabs, only its address and title. The
    /// address and title are checked here, against the address as the agent
    /// is given it (`url`, with secrets taken out of it), never in the page.
    struct Condition {
        /// For PageScripts.check: text, role, name.
        var page: [String: Any] = [:]
        var url: String?
        var title: String?
        var gone = false
        var none: Bool { page.isEmpty && url == nil && title == nil }

        func met(page ok: Bool, url address: String, title said: String) -> Bool {
            var all = ok
            if let url { all = all && AgentRules.url(address).contains(url) }
            if let title { all = all && said.contains(title) }
            return gone ? !all : all
        }
    }

    static func condition(_ request: [String: Any], own: Bool) -> Result<Condition, AgentRefusal> {
        if request["selector"] != nil {
            return .failure(AgentRefusal(code: "bad_condition", message: "wait_for takes no selector",
                                         hint: "Wait for text, a role and name, the url or the title."))
        }
        var out = Condition()
        for key in ["text", "role", "name"] {
            guard let value = request[key] as? String else { continue }
            guard own else {
                return .failure(AgentRefusal(code: "bad_condition", message: "On the person's tab, only url and title",
                                             hint: "Open the address in a tab of your own to wait on its content."))
            }
            out.page[key] = value
        }
        out.url = request["url"] as? String
        out.title = request["title"] as? String
        out.gone = request["gone"] as? Bool ?? false
        return .success(out)
    }

    /// An address as an agent is given it: the values of anything in its
    /// query or fragment named like a password, a code or a token taken out.
    /// A sign-in sent by GET, or a link back from one, carries them there.
    nonisolated static func url(_ text: String) -> String {
        guard var parts = URLComponents(string: text) else { return text }
        let named = #"pass|pwd|^pw$|^p$|otp|code|token|secret|auth|key|session|sig|cvc|cvv|card|pin$"#
        func hidden(_ items: [URLQueryItem]) -> [URLQueryItem] {
            items.map { item in
                guard item.value?.isEmpty == false,
                      item.name.range(of: named, options: [.regularExpression, .caseInsensitive]) != nil else { return item }
                return URLQueryItem(name: item.name, value: "redacted")
            }
        }
        var changed = false
        if let items = parts.queryItems {
            let kept = hidden(items)
            if kept != items { parts.queryItems = kept; changed = true }
        }
        // access_token=… after the #, as OAuth hands it back.
        if let fragment = parts.fragment, fragment.contains("=") {
            var inner = URLComponents()
            inner.query = fragment
            if let items = inner.queryItems {
                let kept = hidden(items)
                if kept != items, let query = { var c = URLComponents(); c.queryItems = kept; return c.query }() {
                    parts.fragment = query
                    changed = true
                }
            }
        }
        return changed ? (parts.string ?? text) : text
    }

    /// A click on Allow, Don't Allow or Stop that came from a person: the
    /// mouse, in that window. A press through Accessibility arrives with no
    /// mouse event at all, and is refused. Events made up by another trusted
    /// process (CGEventPost, a tool with Accessibility and input access) look
    /// like a hand's, and are out of what this can tell.
    static func isClick(_ event: NSEvent?, in window: NSWindow?) -> Bool {
        guard let event, let window, [.leftMouseDown, .leftMouseUp].contains(event.type) else { return false }
        return event.window === window || event.windowNumber == window.windowNumber
    }

    /// Why an agent can't use a tab this way, or nil if it can. A private
    /// tab is never there at all: not listed, not found, not said to exist.
    static func refusal(for tab: Tab, own: Bool, consent: AgentConsent, use: AgentConsent.Use) -> String? {
        if tab.shy { return "stale_page" }
        return consent.may(use, own: own) ? nil : "not_yours"
    }

    /// The name a client gives itself, as it may be shown: printable, short,
    /// and never empty. It is the client's word, and the question says whose
    /// program asked beside it.
    static func clientName(_ raw: Any?) -> String {
        let text = (raw as? String ?? "").unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) && !"“”\"".unicodeScalars.contains($0) }
        let name = String(String.UnicodeScalarView(text)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "A program" : String(name.prefix(40))
    }
}

/// How fast an agent's requests are taken: a few at once, then about five
/// a second — a quick person's speed. Too fast and they wait their turn.
struct AgentPace {
    var burst = 8.0
    var perSecond = 5.0
    private var tokens: Double?
    private var last: TimeInterval?

    /// How long the next request waits, asked at `now`.
    mutating func delay(at now: TimeInterval) -> TimeInterval {
        var have = tokens ?? burst
        if let last { have = min(burst, have + max(0, now - last) * perSecond) }
        last = now
        have -= 1
        tokens = have
        return have >= 0 ? 0 : -have / perSecond
    }
}

/// A refusal: a code an agent can branch on, what happened, what to do.
struct AgentRefusal: Error {
    let code: String
    let message: String
    var hint = ""

    var said: [String: Any] {
        var out: [String: Any] = ["code": code, "message": message]
        if !hint.isEmpty { out["hint"] = hint }
        return ["error": out]
    }
}

// MARK: - one connection

@MainActor
final class AgentSession: ObservableObject, Identifiable {
    let id = UUID()
    fileprivate let fd: Int32
    /// Which program connected, as macOS says: "python3, started by claude".
    let program: String
    /// What it calls itself.
    @Published fileprivate(set) var client = ""
    @Published fileprivate(set) var consent = AgentConsent()
    /// The window it asked in, and works in.
    weak var browser: Browser?
    /// When the question went up: a click in its first half second is taken
    /// as one meant for whatever was there before.
    fileprivate(set) var asked = Date()

    fileprivate var source: DispatchSourceRead?
    /// What is still to be sent, and the source that sends it once the
    /// client reads again: a client that stops reading never holds the app.
    fileprivate var outbox = Data()
    fileprivate var writer: DispatchSourceWrite?
    /// Its window closing ends it, asked or allowed.
    fileprivate var closing: NSObjectProtocol?
    fileprivate var bytes = Data()
    fileprivate var inbox: [[String: Any]] = []
    fileprivate var working = false
    fileprivate var hello: (([String: Any]) -> Void)?
    fileprivate var pace = AgentPace()

    /// p1 → the tab it names. Its own tabs, and yours once listed.
    fileprivate var pages: [String: Tab.ID] = [:]
    /// The tabs it opened, and the ones those opened.
    fileprivate(set) var own: Set<Tab.ID> = []
    /// p1 → the number of its last read.
    fileprivate var snaps: [String: Int] = [:]
    private var counter = 0

    fileprivate init(fd: Int32, program: String) {
        self.fd = fd
        self.program = program
    }

    fileprivate func handle(for tab: Tab) -> String {
        if let found = pages.first(where: { $0.value == tab.id }) { return found.key }
        counter += 1
        let handle = "p\(counter)"
        pages[handle] = tab.id
        return handle
    }

    fileprivate func forget(_ handle: String) {
        pages[handle] = nil
        snaps[handle] = nil
    }
}

// MARK: - the listener

@MainActor
final class AgentControl: ObservableObject {
    static let shared = AgentControl()
    static let log = Logger(subsystem: "com.officecommun.search", category: "Agent")

    /// In a folder of its own beside the session file, 0700 and this
    /// user's: a test world's is its own.
    static var folder: URL { Store.file("Agent") }
    static var socket: URL { folder.appendingPathComponent("agent.sock") }
    /// Past this much unsent, a client isn't reading, and is let go.
    static let most = 64 << 20
    /// After Don't Allow or Stop, no new question for this long.
    static let quiet: TimeInterval = 10
    /// Where the element lists live in each page, apart from the bench's.
    private static let key = "__searchAgent"

    /// The one connection there is, asking or allowed.
    @Published private(set) var session: AgentSession?
    private(set) var running = false
    private var listener: Int32 = -1
    private var accepting: DispatchSourceRead?
    private var quietUntil = Date.distantPast

    // MARK: starting and stopping

    func start() {
        guard !running, let fd = Self.listen() else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.accept() } }
        source.resume()
        accepting = source
        listener = fd
        running = true
        Self.log.notice("listening")
    }

    /// The listening socket, made where nobody else can reach it: in a
    /// folder this user owns, 0700, that is no link to somewhere else. The
    /// process's umask is left alone; the folder is what keeps others out
    /// between the socket being made and its mode set, and the mode is set
    /// on the socket itself, never through a link.
    static func listen() -> Int32? {
        let dir = folder.path, path = socket.path
        try? FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mkdir(dir, 0o700) != 0, errno != EEXIST { return nil }
        var info = stat()
        guard lstat(dir, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            log.error("the agent folder isn't a folder of this user's; not listening")
            return nil
        }
        let folderFD = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard folderFD >= 0 else { return nil }
        let held = fchmod(folderFD, 0o700)
        close(folderFD)
        guard held == 0 else { return nil }
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < room else { close(fd); return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { sun in
            sun.withMemoryRebound(to: CChar.self, capacity: room) { _ = strlcpy($0, path, room) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, fchmodat(AT_FDCWD, path, 0o600, AT_SYMLINK_NOFOLLOW) == 0, Darwin.listen(fd, 4) == 0 else {
            close(fd)
            unlink(path)
            return nil
        }
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    func stop() {
        if let session { end(session, "the setting was turned off") }
        guard running else { return }
        accepting?.cancel()
        accepting = nil
        close(listener)
        listener = -1
        unlink(Self.socket.path)
        running = false
        Self.log.notice("closed")
    }

    private func accept() {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        // Only this user. The file's mode already says so; this says it
        // again, for the day the folder's permissions are not what they were.
        var uid = uid_t(0)
        var gid = gid_t(0)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            Self.log.notice("refused a connection from another user")
            return
        }
        var quietly = Int32(1)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &quietly, socklen_t(MemoryLayout<Int32>.size))
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        if session != nil || Date() < quietUntil {
            let busy = session != nil
            let refusal = AgentRefusal(
                code: busy ? "busy" : "not_now",
                message: busy ? "Another agent is using Search" : "Search was just told no, or stopped",
                hint: busy ? "Wait for it to finish." : "Ask again in a few seconds, once."
            )
            Self.write(refusal.said, to: fd)
            close(fd)
            Self.log.notice("refused a connection: \(busy ? "busy" : "too soon", privacy: .public)")
            return
        }
        let session = AgentSession(fd: fd, program: Self.program(of: fd))
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self, weak session] in
            MainActor.assumeIsolated { if let self, let session { self.read(session) } }
        }
        // The socket goes with the source, and only then: nothing reads or
        // writes a number that may already be someone else's.
        source.setCancelHandler { close(fd) }
        session.source = source
        self.session = session
        source.resume()
        Self.log.notice("connected: \(session.program, privacy: .public)")
    }

    /// The program at the other end, and the one that started it — what the
    /// question says beside the name the client gives itself.
    static func program(of fd: Int32) -> String {
        var pid = pid_t(0)
        var size = socklen_t(MemoryLayout<pid_t>.size)
        // SOL_LOCAL, LOCAL_PEERPID.
        guard getsockopt(fd, 0, 0x002, &pid, &size) == 0, pid > 0 else { return "" }
        let (name, parent) = process(pid)
        let parentName = parent > 1 ? process(parent).name : ""
        return parentName.isEmpty || parentName == name ? name : "\(name), started by \(parentName)"
    }

    private static func process(_ pid: pid_t) -> (name: String, parent: pid_t) {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return ("", 0) }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return (name, info.kp_eproc.e_ppid)
    }

    // MARK: reading and writing

    private func read(_ session: AgentSession) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(session.fd, &chunk, chunk.count)
        if count <= 0 {
            if count == 0 || errno != EAGAIN { end(session, "the connection closed") }
            return
        }
        session.bytes.append(contentsOf: chunk[0..<count])
        // A line that never ends is not a request, and a pile of them is
        // not something a person's pace explains.
        if session.bytes.count > 1_000_000 || session.inbox.count > 32 {
            say(AgentRefusal(code: "too_much", message: "Too much at once").said, to: session)
            end(session, "it sent too much")
            return
        }
        while let newline = session.bytes.firstIndex(of: 0x0A) {
            let line = session.bytes[session.bytes.startIndex..<newline]
            session.bytes = Data(session.bytes[session.bytes.index(after: newline)...])
            guard !line.isEmpty else { continue }
            guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                say(AgentRefusal(code: "bad_request", message: "Not a JSON object").said, to: session)
                continue
            }
            session.inbox.append(request)
        }
        pump(session)
    }

    private func say(_ answer: [String: Any], to session: AgentSession) {
        guard self.session === session else { return }
        var out = (try? JSONSerialization.data(withJSONObject: answer)) ?? Data(#"{"error":{"code":"internal","message":"unwritable answer"}}"#.utf8)
        out.append(0x0A)
        session.outbox.append(out)
        guard session.outbox.count <= Self.most else {
            session.outbox = Data()
            end(session, "it stopped reading")
            return
        }
        flush(session)
    }

    /// As much as the socket takes now; the rest when it takes more.
    private func flush(_ session: AgentSession) {
        while !session.outbox.isEmpty {
            let sent = session.outbox.withUnsafeBytes { Darwin.write(session.fd, $0.baseAddress!, $0.count) }
            if sent > 0 { session.outbox.removeFirst(sent); continue }
            if sent < 0, errno == EAGAIN { break }
            session.outbox = Data()
            if self.session === session, session.consent.state != .ended { end(session, "the connection closed") }
            return
        }
        if session.outbox.isEmpty {
            session.writer?.cancel()
            session.writer = nil
        } else if session.writer == nil {
            let writer = DispatchSource.makeWriteSource(fileDescriptor: session.fd, queue: .main)
            writer.setEventHandler { [weak self, weak session] in
                MainActor.assumeIsolated { if let self, let session { self.flush(session) } }
            }
            session.writer = writer
            writer.resume()
        }
    }

    /// One small answer to a connection that never becomes a session.
    private static func write(_ answer: [String: Any], to fd: Int32) {
        guard var out = try? JSONSerialization.data(withJSONObject: answer) else { return }
        out.append(0x0A)
        _ = out.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
    }

    /// The next request, once the one before has its answer, at the pace.
    private func pump(_ session: AgentSession) {
        guard self.session === session, !session.working, let request = session.inbox.first else { return }
        let verb = request["do"] as? String ?? ""
        switch session.consent.verdict(for: verb) {
        case .wait:
            return
        case .refuse(let code):
            session.inbox.removeFirst()
            say(reply(AgentRefusal(code: code, message: refusalText(code)).said, to: request), to: session)
            Self.log.notice("\(verb, privacy: .public) refused: \(code, privacy: .public)")
            pump(session)
            return
        case .go:
            break
        }
        session.inbox.removeFirst()
        session.working = true
        let delay = verb == "hello" ? 0 : session.pace.delay(at: ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak session] in
            guard let self, let session, self.session === session else { return }
            var answered = false
            let answer: ([String: Any]) -> Void = { [weak self, weak session] out in
                guard !answered, let self, let session else { return }
                answered = true
                let code = ((out["error"] as? [String: Any])?["code"] as? String) ?? "ok"
                Self.log.notice("\(verb, privacy: .public) \(request["page"] as? String ?? request["element"] as? String ?? "", privacy: .public) \(code, privacy: .public)")
                self.say(self.reply(out, to: request), to: session)
                session.working = false
                self.pump(session)
            }
            // One answer, always: a page that never replies doesn't hold the
            // agent, or the next request, for ever. You, answering the
            // question, are not on a clock.
            if verb != "hello" {
                let patience = min(60, (request["timeout"] as? Double ?? 20) + 15)
                DispatchQueue.main.asyncAfter(deadline: .now() + patience) {
                    answer(AgentRefusal(code: "no_answer", message: "No answer within \(Int(patience)) s").said)
                }
            }
            self.run(verb, request, in: session, answer)
        }
    }

    private func reply(_ out: [String: Any], to request: [String: Any]) -> [String: Any] {
        var out = out
        if let n = request["n"] { out["n"] = n }
        return out
    }

    private func refusalText(_ code: String) -> String {
        switch code {
        case "hello_first": return "Say hello first"
        case "said_hello": return "Already said"
        case "not_allowed": return "You were not allowed to use Search"
        default: return "Stopped in Search"
        }
    }

    // MARK: ending

    /// Stop, from the pill.
    func stopSession() {
        if let session { end(session, "stopped from the window") }
    }

    private func end(_ session: AgentSession, _ why: String) {
        guard self.session === session else { return }
        let was = session.consent.state
        session.hello?(AgentRefusal(code: "stopped", message: "Stopped in Search").said)
        session.hello = nil
        session.consent.end()
        // What was said last goes if the socket takes it now; nothing waits.
        flush(session)
        if let closing = session.closing { NotificationCenter.default.removeObserver(closing) }
        session.closing = nil
        session.writer?.cancel()
        session.writer = nil
        session.inbox = []
        session.source?.cancel()
        session.source = nil
        self.session = nil
        // A question you said no to, walked away from, or an agent you
        // stopped, doesn't come straight back.
        if was == .refused || was == .asking || (was == .allowed && why.hasPrefix("stopped")) {
            quietUntil = Date().addingTimeInterval(Self.quiet)
        }
        Self.log.notice("ended: \(why, privacy: .public)")
    }

    /// Whether a session may still act: the one there is, and allowed.
    /// Asked again before every step that touches a page, so nothing it
    /// asked for runs after Stop.
    private func live(_ session: AgentSession) -> Bool {
        self.session === session && session.consent.state == .allowed
    }

    // MARK: answering the question

    /// Allow or Don't Allow, from the question in the window: only a mouse
    /// click in that window (AgentRules.isClick), and none in the
    /// question's first half second.
    func answer(allow: Bool, seesTabs: Bool, event: NSEvent?) {
        guard let session, AgentRules.isClick(event, in: session.browser?.window) else {
            Self.log.notice("an answer that was no click in the window was ignored")
            return
        }
        decide(allow: allow, seesTabs: seesTabs, now: Date())
    }

    /// The bench's answer, in a test run (Bench `agents`).
    func answerForTest(allow: Bool, seesTabs: Bool) {
        guard Store.testing else { return }
        decide(allow: allow, seesTabs: seesTabs, now: .distantFuture)
    }

    private func decide(allow: Bool, seesTabs: Bool, now: Date) {
        guard let session, session.consent.state == .asking, now.timeIntervalSince(session.asked) > 0.5 else { return }
        session.consent.answer(allow: allow, seesTabs: seesTabs)
        Self.log.notice("\(allow ? "allowed" : "not allowed", privacy: .public)\(allow && seesTabs ? ", with your tabs" : "", privacy: .public)")
        let hello = session.hello
        session.hello = nil
        if allow {
            hello?(["allowed": true, "seesTabs": session.consent.seesTabs])
            pump(session)
        } else {
            hello?(AgentRefusal(code: "not_allowed", message: "You were not allowed to use Search").said)
            // Said, then gone.
            DispatchQueue.main.async { [weak self, weak session] in
                if let self, let session { self.end(session, "not allowed") }
            }
        }
    }

    /// For the bench's `agents`.
    var state: [String: Any] {
        guard let session else { return ["running": running, "connected": false] }
        let state: String = switch session.consent.state {
        case .connected: "connected"
        case .asking: "asking"
        case .allowed: "allowed"
        case .refused: "refused"
        case .ended: "ended"
        }
        return ["running": running, "connected": true, "state": state, "client": session.client,
                "program": session.program, "seesTabs": session.consent.seesTabs,
                "own": session.own.count]
    }

    /// A tab an agent's tab opened (Browser's createWebViewWith): its own too.
    func adopted(_ tab: Tab, from opener: Tab) {
        guard let session, session.own.contains(opener.id) else { return }
        session.own.insert(tab.id)
    }

    // MARK: - the verbs

    private func run(_ verb: String, _ request: [String: Any], in session: AgentSession, _ answer: @escaping ([String: Any]) -> Void) {
        func refuse(_ refusal: AgentRefusal) { answer(refusal.said) }
        if verb == "hello" {
            session.client = AgentRules.clientName(request["client"])
            session.browser = Browsers.all.first { $0.window?.isKeyWindow == true } ?? Browsers.primary
            guard session.browser != nil else {
                refuse(AgentRefusal(code: "no_window", message: "Search has no window open"))
                end(session, "no window")
                return
            }
            session.consent.hello()
            session.asked = Date()
            session.closing = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: session.browser?.window, queue: .main
            ) { [weak self, weak session] _ in
                MainActor.assumeIsolated { if let self, let session { self.end(session, "the window closed") } }
            }
            // Answered when you answer.
            session.hello = answer
            return
        }
        guard let browser = session.browser, Browsers.all.contains(where: { $0 === browser }) else {
            refuse(AgentRefusal(code: "stopped", message: "Its window was closed"))
            end(session, "the window closed")
            return
        }
        do {
            switch verb {
            case "status":
                answer(["allowed": true, "seesTabs": session.consent.seesTabs, "client": session.client])
            case "tabs":
                tabs(session, browser, answer)
            case "open":
                guard let url = AgentRules.address(request["url"] as? String ?? "") else { throw Self.badAddress }
                let tab = browser.benchOpen(url, agent: true)
                session.own.insert(tab.id)
                PageRoom.shared.house(tab)
                settle(tab, session, timeout: request["timeout"] as? Double ?? 20, answer)
            case "go":
                let tab = try self.tab(request, session, browser, .drive)
                guard let url = AgentRules.address(request["url"] as? String ?? "") else { throw Self.badAddress }
                tab.go(to: url)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.settle(tab, session, timeout: request["timeout"] as? Double ?? 20, answer)
                }
            case "back", "forward":
                let tab = try self.tab(request, session, browser, .drive)
                PageRoom.shared.house(tab)
                if verb == "back" { tab.web.goBack() } else { tab.web.goForward() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.settle(tab, session, timeout: request["timeout"] as? Double ?? 20, answer)
                }
            case "close":
                let tab = try self.tab(request, session, browser, .drive)
                let handle = request["page"] as? String ?? ""
                browser.close(tab)
                session.own.remove(tab.id)
                session.forget(handle)
                answer(["closed": handle])
            case "read":
                try read(request, session, browser, answer)
            case "click":
                try click(request, session, browser, answer)
            case "type":
                try type(request, session, browser, answer)
            case "press":
                let tab = try self.tab(request, session, browser, .drive)
                guard let key = AgentRules.key(request["key"] as? String ?? "") else {
                    throw AgentRefusal(code: "bad_key", message: "Not a key this can press",
                                       hint: "Enter, Tab, Escape, Backspace, an arrow, or one character, after shift+, alt+ or ctrl+. Never cmd.")
                }
                guard live(session) else { throw AgentRefusal(code: "stopped", message: "Stopped in Search") }
                PageRoom.shared.house(tab)
                PageHands.key(tab.web, code: key.code, characters: key.characters, flags: key.flags)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.settle(tab, session, timeout: 10, answer)
                }
            case "scroll":
                try scroll(request, session, browser, answer)
            case "wait_for":
                try waitFor(request, session, browser, answer)
            case "shot":
                try shot(request, session, browser, answer)
            case "bye":
                answer(["bye": true])
                DispatchQueue.main.async { [weak self] in self?.end(session, "it said goodbye") }
            default:
                throw AgentRefusal(code: "no_verb", message: "Search doesn't do “\(verb)” for an agent")
            }
        } catch let refusal as AgentRefusal {
            refuse(refusal)
        } catch {
            refuse(AgentRefusal(code: "internal", message: error.localizedDescription))
        }
    }

    private static let badAddress = AgentRefusal(
        code: "refused_address", message: "Only http and https addresses",
        hint: "Search's own pages, Settings, extensions and files are not for agents."
    )

    /// The tab a request's page handle names, if it may be used that way.
    /// A private tab is never found, and a tab of yours is read at most.
    private func tab(_ request: [String: Any], _ session: AgentSession, _ browser: Browser, _ use: AgentConsent.Use) throws -> Tab {
        let handle = request["page"] as? String ?? ""
        let found = session.pages[handle].flatMap { id in browser.tabs.first { $0.id == id } }
        let refusal = found.map { AgentRules.refusal(for: $0, own: session.own.contains($0.id), consent: session.consent, use: use) }
            ?? "stale_page"
        switch refusal {
        case nil:
            return found!
        case "not_yours":
            throw AgentRefusal(code: "not_yours", message: "That tab is the person's own: it can be read, never used",
                               hint: "Open the address in a tab of your own with open_tab.")
        default:
            if session.pages[handle] != nil { session.forget(handle) }
            throw AgentRefusal(code: "stale_page", message: "No page \(handle.isEmpty ? "given" : "“\(handle)”")", hint: "Use list_tabs or open_tab.")
        }
    }

    private func element(_ request: [String: Any], _ session: AgentSession, _ browser: Browser) throws -> (Tab, String, Int, Int) {
        let text = request["element"] as? String ?? ""
        let parts = text.split(separator: ".")
        guard parts.count == 3, parts[1].hasPrefix("s"), parts[2].hasPrefix("e"),
              let snap = Int(parts[1].dropFirst()), let index = Int(parts[2].dropFirst()) else {
            throw AgentRefusal(code: "bad_handle", message: "An element handle looks like p1.s3.e12, from read_page")
        }
        let page = String(parts[0])
        let tab = try self.tab(["page": page], session, browser, .drive)
        guard session.snaps[page] == snap else {
            throw AgentRefusal(code: "stale_element", message: "That handle is from an earlier read_page", hint: "Call read_page again.")
        }
        return (tab, page, snap, index)
    }

    /// A script of Search's, in Search's world, on the tab's page: its own
    /// tab housed off screen first; one of yours read as it is, and never
    /// woken for it.
    private func page(_ tab: Tab, _ session: AgentSession, _ script: String,
                      _ done: @escaping (Result<[String: Any], AgentRefusal>) -> Void) {
        guard live(session) else {
            done(.failure(AgentRefusal(code: "stopped", message: "Stopped in Search")))
            return
        }
        let web: WKWebView
        if tab.bench {
            PageRoom.shared.house(tab)
            web = tab.web
        } else if let built = tab.built, !tab.asleep {
            web = built
        } else {
            done(.failure(AgentRefusal(code: "asleep", message: "That tab is asleep, and isn't woken for an agent")))
            return
        }
        web.evaluateJavaScript(script, in: nil, in: Web.world) { [weak self] result in
            guard let self, live(session) else {
                done(.failure(AgentRefusal(code: "stopped", message: "Stopped in Search")))
                return
            }
            switch result {
            case .failure(let error):
                done(.failure(AgentRefusal(code: "page", message: error.localizedDescription)))
            case .success(let value):
                guard let text = value as? String, let data = text.data(using: .utf8),
                      let out = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    done(.failure(AgentRefusal(code: "page", message: "The page gave nothing back")))
                    return
                }
                if let code = out["error"] as? String {
                    let stale = ["stale_element", "detached"].contains(code)
                    done(.failure(AgentRefusal(code: code, message: out["message"] as? String ?? "",
                                               hint: stale ? "Call read_page again." : "")))
                } else {
                    done(.success(out))
                }
            }
        }
    }

    private func describe(_ tab: Tab, _ session: AgentSession) -> [String: Any] {
        var out: [String: Any] = ["page": session.handle(for: tab), "url": AgentRules.url(tab.address?.absoluteString ?? ""),
                                  "title": tab.title, "loading": tab.loading]
        if let failure = tab.failure { out["failure"] = failure }
        return out
    }

    /// Once the page has stopped loading, or the time is up.
    private func settle(_ tab: Tab, _ session: AgentSession, timeout: Double, _ answer: @escaping ([String: Any]) -> Void) {
        let limit = Date().addingTimeInterval(min(max(timeout, 0), 30))
        func look() {
            if !tab.loading, tab.address != nil {
                // A beat for the document's own scripts to settle.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self else { return }
                    answer(describe(tab, session))
                }
                return
            }
            guard Date() < limit else {
                var out = describe(tab, session)
                out["timeout"] = true
                answer(out)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { look() }
        }
        look()
    }

    private func tabs(_ session: AgentSession, _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let live = Set(browser.tabs.map(\.id))
        for (handle, id) in session.pages where !live.contains(id) { session.forget(handle) }
        session.own.formIntersection(live)
        let shown = browser.tabs.filter { tab in
            AgentRules.refusal(for: tab, own: session.own.contains(tab.id), consent: session.consent, use: .read) == nil
        }
        answer(["tabs": shown.map { tab -> [String: Any] in
            var out = describe(tab, session)
            out["mine"] = session.own.contains(tab.id)
            return out
        }])
    }

    private func read(_ request: [String: Any], _ session: AgentSession, _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) throws {
        let tab = try self.tab(request, session, browser, .read)
        let handle = session.handle(for: tab)
        let snap = (session.snaps[handle] ?? 0) + 1
        let most = min(max(request["max_nodes"] as? Int ?? 300, 1), 2000)
        let longest = min(max(request["max_text"] as? Int ?? 20000, 0), 200_000)
        page(tab, session, PageScripts.read(key: Self.key, snap: snap, most: most, longest: longest, text: request["text"] as? Bool ?? true)) { result in
            switch result {
            case .failure(let refusal): answer(refusal.said)
            case .success(var out):
                session.snaps[handle] = snap
                let own = session.own.contains(tab.id)
                out["nodes"] = (out["nodes"] as? [[String: Any]] ?? []).map { node in
                    var node = node
                    let index = node.removeValue(forKey: "e") as? Int ?? -1
                    // Your tabs are read, never touched: no handles to touch them by.
                    if own { node["element"] = "\(handle).s\(snap).e\(index)" }
                    if let href = node["href"] as? String { node["href"] = AgentRules.url(href) }
                    return node
                }
                out["page"] = handle
                out["url"] = AgentRules.url(out["url"] as? String ?? "")
                answer(out)
            }
        }
    }

    private func click(_ request: [String: Any], _ session: AgentSession, _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) throws {
        let (tab, page, snap, index) = try element(request, session, browser)
        let before = tab.address
        self.page(tab, session, PageScripts.touch(key: Self.key, snap: snap, index: index, how: "click", text: nil, replace: true, strict: true)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let refusal): answer(refusal.said)
            case .success(let seen):
                guard self.live(session) else { return answer(AgentRefusal(code: "stopped", message: "Stopped in Search").said) }
                guard let at = seen["at"] as? [Double], PageHands.click(tab.web, at: at) else {
                    answer(AgentRefusal(code: "not_clicked", message: "The page had nowhere to click").said)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.settle(tab, session, timeout: request["timeout"] as? Double ?? 10) { out in
                        var out = out
                        out["page"] = page
                        out["navigated"] = tab.address != before
                        answer(out)
                    }
                }
            }
        }
    }

    private func type(_ request: [String: Any], _ session: AgentSession, _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) throws {
        let (tab, _, snap, index) = try element(request, session, browser)
        let text = String((request["text"] as? String ?? "").prefix(10000))
        let replace = request["replace"] as? Bool ?? true
        func touch(_ how: String, _ text: String?, _ then: @escaping ([String: Any]) -> Void) {
            page(tab, session, PageScripts.touch(key: Self.key, snap: snap, index: index, how: how, text: text, replace: replace, strict: true)) { result in
                switch result {
                case .failure(let refusal): answer(refusal.said)
                case .success(let out): then(out)
                }
            }
        }
        func finish(_ out: [String: Any]) {
            guard request["submit"] as? Bool == true else { return answer(out) }
            touch("submit", "") { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self?.settle(tab, session, timeout: request["timeout"] as? Double ?? 10) { state in
                        answer(out.merging(state) { mine, _ in mine })
                    }
                }
            }
        }
        if request["keys"] as? Bool == true {
            // Real key events, into the field once focused. A field in the
            // room off screen may take the focus; one in your window you
            // are looking at never takes it from you.
            touch("focus", text) { focused in
                let web = tab.web
                if web.window === PageRoom.shared.window { web.window?.makeFirstResponder(web) }
                guard self.live(session) else { return answer(AgentRefusal(code: "stopped", message: "Stopped in Search").said) }
                PageHands.type(text, into: web)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    touch("verify", focused["want"] as? String) { finish($0) }
                }
            }
        } else {
            touch("set", text) { finish($0) }
        }
    }

    private func scroll(_ request: [String: Any], _ session: AgentSession, _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) throws {
        if request["element"] != nil {
            let (tab, _, snap, index) = try element(request, session, browser)
            page(tab, session, PageScripts.touch(key: Self.key, snap: snap, index: index, how: "scroll", text: nil, replace: true, strict: true)) { result in
                switch result {
                case .failure(let refusal): answer(refusal.said)
                case .success(let out): answer(out)
                }
            }
            return
        }
        let tab = try self.tab(request, session, browser, .drive)
        let dy = request["dy"] as? Double ?? 0
        let dx = request["dx"] as? Double ?? 0
        page(tab, session, PageScripts.scroll(dx: dx, dy: dy, to: request["to"] as? String)) { result in
            switch result {
            case .failure(let refusal): answer(refusal.said)
            case .success(let out): answer(out)
            }
        }
    }

    private func waitFor(_ request: [String: Any], _ session: AgentSession, _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) throws {
        let tab = try self.tab(request, session, browser, .read)
        let timeout = min(max(request["timeout"] as? Double ?? 10, 0), 30)
        let condition: AgentRules.Condition
        switch AgentRules.condition(request, own: session.own.contains(tab.id)) {
        case .failure(let refusal): throw refusal
        case .success(let made): condition = made
        }
        if condition.none {
            settle(tab, session, timeout: timeout) { out in
                if out["timeout"] as? Bool == true {
                    answer(AgentRefusal(code: "timeout", message: "Still loading after \(Int(timeout)) s").said)
                } else {
                    answer(out)
                }
            }
            return
        }
        let began = Date()
        func look() {
            guard live(session) else { return }
            // On your tab nothing is asked of the page: its address and title
            // are Search's to know.
            let asked: (@escaping (Result<[String: Any], AgentRefusal>) -> Void) -> Void = condition.page.isEmpty
                ? { done in done(.success(["met": true, "url": tab.address?.absoluteString ?? "", "title": tab.title])) }
                : { done in self.page(tab, session, PageScripts.check(condition.page), done) }
            asked { result in
                if case .success(let out) = result,
                   condition.met(page: out["met"] as? Bool == true, url: out["url"] as? String ?? "", title: out["title"] as? String ?? "") {
                    answer(["met": true, "page": session.handle(for: tab), "url": AgentRules.url(out["url"] as? String ?? ""),
                            "title": out["title"] ?? "", "waitedMs": Int(Date().timeIntervalSince(began) * 1000)])
                    return
                }
                if case .failure(let refusal) = result, ["bad_condition", "stopped"].contains(refusal.code) {
                    answer(refusal.said)
                    return
                }
                guard Date().timeIntervalSince(began) < timeout else {
                    answer(AgentRefusal(code: "timeout", message: "Not met within \(Int(timeout)) s",
                                        hint: "Nothing was repeated. read_page to see where the page is.").said)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { look() }
            }
        }
        look()
    }

    /// A picture of its own tab only, with every secret field and card
    /// form blacked out before it leaves.
    private func shot(_ request: [String: Any], _ session: AgentSession, _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) throws {
        let tab = try self.tab(request, session, browser, .drive)
        let width = (request["width"] as? Double).map { min(max($0, 200), 2560) }
        page(tab, session, PageScripts.secrets) { result in
            guard case .success(let found) = result else {
                if case .failure(let refusal) = result { answer(refusal.said) }
                return
            }
            guard self.live(session) else { return answer(AgentRefusal(code: "stopped", message: "Stopped in Search").said) }
            PageHands.snapshot(tab.web, width: width) { taken in
                switch taken {
                case .failure(let error):
                    answer(AgentRefusal(code: "no_picture", message: error.localizedDescription).said)
                case .success(let rep):
                    let across = found["width"] as? Double ?? Double(rep.pixelsWide)
                    let scale = across > 0 ? Double(rep.pixelsWide) / across : 1
                    let boxes = (found["boxes"] as? [[Double]] ?? []).filter { $0.count == 4 }
                    guard let png = Self.blackedOut(rep, boxes: boxes, scale: scale) else {
                        answer(AgentRefusal(code: "no_picture", message: "No picture").said)
                        return
                    }
                    answer(["png": png.base64EncodedString(), "width": rep.pixelsWide, "height": rep.pixelsHigh,
                            "blackedOut": boxes.count, "page": session.handle(for: tab)])
                }
            }
        }
    }

    /// The picture as a PNG, with each box (top-left CSS pixels) painted
    /// over.
    static func blackedOut(_ rep: NSBitmapImageRep, boxes: [[Double]], scale: Double) -> Data? {
        guard !boxes.isEmpty else { return rep.representation(using: .png, properties: [:]) }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.black.setFill()
        let height = Double(rep.pixelsHigh)
        // The context draws in points of the image's size; the boxes are in
        // pixels of the page.
        let points = rep.size.width > 0 ? rep.size.width / CGFloat(rep.pixelsWide) : 1
        for box in boxes {
            let x = box[0] * scale, y = box[1] * scale, w = box[2] * scale, h = box[3] * scale
            NSRect(x: x * points, y: (height - y - h) * points, width: w * points, height: h * points).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
