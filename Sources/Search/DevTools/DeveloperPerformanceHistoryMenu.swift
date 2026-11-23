import SwiftUI

/// Chrome's recording history in the Performance toolbar: a menu of this
/// session's last recordings, newest first, the one shown ticked; choosing
/// another shows it in place, with its annotations.
struct DeveloperPerformanceHistoryMenu: View {
    let entries: [DeveloperPerformanceRecordings.Entry]
    /// The recording shown, by its key.
    let current: String
    let choose: (DeveloperPerformanceRecordings.Entry) -> Void

    var body: some View {
        Menu {
            ForEach(entries) { entry in
                Toggle(entry.title, isOn: Binding(get: { entry.id == current }, set: { _ in choose(entry) }))
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recordings in this session (up to \(DeveloperPerformanceRecordings.limit))")
        .accessibilityLabel("Recording history")
        .accessibilityIdentifier("developer-performance-history")
    }
}
