import AppKit
import SearchPluginAPI
import SwiftUI
import WebKit

// Developer Tools Lite: what Web Inspector doesn't have, as a package
// Search downloads on request (Settings › About › Developer). Three tools,
// each on the tab in front, from View › Developer:
//   - Lighthouse: performance, accessibility, best practices and SEO audits,
//     Lighthouse's categories and scoring over the package's own checks
//     (Lighthouse.swift);
//   - Recorder: a flow recorded, replayed and exported (Recorder.swift);
//   - Device Toolbar: the page at a phone's size, with sensors and
//     rendering emulated (DeviceToolbar.swift).
// Web Inspector stays the inspector; nothing here touches it.
//
// What a page can see of it, and what it can't:
//   - Every script runs in the package's own content world (the host's
//     isolatedWorld), never the page's: the page sees none of their
//     variables, can't replace what they call, and can't reach their
//     message handler. Scripts go into a tab only while a tool that needs
//     them is open on it, and come out when it closes. The one handler (the
//     recorder's) is on that world alone, for the main frame, and only while
//     recording; each message is checked.
//   - The one exception is a sensor override (a location or an orientation
//     you set): the page's own functions are what answer it, so a small
//     script with your values written into it stands in the page's world,
//     only on that tab and only while the override is set. It has no
//     globals, no handler and no way back.
//   - Nothing goes through WebKit's private inspector: the tools are page
//     scripts and WKWebView's public calls.
//   - Nothing is kept but the choices made in the tools (form factor,
//     device), in the profile through the host, and not even those from a
//     private tab. Reports and recordings live with the tab, and go to a file
//     only through a save panel.

/// The package's principal class (Info.plist NSPrincipalClass).
@objc(SearchDevToolsLite)
@MainActor
public final class LitePlugin: NSObject, SearchDevToolsPlugin, DevToolsOwner {
    public static var apiVersion: Int { SearchDevToolsAPI.version }

    /// The one instance, once Search has started it.
    static var current: LitePlugin?

    private(set) var host: SearchDevToolsHost?
    /// Each tab with a tool open on it.
    private var sessions: [ObjectIdentifier: DevToolsSession] = [:]
    private var docks: [ObjectIdentifier: NSView] = [:]
    private var bars: [ObjectIdentifier: NSView] = [:]

    override public required init() { super.init() }

    public func start(host: SearchDevToolsHost) {
        self.host = host
        Self.current = self
    }

    public func shutdown() {
        for session in sessions.values {
            session.end()
            if let web = session.web { host?.rearm(web); host?.keepAwake(false, webView: web) }
        }
        sessions.removeAll()
        docks.removeAll()
        bars.removeAll()
        host?.invalidate()
    }

    var world: WKContentWorld { host?.isolatedWorld ?? .defaultClient }

    public func menuItems() -> [[String: String]] {
        DevTool.allCases.map { ["id": $0.rawValue, "title": $0.title] }
    }

    func session(_ web: WKWebView) -> DevToolsSession? { sessions[ObjectIdentifier(web)] }

    public func open(_ item: String, webView: WKWebView) {
        guard let tool = DevTool(rawValue: item) else { return }
        let session = sessions[ObjectIdentifier(webView)] ?? {
            let made = DevToolsSession(web: webView, plugin: self)
            sessions[ObjectIdentifier(webView)] = made
            host?.keepAwake(true, webView: webView)
            return made
        }()
        switch tool {
        case .device: session.device.on.toggle()
        case .lighthouse, .recorder: session.panel = session.panel == tool ? nil : tool
        }
        if session.idle { close(webView: webView) }
        host?.invalidate()
    }

    public func close(webView: WKWebView) {
        let id = ObjectIdentifier(webView)
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.end()
        docks[id] = nil
        bars[id] = nil
        host?.rearm(webView)
        host?.keepAwake(false, webView: webView)
        host?.invalidate()
    }

    func toolsIdle(webView: WKWebView) { close(webView: webView) }

    public func isOpen(webView: WKWebView) -> Bool { sessions[ObjectIdentifier(webView)] != nil }

    public func keyDown(_ event: NSEvent, webView: WKWebView) -> Bool { false }

    public func inspect(at point: NSPoint, webView: WKWebView) -> Bool { false }

    public func dockPlacement(webView: WKWebView) -> [String: Any]? { nil }

    public func setDockSize(_ size: Double, webView: WKWebView) {}

    public func dockView(webView: WKWebView) -> NSView? {
        let id = ObjectIdentifier(webView)
        guard let session = sessions[id], session.panel != nil else { return nil }
        if let made = docks[id] { return made }
        let view = NSHostingView(rootView: DevToolsDock(session: session) { [weak self] in self?.close(webView: webView) })
        docks[id] = view
        return view
    }

    public func barView(webView: WKWebView) -> NSView? {
        let id = ObjectIdentifier(webView)
        guard let session = sessions[id], session.device.on else { return nil }
        if let made = bars[id] { return made }
        let view = NSHostingView(rootView: DeviceBar(device: session.device))
        bars[id] = view
        return view
    }

    public func viewportSize(webView: WKWebView) -> NSValue? {
        guard let device = sessions[ObjectIdentifier(webView)]?.device, device.on else { return nil }
        return NSValue(size: device.size)
    }

    public func scripts(webView: WKWebView) -> [WKUserScript] {
        sessions[ObjectIdentifier(webView)]?.scripts() ?? []
    }

    public func didReceiveResponse(_ response: URLResponse, webView: WKWebView) {
        sessions[ObjectIdentifier(webView)]?.response = response as? HTTPURLResponse
    }

    public func tabWillUnload(webView: WKWebView) {
        let id = ObjectIdentifier(webView)
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.end(quietly: true)
        docks[id] = nil
        bars[id] = nil
        host?.invalidate()
    }

    public func perform(_ command: String, arguments: [String: Any], webView: WKWebView?,
                        completion: @escaping ([String: Any]) -> Void) {
        Automation.perform(command, arguments, webView, plugin: self, completion: completion)
    }
}

// MARK: - Automation

/// The tools driven by name (SearchDevToolsPlugin.perform): what tests and
/// the bench use. Every answer is a property list.
@MainActor
enum Automation {
    static func perform(_ command: String, _ arguments: [String: Any], _ web: WKWebView?, plugin: LitePlugin,
                        completion: @escaping ([String: Any]) -> Void) {
        guard let web else { return completion(["error": "no page"]) }
        func session() -> DevToolsSession? { plugin.session(web) }
        switch command {
        case "open":
            plugin.open(arguments["item"] as? String ?? "", webView: web)
            completion(["open": plugin.isOpen(webView: web)])
        case "close":
            plugin.close(webView: web)
            completion([:])
        case "lighthouse.run":
            guard let model = session()?.lighthouse else { return completion(["error": "Lighthouse isn't open"]) }
            if let mode = (arguments["mode"] as? String).flatMap(LighthouseMode.init) { model.mode = mode }
            if let form = (arguments["form"] as? String).flatMap(LighthouseFormFactor.init) { model.form = form }
            if let wanted = arguments["categories"] as? [String] { model.categories = Set(wanted.compactMap(LighthouseCategory.init)) }
            model.run()
            Task { @MainActor in
                while model.running { try? await Task.sleep(nanoseconds: 50_000_000) }
                guard let report = model.report else { return completion(["error": model.notice ?? "no report"]) }
                completion(["report": LighthouseJSON.object(report)])
            }
        case "recorder.record":
            session()?.recorder.record()
            completion(["state": "\(session()?.recorder.state ?? .idle)"])
        case "recorder.stop":
            session()?.recorder.stop()
            completion(["steps": session()?.recorder.recording.steps.map(\.json) ?? []])
        case "recorder.steps":
            completion(["steps": session()?.recorder.recording.steps.map(\.json) ?? [],
                        "recording": session()?.recorder.state == .recording])
        case "recorder.import":
            guard let recorder = session()?.recorder else { return completion(["error": "Recorder isn't open"]) }
            recorder.load((arguments["json"] as? String).map { Data($0.utf8) })
            completion(recorder.notice.map { ["error": $0] } ?? ["steps": recorder.recording.steps.map(\.json)])
        case "recorder.play":
            guard let recorder = session()?.recorder else { return completion(["error": "Recorder isn't open"]) }
            recorder.play()
            Task { @MainActor in
                while recorder.busy { try? await Task.sleep(nanoseconds: 50_000_000) }
                switch recorder.state {
                case .played: completion(["state": "played"])
                case .failed(let index, let why): completion(["state": "failed", "step": index, "error": why])
                default: completion(["state": "stopped"])
                }
            }
        case "device.set":
            guard let device = session()?.device else { return completion(["error": "Device toolbar isn't open"]) }
            device.set(arguments)
            completion(["on": device.on, "width": device.size.width, "height": device.size.height])
        case "state":
            completion(["open": plugin.isOpen(webView: web), "scripts": plugin.scripts(webView: web).count,
                        "panel": session()?.panel?.rawValue ?? "", "device": session()?.device.on ?? false])
        default:
            completion(["error": "unknown command"])
        }
    }
}
