import Combine
import Foundation
import SwiftUI

/// The Issues tool's collection, one per DevTools session and alive as
/// long as it is (the toolbar's counter asks for it): the Console's
/// messages as they arrive, the Set-Cookie headers the frontend hears
/// (DeveloperIssues-frontend.js), the Network panel's requests, and a scan
/// of the page's forms (DeveloperIssues-collect.js) after each load and
/// each change to its fields. DeveloperIssueRules turns them into issues.
///
/// As in Chrome, issues outlive Clear console, and go when the page
/// navigates unless the Console's Preserve log is on.
///
/// Polling is kept light, since every script run in the page is a new
/// script for the debugger (and the Sources panel): the frontend listener
/// is installed once and afterwards only drained; the page's forms are
/// scanned when a document is new, when its fields change (read off the
/// scan's state object, no script) and when the Issues view opens; the
/// contrast scan runs only while the view is shown. With only the counter
/// shown, the poll slows to every five seconds.
@MainActor
final class DeveloperIssuesModel: ObservableObject {
    /// The pane's rows, third-party cookie issues left out unless included.
    @Published private(set) var groups: [DeveloperIssueGroup] = []
    /// Third-party cookie issues not shown.
    @Published private(set) var hidden = 0
    @Published private(set) var problem: String?
    @Published var expanded = Set<String>()
    /// Elements' issue underlines: each node's issues, by its id in the tree.
    @Published private(set) var marks: [Int: [DeveloperIssueMark]] = [:]
    /// A row an Elements underline opened, for the Issues view to scroll to.
    @Published var revealed: String?
    @Published var options = DeveloperIssueOptions(
        includeThirdPartyCookies: DevDefaults.store.bool(forKey: DeveloperIssuesModel.thirdPartyKey),
        groupByCategory: DevDefaults.store.bool(forKey: DeveloperIssuesModel.byCategoryKey),
        groupByKind: DevDefaults.store.object(forKey: DeveloperIssuesModel.byKindKey) as? Bool ?? true
    ) {
        didSet {
            DevDefaults.store.set(options.includeThirdPartyCookies, forKey: Self.thirdPartyKey)
            DevDefaults.store.set(options.groupByCategory, forKey: Self.byCategoryKey)
            DevDefaults.store.set(options.groupByKind, forKey: Self.byKindKey)
            if options.includeThirdPartyCookies != oldValue.includeThirdPartyCookies { recompute() }
        }
    }
    /// Chrome keeps low text contrast issues behind a setting; so does this.
    @Published var showLowContrast = DevDefaults.store.bool(forKey: DeveloperIssuesModel.contrastKey) {
        didSet {
            DevDefaults.store.set(showLowContrast, forKey: Self.contrastKey)
            if showLowContrast { contrastDue = true } else { contrastIssues = []; release(&contrastHolder) }
            recompute()
        }
    }

    var counts: [DeveloperIssueKind: Int] { DeveloperIssueRules.counts(groups) }
    var total: Int { groups.reduce(0) { $0 + $1.count } }

    private static let thirdPartyKey = "developerTools.issues.thirdPartyCookies"
    private static let byCategoryKey = "developerTools.issues.groupByCategory"
    private static let byKindKey = "developerTools.issues.groupByKind"
    private static let contrastKey = "developerTools.issues.lowTextContrast"

    static let collect = DevToolsScripts.issuesCollect
    static let frontend = DevToolsScripts.issuesFrontend
    /// Posted with the session as object and the request's id, for the
    /// DevTools view to select it in Network.
    static let revealRequestNotification = Notification.Name("DeveloperIssuesRevealRequest")

    private weak var session: DeveloperToolsSession?
    private var subscriptions = Set<AnyCancellable>()
    private var poll: Task<Void, Never>?

    /// Console messages that may be issues, in order, since the last navigation.
    private var messages: [DeveloperIssueMessage] = []
    private var seenLines = Set<UUID>()
    /// Cookie issues by response, and when each was heard.
    private struct CookieEntry {
        var requestID: String
        var url: String
        var issues: [DeveloperIssue]
        var time: Date
    }
    private var cookieEntries: [CookieEntry] = []
    private var formIssues: [DeveloperIssue] = []
    /// Responses' isolation headers since the last navigation, newest last.
    private var isolationResponses: [DeveloperIsolationResponse] = []
    /// The page's `crossOriginIsolated`, from the last form scan.
    private var crossOriginIsolated: Bool?
    private var contrastIssues: [DeveloperIssue] = []
    /// Issues of earlier pages kept by Preserve log, their elements unlinked.
    private var preserved: [DeveloperIssue] = []

    /// A scan's elements, kept in the page.
    private struct Holder {
        var scan: String
        var objectID: String
        var target: String?
    }
    private var formHolder: Holder?
    /// The scan's state object in the page, whose version counts changes
    /// to the page's fields since.
    private var stateHolder: Holder?
    private var contrastHolder: Holder?
    private var scanSerial = 0
    private var scannedVersion = -2
    private var scannedTarget: String??
    private var lastScan = Date.distantPast
    /// A form scan is wanted: the document is new, its fields changed, or
    /// the Issues view opened.
    private var formScanDue = true
    /// Scans that failed in a row; retried a few times, then left until
    /// the next navigation or the Issues view opening.
    private var failedScans = 0
    /// Rescans because the state object was lost (not by a navigation we
    /// heard of), in a row; bounded so a page that keeps losing it is not
    /// scanned forever.
    private var lostStates = 0
    private var contrastDue = false
    private var lastContrast = Date.distantPast
    private var hoverTask: Task<Void, Never>?
    private var marksTask: Task<Void, Never>?
    /// What `marks` was resolved from: the elements' marks and the tree's root.
    private var marked: (wanted: [DeveloperIssueElement: [DeveloperIssueMark]], revision: Int, root: Int)?
    /// The last console line ingested, so each publish of the Console's
    /// lines only walks the ones after it.
    private var lastLineID: UUID?
    /// Issues views on screen; the poll runs fast only while there is one.
    private var viewers = 0
    private var wake = false
    /// Installs of the frontend listener that threw, in a row (an older
    /// WebKit without the hook); after a few it is not tried again until
    /// the page navigates.
    private var frontendFailures = 0

    private static var models: [ObjectIdentifier: (session: WeakSession, model: DeveloperIssuesModel)] = [:]
    struct WeakSession { weak var value: DeveloperToolsSession? }

    static func model(for session: DeveloperToolsSession) -> DeveloperIssuesModel {
        models = models.filter { $0.value.session.value != nil }
        let key = ObjectIdentifier(session)
        if let found = models[key], found.session.value === session { return found.model }
        let model = DeveloperIssuesModel(session: session)
        // A view drawn once more after DevTools closed gets a model that
        // neither polls nor stays.
        if !session.isClosed { models[key] = (WeakSession(value: session), model) }
        return model
    }

    /// DevTools closed: the session's model stops polling and goes.
    static func closed(_ session: DeveloperToolsSession) {
        guard let found = models.removeValue(forKey: ObjectIdentifier(session)) else { return }
        found.model.poll?.cancel()
        found.model.poll = nil
        found.model.marksTask?.cancel()
        found.model.release(&found.model.stateHolder)
    }

    /// The page navigated (DeveloperToolsSession's drain): what it found
    /// goes, unless the Console keeps its log.
    static func navigated(_ session: DeveloperToolsSession) {
        guard let found = models[ObjectIdentifier(session)], found.session.value === session else { return }
        found.model.navigated()
    }

    private init(session: DeveloperToolsSession) {
        self.session = session
        contrastDue = showLowContrast
        ingest(session.console)
        session.$console
            .sink { [weak self] lines in self?.ingest(lines) }
            .store(in: &subscriptions)
        session.$requests
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &subscriptions)
        // Entering Elements reads the document afresh and can renumber its nodes.
        session.$root.combineLatest(session.$panel).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resolveMarks() }
            .store(in: &subscriptions)
        guard !session.isClosed else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.session?.isClosed ?? true { return }
                await self.tick()
                // Every second while the Issues view is shown, else every
                // five; the view opening cuts the wait short.
                var waited = 0
                while !Task.isCancelled, !self.wake, waited < (self.viewers > 0 ? 1_000 : 5_000) {
                    try? await Task.sleep(for: .milliseconds(250))
                    waited += 250
                }
                self.wake = false
            }
        }
    }

    /// The Issues view appeared: poll fast, and scan the page afresh.
    func viewAppeared() {
        viewers += 1
        formScanDue = true
        failedScans = 0
        lostStates = 0
        if showLowContrast { contrastDue = true }
        wake = true
    }

    func viewDisappeared() {
        viewers = max(0, viewers - 1)
    }

    // MARK: Collecting

    private func ingest(_ lines: [DeveloperToolsSession.ConsoleLine]) {
        // The Console appends; only the lines after the last one ingested
        // are new. When that line is gone (Clear console, a navigation)
        // all of them are walked, the seen ids keeping out repeats.
        var start = 0
        if let last = lastLineID, let index = lines.lastIndex(where: { $0.id == last }) { start = index + 1 }
        lastLineID = lines.last?.id
        var added = false
        for line in lines[start...] where !seenLines.contains(line.id) {
            seenLines.insert(line.id)
            let message = DeveloperIssueMessage(line)
            guard DeveloperIssueRules.isCandidate(message) else { continue }
            messages.append(message)
            added = true
        }
        // Only the lines the Console still holds can come again.
        if seenLines.count > 4 * max(1, lines.count) + 1_000 { seenLines = Set(lines.map(\.id)) }
        if messages.count > 2_000 { messages.removeFirst(messages.count - 2_000) }
        if added { recompute() }
    }

    private func navigated() {
        let keep = session?.preserveConsoleLog ?? false
        let address = session?.address?.absoluteString
        if keep {
            // The old page's elements are gone with it.
            preserved += current().map { issue in
                var issue = issue
                issue.resources = issue.resources.map { var resource = $0; resource.element = nil; return resource }
                return issue
            }
            if preserved.count > 5_000 { preserved.removeFirst(preserved.count - 5_000) }
        }
        messages = []
        // The new document's own response usually arrives before the commit.
        let now = Date()
        cookieEntries = keep ? [] : cookieEntries.filter { $0.url == address && now.timeIntervalSince($0.time) < 10 }
        formIssues = []
        crossOriginIsolated = nil
        isolationResponses = keep ? [] : isolationResponses.filter { $0.url == address && $0.type == "Document" }
        contrastIssues = []
        release(&formHolder)
        release(&stateHolder)
        release(&contrastHolder)
        scannedVersion = -2
        formScanDue = true
        failedScans = 0
        lostStates = 0
        frontendFailures = 0
        contrastDue = showLowContrast
        recompute()
    }

    private func tick() async {
        guard let session, session.ready else { return }
        await drainFrontend(session)
        await checkPage(session)
    }

    /// Drains the frontend listener; null when it is not there (not yet
    /// installed, or WebKit reloaded its hidden frontend).
    private static let drain = "return globalThis.searchIssues ? globalThis.searchIssues.drain() : null;"

    private func drainFrontend(_ session: DeveloperToolsSession) async {
        do {
            var result = try await session.evaluateInFrontend(Self.drain)
            if result as? [Any] == nil {
                // Installed once per frontend; only a fresh one gets the source again.
                guard frontendFailures < 3 else { return }
                do {
                    result = try await session.evaluateInFrontend(Self.frontend + "\nreturn searchIssues.drain();")
                    frontendFailures = 0
                } catch is CancellationError {
                    return
                } catch {
                    frontendFailures += 1
                    throw error
                }
            }
            let raw = result as? [[String: Any]] ?? []
            guard !raw.isEmpty else { return }
            let page = session.address?.absoluteString
            let now = Date()
            for item in raw {
                guard let url = item["url"] as? String, !url.isEmpty else { continue }
                let id = item["requestId"] as? String
                if let headers = item["isolation"] as? [String: String] {
                    isolationResponses.append(DeveloperIsolationResponse(
                        requestID: id ?? "", url: url, type: item["type"] as? String ?? "", coop: headers["coop"],
                        coep: headers["coep"], corp: headers["corp"], allowOrigin: headers["allowOrigin"]))
                }
                guard let header = item["setCookie"] as? String else { continue }
                let issues = DeveloperIssueRules.cookies(setCookie: header, responseURL: url, pageURL: page, requestID: id)
                guard !issues.isEmpty else { continue }
                cookieEntries.append(CookieEntry(requestID: id ?? "", url: url, issues: issues, time: now))
            }
            if cookieEntries.count > 1_000 { cookieEntries.removeFirst(cookieEntries.count - 1_000) }
            if isolationResponses.count > 2_000 { isolationResponses.removeFirst(isolationResponses.count - 2_000) }
            recompute()
        } catch is CancellationError {
        } catch {
            // The frontend reloads now and then; the next tick sets it up again.
        }
    }

    /// How many times the page's fields changed since the scan, read off
    /// its state object without running a script (each script run is a
    /// new script for the debugger). Nil when there is no scan of this
    /// document: none yet, or the page navigated and took the object.
    private func pageVersion(_ session: DeveloperToolsSession, target: String?) async -> Int? {
        guard let state = stateHolder, state.target == target,
              let reply = try? await session.command("Runtime.getProperties", [
                  "objectId": state.objectID, "ownProperties": true,
              ], targetID: target) else { return nil }
        let properties = reply["properties"] as? [[String: Any]] ?? reply["result"] as? [[String: Any]] ?? []
        let version = properties.first { $0["name"] as? String == "version" }?["value"] as? [String: Any]
        return (version?["value"] as? NSNumber)?.intValue
    }

    /// Scans the page's forms when the document is new, its fields
    /// changed or the Issues view opened, at most every three seconds.
    /// Contrast is scanned only while the Issues view is shown.
    private func checkPage(_ session: DeveloperToolsSession) async {
        let target = session.runtimeTargetID
        if scannedTarget != .some(target) { formScanDue = true }
        if !formScanDue, stateHolder != nil {
            if let version = await pageVersion(session, target: target) {
                lostStates = 0
                if version != scannedVersion { formScanDue = true }
            } else {
                // The state object went with its document.
                release(&stateHolder)
                if lostStates < 2 {
                    lostStates += 1
                    formScanDue = true
                }
            }
        }
        if formScanDue, Date().timeIntervalSince(lastScan) >= (failedScans > 0 ? 10 : 3) {
            lastScan = Date()
            formScanDue = false
            do {
                try await scanForms(session, target: target)
                problem = nil
                failedScans = 0
            } catch is CancellationError {
                formScanDue = true
            } catch {
                problem = error.localizedDescription
                failedScans += 1
                if failedScans < 3 { formScanDue = true }
            }
            if showLowContrast { contrastDue = true }
        }
        if viewers > 0, showLowContrast, contrastDue, Date().timeIntervalSince(lastContrast) >= 10 {
            lastContrast = Date()
            contrastDue = false
            try? await scanContrast(session, target: target)
        }
    }

    /// Runs a scan script that returns {elements, data}, keeping the
    /// holder in the page and handing back the data.
    private func scan(_ source: String, _ session: DeveloperToolsSession, target: String?) async throws -> (Holder, [String: Any]) {
        let reply = try await session.command("Runtime.evaluate", [
            "expression": source, "objectGroup": "search-issues",
            "doNotPauseOnExceptionsAndMuteConsole": true, "includeCommandLineAPI": false,
        ], targetID: target)
        if reply["wasThrown"] as? Bool == true {
            let description = (reply["result"] as? [String: Any])?["description"] as? String
            throw DeveloperCSSOverviewError(description ?? "The page refused the issues scan.")
        }
        guard let object = reply["result"] as? [String: Any], let id = object["objectId"] as? String else {
            throw DeveloperCSSOverviewError("The page sent nothing back.")
        }
        let data = try await session.command("Runtime.callFunctionOn", [
            "objectId": id, "functionDeclaration": "function() { return this.data; }", "returnByValue": true,
        ], targetID: target)
        guard let value = (data["result"] as? [String: Any])?["value"] as? [String: Any] else {
            _ = try? await session.command("Runtime.releaseObject", ["objectId": id], targetID: target)
            throw DeveloperCSSOverviewError("The issues scan was too large to read back.")
        }
        scanSerial += 1
        return (Holder(scan: "scan\(scanSerial)", objectID: id, target: target), value)
    }

    private func scanForms(_ session: DeveloperToolsSession, target: String?) async throws {
        let (holder, data) = try await scan(Self.collect, session, target: target)
        release(&formHolder)
        formHolder = holder
        release(&stateHolder)
        if let state = try? await session.command("Runtime.callFunctionOn", [
            "objectId": holder.objectID, "functionDeclaration": "function() { return this.state; }",
        ], targetID: target), let id = (state["result"] as? [String: Any])?["objectId"] as? String {
            stateHolder = Holder(scan: holder.scan, objectID: id, target: target)
        }
        scannedVersion = (data["version"] as? NSNumber)?.intValue ?? 0
        scannedTarget = .some(target)
        let snapshot = DeveloperFormSnapshot(raw: data)
        formIssues = DeveloperIssueRules.forms(snapshot, scan: holder.scan) + DeveloperIssueRules.aria(snapshot, scan: holder.scan)
        crossOriginIsolated = snapshot.crossOriginIsolated
        recompute()
    }

    private func scanContrast(_ session: DeveloperToolsSession, target: String?) async throws {
        let (holder, data) = try await scan(DeveloperCSSOverviewModel.collect, session, target: target)
        guard showLowContrast else {
            var dropped: Holder? = holder
            release(&dropped)
            return
        }
        release(&contrastHolder)
        contrastHolder = holder
        let report = DeveloperCSSOverview.report(data)
        contrastIssues = DeveloperIssueRules.contrast(report.contrast, label: report.label, scan: holder.scan)
        recompute()
    }

    private func release(_ holder: inout Holder?) {
        guard let old = holder, let session else { holder = nil; return }
        holder = nil
        Task {
            // The form scan's watcher stops with its state (the other
            // holders have none).
            _ = try? await session.command("Runtime.callFunctionOn", [
                "objectId": old.objectID,
                "functionDeclaration": "function() { if (this.observer) { clearTimeout(this.timer); this.observer.disconnect(); } }",
            ], targetID: old.target)
            _ = try? await session.command("Runtime.releaseObject", ["objectId": old.objectID], targetID: old.target)
        }
    }

    // MARK: Issues

    /// This page's issues, in the order found.
    private func current() -> [DeveloperIssue] {
        var issues = DeveloperIssueRules.classify(messages)
        issues += cookieEntries.flatMap(\.issues)
        if let session {
            let requests = session.requests.map { (id: $0.id, url: $0.url, failed: $0.failure != nil) }
            issues += DeveloperIssueRules.mixedContent(requests: requests, pageURL: session.address?.absoluteString)
            issues += isolationIssues(session)
        }
        issues += formIssues
        issues += contrastIssues
        return issues
    }

    /// COOP, COEP and CORP problems: the page's document is the newest
    /// Document response at its address (else the newest Document).
    private func isolationIssues(_ session: DeveloperToolsSession) -> [DeveloperIssue] {
        let address = session.address?.absoluteString
        let documents = isolationResponses.filter { $0.type == "Document" }
        guard let document = documents.last(where: { $0.url == address }) ?? documents.last else { return [] }
        let failed = Set(session.requests.filter { $0.failure != nil }.map(\.id))
        let responses = isolationResponses.map { response in
            var response = response
            response.failed = failed.contains(response.requestID)
            return response
        }
        return DeveloperIssueRules.isolation(document: document, responses: responses,
                                             crossOriginIsolated: crossOriginIsolated)
    }

    private func recompute() {
        var issues = preserved + current()
        if let session { issues = DeveloperIssueRules.link(issues, requests: session.requests.map { ($0.id, $0.url) }) }
        let include = options.includeThirdPartyCookies
        let next = DeveloperIssueRules.aggregate(issues, includeThirdParty: include)
        if next != groups { groups = next; resolveMarks() }
        let hiddenNow = DeveloperIssueRules.hiddenCount(issues, includeThirdParty: include)
        if hiddenNow != hidden { hidden = hiddenNow }
    }

    // MARK: Links

    /// Network, with the request selected.
    func reveal(request id: String) {
        guard let session else { return }
        session.select(.network)
        // The Network view may only now be appearing.
        Task { @MainActor in
            NotificationCenter.default.post(name: Self.revealRequestNotification, object: session, userInfo: ["id": id])
            try? await Task.sleep(for: .milliseconds(150))
            NotificationCenter.default.post(name: Self.revealRequestNotification, object: session, userInfo: ["id": id])
        }
    }

    /// Sources, open at the line.
    func reveal(source url: String, line: Int, column: Int?) {
        session?.revealSource(url: url, line: line, column: column)
    }

    func canReveal(_ element: DeveloperIssueElement) -> Bool {
        formHolder?.scan == element.scan || contrastHolder?.scan == element.scan
    }

    private func node(_ element: DeveloperIssueElement) async -> Int? {
        guard let session,
              let holder = [formHolder, contrastHolder].compactMap({ $0 }).first(where: { $0.scan == element.scan }) else { return nil }
        guard let reply = try? await session.command("Runtime.callFunctionOn", [
            "objectId": holder.objectID,
            "functionDeclaration": "function(index) { return this.elements[index] || null; }",
            "arguments": [["value": element.index]],
        ], targetID: holder.target),
            let object = (reply["result"] as? [String: Any])?["objectId"] as? String else { return nil }
        let node = try? await session.command("DOM.requestNode", ["objectId": object], targetID: session.domTargetID)
        _ = try? await session.command("Runtime.releaseObject", ["objectId": object], targetID: holder.target)
        guard let id = (node?["nodeId"] as? NSNumber)?.intValue, id > 0 else { return nil }
        return id
    }

    /// Resolve at most one batch per scan when its marks or document
    /// change. A scan's node IDs belong to its own document.
    private func resolveMarks() {
        guard let session, session.panel == .elements, let root = session.root else { return }
        let revision = session.domRevision
        let wanted = DeveloperIssueRules.marks(groups)
        if let marked, marked.wanted == wanted, marked.revision == revision, marked.root == root { return }
        marked = (wanted, revision, root)
        marksTask?.cancel()
        marksTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            var next: [Int: [DeveloperIssueMark]] = [:]
            for holder in [self.formHolder, self.contrastHolder].compactMap({ $0 }) {
                let indexes = Array(wanted.keys.filter { $0.scan == holder.scan }.map(\.index).sorted().prefix(500))
                if !indexes.isEmpty {
                    let nodes = await self.scannedNodes(holder: holder, indexes: indexes)
                    for (index, id) in nodes {
                        next[id, default: []] += wanted[DeveloperIssueElement(scan: holder.scan, index: index)] ?? []
                    }
                }
            }
            guard !Task.isCancelled, revision == self.session?.domRevision,
                  root == self.session?.root, next != self.marks else { return }
            self.marks = next
        }
    }

    private func scannedNodes(holder: Holder, indexes: [Int]) async -> [Int: Int] {
        guard let session, let list = try? await session.command("Runtime.callFunctionOn", [
            "objectId": holder.objectID, "functionDeclaration": "function(indexes) { return indexes.map(i => this.elements[i] || null); }",
            "arguments": [["value": indexes]], "doNotPauseOnExceptionsAndMuteConsole": true,
        ], targetID: holder.target).object("result")?.string("objectId") else { return [:] }
        let reply = try? await session.command("Runtime.getProperties", ["objectId": list, "ownProperties": true], targetID: holder.target)
        let properties = reply?.objects("properties") ?? reply?.objects("result") ?? []
        var nodes: [Int: Int] = [:]
        for property in properties {
            guard let position = property.string("name").flatMap(Int.init), indexes.indices.contains(position),
                  let object = property.object("value")?.string("objectId") else { continue }
            if !Task.isCancelled {
                let result = try? await session.command("DOM.requestNode", ["objectId": object], targetID: session.domTargetID)
                if let id = result?.int("nodeId"), id > 0 { nodes[indexes[position]] = id }
            }
            _ = try? await session.command("Runtime.releaseObject", ["objectId": object], targetID: holder.target)
        }
        _ = try? await session.command("Runtime.releaseObject", ["objectId": list], targetID: holder.target)
        return nodes
    }

    /// The Issues drawer tab, open at an issue's row (an underline in Elements).
    func reveal(issue group: String) {
        expanded = expanded.filter { !$0.hasPrefix("section:") }
        expanded.insert(group)
        revealed = group
        Self.show()
    }

    /// An element row hovered: drawn on the page; nil hides it.
    func hover(_ element: DeveloperIssueElement?) {
        hoverTask?.cancel()
        guard let session else { return }
        guard let element else { session.hideHighlight(); return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, let node = await self?.node(element), !Task.isCancelled else { return }
            session.highlightNode(node)
        }
    }

    /// Elements, with the node selected (as the CSS overview reveals one).
    func reveal(_ element: DeveloperIssueElement) {
        guard let session else { return }
        hoverTask?.cancel()
        session.hideHighlight()
        let switching = session.panel != .elements
        let before = session.root
        session.select(.elements)
        Task { [weak self] in
            for _ in 0..<40 where switching {
                guard session.root == before || session.root == nil else { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let node = await self?.node(element) else { return }
            for _ in 0..<40 where session.nodes[node] == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            session.selectNode(node)
        }
    }

    /// The Issues drawer tab, opened.
    static func show() {
        DeveloperToolsShell.shared.showDrawer(.tool(.issues))
    }
}
