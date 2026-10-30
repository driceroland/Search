import SwiftUI

/// Details are optional and independent of tab layout, so resizing never
/// changes whether previews or resource information were requested.
@MainActor
final class SidebarDetailsPreferences: ObservableObject {
    static let shared = SidebarDetailsPreferences()
    private let store: UserDefaults
    @Published var showsPreviews: Bool {
        didSet { store.set(showsPreviews, forKey: "sidebar.previews") }
    }
    @Published var showsMemory: Bool {
        didSet { store.set(showsMemory, forKey: "sidebar.memory") }
    }

    init(store: UserDefaults? = nil) {
        let store = store ?? Store.settings
        self.store = store
        showsPreviews = store.bool(forKey: "sidebar.previews")
        showsMemory = store.bool(forKey: "sidebar.memory")
    }
}

/// A snapshot belongs to the hover and address that requested it, not to
/// whichever tab happens to be under the pointer when WebKit answers.
struct TabHoverRequestState {
    struct Request: Equatable {
        let token: UUID
        let tabID: UUID
        let address: URL?
    }
    private(set) var current: Request?

    mutating func begin(tabID: UUID, address: URL?) -> Request {
        let request = Request(token: UUID(), tabID: tabID, address: address)
        current = request
        return request
    }
    mutating func cancel() { current = nil }
    func accepts(_ request: Request, tabID: UUID, address: URL?, stillPresent: Bool) -> Bool {
        current == request && request.tabID == tabID && request.address == address && stillPresent
    }
    static func presentationChanged(shownPreviews: Bool?, shownMemory: Bool?, previews: Bool, memory: Bool) -> Bool {
        guard let shownPreviews, let shownMemory else { return false }
        return shownPreviews != previews || shownMemory != memory
    }
    static func canReusePreview(isPrivate: Bool, address: URL?) -> Bool { !isPrivate && address != nil }
}

enum CompactSidebarChrome {
    static func hidesLights(compact: Bool, fullscreen: Bool) -> Bool { compact && !fullscreen }
    static func topInset(compact: Bool, folded: Bool, fullscreen: Bool, immersed: Bool) -> CGFloat {
        0
    }
    static func lightsX(windowWidth: CGFloat, right: Bool, compact: Bool, sidebarWidth: CGFloat) -> CGFloat {
        right ? windowWidth - (compact ? 100 : sidebarWidth) + 26 : 26
    }
}

enum SidebarMemoryText {
    /// Binary units, kept short enough for the rail's optional bottom readout.
    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "Not measured" }
        if value >= 1_073_741_824 { return String(format: "%.1f GB", Double(value) / 1_073_741_824) }
        return "\(Int((Double(value) / 1_048_576).rounded())) MB"
    }
}
