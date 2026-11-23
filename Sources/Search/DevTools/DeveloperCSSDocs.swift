import AppKit
import SwiftUI

/// Elements › Styles' CSS documentation tooltip, as in Chrome DevTools: a
/// short description of a hovered property's name and a "Learn more" link
/// to MDN. The descriptions are Search's own, for the common properties, in
/// Resources/data/DeveloperCSSDocs-properties.json (build.sh copies it into
/// the app); an unknown property has none, and no tooltip.
enum DeveloperCSSDocs {
    /// Settings › Preferences › Elements › "Show CSS documentation tooltip".
    static let settingKey = "developerShowCSSDocumentation"

    static let fileName = "DeveloperCSSDocs-properties.json"

    static let descriptions: [String: String] = load()

    static func load() -> [String: String] {
        DevToolsResources.decode([String: String].self, named: fileName) ?? [:]
    }

    /// The description of a property by its name, in any case; nil for a
    /// custom property or one not in the table.
    static func description(for property: String) -> String? {
        let name = property.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.hasPrefix("--") else { return nil }
        return descriptions[name]
    }

    /// The property's page on MDN.
    static func learnMore(_ property: String) -> URL? {
        let name = property.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return URL(string: "https://developer.mozilla.org/en-US/docs/Web/CSS/" + name)
    }
}

/// The tooltip on a property name: shown after a moment's hover, kept
/// while the pointer is over it, so its link can be clicked.
struct DeveloperCSSDocsHover: ViewModifier {
    let property: String
    @AppStorage(DeveloperCSSDocs.settingKey) private var enabled = true
    @State private var shown = false
    @State private var overName = false
    @State private var overTip = false
    @State private var pending: DispatchWorkItem?

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled, let text = DeveloperCSSDocs.description(for: property) {
            content
                .onHover { inside in
                    overName = inside
                    schedule()
                }
                .popover(isPresented: $shown, arrowEdge: .bottom) { tip(text) }
        } else {
            content
        }
    }

    private func schedule() {
        pending?.cancel()
        let opening = overName || overTip
        let item = DispatchWorkItem { shown = overName || overTip }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (opening ? 0.6 : 0.3), execute: item)
    }

    private func tip(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(property).font(DeveloperToolsStyle.code).fontWeight(.semibold)
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            if let url = DeveloperCSSDocs.learnMore(property) {
                Button {
                    shown = false
                    _ = Browsers.acting.open(url, foreground: true)
                } label: {
                    Text("Learn more").underline().foregroundStyle(DeveloperToolsStyle.tint)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .help(url.absoluteString)
            }
        }
        .padding(10)
        .frame(width: 260, alignment: .leading)
        .onHover { inside in
            overTip = inside
            schedule()
        }
    }
}

extension View {
    /// Chrome's CSS documentation tooltip on a property name.
    func developerCSSDocs(_ property: String) -> some View {
        modifier(DeveloperCSSDocsHover(property: property))
    }
}
