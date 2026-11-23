import AppKit
import SwiftUI

/// Dock side › Undock into separate window, as in Chrome DevTools: DevTools
/// in a window of its own while the page has the whole of its window.
/// Closing the window closes DevTools.
@MainActor
final class DeveloperToolsWindow: NSObject, NSWindowDelegate {
    static let shared = DeveloperToolsWindow()

    private var window: NSWindow?
    private let host = DeveloperToolsHostView()
    /// Set while Search closes the window itself, so DevTools stays open
    /// when it is docked again.
    private var dismissing = false

    /// The host, when the window is this one's.
    func host(in window: NSWindow?) -> DeveloperToolsHostView? {
        guard let window, window === self.window else { return nil }
        return host
    }

    func show(_ content: AnyView, context: DeveloperToolsContext) {
        host.context = context
        host.hosting.rootView = content
        let window = self.window ?? make()
        let session = context.session
        window.title = "DevTools - " + (session.address?.absoluteString ?? session.host)
        if !window.isVisible { window.makeKeyAndOrderFront(nil) }
    }

    func dismiss() {
        guard let window else { return }
        dismissing = true
        window.close()
        dismissing = false
        // Made again on the next undock, where the autosaved frame puts it
        // back; a closed window kept for that holds its buffers meanwhile.
        window.delegate = nil
        self.window = nil
        host.context = nil
        host.hosting.rootView = AnyView(EmptyView())
    }

    private func make() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 240)
        window.contentView = host
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("Search Developer Tools")
        window.tabbingMode = .disallowed
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard !dismissing, let session = host.context?.session else { return }
        host.context = nil
        // After the close is done, so the dock's anchor going away finds
        // the window already shut.
        DispatchQueue.main.async {
            DeveloperTools.shared.close(ifCurrent: session)
        }
    }
}

