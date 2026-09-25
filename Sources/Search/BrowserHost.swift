import AppKit
import SwiftUI

// A second window: the same ContentView, in an NSWindow of its own. The first
// window is the SwiftUI scene; one the app opens itself — ⌘N, or a tab torn
// off — is this. It is dressed the same way, so there is nothing to learn
// about which kind of window you are in.

@MainActor
final class BrowserHost: NSObject, NSWindowDelegate {
    /// Open ones, until each is closed.
    private static var open: [BrowserHost] = []

    let model: WindowModel
    private let window: NSWindow
    private var closing = false

    /// A new window for `model`, on screen and in front.
    @discardableResult
    static func show(_ model: WindowModel) -> BrowserHost {
        let host = BrowserHost(model: model)
        open.append(host)
        if let frame = model.frameRequest {
            model.frameRequest = nil
            host.window.setFrame(frame, display: true)
        } else if let keyHost = model.profile.keyHost {
            let topLeft = NSPoint(x: keyHost.frame.minX, y: keyHost.frame.maxY)
            let p = host.window.cascadeTopLeft(from: topLeft)
            host.window.setFrameTopLeftPoint(p)
        } else {
            host.window.center()
        }
        host.window.makeKeyAndOrderFront(nil)
        model.profile.becameKey(model)
        model.askFocus()
        return host
    }

    /// The host whose window is this one, if it is one of ours.
    static func owning(_ window: NSWindow?) -> BrowserHost? {
        guard let window else { return nil }
        return open.first { $0.window === window }
    }

    private init(model: WindowModel) {
        self.model = model
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 420)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ContentView(window: model))
        model.profile.claim(window, for: model)
    }

    func windowWillClose(_ notification: Notification) {
        guard !closing else { return }
        closing = true
        window.delegate = nil
        BrowserHost.open.removeAll { $0 === self }
        model.profile.close(model)
        window.contentView = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.profile.becameKey(model)
        model.askFocus()
    }
}
