import SwiftUI
import UniformTypeIdentifiers

// A tab on the move. Dragged along its row it slides the others aside (see
// Carried); dragged out of the window it tears off into one of its own, or
// lands in another window's row and joins that one.

extension UTType {
    /// Search's own tab: one already open, being carried between windows.
    static let searchTab = UTType(exportedAs: "app.officecommun.search.tab")
}

/// The payload of a tab drag: which tab, and the row it left.
struct TabTransfer: Codable, Transferable {
    let tabID: Tab.ID
    let from: WindowID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .searchTab)
    }
}

extension WindowModel {
    /// The tab leaves this row for a window of its own — a drag that ended
    /// over nothing. One window more, and this row is one tab shorter.
    @discardableResult
    func detach(_ tab: Tab) -> WindowModel {
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
        window.insert(freed, at: index)
        window.select(freed)
    }

    /// A tab drag landed on this row: put it where it was let go.
    func take(_ transfer: TabTransfer, at index: Int) -> Bool {
        guard let tab = profile.tab(for: transfer.tabID) else { return false }
        let from = tab.owner ?? self
        from.move(tab, to: self, at: index)
        return true
    }
}
