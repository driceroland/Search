import SwiftUI

public enum TopToolbarItem: String, CaseIterable, Identifiable {
    case windowControls, address, sidebar, spaces, extensions, bookmarks, history, downloads, settings, back, forward, reload, tools

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .windowControls: return "Window Controls"
        case .address: return "Address"
        case .sidebar: return "Sidebar"
        case .spaces: return "Spaces"
        case .extensions: return "Extensions"
        case .bookmarks: return "Bookmarks"
        case .history: return "History"
        case .downloads: return "Downloads"
        case .settings: return "Settings"
        case .back: return "Back"
        case .forward: return "Forward"
        case .reload: return "Reload / Stop"
        case .tools: return "More tools (…)"
        }
    }
}

@MainActor
public final class TopToolbarPreferences: ObservableObject {
    public static let shared = TopToolbarPreferences()
    public static let enabledKey = "top.toolbar.enabled"
    public static let key = "top.toolbar.items"

    private let store: UserDefaults

    @Published public var enabled: Bool {
        didSet { store.set(enabled, forKey: Self.enabledKey) }
    }

    @Published public private(set) var items: Set<TopToolbarItem> {
        didSet {
            store.set(TopToolbarItem.allCases.filter { items.contains($0) }.map(\.rawValue), forKey: Self.key)
        }
    }

    public init(store: UserDefaults? = nil) {
        let store = store ?? Store.settings
        self.store = store
        enabled = store.object(forKey: Self.enabledKey) == nil ? true : store.bool(forKey: Self.enabledKey)
        if let saved = store.stringArray(forKey: Self.key) {
            items = Set(saved.compactMap(TopToolbarItem.init))
        } else {
            items = [.windowControls, .address, .sidebar, .extensions, .downloads, .tools]
        }
    }

    public func contains(_ item: TopToolbarItem) -> Bool { items.contains(item) }

    public func set(_ item: TopToolbarItem, visible: Bool) {
        if visible { items.insert(item) } else { items.remove(item) }
    }

    public func showAll() { items = Set(TopToolbarItem.allCases) }
    public func hideAll() { items = [] }

    public func binding(for item: TopToolbarItem) -> Binding<Bool> {
        Binding(get: { self.contains(item) }, set: { self.set(item, visible: $0) })
    }
}

public enum TopToolbarRevealPolicy {
    public static let height: CGFloat = 44
    public static let triggerHeight: CGFloat = 6
    public static let revealDelay: TimeInterval = 0
    public static let hideDelay: TimeInterval = 0.15
    public static let animationDuration: TimeInterval = 0.20
    // Helium 790ea617, zen-mode.patch; Chromium FAST_OUT_SLOW_IN_3.
    public static let bezier: [Double] = [0.2, 0, 0, 1]
    public static let cursorExitGrace: TimeInterval = 3
    public static let hoverLeeway: CGFloat = 8

    static func animation(duration: TimeInterval = animationDuration) -> Animation? {
        Motion.reduced ? nil : .timingCurve(bezier[0], bezier[1], bezier[2], bezier[3], duration: duration)
    }
    static func duration(current: Double, showing: Bool) -> TimeInterval {
        let value = min(1, max(0, current))
        return animationDuration * (showing ? 1 - value : value)
    }
    /// Solve the cubic's x coordinate first; t is not elapsed-time progress.
    static func progress(at elapsed: Double) -> Double {
        let x = min(1, max(0, elapsed))
        if x == 0 || x == 1 { return x }
        func cubic(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
        }
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let t = (low + high) / 2
            if cubic(t, bezier[0], bezier[2]) < x { low = t } else { high = t }
        }
        return cubic((low + high) / 2, bezier[1], bezier[3])
    }


    public static func eligible(compact: Bool, fullscreen: Bool, immersed: Bool, enabled: Bool, hasItems: Bool) -> Bool {
        compact && enabled && hasItems && !fullscreen && !immersed
    }

    public static func shouldHold(pointerInside: Bool, editing: Bool, popup: Bool, menuTracking: Bool) -> Bool {
        pointerInside || editing || popup || menuTracking
    }

    public static func showsWindowControls(selected: Bool, revealed: Bool, fullscreen: Bool) -> Bool {
        selected && revealed && !fullscreen
    }
}

/// Reserve real space above all browsing content; tools take their measured
/// intrinsic width before the address receives the remainder.
enum TopToolbarLayoutPolicy {
    struct Widths { let address: CGFloat; let trailing: CGFloat }
    static func contentInset(eligible: Bool, revealed: Bool) -> CGFloat {
        eligible && revealed ? TopToolbarRevealPolicy.height : 0
    }
    static func widths(total: CGFloat, leading: CGFloat, trailing: CGFloat, hasAddress: Bool) -> Widths {
        let available = max(0, total - 20 - leading)
        let gap: CGFloat = hasAddress && trailing > 0 ? 6 : 0
        let minimum = hasAddress ? min(140, max(0, available - gap)) : 0
        let tools = min(max(0, trailing), max(0, available - minimum - gap))
        return Widths(address: hasAddress ? max(0, available - tools - gap) : 0, trailing: tools)
    }
}
