import Foundation
import OSLog
import WebKit

// Chrome's native messaging, for the extensions that talk to an app on this
// Mac — a password manager unlocking with its desktop app, a clipper handing
// a page to a notes app.
//
// Those apps register with Chrome by leaving a small JSON file in Chrome's
// NativeMessagingHosts folder: a name, the program to run, and which
// extensions may run it. Search reads the same files, runs the same program
// with the same argument, and speaks the same protocol — each message a
// four-byte length and a line of JSON, over the program's stdin and stdout.
// A host that lists the extension's id among its allowed origins is run;
// any other is not. Some hosts also check which browser is calling and may
// refuse one they don't know; that is theirs to decide.

@available(macOS 15.4, *)
enum ExtensionNative {
    /// Why an app's connection ended (#1122: iCloud Passwords' helper went
    /// after a couple of minutes): the host's name and how, never a message.
    /// `log show --predicate 'subsystem == "com.officecommun.search" AND
    /// category == "ExtensionNative"' --info --last 1h`
    static let log = Logger(subsystem: "com.officecommun.search", category: "ExtensionNative")

    /// "0.21 s": how long after its host started a connection ended. The
    /// moment matters (a port gone a fifth of a second in is the extension's
    /// side going, not the app's), so not rounded to whole seconds.
    static func since(_ start: Date, _ now: Date = Date()) -> String {
        String(format: "%.2f s", now.timeIntervalSince(start))
    }

    /// When each extension's page last lost its web process, and why. An
    /// extension's pages and its worker share one process: a page that
    /// crashes takes the worker's ports to apps down with it, and those
    /// hosts are stopped as the ports go. Kept so the log can say so (a
    /// 1Password page that "kept crashing" left only a closed connection
    /// in its app's log).
    @MainActor static var processEnds: [String: (at: Date, why: String)] = [:]

    /// An extension's page has lost its process (see Dialogs.pageProcessEnded).
    @MainActor
    static func processEnded(of extensionID: String, _ why: String) {
        processEnds[extensionID] = (Date(), why)
        let held = Live.pipes.values.filter { $0.extensionID == extensionID }
        log.notice("An extension's process ended (\(why, privacy: .public)) with \(held.count, privacy: .public) port(s) to apps open: they go with it")
        // At once, not when WebKit gets round to saying the ports went: by
        // then the extension's next process may be starting, and what the
        // app was still saying would be posted into it (idea 797). Each
        // port's own disconnect handler still logs it as it comes.
        for live in held {
            live.relay.close()
            live.pipe.stop()
        }
    }

    /// Why an extension let go of a port, as far as Search can tell.
    @MainActor
    static func letGoReason(of extensionID: String, _ now: Date = Date()) -> String {
        if let end = processEnds[extensionID], abs(now.timeIntervalSince(end.at)) < 3 {
            return "its process had just ended (\(end.why))"
        }
        return "its page or worker closed the port, reloaded or went"
    }

    struct Refused: LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    /// Where Chromium browsers look, per user and for the whole Mac.
    private static var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support")
        // A probe's world reads its own folder first, so a test can run a
        // host of its own without leaving a file in a browser's folder.
        let probe = Store.testing ? [Store.folder.appendingPathComponent("NativeMessagingHosts")] : []
        return probe + [
            support.appendingPathComponent("Google/Chrome/NativeMessagingHosts"),
            support.appendingPathComponent("Chromium/NativeMessagingHosts"),
            support.appendingPathComponent("Microsoft Edge/NativeMessagingHosts"),
            support.appendingPathComponent("BraveSoftware/Brave-Browser/NativeMessagingHosts"),
            support.appendingPathComponent("Arc/User Data/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Application Support/Chromium/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Microsoft/Edge/NativeMessagingHosts"),
            // Read last: a host of the same name that Chrome or the system knows comes first.
            support.appendingPathComponent("Vivaldi/NativeMessagingHosts"),
            support.appendingPathComponent("com.operasoftware.Opera/NativeMessagingHosts"),
        ]
    }

    /// The program for `name`, if one is registered and lets this extension in.
    private static func host(_ name: String, for extensionID: String) throws -> URL {
        guard name.range(of: #"^[a-z0-9_]+(\.[a-z0-9_]+)*$"#, options: .regularExpression) != nil else {
            throw Refused(why: "Invalid native messaging host name")
        }
        let origin = "chrome-extension://\(extensionID)/"
        for folder in folders {
            let file = folder.appendingPathComponent(name + ".json")
            guard let data = try? Data(contentsOf: file),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = manifest["path"] as? String
            else { continue }
            let allowed = manifest["allowed_origins"] as? [String] ?? []
            guard allowed.contains(origin) else {
                throw Refused(why: "Access to the specified native messaging host is forbidden.")
            }
            let program = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
            guard FileManager.default.isExecutableFile(atPath: program.path) else {
                throw Refused(why: "Specified native messaging host not found.")
            }
            return program
        }
        throw Refused(why: "Specified native messaging host not found.")
    }

    /// `runtime.sendNativeMessage`: run, send one, read one, stop.
    static func send(_ message: Any, to name: String, from extensionID: String) async throws -> Any? {
        let program = try host(name, for: extensionID)
        let pipe = HostPipe(program: program, origin: "chrome-extension://\(extensionID)/")
        try pipe.start()
        defer { pipe.stop() }
        return try await pipe.request(message)
    }

    /// `runtime.connectNative`: run, and keep the two talking until either
    /// end lets go.
    @MainActor
    static func connect(_ port: WKWebExtension.MessagePort, from extensionID: String) throws {
        guard let name = port.applicationIdentifier else { throw Refused(why: "No host named") }
        let program = try host(name, for: extensionID)
        // A new port is often a worker starting over; the one before may
        // have left its host behind.
        stopOrphans()
        let pipe = HostPipe(program: program, origin: "chrome-extension://\(extensionID)/")
        pipe.name = name
        let started = Date()
        log.notice("Host \(name, privacy: .public) started for a port")
        pipe.onTerminated = { note in
            log.notice("Host \(name, privacy: .public) ended: \(note, privacy: .public), \(since(started), privacy: .public) after it started")
        }
        // What the app says waits for the extension to speak on the port
        // first (or a second), and never goes to a port that has gone:
        // see PortRelay (idea 797).
        let relay = PortRelay(send: { port.sendMessage($0, completionHandler: nil) },
                              gone: { port.isDisconnected })
        pipe.onMessage = { message in
            DispatchQueue.main.async { MainActor.assumeIsolated { relay.fromApp(message) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + PortRelay.grace) { MainActor.assumeIsolated { relay.open() } }
        pipe.onExit = {
            DispatchQueue.main.async { if !port.isDisconnected { port.disconnect() } }
        }
        // Listened to before it runs: a host may answer at once. One that
        // can't run is let go as one that has exited.
        Live.keep(pipe, for: port, of: extensionID, name: name, started: started, relay: relay)
        do { try pipe.start() } catch { pipe.stop(); throw error }
        var beating: Timer?
        port.messageHandler = { message, _ in
            // The extension's side is there: what the app said may go.
            MainActor.assumeIsolated { relay.heard() }
            guard let message else { return }
            // A worker's shim asking whether the port has arrived (see the
            // shim, after its WebSocket): answered here, never passed on.
            if let asked = message as? [String: Any], let word = asked["__searchNative"] {
                // The shim's answer to "alive" (below) is only the worker
                // keeping itself: nothing to say back.
                guard (word as? String) == "here?" else { return }
                Live.pipes[ObjectIdentifier(pipe)]?.worker = true
                port.sendMessage(["__searchNative": "here"], completionHandler: nil)
                // Asked, it is a worker's port, and WebKit unloads a worker
                // that hasn't posted on a port for two minutes: iCloud
                // Passwords then forgets it was paired and asks for a code
                // again. Chrome keeps a worker with a port to an app alive;
                // here a word on the port now and then, heard only by the
                // shim, has the worker answer on it, which is what WebKit
                // counts.
                if beating == nil {
                    beating = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { timer in
                        guard !port.isDisconnected else { timer.invalidate(); return }
                        port.sendMessage(["__searchNative": "alive"], completionHandler: nil)
                    }
                }
                return
            }
            do { try pipe.write(message) } catch {
                log.notice("A message to host \(name, privacy: .public) wasn't sent: \(error.localizedDescription, privacy: .public)")
            }
        }
        port.disconnectHandler = { error in
            // Said at the default level, as the host's end is: a port the
            // extension lets go a moment after its host started was only
            // in the info log, and the log seemed to say nothing. Said a
            // moment later: WebKit may tell of the port before it tells of
            // the process that took it down.
            let when = since(started), failed = error != nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                log.notice("Port to \(name, privacy: .public) closed by the extension\(failed ? " with an error" : "", privacy: .public): \(letGoReason(of: extensionID), privacy: .public), \(when, privacy: .public) after its host started; its host is stopped")
            }
            MainActor.assumeIsolated { relay.close() }
            beating?.invalidate()
            pipe.stop()
        }
    }

    /// WebKit doesn't always say when a port goes: an extension unloaded —
    /// taken up afresh, turned off, removed — leaves its worker's ports
    /// disconnected without calling their disconnect handlers. Each host
    /// would run on, with any code prompt it had open, until the browser
    /// quit: iCloud Passwords left a helper behind at every restart. So the
    /// hosts of ports that have gone are stopped here; a port still
    /// connected keeps its own.
    @MainActor
    static func stopOrphans() {
        let gone = Live.pipes.values.filter { $0.port.isDisconnected }
        for live in gone {
            log.notice("Stopping host \(live.name, privacy: .public): its port went unannounced (\(letGoReason(of: live.extensionID), privacy: .public)), \(since(live.started), privacy: .public) after it started")
            live.relay.close()
            live.pipe.stop()
        }
    }

    /// A worker's ports go with it, yet WebKit, stopping an idle worker and
    /// starting it again on the next page, neither calls their disconnect
    /// handlers nor always has them read as disconnected: each new worker
    /// of 1Password's opened a host and the last one's ran on, dozens in an
    /// afternoon (#1036). So as an extension's worker starts again, the
    /// hosts its last worker opened are stopped, as Chrome stops a host
    /// whose worker has gone. Only a worker's ports ask "here?" (see the
    /// shim), so its pages' ports are left as they are.
    @MainActor
    static func stopWorkerHosts(of extensionID: String) {
        let last = Live.pipes.values.filter { $0.worker && $0.extensionID == extensionID }
        for live in last {
            log.notice("Stopping host \(live.name, privacy: .public): the extension's worker started again (\(letGoReason(of: extensionID), privacy: .public)), \(since(live.started), privacy: .public) after it started")
            // Its own disconnect handler would log the port as closed by
            // the extension; said above instead. Its keep-alive timer stops
            // itself once the port reads as disconnected.
            live.port.disconnectHandler = nil
            live.relay.close()
            live.pipe.stop()
            if !live.port.isDisconnected { live.port.disconnect() }
        }
    }

    /// Hosts that are connected, held until they end.
    private enum Live {
        nonisolated(unsafe) static var pipes: [ObjectIdentifier: (pipe: HostPipe, port: WKWebExtension.MessagePort, extensionID: String, worker: Bool, name: String, started: Date, relay: PortRelay)] = [:]
        static func keep(_ pipe: HostPipe, for port: WKWebExtension.MessagePort, of extensionID: String, name: String, started: Date, relay: PortRelay) {
            pipes[ObjectIdentifier(pipe)] = (pipe, port, extensionID, false, name, started, relay)
            let previous = pipe.onExit
            pipe.onExit = {
                previous?()
                DispatchQueue.main.async { pipes[ObjectIdentifier(pipe)] = nil }
            }
        }
    }
}

/// One host program and the framing Chrome uses to talk to it.
@available(macOS 15.4, *)
final class HostPipe: @unchecked Sendable {
    /// How long a host that has exited may leave its output open (a child
    /// of its own still holding it) before the connection ends anyway.
    static let exitGrace: TimeInterval = 1.5
    /// How long a host has, once asked to stop, before it is killed, as in Chrome.
    static let killGrace: TimeInterval = 2
    /// The most a host may send in one message, as in Chrome; a message to it is held to the same.
    static let frameCap = 1 << 20

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private let lock = NSLock()
    /// Held around each use of the input handle, so it is never written once closed.
    private let writing = NSLock()
    /// The host's name, for the log only.
    var name = ""
    var onMessage: ((Any) -> Void)?
    var onExit: (() -> Void)?
    /// Once the host's process has exited: how it ended (its status or the
    /// signal) and what came first, in plain words for a log. Nothing it sent.
    var onTerminated: ((String) -> Void)?
    private var waiters: [(id: Int, continuation: CheckedContinuation<Any?, Error>)] = []
    private var nextWaiter = 0
    private var stopped = false
    private var outputClosed = false
    private var finished = false
    private var inputClosed = false
    private var ending = false

    private static var exited: Error { ExtensionNative.Refused(why: "Native host has exited.") }

    init(program: URL, origin: String) {
        process.executableURL = program
        process.arguments = [origin]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A host that is already gone — refused to run, killed as it
        // started — would take the browser with it: writing to its closed
        // pipe raises SIGPIPE. Refused, the write only fails.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.lock.lock()
                self.outputClosed = true
                self.lock.unlock()
                self.finish()
                // As in Chrome, a host whose output has closed is done with,
                // even if it runs on.
                self.end()
                return
            }
            self.take(chunk)
        }
        // A host may exit the moment its last reply is written, before that
        // reply has been read: the end is when its output closes, as in
        // Chrome. But a child of the host's may hold that output open long
        // after, so an exit ends things after a grace in any case.
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.lock.lock()
            let now = self.stopped || self.outputClosed
            let first = self.stopped ? "stopped by the browser" : self.outputClosed ? "its output closed first" : "exited on its own"
            self.lock.unlock()
            let how = process.terminationReason == .uncaughtSignal
                ? "signal \(process.terminationStatus)" : "status \(process.terminationStatus)"
            self.onTerminated?("\(how), \(first)")
            if now {
                self.finish()
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.exitGrace) { self.finish(); self.end() }
            }
        }
        try process.run()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { end() } else { finish() }
    }

    func write(_ message: Any) throws {
        let json = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
        guard json.count <= Self.frameCap else { throw ExtensionNative.Refused(why: "Message too long for a native host") }
        var length = UInt32(json.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        writing.lock()
        defer { writing.unlock() }
        guard !inputClosed else { throw Self.exited }
        try input.fileHandleForWriting.write(contentsOf: frame)
    }

    func readOne() async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            if wait(continuation) == nil { continuation.resume(throwing: Self.exited) }
        }
    }

    /// Writes `message` and reads the reply. The reply's waiter is in place
    /// before the message goes, so a host quick to answer isn't missed.
    func request(_ message: Any) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            guard let id = wait(continuation) else { return continuation.resume(throwing: Self.exited) }
            do {
                try write(message)
            } catch {
                // Unless a reply or the end got to it first.
                lock.lock()
                let index = waiters.firstIndex { $0.id == id }
                if let index { waiters.remove(at: index) }
                lock.unlock()
                if index != nil { continuation.resume(throwing: error) }
            }
        }
    }

    /// Adds a waiter for the next message, or nil once the connection has ended.
    private func wait(_ continuation: CheckedContinuation<Any?, Error>) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        nextWaiter += 1
        waiters.append((nextWaiter, continuation))
        return nextWaiter
    }

    private func take(_ chunk: Data) {
        lock.lock()
        guard !finished else { return lock.unlock() }
        buffer.append(chunk)
        var messages: [Any] = []
        var overlong = false
        var dropped = 0
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            if length > Self.frameCap { overlong = true; buffer = Data(); break }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: 4..<(4 + length))
            buffer.removeSubrange(0..<(4 + length))
            if let message = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) {
                messages.append(message)
            } else {
                dropped += 1
            }
        }
        var handed: [(CheckedContinuation<Any?, Error>, Any)] = []
        for message in messages where !waiters.isEmpty {
            handed.append((waiters.removeFirst().continuation, message))
        }
        let rest = messages.dropFirst(handed.count)
        lock.unlock()
        handed.forEach { $0.0.resume(returning: $0.1) }
        rest.forEach { onMessage?($0) }
        // As in Chrome, a host claiming a message past the cap is done with;
        // what it sent before that in the same read is still heard.
        if dropped > 0 {
            ExtensionNative.log.notice("Host \(self.name, privacy: .public) sent \(dropped, privacy: .public) message(s) that aren't JSON: not passed on")
        }
        if overlong {
            ExtensionNative.log.notice("Host \(self.name, privacy: .public) announced a message over 1 MB: the connection ends, as in Chrome")
            finish(); end()
        }
    }

    /// Stops the host as Chrome does: its input closed and SIGTERM, then
    /// SIGKILL if it is still running after a grace.
    private func end() {
        lock.lock()
        let first = !ending
        ending = true
        lock.unlock()
        guard first else { return }
        // Off the caller's thread: a write stuck on a host that doesn't read
        // holds `writing` until the signals below free it.
        DispatchQueue.global().async {
            self.writing.lock()
            if !self.inputClosed {
                self.inputClosed = true
                try? self.input.fileHandleForWriting.close()
            }
            self.writing.unlock()
        }
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) {
            if self.process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func finish() {
        lock.lock()
        guard !finished else { return lock.unlock() }
        finished = true
        let pending = waiters
        waiters = []
        let exit = onExit
        onExit = nil
        lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        pending.forEach { $0.continuation.resume(throwing: Self.exited) }
        exit?()
    }
}
