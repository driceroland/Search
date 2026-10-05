import SwiftUI

/// Window-centred controls, independent of the tab column and its hover state.
/// No full-width backing view: the page remains visible between the islands.
struct FloatingNavigation: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var refused = false

    private var editing: Bool { browser.fieldShowing }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                navigationButton("chevron.left", label: L("Back"), enabled: tab.canGoBack) { browser.back() }
                navigationButton("chevron.right", label: L("Forward"), enabled: tab.canGoForward) { browser.forward() }
            }
            .padding(3)
            .modifier(NavigationGlass())

            address
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) {
                    if editing, !browser.offers.isEmpty || browser.siteOffer != nil {
                        Omnibox(browser: browser, over: false).suggestions
                            .padding(.top, 46)
                    }
                }
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 20)
        .onChange(of: browser.refusals) { _, _ in refused = true }
        .onChange(of: browser.typed) { _, _ in refused = false }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: editing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Navigation"))
    }

    private var address: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.shy ? "eye.slash" : (tab.address?.scheme == "https" ? "lock" : "globe"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if editing {
                if let site = browser.siteChip { SiteChip(site: site) }
                AddressField(browser: browser, fontSize: 13)
                    .frame(height: 24)
                    .accessibilityLabel(L("Address or search"))
            } else {
                Button { browser.edit() } label: {
                    Text(tab.address.map(Self.displayAddress) ?? L("Address or search"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Edit address   ⌘L"))
                .accessibilityLabel(L("Address or search"))
                .accessibilityValue(tab.address.map(Self.displayAddress) ?? "")
            }
            if refused {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .help(L("Enter a valid address or search"))
                    .accessibilityLabel(L("Enter a valid address or search"))
            }
            navigationButton(tab.loading ? "xmark" : "arrow.clockwise",
                             label: tab.loading ? L("Stop") : L("Reload"), enabled: !tab.isBlank) {
                if tab.loading { tab.stop() } else { browser.reload() }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 3)
        .frame(height: 40)
        .modifier(NavigationGlass())
        .overlay(alignment: .bottom) {
            if tab.loading {
                ProgressView(value: tab.progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 180)
                    .padding(.bottom, 3)
                    .accessibilityLabel(L("Loading"))
            }
        }
    }

    private func navigationButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 32, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(NavigationButtonStyle())
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    /// Never reveal credentials embedded in a URL, including its resting label.
    static func displayAddress(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        parts.user = nil
        parts.password = nil
        guard let safe = parts.url else { return "" }
        return Address.editable(safe)
    }
}

private struct NavigationGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5).allowsHitTesting(false))
                .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
        }
    }
}

private struct NavigationButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary.opacity(enabled ? 0.9 : 0.28))
            .background(.primary.opacity(enabled && (hovering || configuration.isPressed) ? 0.09 : 0), in: Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
    }
}
