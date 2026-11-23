import SwiftUI

/// DevTools' checkbox, as Chrome has one, in the browser's ink rather than
/// the system accent: filled in ink with a white tick when on, an outlined
/// square when off, as the browser's own Switch is ink on its ground.
///
/// A custom style can't see `.labelsHidden()`, so it always draws the
/// label: a checkbox standing alone gives an empty one,
/// `Toggle(isOn:) { EmptyView() }`, and says what it is with
/// `.accessibilityLabel(_:)`.
struct DeveloperCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Box(configuration: configuration)
    }

    private struct Box: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let on = configuration.isOn || configuration.isMixed
            Button { configuration.isOn.toggle() } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(on ? Palette.ink : Palette.ground)
                        .overlay {
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .strokeBorder(on ? Color.clear : Palette.muted.opacity(0.7), lineWidth: 1)
                        }
                        .overlay {
                            if on {
                                Image(systemName: configuration.isMixed ? "minus" : "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Palette.ground)
                            }
                        }
                        .frame(width: 13, height: 13)
                    configuration.label
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : 0.45)
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(configuration.isOn ? "on" : "off")
        }
    }
}

extension ToggleStyle where Self == DeveloperCheckboxStyle {
    static var developerCheckbox: DeveloperCheckboxStyle { DeveloperCheckboxStyle() }
}

/// A text field in DevTools' Settings, as the browser's Settings draws its
/// own: the page's white inside a hairline, rounded. A style rather than a
/// frame, so set on a card or a stack it reaches each field inside alone.
struct DeveloperSettingsFieldStyle: TextFieldStyle {
    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

extension View {
    func developerSettingsField() -> some View {
        textFieldStyle(DeveloperSettingsFieldStyle())
    }
}

/// One titled field in a settings card: the browser's Line with the field
/// where its control goes, every field the same width so they line up.
struct DeveloperSettingsFieldLine<Field: View>: View {
    let title: String
    @ViewBuilder let field: () -> Field

    init(_ title: String, @ViewBuilder field: @escaping () -> Field) {
        self.title = title
        self.field = field
    }

    var body: some View {
        Line(title) { field().frame(width: 260) }
    }
}

/// A heading over a group of settings, as the browser's Settings heads its
/// groups (GroupBlock).
struct DeveloperSettingsHeading: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Palette.ink.opacity(0.62))
            .padding(.leading, 2)
    }
}

/// A titled card of settings: the heading, then the lines in one hairline
/// box, as the browser's Settings groups its own (GroupBlock, Card). Every
/// field inside takes the settings field's look.
struct DeveloperSettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DeveloperSettingsHeading(title)
            Card { content() }
                .developerSettingsField()
        }
    }
}

/// The last line of a settings card: a field with its button, or the
/// card's own action, in a Line's insets.
struct DeveloperSettingsFoot<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) { content() }
            .developerSettingsField()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }
}

/// A line of explanation beside the cards, in the muted small type the
/// browser's Settings gives its own.
struct DeveloperSettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 2)
    }
}
