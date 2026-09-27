import AppKit
import SwiftUI
import WebKit

/// A download visible in the Downloads panel. Resume data and the originating
/// web view live only for this process; neither is part of the saved history.
@MainActor
final class FetchEntry: ObservableObject, Identifiable {
    enum State: Equatable {
        case downloading
        case pausing
        case paused
        case resuming
        case failed
    }

    enum StopAction: Equatable {
        case pause
        case cancel
    }

    let id = UUID()
    @Published private(set) var state: State = .downloading
    @Published private(set) var name: String
    @Published private(set) var fraction: Double?
    @Published private(set) var completedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var errorDescription: String?

    private struct PartialFileVersion: Equatable {
        let volume: UInt64
        let inode: UInt64
        let size: UInt64
        let modified: Date
    }

    var canResume: Bool {
        (state == .paused || state == .failed) && resumeData != nil && webView != nil
    }
    var canRetry: Bool { state == .failed && request != nil && webView != nil }

    // These are deliberately in-memory only. The web view carries the
    // originating website's cookie store for resume and fresh retry.
    var resumeData: Data?
    var request: URLRequest?
    var webView: WKWebView?
    var destination: URL?
    var retryName: String
    var download: WKDownload?
    var pendingStop: StopAction?
    var operationID = UUID()
    private var destinationWasAbsent: Bool?
    private var partialFileVersion: PartialFileVersion?

    init(name: String, request: URLRequest?, webView: WKWebView?) {
        self.name = name
        self.retryName = name
        self.request = request
        self.webView = webView
    }

    func began(_ download: WKDownload, operationID: UUID? = nil) {
        if let operationID, self.operationID != operationID { return }
        self.download = download
        pendingStop = nil
        resumeData = nil
        errorDescription = nil
        state = .downloading
        self.operationID = UUID()
    }

    func record(_ progress: Progress, trackFile: Bool = true) {
        completedBytes = max(0, progress.completedUnitCount)
        totalBytes = max(0, progress.totalUnitCount)
        fraction = totalBytes > 0
            ? min(1, max(0, Double(completedBytes) / Double(totalBytes)))
            : nil
        if trackFile { trackPartialFile() }
    }

    /// At a terminal callback progress can be ahead of the last queued KVO
    /// measurement. Refresh size and date only for a file identity already
    /// claimed during active progress; never claim an unknown path here.
    func recordTerminal(_ progress: Progress) {
        record(progress, trackFile: false)
        guard destinationWasAbsent == true, let destination,
              let expected = partialFileVersion,
              let current = Self.partialFileVersion(at: destination),
              current.volume == expected.volume, current.inode == expected.inode else { return }
        partialFileVersion = current
    }

    func reached(_ file: URL, rememberForRetry: Bool) {
        if destination != file {
            destinationWasAbsent = !FileManager.default.fileExists(atPath: file.path)
            partialFileVersion = nil
        } else if destinationWasAbsent == nil {
            destinationWasAbsent = !FileManager.default.fileExists(atPath: file.path)
        }
        destination = file
        name = file.lastPathComponent
        if rememberForRetry { retryName = file.lastPathComponent }
    }

    /// The output URL is initially required to be absent. Claim it only after
    /// WebKit reports real byte progress, then keep the latest file identity
    /// observed during that transfer. Discard paths only while that identity,
    /// size and modification time still match.
    func discardOwnedPartialFile() {
        guard destinationWasAbsent == true, let destination,
              let expected = partialFileVersion,
              Self.partialFileVersion(at: destination) == expected else { return }
        try? FileManager.default.removeItem(at: destination)
    }

    func stopped(_ action: StopAction, data: Data?) {
        download = nil
        pendingStop = nil
        resumeData = action == .pause ? data : nil
        if action == .cancel {
            clear()
            return
        }
        if data != nil {
            errorDescription = nil
            state = .paused
        } else {
            // WKDownload explicitly returns nil when its server cannot
            // produce resume data. Keep Retry available and explain why.
            errorDescription = "This download could not be paused by the server. You can retry it from the start."
            state = .failed
        }
    }

    func failed(_ error: Error, resumeData: Data?) {
        download = nil
        pendingStop = nil
        self.resumeData = resumeData
        errorDescription = Self.reason(for: error)
        state = .failed
    }

    func preparingToStop(_ action: StopAction) -> UUID {
        state = .pausing
        pendingStop = action
        operationID = UUID()
        return operationID
    }

    func preparingToStart(destination: URL? = nil) -> UUID {
        state = .resuming
        errorDescription = nil
        if let destination, self.destination != destination {
            self.destination = destination
            destinationWasAbsent = nil
            partialFileVersion = nil
        }
        operationID = UUID()
        return operationID
    }

    func resetProgress() {
        fraction = 0
        completedBytes = 0
        totalBytes = 0
    }

    func clear() {
        resumeData = nil
        request = nil
        webView = nil
        destination = nil
        destinationWasAbsent = nil
        partialFileVersion = nil
        download = nil
        pendingStop = nil
        operationID = UUID()
        errorDescription = nil
        fraction = nil
        completedBytes = 0
        totalBytes = 0
    }

    private static func reason(for error: Error) -> String {
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "The download failed for an unknown reason." : text
    }

    private func trackPartialFile() {
        guard completedBytes > 0, destinationWasAbsent == true, let destination,
              let current = Self.partialFileVersion(at: destination) else { return }
        if let previous = partialFileVersion,
           (previous.volume != current.volume || previous.inode != current.inode) {
            return
        }
        partialFileVersion = current
    }

    private static func partialFileVersion(at url: URL) -> PartialFileVersion? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let volume = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return PartialFileVersion(volume: volume, inode: inode, size: size, modified: modified)
    }
}

// Downloads, seen while they happen. Successful files are recorded by Loot;
// these entries only describe active and recoverable downloads.
@MainActor
final class Fetches: ObservableObject {
    @Published private(set) var entries: [FetchEntry] = []

    /// A running download, or one just done: the circle is up.
    @Published private(set) var showing = false
    /// How far the running ones are, together; nil while none says its size.
    @Published private(set) var fraction: Double?
    /// Everything finished, and the circle says so for a moment before it goes.
    @Published private(set) var done = false

    /// How long the circle stays once the last download is in.
    static let linger: TimeInterval = 5

    struct StopOperation {
        let download: WKDownload
        let entry: FetchEntry?
        let operationID: UUID
    }

    struct StartOperation {
        let entry: FetchEntry
        let webView: WKWebView
        let request: URLRequest?
        let resumeData: Data?
        let operationID: UUID
    }

    struct Ended {
        let owner: Browser
        let announceFailure: Bool
    }

    private final class Running {
        let download: WKDownload
        let entry: FetchEntry?
        // WKDownload.delegate is weak. Keep its Browser alive while it needs
        // to receive callbacks, then release it as soon as the attempt stops.
        let owner: Browser
        let webView: WKWebView?
        var watch: NSKeyValueObservation?
        var shown: Progress?
        var stopAction: FetchEntry.StopAction?
        var operationID = UUID()

        init(_ download: WKDownload, entry: FetchEntry?, owner: Browser, webView: WKWebView?) {
            self.download = download
            self.entry = entry
            self.owner = owner
            self.webView = webView
        }
    }

    private var running: [ObjectIdentifier: Running] = [:]
    private var leaving: DispatchWorkItem?

    /// A download has begun. Private downloads are tracked for cleanup and
    /// aggregate progress, but never become entries in the shared panel.
    @discardableResult
    func start(
        _ download: WKDownload,
        owner: Browser,
        webView: WKWebView?,
        listed: Bool,
        entry continuing: FetchEntry? = nil,
        operationID: UUID? = nil
    ) -> Bool {
        if let continuing, let operationID, continuing.operationID != operationID { return false }

        let entry: FetchEntry?
        if let continuing {
            continuing.request = continuing.request ?? download.originalRequest.map { $0 as URLRequest }
            continuing.webView = continuing.webView ?? webView
            continuing.began(download, operationID: operationID)
            entry = continuing
        } else {
            let request = download.originalRequest.map { $0 as URLRequest }
            let suggested = request?.url?.lastPathComponent
            let name = suggested.flatMap { $0.isEmpty ? nil : $0 } ?? "download"
            let made = FetchEntry(name: name, request: request, webView: webView)
            made.download = download
            if listed { entries.append(made) }
            entry = made
        }

        let item = Running(download, entry: entry, owner: owner, webView: webView)
        running[ObjectIdentifier(download)] = item
        leaving?.cancel()
        leaving = nil
        done = false
        showing = true
        item.watch = download.progress.observe(\.fractionCompleted) { [weak self] _, _ in
            DispatchQueue.main.async { self?.measure() }
        }
        measure()
        return true
    }

    /// Destination chosen by the browser, or remembered for a resumed attempt.
    func destination(for download: WKDownload) -> URL? {
        running[ObjectIdentifier(download)]?.entry?.destination
    }

    /// Where the file is going, known: its progress is put on it, for the
    /// Finder's bar under the file and the Dock's Downloads stack.
    func going(_ download: WKDownload, to file: URL, cancel: @escaping @Sendable () -> Void) {
        guard let item = running[ObjectIdentifier(download)] else { return }
        if let shown = item.shown, shown.fileURL == file {
            shown.completedUnitCount = download.progress.completedUnitCount
            item.entry?.record(download.progress)
            return
        }
        let rememberForRetry = item.entry?.destination == nil
        item.entry?.reached(file, rememberForRetry: rememberForRetry)
        let shown = Progress(totalUnitCount: max(1, download.progress.totalUnitCount))
        shown.kind = .file
        shown.fileOperationKind = .downloading
        shown.fileURL = file
        shown.isCancellable = true
        // Finder cancellation can complete without a WKDownload delegate
        // failure callback, so its handler owns the same cleanup path.
        shown.cancellationHandler = cancel
        shown.completedUnitCount = download.progress.completedUnitCount
        shown.publish()
        item.shown = shown
        item.entry?.record(download.progress)
    }

    func entry(for download: WKDownload) -> FetchEntry? {
        running[ObjectIdentifier(download)]?.entry
    }

    func beginStop(_ entry: FetchEntry, action: FetchEntry.StopAction) -> StopOperation? {
        guard entry.state == .downloading, let download = entry.download,
              let item = running[ObjectIdentifier(download)], item.entry === entry else { return nil }
        let token = entry.preparingToStop(action)
        item.stopAction = action
        item.operationID = token
        return StopOperation(download: download, entry: entry, operationID: token)
    }

    /// The Finder can cancel a private download too, so this overload works
    /// from the active WebKit download rather than requiring a visible row.
    func beginFinderStop(_ download: WKDownload) -> StopOperation? {
        guard let item = running[ObjectIdentifier(download)] else { return nil }
        if let entry = item.entry {
            if entry.state == .pausing {
                _ = upgradeStopToCancel(entry)
                return nil
            }
            return beginStop(entry, action: .cancel)
        }
        let token = UUID()
        item.stopAction = .cancel
        item.operationID = token
        return StopOperation(download: download, entry: nil, operationID: token)
    }

    /// Finish a pause or cancellation even when WebKit sends no delegate
    /// callback. The operation token rejects a late completion from an older
    /// attempt after the user has already resumed or retried it.
    func stopped(_ operation: StopOperation, resumeData: Data?) -> Ended? {
        let key = ObjectIdentifier(operation.download)
        guard let item = running[key], item.operationID == operation.operationID,
              let action = item.stopAction else { return nil }
        if let entry = operation.entry {
            guard entry.operationID == operation.operationID,
                  entry.pendingStop == action else { return nil }
            entry.recordTerminal(operation.download.progress)
            if action == .cancel { entry.discardOwnedPartialFile() }
            entry.stopped(action, data: resumeData)
            if action == .cancel { remove(entry) }
        }
        let ended = take(operation.download)
        settle(succeeded: false)
        return Ended(owner: ended.owner, announceFailure: false)
    }

    func beginResume(_ entry: FetchEntry) -> StartOperation? {
        guard entry.canResume, let webView = entry.webView,
              let data = entry.resumeData else { return nil }
        let token = entry.preparingToStart()
        return StartOperation(entry: entry, webView: webView, request: entry.request, resumeData: data, operationID: token)
    }

    func beginRetry(_ entry: FetchEntry, destination: URL) -> StartOperation? {
        guard entry.canRetry, let webView = entry.webView, let request = entry.request else { return nil }
        entry.discardOwnedPartialFile()
        let token = entry.preparingToStart(destination: destination)
        entry.resumeData = nil
        entry.resetProgress()
        return StartOperation(entry: entry, webView: webView, request: request, resumeData: nil, operationID: token)
    }

    /// A new WKDownload returned from either WebKit resume API joins the same
    /// row. An obsolete callback is canceled before it can replace newer work.
    func accepts(_ operation: StartOperation) -> Bool {
        operation.entry.state == .resuming && operation.entry.operationID == operation.operationID
    }

    /// Cancel can race the small interval after WebKit accepted resume/retry
    /// but before it returned the new WKDownload. Invalidating this token
    /// makes that callback cancel its download instead of reviving this row.
    func removeStarting(_ entry: FetchEntry) {
        guard entry.state == .resuming else { return }
        entry.discardOwnedPartialFile()
        remove(entry)
    }

    /// Turn an in-flight pause into a discard while keeping the original
    /// cancel completion token, which is the reliable cleanup callback.
    func upgradeStopToCancel(_ entry: FetchEntry) -> Bool {
        guard entry.state == .pausing, let download = entry.download,
              let item = running[ObjectIdentifier(download)], item.entry === entry else { return false }
        entry.pendingStop = .cancel
        item.stopAction = .cancel
        return true
    }

    /// Arrived. The Dock's Downloads stack is told, as Safari tells it, and
    /// bounces. Successful files move to Loot and no longer remain as entries.
    func finish(_ download: WKDownload, file: URL?) -> Ended? {
        guard let item = running[ObjectIdentifier(download)] else { return nil }
        if let entry = item.entry { remove(entry) }
        let ended = take(download)
        if let file {
            DistributedNotificationCenter.default().post(
                name: Notification.Name("com.apple.DownloadFileFinished"), object: file.path
            )
        }
        settle(succeeded: true)
        return Ended(owner: ended.owner, announceFailure: false)
    }

    /// Failed or canceled. Preserve resume data and the real WebKit error for
    /// visible entries, while intentional pause/cancel callbacks stay quiet.
    func fail(_ download: WKDownload, error: Error, resumeData: Data?) -> Ended? {
        guard let item = running[ObjectIdentifier(download)] else { return nil }
        // The cancel completion provides authoritative resume data. A
        // delegate failure may arrive first with nil, so keep tracking until
        // that completion decides whether this was a pause or a discard.
        if item.stopAction != nil { return nil }
        if let entry = item.entry {
            entry.recordTerminal(download.progress)
            entry.failed(error, resumeData: resumeData)
        }
        let ended = take(download)
        settle(succeeded: false)
        return Ended(owner: ended.owner, announceFailure: true)
    }

    /// Destination selection canceled, so remove the provisional row and all
    /// active bookkeeping without presenting an error.
    func destinationCancelled(_ download: WKDownload) -> Ended? {
        guard let item = running[ObjectIdentifier(download)] else { return nil }
        if let entry = item.entry { remove(entry) }
        let ended = take(download)
        settle(succeeded: false)
        return Ended(owner: ended.owner, announceFailure: false)
    }

    /// Remove a paused or failed row, discarding its in-memory resume state.
    func removeStopped(_ entry: FetchEntry) {
        guard entry.state == .paused || entry.state == .failed else { return }
        entry.discardOwnedPartialFile()
        remove(entry)
    }

    private func remove(_ entry: FetchEntry) {
        entries.removeAll { $0 === entry }
        entry.clear()
    }

    private func take(_ download: WKDownload) -> Running {
        let item = running.removeValue(forKey: ObjectIdentifier(download))!
        item.watch?.invalidate()
        item.shown?.unpublish()
        item.entry?.download = nil
        return item
    }

    /// The last one in: the circle says so, then goes. One that failed with
    /// nothing else running takes the circle away at once. Stopped entries do
    /// not count as activity and cannot leave a spinning ring behind.
    private func settle(succeeded: Bool) {
        guard running.isEmpty else { return measure() }
        guard succeeded else {
            showing = false
            done = false
            fraction = nil
            return
        }
        fraction = 1
        done = true
        let work = DispatchWorkItem { [weak self] in
            guard let self, running.isEmpty else { return }
            showing = false
            done = false
            fraction = nil
        }
        leaving = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Fetches.linger, execute: work)
    }

    /// The running downloads, together, in whole percents; each file's own
    /// progress and row are brought up to date on the way.
    private func measure() {
        var total: Int64 = 0
        var completed: Int64 = 0
        var sized = true
        for item in running.values {
            let progress = item.download.progress
            if progress.totalUnitCount > 0 {
                total += progress.totalUnitCount
                completed += progress.completedUnitCount
            } else {
                sized = false
            }
            if let shown = item.shown {
                if progress.totalUnitCount > 0, shown.totalUnitCount != progress.totalUnitCount {
                    shown.totalUnitCount = progress.totalUnitCount
                }
                shown.completedUnitCount = progress.completedUnitCount
            }
            item.entry?.record(progress)
        }
        guard !running.isEmpty else { return }
        let now: Double? = sized && total > 0 ? (Double(completed) / Double(total) * 100).rounded() / 100 : nil
        if now != fraction { fraction = now }
    }
}

/// The circle in the chrome, beside the other doors: filling while files
/// come, an arrow a moment once they are in. A click opens Downloads.
struct FetchDoor: View {
    @ObservedObject var browser: Browser
    @ObservedObject var fetches: Fetches
    @ObservedObject var prefs: Preferences

    @State private var hovering = false

    init(browser: Browser, fetches: Fetches) {
        self.browser = browser
        self.fetches = fetches
        self.prefs = browser.prefs
    }

    var body: some View {
        // Always there with Settings › Downloads › Always show the downloads
        // button: an arrow at rest, the circle while a file comes in.
        if fetches.showing || !fetches.entries.isEmpty || prefs.alwaysShowsDownloads {
            Button { browser.hoarding = true } label: {
                ZStack {
                    if !fetches.showing {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.muted)
                            .transition(.opacity)
                    } else if fetches.done {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.ink.opacity(0.75))
                            .transition(.opacity)
                    } else if let fraction = fetches.fraction {
                        Circle()
                            .stroke(Palette.muted.opacity(0.3), lineWidth: 1.5)
                        Circle()
                            .trim(from: 0, to: max(0.02, fraction))
                            .stroke(Palette.ink.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.2), value: fraction)
                    } else {
                        // No size given: turning, on Core Animation's time.
                        Ring(size: 12)
                    }
                }
                .frame(width: 12, height: 12)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Palette.hover : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Downloads (⇧⌘J)")
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .animation(Motion.quick, value: fetches.done)
            .animation(Motion.quick, value: fetches.showing)
            .animation(Motion.quick, value: hovering)
        }
    }
}
