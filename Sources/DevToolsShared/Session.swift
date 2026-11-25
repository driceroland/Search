import AppKit
import SearchPluginAPI
import SwiftUI
import WebKit

// What Developer Tools Lite and Full share, compiled into each package
// (each has this folder linked in as Shared/): Lighthouse, the Recorder and
// the device toolbar, one DevToolsSession per tab that has one of them open.

/// Lighthouse, the Recorder or the device toolbar.
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

/// The package a DevToolsSession belongs to.
@MainActor
protocol DevToolsOwner: AnyObject {
    var host: SearchDevToolsHost? { get }
    /// The package's own content world.
    var world: WKContentWorld { get }
    /// The tab's shared tools have nothing left open.
    func toolsIdle(webView: WKWebView)
}

/// One tab's tools.
@MainActor
final class DevToolsSession: ObservableObject {
    /// The recorder's message handler, on the package's world only.
    static let channel = "searchDeveloper"

    weak var web: WKWebView?
    weak var plugin: DevToolsOwner?

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

    init(web: WKWebView, plugin: DevToolsOwner) {
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
            controller.removeScriptMessageHandler(forName: DevToolsSession.channel, contentWorld: world)
            controller.add(made, contentWorld: world, name: DevToolsSession.channel)
            relay = made
        } else if !on, relay != nil {
            controller.removeScriptMessageHandler(forName: DevToolsSession.channel, contentWorld: world)
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

