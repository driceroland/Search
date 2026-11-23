import SwiftUI

private struct TabShortcutNumbers: EnvironmentKey {
    static let defaultValue: [UUID: Int] = [:]
}

extension EnvironmentValues {
    var tabShortcutNumbers: [UUID: Int] {
        get { self[TabShortcutNumbers.self] }
        set { self[TabShortcutNumbers.self] = newValue }
    }
}

struct TabShortcutNumber: View {
    let number: Int

    var body: some View {
        Text(String(number))
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Palette.ink.opacity(0.65))
            .frame(width: 15, height: 15)
            .allowsHitTesting(false)
            .accessibilityLabel("Command \(number)")
    }
}
