import SwiftUI
import AppKit
import Combine

// The pieces of the menus and the window ShyApp is built from.

/// Quit Shy, which can ask first (Settings › General), and Help. One
/// value, because a scene's commands take at most ten.
struct QuitAndHelp: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            Button("Quit Shy") {
                if Links.shouldQuit() { NSApp.terminate(nil) }
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        CommandGroup(replacing: .help) {
            Button("Send Feedback…") { Links.writeFeedback() }
        }
    }
}

/// A page, as a line in a menu: its icon if one is known, and its name.
struct MenuLine: View {
    let title: String
    let url: URL
    let profile: UUID

    var body: some View {
        if let icon = Favicons.of(profile).cached(for: url) {
            Label {
                Text(title)
            } icon: {
                Image(nsImage: MenuLine.small(icon))
            }
        } else {
            Text(title)
        }
    }

    /// The cached icon is sixty-four points across; a menu wants sixteen.
    private static func small(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

/// The base a sheet draws on, and the reason a panel is legible over a page
/// that has hidden its own cursor.
///
/// WebKit turns `cursor: none` into an AppKit cursor rect over the whole web
/// view. SwiftUI panels layered on top add no rect of their own, so when the
/// pointer crosses from the page into a sheet the invisible rect still wins,
/// and the sheet reads as empty air. This gives the sheet one arrow-sized
/// rect to win with, frontmost because its NSView sits above the web view
/// (a sheet is drawn by `.overlay { panels }` on `ContentView.body`).
struct CursorGround: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorGroundView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class CursorGroundView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // Re-arm the rect each time this view joins a window or changes size, so
    // AppKit notices it even if the pointer has not moved since the sheet
    // appeared. Without this the arrow only shows after a twitch.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }
}

final class WeakWindow {
    weak var window: NSWindow?
}
