import AppKit
import Combine
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
            session = DeveloperToolsSession(web: web, after: closing)
            DeveloperToolsKeys.install()
            FullPlugin.current?.host?.keepAwake(true, webView: web)
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
