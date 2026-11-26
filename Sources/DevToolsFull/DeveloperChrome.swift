import SwiftUI

// Search's own sheet, card and pill, as the package's settings and command
// menu draw them.

struct PanelSheet<Panel: View>: View {
    let close: () -> Void
    @ViewBuilder let panel: () -> Panel

    var body: some View {
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
}

extension View {
    /// The plate's card: the page's white, rounded, a hairline round it and
    /// the shadow that lifts it off the window.
    func plateCard() -> some View {
        background(Palette.ground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.16), radius: 34, y: 12)
    }
}

struct PillStyle: ButtonStyle {
    var filled = false
    var tint: Color = Palette.ink

    func makeBody(configuration: Configuration) -> some View {
        Capsule_(configuration: configuration, filled: filled, tint: tint)
    }

    private struct Capsule_: View {
        let configuration: ButtonStyleConfiguration
        let filled: Bool
        let tint: Color
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 11.5))
                .lineLimit(1)
                .foregroundStyle(filled ? Palette.ground : tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(filled ? Palette.ink : (hovering || configuration.isPressed ? Palette.hover : Palette.ground),
                            in: Capsule())
                .overlay(Capsule().strokeBorder(filled ? .clear : Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 && enabled }
                .animation(Motion.quick, value: hovering)
        }
    }
}

struct SettingsRailRow: View {
    let icon: String
    let title: String
    let on: Bool
    /// While searching: how many rows of this section match.
    let count: Int?
    let chosen: Namespace.ID
    /// Its icon alone, the title its tooltip: in a card too narrow for both.
    var compact = false
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                if !compact {
                    Text(title)
                        .font(.system(size: 13, weight: on ? .medium : .regular))
                }
                Spacer(minLength: 0)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(Palette.ground, in: Capsule())
                }
            }
            .foregroundStyle(on ? Palette.ink : (hovering ? Palette.ink.opacity(0.75) : Palette.muted))
            .opacity(count == 0 ? 0.4 : 1)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.ground)
                        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                        .matchedGeometryEffect(id: "chosen", in: chosen)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.hover)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(compact ? title : "")
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}
