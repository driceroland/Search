import Darwin
import Foundation

/// A loopback-only HTTP origin serving a fixed table of pages, for tests that
/// need a page and its neighbours on a real http address. Anything not in
/// the table is a 404 page, as a real site's would be.
final class LocalPageServer {
    struct Page {
        var status = "200 OK"
        var type: String
        var body: String
    }

    private let socket: Int32
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var asked: [String] = []
    private var stopped = false
    private let pages: [String: Page]
    let port: UInt16

    private let acceptQueue = DispatchQueue(label: "search.page-fixture.accept")
    private let clientsQueue = DispatchQueue(label: "search.page-fixture.clients", attributes: .concurrent)

    init(_ pages: [String: Page]) throws {
        self.pages = pages
        let server = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard server >= 0 else { throw Self.failure("socket") }
        socket = server

        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) {
            setsockopt(server, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }
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

        source = DispatchSource.makeReadSource(fileDescriptor: server, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
    }

    deinit { stop() }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    /// Every path asked for, in order.
    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    func stop() {
        lock.lock()
        let first = !stopped
        stopped = true
        lock.unlock()
        guard first else { return }
        source.cancel()
        shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
    }

    private func acceptOne() {
        let client = Darwin.accept(socket, nil, nil)
        guard client >= 0 else { return }
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        clientsQueue.async { [weak self] in self?.serve(client) }
    }

    private func serve(_ client: Int32) {
        defer { Darwin.close(client) }
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
        asked.append(path)
        lock.unlock()

        let page = pages[path] ?? Page(status: "404 Not Found", type: "text/html",
                                       body: "<!doctype html><title>Not found</title><p>Nothing here</p>")
        let body = Data(page.body.utf8)
        let head = "HTTP/1.1 \(page.status)\r\n"
            + "Content-Type: \(page.type)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        _ = send(client, Data(head.utf8) + body)
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
