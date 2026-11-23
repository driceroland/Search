import Foundation

/// A dedicated worker the page started (`new Worker(…)`), as WebKit's
/// frontend tracks it: its own inspector target, with its own Console
/// context, scripts and debugger thread, as Chrome DevTools shows one.
struct DeveloperWorker: Identifiable, Hashable {
    struct Script: Hashable {
        let id: String
        let url: String
    }

    /// The worker's inspector target, which commands for it name.
    let id: String
    let url: String
    /// The name passed to `new Worker(url, {name})`, if any.
    let name: String
    let parentID: String?
    let paused: Bool
    let scripts: [Script]

    init(id: String, url: String, name: String = "", parentID: String? = nil, paused: Bool = false, scripts: [Script] = []) {
        self.id = id
        self.url = url
        self.name = name
        self.parentID = parentID
        self.paused = paused
        self.scripts = scripts
    }

    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        url = raw["url"] as? String ?? ""
        name = raw["name"] as? String ?? ""
        parentID = raw["parentId"] as? String
        paused = raw["paused"] as? Bool ?? false
        scripts = (raw["scripts"] as? [[String: Any]] ?? []).compactMap { script in
            guard let id = script["id"] as? String, let url = script["url"] as? String, !url.isEmpty else { return nil }
            return Script(id: id, url: url)
        }
    }

    /// Chrome's label for a worker: its name, else its script's file.
    var title: String {
        if !name.isEmpty { return name }
        if let address = URL(string: url), !address.lastPathComponent.isEmpty, address.lastPathComponent != "/" {
            return address.lastPathComponent
        }
        return url.isEmpty ? "worker" : url
    }

    /// The navigator's frame id for the worker's scripts
    /// (`DeveloperToolsSession.Resource.frame`): its target, then the
    /// script's id, which `Debugger.getScriptSource` reads it by.
    static func resourceFrame(target: String, script: String) -> String { target + "|" + script }

    /// The target and script id of a worker script's resource.
    static func parse(resourceFrame frame: String) -> (target: String, script: String)? {
        guard let bar = frame.lastIndex(of: "|") else { return nil }
        let target = String(frame[..<bar]), script = String(frame[frame.index(after: bar)...])
        guard !target.isEmpty, !script.isEmpty else { return nil }
        return (target, script)
    }

    /// The resource type of a worker's scripts in Sources.
    static let scriptType = "WorkerScript"
}

extension DeveloperToolsSession {
    /// The worker a target is, if it is one.
    func worker(_ targetID: String?) -> DeveloperWorker? {
        guard let targetID else { return nil }
        return workers.first { $0.id == targetID }
    }

    /// Application › Frames › Web workers: "Reveal in Sources panel".
    func revealWorker(_ worker: DeveloperWorker) {
        guard ready else { return }
        let script = workerScripts.first { $0.frame.hasPrefix(worker.id + "|") && DeveloperDebugger.sameScript($0.url, worker.url) }
            ?? workerScripts.first { $0.frame.hasPrefix(worker.id + "|") }
        select(.sources)
        if let script { openSource(script) } else if !worker.url.isEmpty { revealSource(url: worker.url, line: 1) }
    }
}
