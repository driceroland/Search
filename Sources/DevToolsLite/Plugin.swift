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

/// A tool of the three.
enum DevTool: String, CaseIterable, Identifiable {
    case lighthouse, recorder, device

    var id: Self { self }

    var title: String {
        switch self {
        case .lighthouse: "Lighthouse"
        case .recorder: "Recorder"
        case .device: "Device Toolbar"
        }
    }
}

/// The package's principal class (Info.plist NSPrincipalClass).
@objc(SearchDevToolsLite)
@MainActor
public final class LitePlugin: NSObject, SearchDevToolsPlugin {
    public static var apiVersion: Int { SearchDevToolsAPI.version }

    /// The one instance, once Search has started it.
    static var current: LitePlugin?

    private(set) var host: SearchDevToolsHost?
    /// Each tab with a tool open on it.
    private var sessions: [ObjectIdentifier: DevToolsSession] = [:]
    private var docks: [ObjectIdentifier: NSView] = [:]
    private var bars: [ObjectIdentifier: NSView] = [:]

    /// The recorder's message handler, on the package's world only.
    static let channel = "searchDeveloper"

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

    public func isOpen(webView: WKWebView) -> Bool { sessions[ObjectIdentifier(webView)] != nil }

    public func keyDown(_ event: NSEvent, webView: WKWebView) -> Bool { false }

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

/// One tab's tools.
@MainActor
final class DevToolsSession: ObservableObject {
    weak var web: WKWebView?
    weak var plugin: LitePlugin?

    /// The panel beside the page, if one is up.
    @Published var panel: DevTool? {
        didSet { if panel != oldValue { plugin?.host?.invalidate() } }
    }

    let lighthouse: LighthouseModel
    let recorder: RecorderModel
    let device: DeviceEmulation

    /// The last main-document answer.
    var response: HTTPURLResponse?

    /// A private tab keeps nothing, not even the tools' choices.
    var keeps: Bool {
        guard let web, let host = plugin?.host else { return false }
        return !host.isPrivate(web)
    }

    var world: WKContentWorld { plugin?.world ?? .defaultClient }

    private var relay: DevToolsRelay?

    init(web: WKWebView, plugin: LitePlugin) {
        self.web = web
        self.plugin = plugin
        lighthouse = LighthouseModel()
        recorder = RecorderModel()
        device = DeviceEmulation()
        lighthouse.session = self
        recorder.session = self
        device.session = self
        lighthouse.restore()
        device.restore()
    }

    var idle: Bool { panel == nil && !device.on && !recorder.busy && !lighthouse.running }

    func setting(_ key: String) -> Any? { plugin?.host?.setting(forKey: key) }

    func keep(_ value: Any?, _ key: String) {
        guard keeps else { return }
        plugin?.host?.setSetting(value, forKey: key)
    }

    /// The scripts the open tools need in the next document.
    func scripts() -> [WKUserScript] {
        lighthouse.scripts() + recorder.scripts() + device.scripts()
    }

    /// The tab's scripts again, now that a tool needs others.
    func rearm() {
        if let web { plugin?.host?.rearm(web) }
    }

    func invalidate() { plugin?.host?.invalidate() }

    /// The recorder's handler, on the package's world only, while it records.
    func listen(_ on: Bool) {
        guard let controller = web?.configuration.userContentController else { return }
        if on, relay == nil {
            let made = DevToolsRelay(session: self)
            controller.removeScriptMessageHandler(forName: LitePlugin.channel, contentWorld: world)
            controller.add(made, contentWorld: world, name: LitePlugin.channel)
            relay = made
        } else if !on, relay != nil {
            controller.removeScriptMessageHandler(forName: LitePlugin.channel, contentWorld: world)
            relay = nil
        }
    }

    /// Run in the package's world: a function body, its arguments passed as
    /// values, never written into the source.
    func call(_ body: String, _ arguments: [String: Any] = [:]) async -> Any? {
        guard let web else { return nil }
        do {
            return try await web.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: world)
        } catch {
            return nil
        }
    }

    /// `quietly`: the page view is going, so nothing is loaded again.
    func end(quietly: Bool = false) {
        lighthouse.cancel()
        recorder.end()
        device.end(reloading: !quietly)
        listen(false)
        panel = nil
    }

    fileprivate func heard(_ body: [String: Any]) {
        recorder.heard(body)
    }
}

/// The recorder's handler. A message counts only from the package's world,
/// in this tab's main frame, as a small dictionary: anything else is dropped.
private final class DevToolsRelay: NSObject, WKScriptMessageHandler {
    weak var session: DevToolsSession?

    init(session: DevToolsSession) { self.session = session }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let session, message.world == session.world, message.frameInfo.isMainFrame,
                  let web = session.web, message.webView === web,
                  let body = message.body as? [String: Any], body.count <= 8,
                  DevToolsRelay.small(body, depth: 0) else { return }
            session.heard(body)
        }
    }

    /// Bounded: no deep nesting, no long strings, no huge lists.
    static func small(_ value: Any, depth: Int) -> Bool {
        guard depth < 6 else { return false }
        switch value {
        case let text as String: return text.utf16.count <= 20_000
        case is NSNumber: return true
        case let list as [Any]: return list.count <= 64 && list.allSatisfy { small($0, depth: depth + 1) }
        case let map as [String: Any]:
            return map.count <= 32 && map.allSatisfy { $0.key.utf16.count <= 64 && small($0.value, depth: depth + 1) }
        case is NSNull: return true
        default: return false
        }
    }
}

/// The package's look: the system's own colours, close to Search's.
enum Look {
    static let ink = Color(nsColor: .labelColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let faint = Color(nsColor: .tertiaryLabelColor)
    static let hairline = Color(nsColor: .separatorColor)
    static let ground = Color(nsColor: .textBackgroundColor)
    static let wash = Color(nsColor: .quaternaryLabelColor).opacity(0.5)
    static let frame = Color(nsColor: .windowBackgroundColor)
    static let safe = Color(nsColor: .systemGreen)
    static let unsafe = Color(nsColor: .systemOrange)
}

/// A small borderless symbol button, as Search's own.
struct IconButton: View {
    let icon: String
    var help = ""
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Look.muted)
                .frame(width: 22, height: 22)
                .background(hovering ? Look.wash : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
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
