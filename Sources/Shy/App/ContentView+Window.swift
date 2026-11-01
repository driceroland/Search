import SwiftUI
import AppKit
import Combine

// The window around the content: its title bar, its frame and its full screen.
extension ContentView {
    /// A line that rises from the bottom, says one thing, and leaves.
    @ViewBuilder
    var announcement: some View {
        if let text = browser.announcement {
            HStack(spacing: 8) {
                Text(text)
                    .foregroundStyle(Palette.ink)
                // A file just saved: the line shows it in the Finder.
                if browser.announcedFile != nil {
                    Text("Show in Finder")
                        .foregroundStyle(Palette.muted)
                }
            }
                .font(.system(size: 12))
                .contentShape(Capsule())
                .onTapGesture {
                    if let file = browser.announcedFile { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(Palette.ground, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 18, y: 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(Motion.settle, value: browser.announcement)
        }
    }

    /// A dark pill, for the one mode this browser has. It stays up for as long
    /// as the mode does, which is how you know you are still in it.
    func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.ground.opacity(0.92))
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(Palette.ink.opacity(0.92), in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
    }

    /// The same dimmed ground and spring for every panel that floats over a
    /// page, so they read as one kind of thing.
    @ViewBuilder
    func sheet<Panel: View>(

        @ViewBuilder _ panel: () -> Panel,

        close: @escaping () -> Void
    ) -> some View {
        ZStack {
            // The floor owns the cursor; see CursorGround.
            CursorGround()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            Color.black.opacity(0.10)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            panel()
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
        .transition(.opacity)
    }

    /// True while the tabs are down the left, and not folded away (see Fold.swift).
    var sidebar: Bool {
        !browser.folded && fullscreenTab == nil
    }

    /// Either visible pane may give its page to WebKit's fullscreen window.
    /// Read through immersionRevision: a tab's going full screen and coming
    /// back are the tab's changes, not the browser's, and this view watches
    /// only the browser (see fullscreenWatch).
    var fullscreenTab: Tab? {
        _ = immersionRevision
        if let split = browser.activeSplit,
           let immersed = browser.tabs.first(where: { split.contains($0.id) && $0.immersed }) {
            return immersed
        }
        return browser.active?.immersed == true ? browser.active : nil
    }

    /// The pages on screen, watched for full screen. The page alone too: left
    /// unwatched, a video's full screen ended with nothing to draw the window
    /// again, and the column stayed away until something else did — until
    /// the column was switched off and on again, as it was reported.
    @ViewBuilder
    var fullscreenWatch: some View {
        if let split = browser.activeSplit {
            if let left = browser.tabs.first(where: { $0.id == split.left }) {
                TabImmersionWatch(tab: left) { immersing() }.id(left.id)
            }
            if let right = browser.tabs.first(where: { $0.id == split.right }) {
                TabImmersionWatch(tab: right) { immersing() }.id(right.id)
            }
        } else if let active = browser.active {
            TabImmersionWatch(tab: active) { immersing() }.id(active.id)
        }
    }

    /// A page going full screen or coming back: everything around it at
    /// once, in one transaction and without animation — the column, the
    /// strip, the card's gap and corners, the bookmarks bar, the side panel,
    /// Split View's other page, and the room the page leaves them, given
    /// with them rather than after a slide (see `make(room:after:)`). WebKit's
    /// window covers ours both ways when this happens (see Tab.immersed), so
    /// there is nothing to watch move; one at a time, each in its own turn
    /// and on its own curve, they resized the page four or five times on the
    /// way back from a YouTube video.
    private func immersing() {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            immersionRevision += 1
            roomTicket += 1
            room = chrome
        }
    }

    /// Put the resting circles in the title bar, exactly over the buttons.
    func measureLights() {
        guard let window,
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview
        else { return }

        let view = resting ?? RestingLights()
        if view.superview !== titlebar {
            view.frame = titlebar.bounds
            view.autoresizingMask = [.width, .height]
            titlebar.addSubview(view, positioned: .above, relativeTo: nil)
            resting = view
        }
        view.spots = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: titlebar) }
        view.isHidden = NSApp.isActive
    }

    /// The window, once there is one: held, dressed, and named for the page
    /// in front so its name doesn't wait for the next change.
    func setUp(_ window: NSWindow) {
        held.window = window
        dress(window)
        if let tab = browser.active { WindowTitle.set(tab, in: window) }
    }

    private func dress(_ window: NSWindow) {
        browser.window = window
        // Off screen at once, while a link's small window keeps the browser's
        // windows away (see Browsers.keepAway).
        Browsers.putAway()
        window.tabbingMode = .disallowed
        // Light or dark is the app's to say (Settings › Appearance); the
        // window only has to be the ground colour that goes with it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // A window put back in full screen is so before any notice says it.
        browser.fullScreen = window.styleMask.contains(.fullScreen)
        window.backgroundColor = browser.asCards ? Palette.NS.frame : Palette.NS.ground
        // The strip does the dragging, so the page underneath can't be grabbed
        // by accident while selecting text.
        window.isMovableByWindowBackground = false
        // Nor by its title bar, which the strip is all the way down: AppKit
        // would move the window on any drag there, a tab picked up to take
        // it elsewhere in the row included. DragStrip moves it instead. The
        // window stays movable, though — macOS's Window › Move & Resize, its
        // tiling and the tools that arrange windows ask for a movable one
        // (#286) — and is made unmovable only while the pointer is over the
        // strip (see DragStrip).
        window.isMovable = true

        // The traffic lights set in from the corner and centred in the strip's
        // height, in both modes, without a toolbar's rounder corners — see
        // Lights.swift. The column's first row is the strip's height too, so
        // its three doors sit on the lights' line.
        Lights.keep(window, centreX: { window in
            browser.prefs.sidePosition == .right
                ? window.frame.width - browser.prefs.sideWidth + Lights.centre.x
                : Lights.centre.x
        }) { measureLights() }
        DispatchQueue.main.async { measureLights() }

        // The traffic lights are drawn — measured, they paint themselves — but
        // the window shows white where they are. The content view fills the
        // whole window, title bar included, and its layer was compositing over
        // the title bar's own. AppKit's subview order said otherwise; Core
        // Animation is the one actually deciding, so it is told directly.
        DispatchQueue.main.async {
            guard let close = window.standardWindowButton(.closeButton),
                  let container = close.superview?.superview,
                  let content = window.contentView,
                  let frame = content.superview
            else { return }
            frame.addSubview(container, positioned: .above, relativeTo: content)
            container.wantsLayer = true
            container.layer?.zPosition = 10
        }
    }
}
