import SwiftUI

/// Looking for a word on the page. A pill in the top corner, the same white and
/// hairline as everything else that floats, and gone the moment it isn't wanted.
struct FindBar: View {
    @ObservedObject var browser: Browser

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                if browser.needle.isEmpty {
                    Text(L("Find on page"))
                        .foregroundStyle(Palette.ink.opacity(0.3))
                }
                TextField("", text: $browser.needle)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .focused($focused)
                    .onSubmit { browser.look(forward: true) }
            }
            .font(.system(size: 12.5))
            .frame(width: 160)

            step("chevron.up") { browser.look(forward: false) }
            step("chevron.down") { browser.look(forward: true) }
            step("xmark") { browser.closeFind() }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Palette.ground, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                browser.missed ? Color.red.opacity(0.35) : Palette.hairline,
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.10), radius: 18, y: 5)
        .padding(.top, 12)
        .padding(.trailing, 14)
        .animation(Motion.quick, value: browser.missed)
        .onAppear { focused = true }
        .onChange(of: browser.findFocus) { _, _ in focused = true }
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
