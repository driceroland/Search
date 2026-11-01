import SwiftUI
import WebKit
import Combine

// MARK: - keeping files

extension Browser: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let asked = response.url.flatMap { namedDownloads.removeValue(forKey: $0) }
        let chosen = fetches.destination(for: download)
        let name = Browser.fileName(asked ?? suggestedFilename)
        let file = chosen ?? whereToSave(name)
        guard let file else {
            if let ended = fetches.destinationCancelled(download) {
                ended.owner.relinquish(download)
            } else {
                relinquish(download)
            }
            completionHandler(nil)
            return
        }
        fetches.going(download, to: file, cancel: finderCancellation(for: download))
        // A retry is numbered afresh from the name asked for, or the one you
        // gave it: never from "report 2.pdf", whose own " 2" is not its name.
        if chosen == nil { fetches.entry(for: download)?.retryName = prefs.asksWhereToSave ? file.lastPathComponent : name }
        completionHandler(file)
        announce("Downloading \(file.lastPathComponent)")
    }

    func downloadDidFinish(_ download: WKDownload) {
        let entry = fetches.entry(for: download)
        let source = download.originalRequest?.url ?? entry?.request?.url
        let file = download.progress.fileURL ?? entry?.destination
        let listed = !unlisted.contains(ObjectIdentifier(download))
        let ended = fetches.finish(download, file: file)
        (ended?.owner ?? self).relinquish(download)
        guard ended != nil else { return }
        guard let file else {
            announce("Download finished")
            return
        }
        guard listed else {
            announce("Saved \(file.lastPathComponent)")
            return
        }
        if #available(macOS 15.4, *), let asked = source,
           let id = ExtensionShims.askedDownloads.removeValue(forKey: asked) {
            ExtensionShims.ownDownloads[id, default: []].insert(file.path)
        }
        saved(file, from: source)
    }

    /// The download button in the bar WebKit draws over a PDF. WebKit has the
    /// file already and hands it over whole — to a delegate that answers
    /// this name, outside the public framework, and to nobody otherwise: the
    /// button did nothing at all.
    @objc(_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:)
    func webView(
        _ webView: WKWebView,
        saveDataToFile data: Data?,
        suggestedFilename: String?,
        mimeType: String?,
        originatingURL: URL?
    ) {
        guard let data, let file = whereToSave(suggestedFilename ?? "") else { return }
        do {
            // Written by Shy itself, not by WebKit's download, so nothing
            // else marks it as come from the web: the Mac checks a marked
            // file before it first opens, and a PDF is whatever the site
            // made it.
            try data.write(to: file, options: .withoutOverwriting)
            Browser.quarantine(file, from: originatingURL)
            // A private tab's file is yours, but it leaves no line in the
            // list of what was kept, as its other downloads don't.
            let shy = tab(for: webView)?.shy == true || !webView.configuration.websiteDataStore.isPersistent
            if shy {
                announce("Saved \(file.lastPathComponent)", file: file)
            } else {
                saved(file, from: originatingURL)
            }
        } catch {
            announce("Download failed")
        }
    }

    /// A page's own print(): the Print… item in a page's own menu, or ⌘P in
    /// an editor that keeps the key for itself (the page has it first, see
    /// `pageFirst`). WebKit hands it to a delegate that answers this name,
    /// outside the public framework, and to nobody otherwise: the button did
    /// nothing at all, and neither did ⌘P.
    ///
    /// The page waits while the sheet is up, as it does in Safari: WebKit
    /// holds its script until `done`, and draws the pages meanwhile. Only the
    /// tab in front of the window you are in may ask, one sheet at a time: a
    /// tab behind, or another window's, is answered with nothing, as Safari
    /// does. And a site that asks again each time the sheet is cancelled
    /// asks no more after the second cancel within ten seconds, until the
    /// tab goes to another site (see PrintSheet).
    @objc(_webView:printFrame:pdfFirstPageSize:completionHandler:)
    func webView(
        _ webView: WKWebView,
        printFrame frame: NSObject,
        pdfFirstPageSize: CGSize,
        completionHandler done: @escaping () -> Void
    ) {
        guard let window = webView.window, window.isKeyWindow, window.attachedSheet == nil,
              let tab = anyTab(for: webView), tab.id == activeID, !tab.isBlank,
              PrintSheet.allows(tab)
        else { done(); return }
        let sheet = PrintSheet(tab) { done() }
        Browser.printing(webView, frame: frame).runModal(
            for: window, delegate: sheet,
            didRun: #selector(PrintSheet.printOperationDidRun(_:success:contextInfo:)),
            contextInfo: Unmanaged.passRetained(sheet).toOpaque()
        )
    }

    /// Where a file goes: the downloads folder, or wherever you say when
    /// Settings says to ask. Nil when the question was cancelled. The name
    /// comes from the page, so only its last part is taken: never a path
    /// out of the folder.
    private func whereToSave(_ name: String) -> URL? {
        let name = Browser.fileName(name)
        guard prefs.asksWhereToSave else { return Browser.free(name, in: downloadsFolder) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = downloadsFolder
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// A name a site or an extension suggested, made safe to save under: its
    /// last part only, nothing that turns the writing around or can't be
    /// seen (U+202E makes "invoice‮fdp.app" read as a PDF), and never a
    /// hidden file.
    static func fileName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        var plain = String(String.UnicodeScalarView(last.unicodeScalars.filter { scalar in
            !(scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format)
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        while plain.hasPrefix(".") { plain.removeFirst() }
        return ["", "/"].contains(plain) ? "download" : plain
    }

    /// What WebKit's own downloads are given: the mark of a file from the
    /// web, which has the Mac check it before it first opens.
    static func quarantine(_ file: URL, from source: URL?) {
        var properties: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: "Shy",
        ]
        if let source, ["http", "https"].contains(source.scheme?.lowercased() ?? "") {
            properties[kLSQuarantineDataURLKey as String] = source
        }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var marked = file
        try? marked.setResourceValues(values)
    }

    func saved(_ file: URL, from source: URL?) {
        loot.add(Keep(name: file.lastPathComponent, from: source?.host() ?? "", path: file.path, date: Date()))
        announce("Saved \(file.lastPathComponent)", file: file)
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        guard let ended = fetches.fail(download, error: error, resumeData: resumeData) else { return }
        ended.owner.relinquish(download)
        if ended.announceFailure { announce("Download failed") }
    }

    /// WebKit refuses to write over a file that is already there, so the name
    /// gains a number rather than the download quietly failing.
    static func free(_ name: String, in folder: URL) -> URL {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = folder.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }
}

/// What a page's print() is waiting on: told when the sheet has gone,
/// printed or cancelled, so WebKit can let the page's script go on. The
/// sheet's context keeps it alive until then.
@MainActor
final class PrintSheet: NSObject {
    private let done: () -> Void
    private let tab: Tab.ID
    private let site: String?

    init(_ tab: Tab, _ done: @escaping () -> Void) {
        self.tab = tab.id
        self.site = PrintSheet.site(of: tab)
        self.done = done
    }

    /// The sheets a page's print() had cancelled, by tab, on the site it
    /// was on: its origin, not its address, which the page itself can
    /// change with history.pushState between two print()s. Two cancels
    /// within ten seconds and the site asks no more, until the tab goes to
    /// another site or closes.
    private struct Cancels {
        var site: String?
        var when: [Date] = []
        var blocked = false
    }
    private static var cancelled: [Tab.ID: Cancels] = [:]

    private static func site(of tab: Tab) -> String? {
        guard let page = tab.committed else { return nil }
        return "\(page.scheme ?? "")://\(page.host() ?? ""):\(page.port.map(String.init) ?? "")"
    }

    /// Whether this tab's site may bring the sheet up again.
    static func allows(_ tab: Tab) -> Bool {
        guard let seen = cancelled[tab.id], seen.site == site(of: tab) else {
            cancelled[tab.id] = nil
            return true
        }
        return !seen.blocked
    }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if let contextInfo { Unmanaged<PrintSheet>.fromOpaque(contextInfo).release() }
        if !success {
            var seen = PrintSheet.cancelled[tab].flatMap { $0.site == site ? $0 : nil } ?? Cancels(site: site)
            let now = Date()
            seen.when = seen.when.filter { now.timeIntervalSince($0) < 10 } + [now]
            if seen.when.count >= 2 { seen.blocked = true }
            PrintSheet.cancelled[tab] = seen
        }
        done()
    }
}
