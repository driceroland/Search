import Foundation
import Security

// A Unix socket in the app's own folder that only this user can reach, for
// a program on this Mac to talk to the app: the bench (Bench.swift) and
// agents' pages (Agent.swift) each have one. One JSON object per line in,
// one per line out, one request per connection.
//
// Readable by this user and nobody else — the file mode says so, and the
// other end is checked for the same uid before a word is read.

@MainActor
final class LocalSocket {
    typealias Handle = ([String: Any], @escaping ([String: Any]) -> Void) -> Void

    private let path: String
    private let folder: URL
    private let decorate: (([String: Any]) -> [String: Any])?
    private let handle: Handle
    private var listener: Int32 = -1
    private var accepting: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]

    /// `decorate`: a last word added to every answer as it goes out.
    init(at url: URL, decorate: (([String: Any]) -> [String: Any])? = nil, handle: @escaping Handle) {
        path = url.path
        folder = url.deletingLastPathComponent()
        self.decorate = decorate
        self.handle = handle
    }

    /// Listening, or false when the socket couldn't be made.
    func start() -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        unlink(path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < room else { close(fd); return false }
        withUnsafeMutablePointer(to: &address.sun_path) { sun in
            sun.withMemoryRebound(to: CChar.self, capacity: room) { bytes in
                _ = strlcpy(bytes, path, room)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            unlink(path)
            return false
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        accepting = source
        listener = fd
        return true
    }

    func stop() {
        accepting?.cancel()
        accepting = nil
        if listener >= 0 { close(listener) }
        listener = -1
        unlink(path)
        clients.values.forEach { $0.drop() }
        clients = [:]
    }

    private func accept() {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        // Only this user. The file mode already says so; this says it again,
        // for the day the folder's permissions are not what they were.
        var uid = uid_t(0)
        var gid = gid_t(0)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            return
        }
        // A client gone before its answer is written is a failed write, not
        // a SIGPIPE that ends the app.
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let client = Client(fd: fd, decorate: decorate) { [weak self] request, answer in
            self?.handle(request, answer)
        } gone: { [weak self] fd in
            self?.clients[fd] = nil
        }
        clients[fd] = client
    }

    // MARK: - one connection

    /// Reads until a newline, hands the line up, writes the answer, closes.
    private final class Client {
        let fd: Int32
        private var bytes = Data()
        private let source: DispatchSourceRead
        private let decorate: (([String: Any]) -> [String: Any])?
        private let handle: Handle
        private let gone: (Int32) -> Void
        private var answered = false

        init(
            fd: Int32,
            decorate: (([String: Any]) -> [String: Any])?,
            handle: @escaping Handle,
            gone: @escaping (Int32) -> Void
        ) {
            self.fd = fd
            self.decorate = decorate
            self.handle = handle
            self.gone = gone
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in self?.read() }
            source.resume()
        }

        private func read() {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 {
                if count == 0 || errno != EAGAIN { drop() }
                return
            }
            bytes.append(contentsOf: chunk[0..<count])
            // A line that never ends is not a request.
            if bytes.count > 4_000_000 {
                say(["error": "request too long"])
                return
            }
            guard let newline = bytes.firstIndex(of: 0x0A) else { return }
            let line = bytes[bytes.startIndex..<newline]
            bytes = Data()
            source.cancel()
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                say(["error": "not a JSON object"])
                return
            }
            handle(json) { [weak self] answer in self?.say(answer) }
        }

        private func say(_ answer: [String: Any]) {
            guard !answered else { return }
            answered = true
            // The socket's queue is the main one.
            let answer = decorate.map { decorate in MainActor.assumeIsolated { decorate(answer) } } ?? answer
            var out = (try? JSONSerialization.data(withJSONObject: answer)) ?? Data("{\"error\":\"unwritable answer\"}".utf8)
            out.append(0x0A)
            out.withUnsafeBytes { raw in
                var sent = 0
                // A reader that stops reading gets two seconds, not the app.
                var patience = 1000
                while sent < raw.count {
                    let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                    if n <= 0 {
                        if errno == EAGAIN, patience > 0 { patience -= 1; usleep(2000); continue }
                        break
                    }
                    sent += n
                }
            }
            drop()
        }

        func drop() {
            if !source.isCancelled { source.cancel() }
            close(fd)
            gone(fd)
        }
    }
}

#if DEBUG
/// Whether a socket's switch was turned on in Settings, by you. A setting
/// lives in the defaults, which any program you run can write; on its own it
/// opens nothing. The switch also leaves a mark in the keychain — its data
/// protection half, where only apps signed as Shy with its profile can
/// read or write, under the app's own access group — and without the mark
/// the setting is put back to off at launch, with a word about it. Test runs
/// keep the setting alone: their worlds hold nothing of yours, and scripts
/// set them up with a defaults write.
@MainActor
enum SwitchMark {
    private static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrService as String: "io.github.nxcco.shy.bench",
         kSecAttrAccount as String: Store.world.map { "\(name) (\($0))" } ?? name]
    }

    /// The mark is there. A copy built without Shy's provisioning profile
    /// has nowhere to keep one, and there the switch holds for the launch
    /// it was turned on in only: counted as given, any program could turn
    /// the bench on with a defaults write and drive your signed-in pages at
    /// the next launch, without a word. Test runs hold nothing of yours.
    static func given(_ name: String) -> Bool {
        var asked = query(name)
        asked[kSecReturnAttributes as String] = true
        let status = SecItemCopyMatching(asked as CFDictionary, nil)
        return status == errSecSuccess || (status == errSecMissingEntitlement && Store.testing)
    }

    static func grant(_ name: String) {
        var item = query(name)
        item[kSecValueData as String] = Data("on".utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess, status != errSecDuplicateItem, status != errSecMissingEntitlement {
            NSLog("%@: the switch left no mark (%d)", name, status)
        }
    }

    static func revoke(_ name: String) {
        SecItemDelete(query(name) as CFDictionary)
    }
}
#endif
