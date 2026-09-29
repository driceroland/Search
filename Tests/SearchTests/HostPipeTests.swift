import Darwin
import Foundation
import XCTest
@testable import Search

@available(macOS 15.4, *)
final class HostPipeTests: XCTestCase {
    private var folder: URL!
    private var pids: [URL] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("host-pipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for file in pids { if let pid = pid(file) { kill(pid, SIGKILL) } }
        try? FileManager.default.removeItem(at: folder)
    }

    /// A made-up host: `body` is Python run after the helpers, with `read()`
    /// and `send(obj)` speaking Chrome's framing. Its pid goes to the file returned.
    private func host(_ body: String) throws -> (URL, URL) {
        let name = UUID().uuidString
        let pidFile = folder.appendingPathComponent("\(name).pid")
        let script = folder.appendingPathComponent("\(name).py")
        let source = """
        #!/usr/bin/python3
        import json, os, struct, sys, time
        open(\(String(reflecting: pidFile.path)), "w").write(str(os.getpid()))
        def read():
            head = sys.stdin.buffer.read(4)
            if len(head) < 4: return None
            return json.loads(sys.stdin.buffer.read(struct.unpack("<I", head)[0]))
        def send(obj):
            data = json.dumps(obj).encode()
            sys.stdout.buffer.write(struct.pack("<I", len(data)) + data)
            sys.stdout.buffer.flush()
        \(body)
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        pids.append(pidFile)
        return (script, pidFile)
    }

    private func pid(_ file: URL) -> pid_t? {
        (try? String(contentsOf: file, encoding: .utf8)).flatMap { pid_t($0) }
    }

    private func alive(_ file: URL) -> Bool {
        guard let pid = pid(file) else { return false }
        return kill(pid, 0) == 0
    }

    private func settle(_ seconds: TimeInterval = 5, until: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if until() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return until()
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        private var items: [Any] = []
        func bump() { lock.lock(); value += 1; lock.unlock() }
        func first() -> Bool { lock.lock(); defer { lock.unlock() }; value += 1; return value == 1 }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func add(_ item: Any) { lock.lock(); items.append(item); lock.unlock() }
        var all: [Any] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func pipe(_ script: URL, exits: Counter, messages: Counter? = nil) -> HostPipe {
        let pipe = HostPipe(program: script, origin: "chrome-extension://madeupmadeupmadeupmadeupmadeupma/")
        pipe.onExit = { exits.bump() }
        if let messages { pipe.onMessage = { messages.add($0) } }
        return pipe
    }

    private func waiting(_ pipe: HostPipe) async throws -> Task<Any?, Error> {
        let task = Task { try await pipe.readOne() }
        try await Task.sleep(nanoseconds: 100_000_000)
        return task
    }

    private func result(_ task: Task<Any?, Error>, within seconds: Double = 10) async -> Result<Any?, Error> {
        struct TimedOut: Error {}
        let once = Counter()
        return await withCheckedContinuation { (done: CheckedContinuation<Result<Any?, Error>, Never>) in
            let finish: @Sendable (Result<Any?, Error>) -> Void = { outcome in
                if once.first() { done.resume(returning: outcome) }
            }
            Task { finish(await task.result) }
            Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); finish(.failure(TimedOut())) }
        }
    }

    // (a)
    func testLargeReplyThenImmediateExitIsDeliveredInFull() async throws {
        let (script, pidFile) = try host("""
        read()
        send({"blob": "x" * 200000})
        """)
        let exits = Counter()
        let pipe = pipe(script, exits: exits)
        try pipe.start()
        let first = try await waiting(pipe)
        let second = try await waiting(pipe)
        try pipe.write(["hello": "made up"])
        let reply = try await result(first).get() as? [String: Any]
        XCTAssertEqual((reply?["blob"] as? String)?.count, 200_000)
        guard case .failure(let error) = await result(second) else { return XCTFail("second waiter got a reply") }
        XCTAssertEqual(error.localizedDescription, "Native host has exited.")
        XCTAssertTrue(settle { exits.count == 1 })
        XCTAssertTrue(settle { !self.alive(pidFile) })
        pipe.stop()
        XCTAssertEqual(exits.count, 1)
    }

    // (a) with the reader busy: the host has exited while its reply still sits in the pipe.
    func testReplyStillUnreadWhenHostExitsIsDelivered() async throws {
        let (script, _) = try host("""
        send({"first": True})
        time.sleep(0.1)
        send({"blob": "y" * 30000})
        """)
        let exits = Counter()
        let pipe = pipe(script, exits: exits)
        let reply = Counter()
        pipe.onMessage = { [unowned pipe] _ in
            Task {
                do { reply.add(Result<Any?, Error>.success(try await pipe.readOne())) } catch { reply.add(Result<Any?, Error>.failure(error)) }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        try pipe.start()
        XCTAssertTrue(settle { reply.all.count == 1 })
        let outcome = try XCTUnwrap(reply.all.first as? Result<Any?, Error>)
        XCTAssertEqual(((try? outcome.get()) as? [String: Any])?["blob"].flatMap { ($0 as? String)?.count }, 30_000)
        XCTAssertTrue(settle { exits.count == 1 })
    }

    // (b)
    func testLongLivedHostAnswersEachMessageAndStaysOpenUntilStopped() async throws {
        let (script, pidFile) = try host("""
        while True:
            message = read()
            if message is None: break
            send({"echo": message["n"]})
        """)
        let exits = Counter(), messages = Counter()
        let pipe = pipe(script, exits: exits, messages: messages)
        try pipe.start()
        for n in 0..<5 { try pipe.write(["n": n]) }
        XCTAssertTrue(settle { messages.all.count == 5 })
        XCTAssertEqual(messages.all.compactMap { ($0 as? [String: Any])?["echo"] as? Int }, Array(0..<5))
        try pipe.write(["n": 5])
        XCTAssertTrue(settle { messages.all.count == 6 })
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(exits.count, 0)
        XCTAssertTrue(alive(pidFile))
        pipe.stop()
        XCTAssertTrue(settle { exits.count == 1 })
        XCTAssertTrue(settle { !self.alive(pidFile) })
    }

    // (c)
    func testStopTerminatesRunningHostAndEndsOnce() throws {
        let (script, pidFile) = try host("time.sleep(60)")
        let exits = Counter()
        let pipe = pipe(script, exits: exits)
        try pipe.start()
        XCTAssertTrue(settle { self.alive(pidFile) })
        pipe.stop()
        XCTAssertTrue(settle { exits.count == 1 })
        XCTAssertTrue(settle { !self.alive(pidFile) })
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(exits.count, 1)
    }

    // (d)
    func testStopAfterHostExitedEndsOnceWithoutHanging() throws {
        let (script, pidFile) = try host("send({\"bye\": True})")
        let exits = Counter(), messages = Counter()
        let pipe = pipe(script, exits: exits, messages: messages)
        try pipe.start()
        XCTAssertTrue(settle { self.pid(pidFile) != nil && !self.alive(pidFile) })
        Thread.sleep(forTimeInterval: 0.3)
        pipe.stop()
        XCTAssertTrue(settle { exits.count == 1 })
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(exits.count, 1)
    }

    // (e)
    func testHostClosingOutputEndsConnectionAndIsStopped() throws {
        let (script, pidFile) = try host("""
        send({"last": True})
        os.close(1)
        time.sleep(60)
        """)
        let exits = Counter(), messages = Counter()
        let pipe = pipe(script, exits: exits, messages: messages)
        try pipe.start()
        XCTAssertTrue(settle { exits.count == 1 })
        XCTAssertEqual(messages.all.count, 1)
        // SIGTERM ends it, well before the kill would.
        XCTAssertTrue(settle(HostPipe.killGrace * 0.75) { !self.alive(pidFile) })
        pipe.stop()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(exits.count, 1)
    }

    // (e) with a host that ignores SIGTERM: it is killed after the grace.
    func testHostClosingOutputAndIgnoringTermIsKilled() throws {
        let (script, pidFile) = try host("""
        import signal
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        os.close(1)
        time.sleep(60)
        """)
        let exits = Counter()
        let pipe = pipe(script, exits: exits)
        try pipe.start()
        XCTAssertTrue(settle { exits.count == 1 })
        Thread.sleep(forTimeInterval: HostPipe.killGrace / 2)
        XCTAssertTrue(alive(pidFile))
        XCTAssertTrue(settle(HostPipe.killGrace + 3) { !self.alive(pidFile) })
        XCTAssertEqual(exits.count, 1)
    }

    // (g) a host that exits while a child of its own holds its output open.
    func testHostExitingWithOutputHeldOpenEndsAfterGrace() async throws {
        let childFile = folder.appendingPathComponent("\(UUID().uuidString).pid")
        pids.append(childFile)
        let (script, pidFile) = try host("""
        import subprocess
        child = subprocess.Popen(["/bin/sleep", "30"])
        open(\(String(reflecting: childFile.path)), "w").write(str(child.pid))
        read()
        """)
        let exits = Counter()
        let pipe = pipe(script, exits: exits)
        try pipe.start()
        XCTAssertTrue(settle { self.alive(childFile) })
        let waiter = try await waiting(pipe)
        try pipe.write(["hello": "made up"])
        XCTAssertTrue(settle { !self.alive(pidFile) })
        let exited = Date()
        guard case .failure(let error) = await result(waiter) else { return XCTFail("waiter got a reply") }
        XCTAssertEqual(error.localizedDescription, "Native host has exited.")
        XCTAssertLessThan(Date().timeIntervalSince(exited), HostPipe.exitGrace + 1)
        XCTAssertEqual(exits.count, 1)
        XCTAssertTrue(alive(childFile))
        pipe.stop()
        XCTAssertEqual(exits.count, 1)
    }

    // (h) a host that answers at once is always heard.
    func testRequestToQuickHostAlwaysGetsTheReply() async throws {
        let (script, _) = try host("""
        send({"echo": read()["n"]})
        """)
        for n in 0..<30 {
            let exits = Counter()
            let pipe = pipe(script, exits: exits)
            try pipe.start()
            let reply = try await result(Task { try await pipe.request(["n": n]) }, within: 5).get() as? [String: Any]
            XCTAssertEqual(reply?["echo"] as? Int, n)
            pipe.stop()
        }
    }

    // (h) once ended, a request or read fails at once rather than waiting.
    func testRequestAfterEndFailsAtOnce() async throws {
        let (script, _) = try host("pass")
        let exits = Counter()
        let pipe = pipe(script, exits: exits)
        try pipe.start()
        XCTAssertTrue(settle { exits.count == 1 })
        for task in [Task { try await pipe.request(["n": 1]) }, Task { try await pipe.readOne() }] {
            guard case .failure(let error) = await result(task, within: 1) else { return XCTFail("got a reply") }
            XCTAssertEqual(error.localizedDescription, "Native host has exited.")
        }
        pipe.stop()
    }

    // (f)
    func testHostExitingSilentlyFailsWaiters() async throws {
        let (script, _) = try host("read()")
        let exits = Counter()
        let pipe = pipe(script, exits: exits)
        try pipe.start()
        let waiter = try await waiting(pipe)
        try pipe.write(["hello": "made up"])
        guard case .failure(let error) = await result(waiter) else { return XCTFail("waiter got a reply") }
        XCTAssertEqual(error.localizedDescription, "Native host has exited.")
        XCTAssertTrue(settle { exits.count == 1 })
        pipe.stop()
        XCTAssertEqual(exits.count, 1)
    }
}
