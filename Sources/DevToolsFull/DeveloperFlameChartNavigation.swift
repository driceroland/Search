import CoreGraphics
import Foundation

/// Chrome's Settings › Preferences › Performance › "Flamechart mouse wheel
/// action": what scrolling over the Performance flame chart does.
///
/// Modern, the default: scrolling moves the rows up and down and pans
/// across, Shift-scroll pans across, and ⌘- or Control-scroll zooms.
/// Classic: scrolling zooms around the pointer, and Shift-scroll moves the
/// rows up and down.
enum DeveloperFlameChartNavigation: String, CaseIterable, Identifiable {
    case modern
    case classic

    static let key = "developerTools.performance.flameChartNavigation"

    /// The choice saved in Settings, or Modern when there is none.
    static var current: Self {
        DevDefaults.store.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .modern
    }

    var id: Self { self }

    var title: String {
        switch self {
        case .modern: "Modern"
        case .classic: "Classic"
        }
    }

    /// What one scroll does to the chart: how far to zoom (in scroll
    /// points, positive zooming in), pan across, and move the rows.
    struct Move: Equatable {
        var zoom: CGFloat = 0
        var pan: CGFloat = 0
        var scroll: CGFloat = 0
    }

    /// The move for a scroll of `dx` across and `dy` down. `zoomKey` is ⌘
    /// or Control held. A mouse wheel with Shift held comes in from macOS
    /// as a sideways scroll, so either axis counts for Shift.
    func move(dx: CGFloat, dy: CGFloat, zoomKey: Bool, shift: Bool) -> Move {
        if zoomKey { return Move(zoom: dy) }
        switch self {
        case .modern:
            if shift, dx == 0 { return Move(pan: dy) }
            return Move(pan: dx, scroll: dy)
        case .classic:
            if shift { return Move(scroll: dy != 0 ? dy : dx) }
            return Move(zoom: dy, pan: dx)
        }
    }
}
