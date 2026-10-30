import SwiftUI

/// Shared width policy for the titled sidebar and its compact icon rail.
enum SidebarResize {
    static let collapsedWidth: CGFloat = 42
    static let expandedMin: CGFloat = 160
    static let expandedMax: CGFloat = 440
    /// Midpoint between the 42pt rail and 160pt titled minimum (101pt).
    static let snapThreshold: CGFloat = (collapsedWidth + expandedMin) / 2

    static func isCollapsed(width: CGFloat) -> Bool { width < snapThreshold }

    static func width(for proposed: CGFloat, expanded: Bool) -> CGFloat {
        return expanded ? min(expandedMax, max(expandedMin, proposed)) : collapsedWidth
    }

    static func proposedWidth(start: CGFloat, translation: CGFloat, position: SidebarPosition) -> CGFloat {
        start + (position == .right ? -translation : translation)
    }

    /// Nil means an interrupted gesture must not commit its tentative state;
    /// otherwise, whether the edge snapped in to the rail.
    static func finish(start: CGFloat, proposed: CGFloat, position: SidebarPosition, interrupted: Bool = false) -> Bool? {
        guard !interrupted else { return nil }
        _ = start
        _ = position
        return isCollapsed(width: proposed)
    }

    /// In, the edge snaps to the rail — the dynamic look, and its 42 points. Out,
    /// the titled column comes back at the width it was pulled to.
    @MainActor
    static func apply(proposed: CGFloat, to prefs: Preferences) {
        if isCollapsed(width: proposed) {
            if prefs.iconsStyle != .dynamic { prefs.iconsStyle = .dynamic }
            prefs.sideIcons = true
        } else {
            prefs.sideIcons = false
            prefs.sideWidth = savedWidth(current: prefs.sideWidth, proposed: proposed, collapsed: false)
        }
    }

    /// Keep the remembered expanded width untouched while the rail is selected.
    static func savedWidth(current: CGFloat, proposed: CGFloat, collapsed: Bool) -> CGFloat {
        collapsed ? current : width(for: proposed, expanded: true)
    }
}

/// Kept outside SideBar's conditional content so drag tracking survives style swaps.
struct SidebarResizeHandle: View {
    @ObservedObject var prefs: Preferences
    @State private var start: CGFloat?
    @State private var hovering = false

    private var innerEdge: Alignment { prefs.sidePosition == .right ? .leading : .trailing }

    var body: some View {
        Rectangle()
            .fill(Palette.ink.opacity(hovering ? 0.18 : 0))
            .frame(width: hovering ? 2 : 1)
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { over in
                hovering = over
                (over ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            }
            .onDisappear { start = nil; if hovering { NSCursor.arrow.set() } }
            .onChange(of: prefs.sidePosition) { _, _ in start = nil }
            .onChange(of: prefs.sidebar) { _, _ in start = nil }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if start == nil { start = prefs.iconDynamic ? SidebarResize.collapsedWidth : prefs.sideWidth }
                    let base = start ?? prefs.sideWidth
                    let proposed = SidebarResize.proposedWidth(start: base, translation: value.translation.width, position: prefs.sidePosition)
                    SidebarResize.apply(proposed: proposed, to: prefs)
                }
                .onEnded { _ in start = nil })
            .modifier(OneClick(double: true) {
                if prefs.iconDynamic {
                    prefs.sideIcons = false
                    prefs.sideWidth = max(Metrics.side, SidebarResize.expandedMin)
                } else { prefs.sideWidth = Metrics.side }
            })
    }
}
