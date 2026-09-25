import AppKit
import SwiftUI

// A tab on the move. Dragged along its row it slides the others aside (see
// Carried); dragged out of the window it tears off into one of its own, or
// lands in another window's row and joins that one.

extension WindowModel {
    /// The tab leaves this row for a window of its own — a drag that ended
    /// over nothing. One window more, and this row is one tab shorter.
    @discardableResult
    func detach(_ tab: Tab, at point: NSPoint? = nil) -> WindowModel {
        let freed = release(tab)
        let model = profile.open(space: spaceID)
        // open() puts a blank tab in the new window; the one being carried
        // is what the window is for.
        for blank in model.tabs where blank.isBlank {
            model.release(blank)
            blank.close()
        }
        model.insert(freed, at: 0)
        model.select(freed)
        if let point, let host = profile.host(of: model) {
            let x = max(0, point.x - 120)
            let y = max(0, point.y + 20)
            host.setFrameTopLeftPoint(NSPoint(x: x, y: y))
        }
        // A row left with nothing is a window with nothing to show. Close it
        // once the new one is up, so tearing off the only tab replaces the
        // window rather than leaving an empty one behind.
        if tabs.isEmpty {
            profile.close(self)
        }
        return model
    }

    /// The tab joins another window's row at `index`. Same window: a move
    /// along the row, as the row's own drag does it.
    func move(_ tab: Tab, to window: WindowModel, at index: Int) {
        guard window !== self else {
            move(tab, to: index)
            return
        }
        let freed = release(tab)
        window.insert(freed, at: min(index, window.tabs.count))
        window.select(freed)
        if tabs.isEmpty {
            profile.close(self)
        }
    }

    /// Which slot in the row a drop at `screenPoint` falls into.
    func insertionIndex(at screenPoint: NSPoint) -> Int {
        guard let host = profile.host(of: self) else { return tabs.count }
        if profile.prefs.sidebar && !folded {
            let yFromTop = host.frame.maxY - screenPoint.y - 40
            let idx = Int(max(0, yFromTop) / 28)
            return min(max(0, idx), tabs.count)
        } else {
            let xFromLeft = screenPoint.x - host.frame.minX - Metrics.lights
            guard xFromLeft > 0, !tabs.isEmpty else { return 0 }
            let avail = max(100, host.frame.width - Metrics.lights - 100)
            let tabWidth = avail / CGFloat(tabs.count)
            let idx = Int(xFromLeft / tabWidth)
            return min(max(0, idx), tabs.count)
        }
    }
}
