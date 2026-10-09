import CryptoKit
import Foundation

// "On this Mac": the model runs here, in a small program of its own (the
// engine, Engine/search-ai-engine.cpp), and nothing about the page leaves
// the Mac. Neither the engine nor the model is in Search — a browser of a
// few megabytes stays one — they are downloaded when you turn this on: the
// engine as the signed feed offers it (Updater), the model from the one
// address and the one file pinned below.
//
// Nothing downloaded is taken on trust:
//   - the engine's hash is the signed feed's, its signature Office Commun's
//     Developer ID for its own identifier, checked again before every start;
//     and it must be sandboxed with nothing added — no network, no files —
//     or it isn't started at all;
//   - the model's size and SHA-256 are pinned here, and checked on the very
//     file the engine gets: Search opens it, hashes what it opened, and hands
//     that open file over (descriptor 3), so another file can't be put in its
//     place. (Something already able to write to Search's folder could still
//     change the file itself afterwards; what it reaches then is the engine,
//     inside its sandbox.) The engine can read nothing else;
//   - the engine is started suspended, checked again as the process it now
//     is — its signature, identifier and entitlements, as the system loaded
//     them, so a file swapped after the first check is caught — and only
//     then let run, answerable for itself rather than as Search.
// It is started with nothing of Search's: no other descriptor, no
// environment. It is stopped after five idle minutes, giving its memory back.

@MainActor
final class AIEngine: ObservableObject {
    static let shared = AIEngine()

    /// The model: Qwen3 1.7B, as the bake-off chose it (27 Sep 2026).
    struct Pin {
        let name: String
        let url: URL
        let sha256: String
        let size: Int64
    }
    static let model = Pin(
        name: "Qwen3 1.7B",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/d7f544eead698dbd1f15126ef60b45a1e1933222/Qwen3-1.7B-Q4_K_M.gguf")!,
        sha256: "b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897",
        size: 1_107_409_472
    )

    /// The engine the signed feed offers for this Mac, when it does.
    struct Offer: Equatable {
        let version: Int
        let url: URL
        let sha256: String
        let size: Int64
    }
    @Published var offered: Offer?

    nonisolated static let identifier = "com.officecommun.search.ai-engine"

    enum State: Equatable {
        case absent
        case downloading(Double)
        case preparing
        case ready
        case failed(String)
    }
    @Published private(set) var state: State = .absent

    // MARK: - where

    private static var folder: URL { Store.folder.appendingPathComponent("AI", isDirectory: true) }
    private static var models: URL {
        if Store.testing, let shared = testModels { return shared }
        return folder.appendingPathComponent("Models", isDirectory: true)
    }
    private static var modelFile: URL { models.appendingPathComponent("\(model.sha256).gguf") }
    private static var engines: URL { folder.appendingPathComponent("Engine", isDirectory: true) }

    /// A test run's stand-ins: an engine built by engine.sh (signed ad-hoc)
    /// and a folder of models shared between test worlds (bench ai engine).
    nonisolated(unsafe) static var testEngine: URL?
    nonisolated(unsafe) static var testModels: URL?

    /// The newest engine kept here.
    private var engineFile: URL? {
        if Store.testing, let test = AIEngine.testEngine { return test }
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: AIEngine.engines.path)) ?? []
        guard let newest = versions.compactMap(Int.init).max() else { return nil }
        let file = AIEngine.engines.appendingPathComponent("\(newest)/search-ai-engine")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
    private var installedVersion: Int? { engineFile.flatMap { Int($0.deletingLastPathComponent().lastPathComponent) } }

    /// Whether this Mac can run it: Apple Silicon, and Search running as
    /// itself rather than translated (an Intel copy on Apple Silicon is told
    /// to get the Apple Silicon one).
    static var supported: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    static var translated: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 && value == 1
    }

    /// Worth offering in Settings: supported, and there is something to run.
    var available: Bool {
        AIEngine.supported && (offered != nil || engineFile != nil || (Store.testing && AIEngine.testEngine != nil))
    }

    private init() {
        refreshState()
    }

    func refreshState() {
        if case .downloading = state { return }
        if state == .preparing { return }
        let hasModel = FileManager.default.fileExists(atPath: AIEngine.modelFile.path)
        state = engineFile != nil && hasModel && !(offered.map { $0.version > (installedVersion ?? 0) } ?? false) ? .ready : .absent
    }

    // MARK: - installing

    private var installing: Task<Void, Never>?

    /// What turning it on downloads, for the button.
    var downloadSize: Int64 {
        let modelNeeded = FileManager.default.fileExists(atPath: AIEngine.modelFile.path) ? 0 : AIEngine.model.size
        let engineNeeded = (offered.map { $0.version > (installedVersion ?? 0) } ?? false) ? (offered?.size ?? 0) : 0
        return modelNeeded + engineNeeded
    }

    func install() {
        guard AI.shipped || Store.testing, installing == nil else { return }
        installing = Task { @MainActor in
            defer { installing = nil }
            do {
                try FileManager.default.createDirectory(at: AIEngine.models, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: AIEngine.engines, withIntermediateDirectories: true)
                if let offer = offered, offer.version > (installedVersion ?? 0) {
                    state = .downloading(0)
                    let file = try await AIDownload.fetch(offer.url, size: offer.size, sha256: offer.sha256) { [weak self] done in
                        self?.state = .downloading(done * Double(offer.size) / Double(max(1, self?.downloadSize ?? 1)))
                    }
                    let place = AIEngine.engines.appendingPathComponent("\(offer.version)", isDirectory: true)
                    try? FileManager.default.removeItem(at: place)
                    try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
                    let engine = place.appendingPathComponent("search-ai-engine")
                    try FileManager.default.moveItem(at: file, to: engine)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
                    guard AIEngine.trusted(engine) else {
                        try? FileManager.default.removeItem(at: place)
                        throw AIDownload.Failure("The engine's signature doesn't hold up.")
                    }
                    // Older ones go.
                    for old in (try? FileManager.default.contentsOfDirectory(atPath: AIEngine.engines.path)) ?? []
                    where Int(old).map({ $0 < offer.version }) ?? true {
                        try? FileManager.default.removeItem(at: AIEngine.engines.appendingPathComponent(old))
                    }
                }
                if !FileManager.default.fileExists(atPath: AIEngine.modelFile.path) {
                    let pin = AIEngine.model
                    let start = Double(downloadSize - pin.size) / Double(max(1, downloadSize))
                    state = .downloading(start)
                    let file = try await AIDownload.fetch(pin.url, size: pin.size, sha256: pin.sha256) { [weak self] done in
                        self?.state = .downloading(start + done * (1 - start))
                    }
                    try FileManager.default.moveItem(at: file, to: AIEngine.modelFile)
                    var place = AIEngine.modelFile
                    var values = URLResourceValues()
                    values.isExcludedFromBackup = true
                    try? place.setResourceValues(values)
                }
                // The first start compiles the engine's graphics code for this
                // Mac, which takes a while once: done now, not on the first page.
                state = .preparing
                try await start()
                state = .ready
            } catch is CancellationError {
                state = .absent
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancelInstall() {
        installing?.cancel()
    }

    func remove() {
        stop()
        installing?.cancel()
        try? FileManager.default.removeItem(at: AIEngine.folder.appendingPathComponent("Models"))
        try? FileManager.default.removeItem(at: AIEngine.engines)
        try? FileManager.default.removeItem(at: AIEngine.folder.appendingPathComponent("Downloads"))
        state = .absent
    }

    // MARK: - checking

    /// The engine is Office Commun's, for its own identifier, signed the way
    /// a release is — or, in a test run, at least its identifier — and it is
    /// sandboxed with nothing added: no network, no file access, no way out.
    nonisolated static func trusted(_ file: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(file as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let requirement: SecRequirement?
        if Store.testing {
            var made: SecRequirement?
            SecRequirementCreateWithString("identifier \"\(identifier)\"" as CFString, [], &made)
            requirement = made
        } else {
            requirement = Updater.developerID(team: Updater.team, identifier: identifier)
        }
        guard let requirement else { return false }
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(code, strict, requirement) == errSecSuccess else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSRequirementInformation | kSecCSSigningInformation), &info) == errSecSuccess,
              let signing = info as? [String: Any],
              let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              entitlements["com.apple.security.app-sandbox"] as? Bool == true
        else { return false }
        // The sandbox and nothing else.
        return entitlements.keys.allSatisfy { $0 == "com.apple.security.app-sandbox" }
    }

    /// The model, opened, and checked on what was opened: its size and its
    /// SHA-256. The open file is what the engine gets; nil if it isn't the
    /// pinned one.
    nonisolated static func openModel(_ file: URL) -> Int32? {
        let fd = open(file.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, Int64(info.st_size) == model.size, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            return nil
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var offset: off_t = 0
        while true {
            let count = pread(fd, &buffer, buffer.count, offset)
            if count < 0 { close(fd); return nil }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
            offset += off_t(count)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hex == model.sha256 else {
            close(fd)
            return nil
        }
        return fd
    }

    // MARK: - running

    private var pid: pid_t = 0
    private var input: FileHandle?
    private var output: FileHandle?
    private var carry = Data()
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var ready = false
    private var answering: [Int: AsyncThrowingStream<String, Error>.Continuation] = [:]
    private var nextID = 1
    private var idle: Timer?

    struct Stopped: LocalizedError {
        let why: String
        var errorDescription: String? { why }
    }

    /// One start at a time: a second question while the model is being
    /// checked waits for the same start.
    private var starting: Task<Void, Error>?
    /// Which run of the engine is the current one: a run that has ended can
    /// still have words on their way, and they are for nobody.
    private var generation = 0

    /// The engine, running and loaded. Started if it isn't.
    private func start() async throws {
        guard AI.shipped || Store.testing else { throw CancellationError() }
        if ready, pid != 0 { return }
        if let starting { return try await starting.value }
        let task = Task { @MainActor in try await self.launch() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func launch() async throws {
        if pid == 0 {
            guard let engine = engineFile else { throw Stopped(why: "The engine isn't installed.") }
            let modelURL = AIEngine.modelFile
            // Checked off the main thread: the model is a gigabyte.
            let checked: (Bool, Int32?) = await Task.detached(priority: .userInitiated) {
                (AIEngine.trusted(engine), AIEngine.openModel(modelURL))
            }.value
            guard checked.0 else {
                if let fd = checked.1 { close(fd) }
                throw Stopped(why: "The engine's signature doesn't hold up. Remove it in Settings › AI and download it again.")
            }
            guard let modelFD = checked.1 else {
                throw Stopped(why: "The model isn't the one Search expects. Remove it in Settings › AI and download it again.")
            }
            defer { close(modelFD) }
            try spawn(engine, modelFD: modelFD)
        }
        // Two minutes to get ready: the first start compiles for this Mac.
        let run = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, self.generation == run, self.pid != 0, !self.ready else { return }
            self.ended("The engine didn't start.")
        }
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            if ready { waiter.resume() } else { readyWaiters.append(waiter) }
        }
    }

    private func spawn(_ engine: URL, modelFD: Int32) throws {
        let toEngine = Pipe(), fromEngine = Pipe()
        let null = open("/dev/null", O_WRONLY)
        defer { if null >= 0 { close(null) } }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, toEngine.fileHandleForReading.fileDescriptor, 0)
        posix_spawn_file_actions_adddup2(&actions, fromEngine.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, null, 2)
        posix_spawn_file_actions_adddup2(&actions, modelFD, 3)
        // Only those four: nothing else Search has open goes with it. Held
        // before its first instruction, to be checked as it is loaded; and
        // answerable for itself, not as Search, with anything macOS asks.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_START_SUSPENDED))
        if let disclaim = AIEngine.disclaim { _ = disclaim(&attributes, 1) }
        let arguments = [engine.path, "--context", "8192"]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var child: pid_t = 0
        let status = posix_spawn(&child, engine.path, &actions, &attributes, &argv, &environment)
        toEngine.fileHandleForReading.closeFile()
        fromEngine.fileHandleForWriting.closeFile()
        guard status == 0 else { throw Stopped(why: "The engine couldn't be started.") }
        // The process as the system loaded it, before it runs a thing.
        guard AIEngine.trustedRunning(child) else {
            kill(child, SIGKILL)
            var reaped: Int32 = 0
            waitpid(child, &reaped, 0)
            throw Stopped(why: "The engine's signature doesn't hold up. Remove it in Settings › AI and download it again.")
        }
        kill(child, SIGCONT)
        pid = child
        generation += 1
        let run = generation
        // A write to an engine that has just died fails, rather than taking
        // Search down with it.
        _ = fcntl(toEngine.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        input = toEngine.fileHandleForWriting
        output = fromEngine.fileHandleForReading
        carry = Data()
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.heard(data, run: run) }
        }
    }

    /// responsibility_spawnattrs_setdisclaim, where the system has it.
    nonisolated(unsafe) private static let disclaim: (@convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32).self)
    }()

    /// The started engine, checked as a running process: the same
    /// requirement and entitlements as the file (see `trusted`).
    nonisolated static func trustedRunning(_ pid: pid_t) -> Bool {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code
        else { return false }
        var requirement: SecRequirement?
        if Store.testing {
            SecRequirementCreateWithString("identifier \"\(identifier)\"" as CFString, [], &requirement)
        } else {
            requirement = Updater.developerID(team: Updater.team, identifier: identifier)
        }
        guard let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSRequirementInformation | kSecCSSigningInformation), &info) == errSecSuccess,
              let signing = info as? [String: Any],
              let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              entitlements["com.apple.security.app-sandbox"] as? Bool == true
        else { return false }
        return entitlements.keys.allSatisfy { $0 == "com.apple.security.app-sandbox" }
    }

    private func heard(_ data: Data, run: Int) {
        guard run == generation else { return }
        guard !data.isEmpty else { return ended("The engine stopped.") }
        carry.append(data)
        while let end = carry.firstIndex(of: 0x0A) {
            let line = carry[carry.startIndex..<end]
            carry = Data(carry[carry.index(after: end)...])
            guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if message["ready"] as? Bool == true {
                ready = true
                readyWaiters.forEach { $0.resume() }
                readyWaiters = []
            } else if let id = message["id"] as? Int, let answer = answering[id] {
                if let piece = message["piece"] as? String {
                    answer.yield(piece)
                } else if let error = message["error"] as? String {
                    answering[id] = nil
                    answer.finish(throwing: Stopped(why: error))
                } else if message["done"] as? Bool == true {
                    answering[id] = nil
                    answer.finish()
                }
            } else if let error = message["error"] as? String {
                ended(error)
            }
        }
    }

    private func ended(_ why: String) {
        output?.readabilityHandler = nil
        if pid != 0 {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        pid = 0
        ready = false
        generation += 1
        input = nil
        output = nil
        readyWaiters.forEach { $0.resume(throwing: Stopped(why: why)) }
        readyWaiters = []
        answering.values.forEach { $0.finish(throwing: Stopped(why: why)) }
        answering = [:]
    }

    func stop() {
        idle?.invalidate()
        guard pid != 0 else { return }
        ended("Stopped.")
    }

    /// An answer from the model here, a piece at a time.
    func stream(system: String, messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let id = nextID
            nextID += 1
            let task = Task { @MainActor [weak self] in
                guard let self else { return continuation.finish() }
                do {
                    try await self.start()
                    self.answering[id] = continuation
                    let request: [String: Any] = [
                        "id": id, "system": system, "max_tokens": 768, "temperature": 0.2,
                        "messages": messages.map { ["role": $0.role.rawValue, "content": $0.text] },
                    ]
                    var line = try JSONSerialization.data(withJSONObject: request)
                    line.append(0x0A)
                    try self.input?.write(contentsOf: line)
                    self.rest()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                Task { @MainActor in
                    guard let self, self.answering.removeValue(forKey: id) != nil else { return }
                    try? self.input?.write(contentsOf: Data("{\"stop\":\(id)}\n".utf8))
                }
            }
        }
    }

    /// Five minutes after the last question, the engine goes.
    private func rest() {
        idle?.invalidate()
        idle = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard AIEngine.shared.answering.isEmpty else { return AIEngine.shared.rest() }
                AIEngine.shared.stop()
            }
        }
    }

    /// For the bench: whether the engine is running, and ready.
    var running: (pid: Int32, ready: Bool) { (pid, ready) }
}

/// A download of something pinned: its size and SHA-256 known beforehand,
/// checked as it arrives; kept only when both match.
enum AIDownload {
    struct Failure: LocalizedError {
        let why: String
        init(_ why: String) { self.why = why }
        var errorDescription: String? { why }
    }

    @MainActor
    static func fetch(_ url: URL, size: Int64, sha256: String, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        guard url.scheme?.lowercased() == "https" else { throw Failure("Not a secure address.") }
        let folder = Store.folder.appendingPathComponent("AI/Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < size + size / 10 {
            throw Failure("There isn't enough free space on this Mac (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) needed).")
        }
        let watcher = Watcher(progress: progress, size: size)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3 * 3600
        let session = URLSession(configuration: configuration, delegate: watcher, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(from: url, delegate: watcher)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure("The download was refused.")
        }
        let file = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: temporary, to: file)
        let matches = await Task.detached(priority: .utility) { () -> Bool in
            guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
            defer { try? handle.close() }
            var hasher = SHA256()
            var total: Int64 = 0
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
                total += Int64(chunk.count)
            }
            return total == size && hasher.finalize().map { String(format: "%02x", $0) }.joined() == sha256
        }.value
        guard matches else {
            try? FileManager.default.removeItem(at: file)
            throw Failure("What arrived isn't what was expected, so it was deleted.")
        }
        return file
    }

    /// Progress, and only secure addresses followed — a model is fetched
    /// through its host's CDN. What arrives is judged by its hash, not by
    /// where it came from; nothing of yours is sent along.
    private final class Watcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @MainActor (Double) -> Void
        let size: Int64
        init(progress: @escaping @MainActor (Double) -> Void, size: Int64) {
            self.progress = progress
            self.size = size
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let done = Double(totalBytesWritten) / Double(max(1, size))
            let report = progress
            Task { @MainActor in report(min(1, done)) }
            if totalBytesWritten > size + 1024 { downloadTask.cancel() }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
        }
    }
}
