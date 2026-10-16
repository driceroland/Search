import Darwin
import Foundation

/// A loopback-only HTTP origin for WebKit download tests. It supports byte
/// ranges and can deliberately truncate one response to exercise retry paths.
final class LocalDownloadServer {
    private struct Request {
        let path: String
        let range: String?
        let cookie: String?
    }

    private let socket: Int32
    private let source: DispatchSourceRead
    private let requestsLock = NSLock()
    private var requests: [Request] = []
    private var completedPaths: [String] = []
    private var stopped = false
    private let cancelTransferGate = DispatchSemaphore(value: 0)
    private let payload: Data
    let port: UInt16

    private let acceptQueue = DispatchQueue(label: "search.download-fixture.accept")
    private let clientsQueue = DispatchQueue(label: "search.download-fixture.clients", attributes: .concurrent)

    init(size: Int = 4 * 1024 * 1024) throws {
        payload = Data((0..<size).map { index in
            UInt8(truncatingIfNeeded: (index &* 31) ^ (index >> 8) ^ (index >> 17))
        })

        let server = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard server >= 0 else { throw Self.socketError("socket") }
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
            throw Self.socketError("bind/listen")
        }

        var actual = sockaddr_in()
        var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(server, $0, &actualLength)
            }
        }
        guard named == 0 else {
            Darwin.close(server)
            throw Self.socketError("getsockname")
        }
        port = UInt16(bigEndian: actual.sin_port)

        source = DispatchSource.makeReadSource(fileDescriptor: server, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
    }

    deinit { stop() }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func url(_ path: String) -> URL {
        baseURL.appendingPathComponent(String(path.drop(while: { $0 == "/" })))
    }

    func count(_ path: String) -> Int {
        requestsLock.lock()
        defer { requestsLock.unlock() }
        return requests.filter { $0.path == path }.count
    }

    func ranges(_ path: String) -> [String?] {
        requestsLock.lock()
        defer { requestsLock.unlock() }
        return requests.filter { $0.path == path }.map(\.range)
    }

    func cookies(_ path: String) -> [String?] {
        requestsLock.lock()
        defer { requestsLock.unlock() }
        return requests.filter { $0.path == path }.map(\.cookie)
    }

    func completed(_ path: String) -> Int {
        requestsLock.lock()
        defer { requestsLock.unlock() }
        return completedPaths.filter { $0 == path }.count
    }

    func expectedBytes() -> Data { payload }

    func stop() {
        requestsLock.lock()
        let shouldStop = !stopped
        stopped = true
        requestsLock.unlock()
        guard shouldStop else { return }
        cancelTransferGate.signal()
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
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        clientsQueue.async { [weak self] in self?.serve(client) }
    }

    private func serve(_ client: Int32) {
        defer { Darwin.close(client) }
        guard let request = readRequest(client) else { return }
        requestsLock.lock()
        requests.append(request)
        let attempt = requests.filter { $0.path == request.path }.count
        let shouldTruncate = ["/failure.bin", "/retry.bin"].contains(request.path) && attempt == 1
        requestsLock.unlock()

        if request.path == "/page" {
            let body = Data("<!doctype html><title>Download fixture</title><p>Local test page</p>".utf8)
            let headers = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: text/html; charset=utf-8\r\n"
                + "Set-Cookie: download-session=fixture-cookie; Path=/; HttpOnly\r\n"
                + "Content-Length: \(body.count)\r\n"
                + "Connection: close\r\n\r\n"
            if sendAll(client, Data(headers.utf8)), sendAll(client, body) {
                requestsLock.lock()
                completedPaths.append(request.path)
                requestsLock.unlock()
            }
            return
        }

        let start = Self.rangeStart(request.range)
        let lower = min(max(0, start), payload.count)
        let status = start > 0 ? "206 Partial Content" : "200 OK"
        let remaining = payload.count - lower
        let extraRange = start > 0
            ? "Content-Range: bytes \(lower)-\(payload.count - 1)/\(payload.count)\r\n"
            : ""
        let supportsRanges = request.path != "/retry.bin"
        let rangeHeaders = supportsRanges ? "Accept-Ranges: bytes\r\nETag: \"fixture-v1\"\r\n" : ""
        let headers = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: application/octet-stream\r\n"
            + "Content-Disposition: attachment; filename=\"fixture.bin\"\r\n"
            + rangeHeaders
            + extraRange
            + "Content-Length: \(remaining)\r\n"
            + "Connection: close\r\n\r\n"
        guard sendAll(client, Data(headers.utf8)) else { return }

        let length = shouldTruncate ? min(128 * 1024, remaining) : remaining
        let chunkSize = 16 * 1024
        var offset = lower
        let end = lower + length
        while offset < end {
            let next = min(offset + chunkSize, end)
            guard sendAll(client, payload.subdata(in: offset..<next)) else { return }
            offset = next
            // Cancellation cases require a live partial transfer. A clean CI
            // WebKit process can publish its first progress after the original
            // two-second response already finished. Hold the response open;
            // fixture.stop() releases this client during test teardown.
            if request.path == "/cancel.bin", offset - lower == 256 * 1024 {
                cancelTransferGate.wait()
            }
            // Leave enough time for the test to pause after real bytes arrive.
            Thread.sleep(forTimeInterval: 0.008)
        }
        if !shouldTruncate {
            requestsLock.lock()
            completedPaths.append(request.path)
            requestsLock.unlock()
        }
    }

    private func readRequest(_ client: Int32) -> Request? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let terminator = Data("\r\n\r\n".utf8)
        while data.count < 64 * 1024, data.range(of: terminator) == nil {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let header = String(data: data, encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first, let requestTarget = first.split(separator: " ").dropFirst().first else {
            return nil
        }
        let path = URLComponents(string: "http://fixture\(requestTarget)")?.path ?? String(requestTarget)
        var range: String?
        var cookie: String?
        for line in lines.dropFirst() {
            let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if fields.count == 2 {
                let key = fields[0].lowercased()
                if key == "range" { range = fields[1].trimmingCharacters(in: .whitespaces) }
                if key == "cookie" { cookie = fields[1].trimmingCharacters(in: .whitespaces) }
            }
        }
        return Request(path: path, range: range, cookie: cookie)
    }

    private func sendAll(_ client: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let count = send(client, base.advanced(by: sent), raw.count - sent, 0)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    private static func rangeStart(_ header: String?) -> Int {
        guard let header, let dash = header.firstIndex(of: "-"),
              let equals = header.firstIndex(of: "="), equals < dash else { return 0 }
        return Int(header[header.index(after: equals)..<dash]) ?? 0
    }

    private static func socketError(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(operation) failed"])
    }
}
