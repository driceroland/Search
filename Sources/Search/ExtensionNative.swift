import Foundation
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
    struct Refused: LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    /// Where Chromium and system browsers look, per user and for the whole Mac,
    /// including macOS system cryptex and Mozilla locations.
    private static var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support")
        return [
            support.appendingPathComponent("Google/Chrome/NativeMessagingHosts"),
            support.appendingPathComponent("Chromium/NativeMessagingHosts"),
            support.appendingPathComponent("Microsoft Edge/NativeMessagingHosts"),
            support.appendingPathComponent("BraveSoftware/Brave-Browser/NativeMessagingHosts"),
            support.appendingPathComponent("Arc/User Data/NativeMessagingHosts"),
            support.appendingPathComponent("Mozilla/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Application Support/Chromium/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Microsoft/Edge/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Application Support/Mozilla/NativeMessagingHosts"),
            URL(fileURLWithPath: "/System/Volumes/Preboot/Cryptexes/App/Library/Google/Chrome/NativeMessagingHosts"),
            URL(fileURLWithPath: "/System/Volumes/Preboot/Cryptexes/App/Library/Application Support/Mozilla/NativeMessagingHosts"),
            URL(fileURLWithPath: "/System/Cryptexes/App/Library/Google/Chrome/NativeMessagingHosts"),
            URL(fileURLWithPath: "/System/Cryptexes/App/Library/Application Support/Mozilla/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Apple/System/Library/CoreServices/NativeMessagingHosts"),
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
            let allowed = (manifest["allowed_origins"] as? [String])
                ?? (manifest["allowed_extensions"] as? [String]) ?? []
            guard allowed.contains(origin) || allowed.contains(extensionID) else {
                throw Refused(why: "Access to the specified native messaging host is forbidden.")
            }
            let program = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
            guard FileManager.default.isExecutableFile(atPath: program.path) else {
                throw Refused(why: "Specified native messaging host not found.")
            }
            return program
        }

        // Apple Passwords helper fallback if no manifest file was found on disk
        // (for example, on a Mac where Chrome or Edge was never installed).
        if name == "com.apple.passwordmanager" {
            let appleAllowed = [
                "pejdijmoenmkgeppbflobdenhhabjlaj", // Chrome Web Store
                "mfbcdcnpokpoajjciilocoachedjkima", // Edge Add-ons
            ]
            guard appleAllowed.contains(extensionID) else {
                throw Refused(why: "Access to the specified native messaging host is forbidden.")
            }
            let candidates = [
                "/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper",
                "/System/Volumes/Preboot/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper",
                "/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper",
            ]
            for candidate in candidates {
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }

        throw Refused(why: "Specified native messaging host not found.")
    }

    /// `runtime.sendNativeMessage`: run, send one, read one, stop.
    static func send(_ message: Any, to name: String, from extensionID: String) async throws -> Any? {
        let program = try host(name, for: extensionID)
        let pipe = HostPipe(program: program, origin: "chrome-extension://\(extensionID)/")
        try pipe.start()
        defer { pipe.stop() }
        try pipe.write(message)
        return try await pipe.readOne()
    }

    /// `runtime.connectNative`: run, and keep the two talking until either
    /// end lets go.
    @MainActor
    static func connect(_ port: WKWebExtension.MessagePort, from extensionID: String) throws {
        guard let name = port.applicationIdentifier else { throw Refused(why: "No host named") }
        let program = try host(name, for: extensionID)
        let pipe = HostPipe(program: program, origin: "chrome-extension://\(extensionID)/")
        try pipe.start()
        pipe.onMessage = { message in
            DispatchQueue.main.async { port.sendMessage(message, completionHandler: nil) }
        }
        pipe.onExit = {
            DispatchQueue.main.async { if !port.isDisconnected { port.disconnect() } }
        }
        port.messageHandler = { message, _ in
            guard let message else { return }
            try? pipe.write(message)
        }
        port.disconnectHandler = { _ in pipe.stop() }
        Live.keep(pipe)
    }

    /// Hosts that are connected, held until they end.
    private enum Live {
        nonisolated(unsafe) static var pipes: [ObjectIdentifier: HostPipe] = [:]
        static func keep(_ pipe: HostPipe) {
            pipes[ObjectIdentifier(pipe)] = pipe
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
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private let lock = NSLock()
    var onMessage: ((Any) -> Void)?
    var onExit: (() -> Void)?
    private var waiters: [CheckedContinuation<Any?, Error>] = []

    init(program: URL, origin: String) {
        process.executableURL = program
        process.arguments = [origin]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.finish()
                return
            }
            self.take(chunk)
        }
        process.terminationHandler = { [weak self] _ in self?.finish() }
        try process.run()
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    func write(_ message: Any) throws {
        let json = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
        guard json.count <= 1 << 20 else { throw ExtensionNative.Refused(why: "Message too long for a native host") }
        var length = UInt32(json.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        try input.fileHandleForWriting.write(contentsOf: frame)
    }

    func readOne() async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            waiters.append(continuation)
            lock.unlock()
        }
    }

    private func take(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var messages: [Any] = []
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: 4..<(4 + length))
            buffer.removeSubrange(0..<(4 + length))
            if let message = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) {
                messages.append(message)
            }
        }
        var handed: [(CheckedContinuation<Any?, Error>, Any)] = []
        for message in messages where !waiters.isEmpty {
            handed.append((waiters.removeFirst(), message))
        }
        let rest = messages.dropFirst(handed.count)
        lock.unlock()
        handed.forEach { $0.0.resume(returning: $0.1) }
        rest.forEach { onMessage?($0) }
    }

    private func finish() {
        lock.lock()
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume(throwing: ExtensionNative.Refused(why: "Native host has exited.")) }
        onExit?()
        onExit = nil
    }
}
