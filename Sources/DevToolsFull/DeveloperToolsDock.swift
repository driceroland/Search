import AppKit
import Combine
import SearchPluginAPI
import WebKit

enum DeveloperPanel: String, CaseIterable, Identifiable {
    case elements = "Elements"
    case console = "Console"
    case network = "Network"
    case sources = "Sources"
    case storage = "Application"
    case performance = "Performance"
    case memory = "Memory"
    case lighthouse = "Lighthouse"
    case recorder = "Recorder"

    var id: Self { self }

    var icon: String {
        switch self {
        case .elements: "chevron.left.forwardslash.chevron.right"
        case .console: "apple.terminal"
        case .network: "point.3.connected.trianglepath.dotted"
        case .sources: "doc.text"
        case .storage: "externaldrive"
        case .performance: "waveform.path"
        case .memory: "memorychip"
        case .lighthouse: "gauge.with.needle"
        case .recorder: "record.circle"
        }
    }
}

/// Built-in and extension pages share the strip, including its overflow.
enum DeveloperToolsTab: Hashable {
    case panel(DeveloperPanel)
    case extensionPanel(String)
}

/// A session's view of the extension panels. Search owns their pages and
/// grants them access to the inspected tab. The package only mounts a view.
@MainActor
final class DeveloperExtensionPanelState: ObservableObject {
    struct Item: Identifiable {
        let id: String
        let title: String
        let icon: NSImage?
    }

    struct Selection {
        let id: String
        let view: NSView?
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var selection: Selection?
    private weak var web: WKWebView?
    private weak var host: SearchDevToolsExtensionHost?
    private var changingSelection = false

    func start(in web: WKWebView, host: SearchDevToolsHost) {
        guard !host.isPrivate(web), let host = host as? SearchDevToolsExtensionHost else { return }
        self.web = web
        self.host = host
        host.startExtensionPanels(in: web) { [weak self, weak web] in
            guard let self, let web, self.web === web else { return }
            self.refresh()
        }
        refresh()
    }

    func stop() {
        let web = self.web
        let host = self.host
        self.web = nil
        self.host = nil
        if !items.isEmpty { items = [] }
        if selection != nil { selection = nil }
        if let web { host?.stopExtensionPanels(in: web) }
    }

    func item(_ id: String) -> Item? { items.first { $0.id == id } }

    func select(_ id: String?) {
        guard let host, let web, !changingSelection else { return }
        if let id, item(id) == nil { return }
        guard id != selection?.id else { return }
        changingSelection = true
        defer { changingSelection = false }
        let view = host.showExtensionPanel(id, in: web)
        let shown = host.selectedExtensionPanel(in: web)
        if let id, shown == id, item(id) != nil {
            selection = Selection(id: id, view: view)
        } else if shown == nil {
            selection = nil
        }
    }

    private func refresh() {
        guard let host, let web else { return }
        items = host.extensionPanels(in: web).compactMap { row in
            guard let id = row["id"], let title = row["title"] else { return nil }
            return Item(id: id, title: title, icon: host.extensionPanelIcon(id, in: web))
        }
        guard !changingSelection else { return }
        if let selected = host.selectedExtensionPanel(in: web), item(selected) != nil {
            select(selected)
        } else if selection != nil {
            selection = nil
        }
    }
}

enum DeveloperDockPosition: String, CaseIterable, Identifiable {
    /// As in Chrome DevTools' Dock side: undocked into a window of its own
    /// first, then left, bottom and right.
    case window, left, bottom, right

    var id: Self { self }
    var vertical: Bool { self == .bottom }
    var title: String { self == .window ? "Undock into separate window" : "Dock to " + rawValue }
    var icon: String {
        switch self {
        case .window: "macwindow.on.rectangle"
        case .left: "rectangle.lefthalf.inset.filled"
        case .bottom: "rectangle.bottomhalf.inset.filled"
        case .right: "rectangle.righthalf.inset.filled"
        }
    }
}

/// The one inspection session, on one tab at a time, as the package's
/// dock shows it (FullPlugin.dockView).
@MainActor
final class DeveloperTools: ObservableObject {
    static let shared = DeveloperTools()
    private static let dockKey = "developerTools.dock"
    @Published private(set) var session: DeveloperToolsSession?
    @Published var dockPosition = DevDefaults.store.string(forKey: dockKey).flatMap(DeveloperDockPosition.init) ?? .bottom {
        didSet {
            DevDefaults.store.set(dockPosition.rawValue, forKey: Self.dockKey)
            FullPlugin.current?.host?.invalidate()
        }
    }
    private var closing: Task<Void, Never>?

    /// The panel's size along the window, kept apart for the bottom and
    /// the sides, as Chrome keeps them.
    func dockSize(vertical: Bool) -> Double {
        let kept = DevDefaults.store.double(forKey: vertical ? "developerTools.dock.height" : "developerTools.dock.width")
        return kept > 0 ? kept : (vertical ? 338 : 485)
    }

    func setDockSize(_ size: Double, vertical: Bool) {
        DevDefaults.store.set(max(vertical ? 182 : 270, size), forKey: vertical ? "developerTools.dock.height" : "developerTools.dock.width")
        FullPlugin.current?.host?.invalidate()
    }

    @discardableResult
    func open(web: WKWebView, panel: DeveloperPanel, point: NSPoint? = nil) -> DeveloperToolsSession {
        if session?.web !== web || session?.connectionFailed == true {
            close()
            let opened = DeveloperToolsSession(web: web, after: closing)
            session = opened
            DeveloperToolsKeys.install()
            if let host = FullPlugin.current?.host {
                host.keepAwake(true, webView: web)
                opened.extensionPanels.start(in: web, host: host)
            }
        }
        let session = session!
        session.select(panel)
        if let point { session.inspect(at: point) }
        FullPlugin.current?.host?.invalidate()
        return session
    }

    func close(ifCurrent inspected: DeveloperToolsSession) {
        if session === inspected { close() }
    }

    @discardableResult
    func close() -> Task<Void, Never>? {
        if let session {
            closing = session.disconnect()
            if let web = session.web {
                FullPlugin.current?.host?.keepAwake(false, webView: web)
                FullPlugin.current?.host?.rearm(web)
            }
            self.session = nil
            DeveloperToolsKeys.uninstall()
            DeveloperToolsWindow.shared.dismiss()
            DeveloperResponseMedia.clear()
            FullPlugin.current?.host?.invalidate()
        }
        return closing
    }

    func isOpen(on web: WKWebView) -> Bool { session?.web === web }

    /// ⌃⇧⌘D: the next side, bottom, right, left.
    func toggleDockSide() {
        dockPosition = switch dockPosition { case .bottom: .right; case .right: .left; default: .bottom }
    }
}
