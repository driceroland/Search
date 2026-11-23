import SwiftUI

/// DevTools' sheets, drawn the way the browser draws a panel over a page
/// (PanelSheet): the window dimmed under a card. An AppKit sheet would
/// hang from the window's title bar, grey out its close light and leave
/// the other two lit; this keeps the window's lights as they always are,
/// over the same dimmed ground as everything else.
///
/// A view asks for one with `.developerSheet(isPresented:)` or
/// `.developerSheet(item:)`, as it would `.sheet`; whichever window holds
/// DevTools draws it (DeveloperSheetLayer). Its content closes itself with
/// `@Environment(\.developerDismiss)`, as with `\.dismiss`.
@MainActor
final class DeveloperSheets: ObservableObject {
    static let shared = DeveloperSheets()

    struct Front {
        let id: UUID
        let content: AnyView
        let close: () -> Void
    }

    @Published private(set) var front: Front?

    func present(id: UUID, content: AnyView, close: @escaping () -> Void) {
        front = Front(id: id, content: content, close: close)
    }

    /// Takes down the sheet `id` asked for, if it is still the one up.
    func withdraw(_ id: UUID) {
        if front?.id == id { front = nil }
    }

    /// Esc, a click on the dimmed ground, the card's own cross.
    func closeFront() {
        front?.close()
    }
}

/// What a DevTools sheet's content calls to close itself.
struct DeveloperDismissAction {
    var close: () -> Void = {}
    func callAsFunction() { close() }
}

private struct DeveloperDismissKey: EnvironmentKey {
    static let defaultValue = DeveloperDismissAction()
}

extension EnvironmentValues {
    var developerDismiss: DeveloperDismissAction {
        get { self[DeveloperDismissKey.self] }
        set { self[DeveloperDismissKey.self] = newValue }
    }
}

extension View {
    func developerSheet<Sheet: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                     @ViewBuilder content: @escaping () -> Sheet) -> some View {
        modifier(DeveloperSheetModifier(isPresented: isPresented, onDismiss: onDismiss, sheet: content))
    }

    func developerSheet<Item: Identifiable, Sheet: View>(item: Binding<Item?>,
                                                         @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
        modifier(DeveloperItemSheetModifier(item: item, sheet: content))
    }
}

private struct DeveloperSheetModifier<Sheet: View>: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    let sheet: () -> Sheet
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented, initial: true) { was, shown in
                let sheets = DeveloperSheets.shared
                if shown {
                    sheets.present(id: id, content: AnyView(sheet())) { isPresented = false }
                } else {
                    sheets.withdraw(id)
                    if was { onDismiss?() }
                }
            }
            .onDisappear { DeveloperSheets.shared.withdraw(id) }
    }
}

private struct DeveloperItemSheetModifier<Item: Identifiable, Sheet: View>: ViewModifier {
    @Binding var item: Item?
    let sheet: (Item) -> Sheet
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: item?.id, initial: true) { _, _ in
                let sheets = DeveloperSheets.shared
                if let item {
                    sheets.present(id: id, content: AnyView(sheet(item))) { self.item = nil }
                } else {
                    sheets.withdraw(id)
                }
            }
            .onDisappear { DeveloperSheets.shared.withdraw(id) }
    }
}

/// Where DevTools' sheets are drawn: over the tools themselves, docked or
/// in their own window.
struct DeveloperSheetLayer: View {
    @ObservedObject private var sheets = DeveloperSheets.shared
    @ObservedObject private var tools = DeveloperTools.shared

    private var here: Bool { tools.session != nil }

    var body: some View {
        ZStack {
            if let front = sheets.front, here {
                PanelSheet(close: front.close) {
                    front.content
                        .environment(\.developerDismiss, DeveloperDismissAction(close: front.close))
                        .tint(DeveloperToolsStyle.tint)
                        .toggleStyle(.developerCheckbox)
                        .buttonStyle(PillStyle())
                        .plateCard()
                        .padding(24)
                }
                .id(front.id)
            }
        }
        .animation(Motion.reduced ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: sheets.front?.id)
    }
}
