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
    case sensors = "Sensors"
    case rendering = "Rendering"
    case security = "Security"

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
        case .sensors: "location.viewfinder"
        case .rendering: "paintbrush"
        case .security: "lock.shield"
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

/// One local inspection session. Only its dock observes diagnostics updates.
@MainActor
final class DeveloperTools: ObservableObject {
    static let shared = DeveloperTools()
    private static let dockKey = "developerTools.dock"
    @Published private(set) var session: DeveloperToolsSession?
    private static let previousDockKey = "developerTools.dock.previous"
    @Published var dockPosition = Store.settings.string(forKey: dockKey).flatMap(DeveloperDockPosition.init) ?? .bottom {
        didSet {
            Store.settings.set(dockPosition.rawValue, forKey: Self.dockKey)
            if oldValue != dockPosition {
                previousDockPosition = oldValue
                Store.settings.set(oldValue.rawValue, forKey: Self.previousDockKey)
            }
        }
    }
    /// The side ⇧⌘D goes back to, as Chrome's "Toggle dock side" does.
    private(set) var previousDockPosition = Store.settings.string(forKey: previousDockKey)
        .flatMap(DeveloperDockPosition.init) ?? .right
    private var closing: Task<Void, Never>?

    // One key monitor for DevTools (DeveloperToolsKeys.takeFirst): the
    // Sources code view's keys (⌘F, ⌃G), then the Elements panel's ⌘F, ⌘G,
    // ⌘Z and clipboard keys, then DevTools' own (⇧⌘P, ⌘[, Esc). The
    // browser window's monitor asks it first too.
    init() {
        DeveloperToolsKeys.install()
    }

    /// ⇧⌘D: back to the dock side used before this one.
    func toggleDockSide() {
        dockPosition = previousDockPosition == dockPosition
            ? (dockPosition == .bottom ? .right : .bottom) : previousDockPosition
    }

    @discardableResult
    func open(in browser: Browser, panel: DeveloperPanel, web: WKWebView? = nil, point: NSPoint? = nil) -> Bool {
        guard let tab = browser.active, tab.isWeb, !tab.floating,
              let target = tab.built, web == nil || web === target else { return false }
        if session?.web !== target || session?.connectionFailed == true {
            close()
            session = DeveloperToolsSession(tab: tab, web: target, after: closing)
        }
        guard let session else { return false }
        session.select(panel)
        if let point { session.inspect(at: point) }
        return true
    }

    func close(ifCurrent inspected: DeveloperToolsSession) {
        if session === inspected { close() }
    }

    @discardableResult
    func close() -> Task<Void, Never>? {
        if let session {
            closing = session.disconnect()
            self.session = nil
        }
        return closing
    }

    static func isOpen(for tab: Tab) -> Bool { shared.session?.tab === tab }
}

extension Browser {
    /// ⇧⌘C. As in Chrome DevTools, while DevTools is open for the page it
    /// picks an element (pressed again, the picking stops); otherwise the
    /// address is copied, as before.
    func copyAddressOrPickElement() {
        if prefs.devTools, let tab = active, DeveloperTools.isOpen(for: tab) {
            inspectElement()
        } else {
            copyAddress()
        }
    }
}
