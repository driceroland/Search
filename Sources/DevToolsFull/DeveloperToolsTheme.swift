import AppKit
import SwiftUI

/// Settings › Preferences › Appearance › Theme, as Chrome has it: DevTools
/// follows the browser's appearance (Chrome's "System preference"), or is
/// light or dark whatever the browser is. Kept across launches.
/// DeveloperToolsHostView puts it on the views DevTools is drawn in; a
/// sheet, drawn by the window rather than inside them, takes it with
/// `.developerToolsThemed()`.
enum DeveloperToolsTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: return "System preference"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Nil follows the window, which follows the browser's own Look.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// The theme chosen, published for the host views and Settings.
@MainActor
final class DeveloperToolsThemeStore: ObservableObject {
    static let shared = DeveloperToolsThemeStore()
    static let key = "search.devtools.theme"

    @Published var theme: DeveloperToolsTheme {
        didSet { DevDefaults.store.set(theme.rawValue, forKey: Self.key) }
    }

    private init() {
        theme = DeveloperToolsTheme(rawValue: DevDefaults.store.string(forKey: Self.key) ?? "") ?? .system
    }
}

/// A view in DevTools' chosen theme, for one drawn outside the host views.
private struct DeveloperToolsThemed<Content: View>: View {
    @ObservedObject private var store = DeveloperToolsThemeStore.shared
    @Environment(\.colorScheme) private var scheme
    let content: Content

    init(content: Content) { self.content = content }

    var body: some View {
        content.environment(\.colorScheme, store.theme.colorScheme ?? scheme)
    }
}

extension View {
    func developerToolsThemed() -> some View { DeveloperToolsThemed(content: self) }
}
