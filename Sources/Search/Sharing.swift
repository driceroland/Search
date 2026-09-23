import SwiftUI
import AppKit

// File › Share…: the page, wherever the Mac would send it — Mail, Messages,
// AirDrop, Notes, anything else registered. Safari has a button for this on
// its toolbar; this app has no toolbar, so it lives in the File menu instead,
// and — Settings › Tabs willing — a door of its own beside the bookmarks.

extension Browser {
    /// From the door, the picker opens under it, the way the bookmarks
    /// dropdown does. From the File menu there is no door to open under, so
    /// it centers on the window instead.
    func share(from door: NSView? = nil) {
        guard let url = active?.address else { return }
        let picker = NSSharingServicePicker(items: [url])
        if let door {
            picker.show(relativeTo: door.bounds, of: door, preferredEdge: .minY)
            return
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frameAutosaveName == "search" }),
              let view = window.contentView
        else { return }
        let anchor = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }
}

/// A door's own spot in the window, read back out as a real NSView so
/// something AppKit-only — the share picker among them — can open under it
/// exactly the way a SwiftUI popover would.
struct DoorAnchor: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let made = NSView()
        DispatchQueue.main.async { view = made }
        return made
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
