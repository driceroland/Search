import AppKit
import Combine
import Darwin
import WebKit
import XCTest
@testable import Search

/// Waking a sleeping tab: the page loads the moment its view is in a window,
/// not on the next tick of a timer, and the picture of the old page comes off
/// once the new one has drawn, not half a second after it arrived. Nothing
/// is shown: the window is far off every screen.
@MainActor
final class WakeLatencyTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "wake-latency-\(getpid())", 1)
        super.setUp()
    }

    private var browser: Browser!
    private var window: NSWindow!
    private var server: SlowServer!
    private var watching: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        // The second time a page is asked for, it stops after its first
        // words and never finishes: loaded, drawn, and not done, as a page
        // with a slow picture or script is for seconds after it shows.
        server = try SlowServer { _, count in
            let words = String(repeating: "A page that has drawn something to look at. ", count: 200)
            return .init(body: "<!doctype html><title>Woken</title><body style='margin:0'><p>\(words)</p>", stalls: count > 1)
        }
    }

    override func tearDown() {
        watching = []
        server.stop()
        browser.closeAll()
        window.close()
        browser = nil
        window = nil
        server = nil
    }

    /// The stage's part, done by hand: the view in the window at the window's size.
    private func attach(_ tab: Tab) {
        let page = tab.web
        // A window far off every screen counts as hidden to WebKit, which
        // then lays nothing out; the page is to see itself shown.
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if page.responds(to: occlusion) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(page.method(for: occlusion), to: Setter.self)(page, occlusion, false)
        }
        page.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(page)
    }

    /// The run loop turned over by hand, at least once, until `done` or the time is up.
    /// Not `await`ed: a test's async body runs on the main queue, and the
    /// blocks this waits for would queue behind it.
    private func spin(for seconds: TimeInterval, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
        } while !done() && Date() < end
    }

    /// A tab that has been somewhere and is put to sleep with a picture, as
    /// the browser does after half an hour.
    private func asleep() throws -> Tab {
        let tab = browser.benchOpen(server.url("/page"))
        attach(tab)
        spin(for: 10) { tab.built?.isLoading == false && tab.built?.url?.path == "/page" }
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        tab.sleep(picture: rep.representation(using: .jpeg, properties: [:]))
        XCTAssertTrue(tab.asleep)
        return tab
    }

    /// The load is asked for in the run loop's next turn after the view lands
    /// in a window. Waiting for a timer to look again, it was asked for at
    /// the timer's next tick, 20 ms after the wake, however soon the stage
    /// had the view in place.
    func testAWokenPageLoadsAsSoonAsItsViewIsInAWindow() throws {
        let tab = try asleep()
        let before = server.requests("/page")
        tab.wake()
        attach(tab)
        // A few milliseconds of the run loop, a good deal less than a tick.
        spin(for: 0.008) { server.requests("/page") > before || tab.web.isLoading }
        XCTAssertTrue(tab.web.isLoading, "The page should be asked for as the view lands, not on a timer's tick")
    }

    /// A view nobody puts in a window still loads, once the second the wait
    /// is bounded at is up.
    func testAWokenPageWithNoStageLoadsAfterAboutASecond() throws {
        let tab = try asleep()
        let before = server.requests("/page")
        tab.wake()
        spin(for: 0.4) { false }
        XCTAssertEqual(server.requests("/page"), before, "It waits for a window first")
        spin(for: 4) { server.requests("/page") > before }
        XCTAssertGreaterThan(server.requests("/page"), before, "It loads all the same, with no window to wait for")
    }

    /// The picture of the old page goes once the page has drawn under it,
    /// where it stayed until half a second after the page arrived whatever
    /// the page had done by then. The load here never finishes, so nothing
    /// else takes the picture off before the half second does.
    func testTheWakePictureComesOffOnceThePageHasDrawn() throws {
        let tab = try asleep()
        var drawn: CFTimeInterval?
        var off: CFTimeInterval?
        tab.$painted.dropFirst().sink { if $0, drawn == nil { drawn = CACurrentMediaTime() } }.store(in: &watching)
        tab.$cover.dropFirst().sink { if $0 == nil, off == nil { off = CACurrentMediaTime() } }.store(in: &watching)

        tab.wake()
        XCTAssertNotNil(tab.cover, "The picture covers the page while it comes back")
        attach(tab)
        spin(for: 6) { off != nil }

        let first = try XCTUnwrap(drawn, "The page never drew")
        let gone = try XCTUnwrap(off, "The picture never came off")
        XCTAssertTrue(tab.built?.isLoading == true, "The load is meant to still be going, so only the first frame can have done it")
        XCTAssertGreaterThanOrEqual(gone, first, "Not before there is a page to see")
        XCTAssertLessThan(gone - first, 0.3, "The picture stayed on long after the page had drawn")
    }
}

/// A loopback origin that can stop partway through a page: it sends what it
/// has and holds the connection open, as a site still sending does. Asked for
/// the page's nth time, `reply` says what it is and whether it stalls.
private final class SlowServer: @unchecked Sendable {
    struct Reply {
        var body: String
        var stalls = false
    }

    private let socket: Int32
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var stopped = false
    private let reply: (String, Int) -> Reply
    let port: UInt16

    init(_ reply: @escaping (String, Int) -> Reply) throws {
        self.reply = reply
        let server = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard server >= 0 else { throw Self.failure("socket") }
        socket = server
        var reuse: Int32 = 1
        _ = setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(server, 8) == 0 else {
            Darwin.close(server)
            throw Self.failure("bind/listen")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &length) }
        }
        guard named == 0 else {
            Darwin.close(server)
            throw Self.failure("getsockname")
        }
        port = UInt16(bigEndian: actual.sin_port)
        Thread.detachNewThread { [weak self] in
            while let self, !self.isStopped {
                let client = Darwin.accept(self.socket, nil, nil)
                guard client >= 0 else { return }
                Thread.detachNewThread { [weak self] in self?.serve(client) }
            }
        }
    }

    deinit { stop() }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    func requests(_ path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[path] ?? 0
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        let first = !stopped
        stopped = true
        lock.unlock()
        guard first else { return }
        shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
    }

    private func serve(_ client: Int32) {
        defer { Darwin.close(client) }
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 64 * 1024, data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let header = String(data: data, encoding: .utf8),
              let target = header.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first
        else { return }
        let path = URLComponents(string: "http://fixture\(target)")?.path ?? String(target)
        lock.lock()
        let count = (counts[path] ?? 0) + 1
        counts[path] = count
        lock.unlock()

        let answer = reply(path, count)
        let body = Data(answer.body.utf8)
        // Never kept: waking has to ask again.
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\n"
            + "\(answer.stalls ? "" : "Content-Length: \(body.count)\r\n")Connection: close\r\n\r\n"
        guard send(client, Data(head.utf8) + body), answer.stalls else { return }
        while !isStopped { usleep(50_000) }
    }

    private func send(_ client: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(client, base.advanced(by: sent), raw.count - sent, 0)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    private static func failure(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(operation) failed"])
    }
}
