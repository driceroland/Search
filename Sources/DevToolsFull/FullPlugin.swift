import AppKit
import SearchPluginAPI
import SwiftUI
import WebKit

// Developer Tools Full: Chrome-style developer tools docked beside the
// page, as a package Search downloads on request (Settings › About ›
// Developer). Elements and Styles, Console, Sources and the debugger,
// Network, Application, Performance, Memory, CSS overview, Coverage and
// Issues, with Lite's Lighthouse, Recorder and device toolbar (Shared/).
// With this package the one View › Developer uses, ⌥⌘I, ⌥⌘J and ⌥⌘C open
// it; View › Web Inspector is still WebKit's own.
//
// What a page can see of it, and what it can't:
//   - The panels read the page through WebKit's inspector, the one Web
//     Inspector uses, connected without its window (DeveloperInspectorLink
//     is the only file that touches it, and asks for every name first: a
//     WebKit without them shows "Not available on this macOS"). Its
//     scripts run in the inspector's own page, not the site's.
//   - What runs in the site's document runs in the package's own content
//     world (the host's isolatedWorld), only on the tab the tools are open
//     on, and comes out when they close; the page sees no variable of it and
//     reaches no handler. The one page-world script is Lite's sensor
//     override (Shared/DeviceToolbar.swift): values only, no globals.
//   - The Console runs what you type in the page, as any console does.
//   - Nothing is kept but the choices made in the tools, in the package's
//     own store (host.defaults), and nothing a page showed them: the
//     Console's history lives for the session; a private tab keeps no
//     breakpoint, watch or override. Reports, screenshots and response
//     bodies go to a file only through a save panel.

/// The package's principal class (Info.plist NSPrincipalClass).
@objc(SearchDevToolsFull)
@MainActor
public final class FullPlugin: NSObject, SearchDevToolsPlugin, DevToolsOwner {
    public static var apiVersion: Int { SearchDevToolsAPI.version }

    static weak var current: FullPlugin?

    private(set) var host: SearchDevToolsHost?
    /// Lighthouse, the Recorder and the device toolbar, each tab its own.
    private var shared: [ObjectIdentifier: DevToolsSession] = [:]
    private var bars: [ObjectIdentifier: NSView] = [:]
    /// The dock's view, made once for the session it shows.
    private var dock: (session: ObjectIdentifier, view: DeveloperToolsHostView)?

    override public required init() { super.init() }

    public func start(host: SearchDevToolsHost) {
        self.host = host
        Self.current = self
        DevHost.host = host
        DevDefaults.store = host.defaults
        DeveloperResponseMedia.clear()
    }

    public func shutdown() {
        DeveloperTools.shared.close()
        DeveloperResponseMedia.clear()
        for session in shared.values {
            session.end()
            if let web = session.web { host?.rearm(web); host?.keepAwake(false, webView: web) }
        }
        shared.removeAll()
        bars.removeAll()
        dock = nil
        host?.invalidate()
    }

    var world: WKContentWorld { host?.isolatedWorld ?? .defaultClient }

    public func menuItems() -> [[String: String]] {
        [["id": "devtools", "title": "Developer Tools"], ["id": "console", "title": "Console"],
         ["id": "pick", "title": "Inspect Element"]]
            + DevTool.allCases.map { ["id": $0.rawValue, "title": $0.title] }
    }

    // MARK: - the tab's tools

    /// The tab's Lighthouse, Recorder and device toolbar.
    func sharedSession(_ web: WKWebView, making: Bool = true) -> DevToolsSession? {
        if let made = shared[ObjectIdentifier(web)] { return made }
        guard making else { return nil }
        let made = DevToolsSession(web: web, plugin: self)
        shared[ObjectIdentifier(web)] = made
        host?.keepAwake(true, webView: web)
        return made
    }

    public func open(_ item: String, webView: WKWebView) {
        let tools = DeveloperTools.shared
        switch item {
        case "devtools":
            if tools.isOpen(on: webView) { tools.close() } else { tools.open(web: webView, panel: tools.session?.panel ?? .elements) }
        case "console":
            tools.open(web: webView, panel: .console)
        case "pick":
            let session = tools.open(web: webView, panel: .elements)
            session.togglePicker()
        case DevTool.lighthouse.rawValue:
            _ = sharedSession(webView)
            tools.open(web: webView, panel: .lighthouse)
        case DevTool.recorder.rawValue:
            _ = sharedSession(webView)
            tools.open(web: webView, panel: .recorder)
        case DevTool.device.rawValue:
            guard let session = sharedSession(webView) else { return }
            session.device.on.toggle()
            if session.idle { toolsIdle(webView: webView) }
        default:
            return
        }
        host?.invalidate()
    }

    /// The device toolbar off and no Lighthouse run or recording going:
    /// its session goes, with what it put in the page.
    func toolsIdle(webView: WKWebView) {
        let id = ObjectIdentifier(webView)
        guard let session = shared[id], session.idle else { return }
        shared[id] = nil
        bars[id] = nil
        session.end()
        host?.rearm(webView)
        if !DeveloperTools.shared.isOpen(on: webView) { host?.keepAwake(false, webView: webView) }
        host?.invalidate()
    }

    public func close(webView: WKWebView) {
        if DeveloperTools.shared.isOpen(on: webView) { DeveloperTools.shared.close() }
        let id = ObjectIdentifier(webView)
        if let session = shared.removeValue(forKey: id) {
            session.end()
            bars[id] = nil
            host?.rearm(webView)
            host?.keepAwake(false, webView: webView)
        }
        host?.invalidate()
    }

    public func isOpen(webView: WKWebView) -> Bool {
        DeveloperTools.shared.isOpen(on: webView) || shared[ObjectIdentifier(webView)] != nil
    }

    public func keyDown(_ event: NSEvent, webView: WKWebView) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // F12 on the page, as in Chrome; in the tools it closes them
        // (DeveloperToolsKeys).
        if event.keyCode == DeveloperToolsKeyRouting.f12, flags.isEmpty,
           DeveloperToolsKeys.host(of: event.window?.firstResponder) == nil {
            open("devtools", webView: webView)
            return true
        }
        guard DeveloperTools.shared.session != nil else { return false }
        return DeveloperToolsKeys.takeFirst(event)
    }

    public func inspect(at point: NSPoint, webView: WKWebView) -> Bool {
        DeveloperTools.shared.open(web: webView, panel: .elements, point: point)
        return true
    }

    // MARK: - around the page

    public func dockView(webView: WKWebView) -> NSView? {
        let tools = DeveloperTools.shared
        guard let session = tools.session, session.web === webView else { return nil }
        let context = DeveloperToolsContext(session: session, tools: tools, shell: DeveloperToolsShell.shared)
        let root = AnyView(DeveloperToolsRoot(session: session, tools: tools).id(ObjectIdentifier(session)))
        if tools.dockPosition == .window {
            // Keep a host-owned extension view in only one view tree.
            dock?.view.hosting.rootView = AnyView(EmptyView())
            dock = nil
            DeveloperToolsWindow.shared.show(root, context: context)
            return nil
        }
        DeveloperToolsWindow.shared.dismiss()
        let view: DeveloperToolsHostView
        if let dock, dock.session == ObjectIdentifier(session) {
            view = dock.view
        } else {
            view = DeveloperToolsHostView()
            dock = (ObjectIdentifier(session), view)
        }
        view.context = context
        view.hosting.rootView = root
        return view
    }

    public func dockPlacement(webView: WKWebView) -> [String: Any]? {
        let position = DeveloperTools.shared.dockPosition
        return ["edge": position.rawValue, "size": DeveloperTools.shared.dockSize(vertical: position.vertical)]
    }

    public func setDockSize(_ size: Double, webView: WKWebView) {
        DeveloperTools.shared.setDockSize(size, vertical: DeveloperTools.shared.dockPosition.vertical)
    }

    public func barView(webView: WKWebView) -> NSView? {
        let id = ObjectIdentifier(webView)
        guard let session = shared[id], session.device.on else { return nil }
        if let made = bars[id] { return made }
        let view = NSHostingView(rootView: DeviceBar(device: session.device))
        bars[id] = view
        return view
    }

    public func viewportSize(webView: WKWebView) -> NSValue? {
        guard let device = shared[ObjectIdentifier(webView)]?.device, device.on else { return nil }
        return NSValue(size: device.size)
    }

    // MARK: - the page

    public func scripts(webView: WKWebView) -> [WKUserScript] {
        let mine = shared[ObjectIdentifier(webView)]?.scripts() ?? []
        guard let session = DeveloperTools.shared.session, session.web === webView else { return mine }
        return mine + session.pageScripts()
    }

    public func didReceiveResponse(_ response: URLResponse, webView: WKWebView) {
        shared[ObjectIdentifier(webView)]?.response = response as? HTTPURLResponse
    }

    public func tabWillUnload(webView: WKWebView) {
        if DeveloperTools.shared.isOpen(on: webView) { DeveloperTools.shared.close() }
        let id = ObjectIdentifier(webView)
        if let session = shared.removeValue(forKey: id) {
            session.end(quietly: true)
            bars[id] = nil
        }
        host?.invalidate()
    }

    public func perform(_ command: String, arguments: [String: Any], webView: WKWebView?,
                        completion: @escaping ([String: Any]) -> Void) {
        FullAutomation.perform(command, arguments, webView, plugin: self, completion: completion)
    }
}

/// The dock's content: the tools for the session, with their sheets.
struct DeveloperToolsRoot: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var tools: DeveloperTools

    var body: some View {
        DeveloperToolsView(session: session, tools: tools, extensionPanels: session.extensionPanels, retry: {
            if let web = session.web { tools.close(); tools.open(web: web, panel: session.panel) }
        })
        .overlay { DeveloperSheetLayer() }
        .defaultAppStorage(DevDefaults.store)
    }
}
