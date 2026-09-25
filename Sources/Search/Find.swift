import SwiftUI

/// Looking for a word on the page. A pill in the top corner, the same white and
/// hairline as everything else that floats, and gone the moment it isn't wanted.
struct FindBar: View {
    @ObservedObject var window: WindowModel

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                if window.needle.isEmpty {
                    Text("Find on page")
                        .foregroundStyle(Palette.ink.opacity(0.3))
                }
                TextField("", text: $window.needle)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .focused($focused)
                    .onSubmit { window.look(forward: true) }
            }
            .font(.system(size: 12.5))
            .frame(width: 160)

            step("chevron.up") { window.look(forward: false) }
            step("chevron.down") { window.look(forward: true) }
            step("xmark") { window.closeFind() }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Palette.ground, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                window.missed ? Color.red.opacity(0.35) : Palette.hairline,
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.10), radius: 18, y: 5)
        .padding(.top, 12)
        .padding(.trailing, 14)
        .animation(Motion.quick, value: window.missed)
        .onAppear { focused = true }
        .onChange(of: window.findFocus) { _, _ in focused = true }
    }

    private func step(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
