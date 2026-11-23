import SwiftUI

/// One look for every tab in DevTools: the panel strip, the drawer, a
/// sidebar's sections, a request's details, Sources' navigator and open
/// files. The chosen tab is lifted in the selected grey and set in ink and
/// semibold, as the browser's own rail and segmented controls mark the
/// chosen one with a fill, never a line; the rest are muted and wash on
/// hover. Tabs that close add their cross inside the label.
extension View {
    func developerTab(selected: Bool) -> some View {
        modifier(DeveloperTabLook(selected: selected))
    }
}

private struct DeveloperTabLook: ViewModifier {
    let selected: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .fontWeight(selected ? .semibold : .regular)
            .lineLimit(1)
            .foregroundStyle(selected ? Palette.ink : hovering ? Palette.ink.opacity(0.75) : Color.secondary)
            .padding(.horizontal, 6)
            .frame(height: DeveloperToolsStyle.controlHeight)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius).fill(DeveloperToolsStyle.selected)
                } else if hovering {
                    RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius).fill(DeveloperToolsStyle.raised)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A row of tabs over a pane: the chrome's grey, the toolbar's height,
/// scrolling sideways when it is too narrow. Anything before or after the
/// tabs (a close button, a pane's own controls) goes in `leading` and
/// `trailing`.
struct DeveloperTabBar<Item: Hashable, Leading: View, Trailing: View>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    var identifier: ((Item) -> String)?
    /// False where the tabs share a toolbar with controls that should give
    /// way first (a filter field): the tabs then keep their width.
    var scrolls = true
    let leading: Leading
    let trailing: Trailing

    init(_ items: [Item], selection: Binding<Item>, title: @escaping (Item) -> String,
         identifier: ((Item) -> String)? = nil, scrolls: Bool = true,
         @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.scrolls = scrolls
        self.items = items
        _selection = selection
        self.title = title
        self.identifier = identifier
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 0) {
            leading
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                ForEach(items, id: \.self) { item in
                    Button { selection = item } label: {
                        Text(title(item)).developerTab(selected: selection == item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(identifier?(item) ?? "")
                }
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .modifier(Strip(scrolls: scrolls))
            trailing
        }
        .frame(height: DeveloperToolsStyle.toolbarHeight)
        .background(DeveloperToolsStyle.chrome)
    }
}

private struct Strip: ViewModifier {
    let scrolls: Bool

    func body(content: Content) -> some View {
        if scrolls {
            content.developerTabStrip()
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)
        } else {
            content.fixedSize(horizontal: true, vertical: false)
        }
    }
}

extension DeveloperTabBar where Leading == EmptyView {
    init(_ items: [Item], selection: Binding<Item>, title: @escaping (Item) -> String,
         identifier: ((Item) -> String)? = nil, scrolls: Bool = true, @ViewBuilder trailing: () -> Trailing) {
        self.init(items, selection: selection, title: title, identifier: identifier, scrolls: scrolls,
                  leading: { EmptyView() }, trailing: trailing)
    }
}

extension DeveloperTabBar where Leading == EmptyView, Trailing == EmptyView {
    init(_ items: [Item], selection: Binding<Item>, title: @escaping (Item) -> String,
         identifier: ((Item) -> String)? = nil, scrolls: Bool = true) {
        self.init(items, selection: selection, title: title, identifier: identifier, scrolls: scrolls,
                  leading: { EmptyView() }, trailing: { EmptyView() })
    }
}
