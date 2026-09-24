import AppKit

// File › Share…: the page, wherever the Mac would send it — Mail, Messages,
// AirDrop, Notes, anything else registered. Safari has a button for this on
// its toolbar; this app has no toolbar, so it lives in the File menu instead.

extension Browser {
    /// With no button to open under, the picker opens from the top right
    /// corner of the page, about where Safari keeps its Share button: just
    /// under the row when the tabs are across the top, and beside the
    /// column's page otherwise. The window's own corner is the fallback.
    func share() {
        guard let url = active?.address, let window = Links.window,
              let view = active?.built.flatMap({ $0.window === window ? $0 : nil }) ?? window.contentView
        else { return }
        // A few points in from the corner, so the arrow points at the page
        // rather than at its edge. Flipped or not, the picker hangs below.
        let inset: CGFloat = 12
        let y = view.isFlipped ? inset : view.bounds.maxY - inset
        let anchor = NSRect(x: view.bounds.maxX - inset, y: y, width: 1, height: 1)
        NSSharingServicePicker(items: [url]).show(relativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }
}
