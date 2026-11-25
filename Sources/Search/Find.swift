import SwiftUI

/// Find on Page's words, its two switches and what the page last answered
/// (`Browser.seeking`): the find bar watches it, and nothing else has to.
@MainActor
final class FindState: ObservableObject {
    @Published var needle = ""
    @Published var matchCase = false
    @Published var wholeWords = false
    @Published var missed = false
    @Published var focus = 0
    @Published var result: PageFind.Result?
}

/// Looking for a word on the page. A small bar in the top corner, on the same
/// glass as everything else that floats, and gone the moment it isn't wanted.
struct FindBar: View {
    @ObservedObject var browser: Browser
    var availableWidth: CGFloat? = nil
    var onPillFrame: ((CGRect) -> Void)? = nil
    /// The words and the page's answer, which `browser` doesn't announce.
    @ObservedObject private var seeking: FindState

    init(browser: Browser) {
        self.browser = browser
        seeking = browser.seeking
    }

    @FocusState private var focused: Bool

    private var narrow: Bool { availableWidth.map { $0 < 320 } ?? false }
    private var fieldWidth: CGFloat {
        guard let availableWidth else { return 150 }
        return max(40, min(150, availableWidth - (narrow ? 175 : 235)))
    }

    /// The bar's corners, and how far in from them what it holds sits.
    fileprivate static let corner: CGFloat = 21
    fileprivate static let inset: CGFloat = 7

    var body: some View {
        HStack(spacing: 2) {
            // As Safari's: the words in a field of their own, what the page
            // answered inside its far end, and the arrows beside it.
            HStack(spacing: 7) {
                options

                ZStack(alignment: .leading) {
                    if browser.needle.isEmpty {
                        Text("Find on page")
                            .foregroundStyle(Palette.muted)
                    }
                    TextField("", text: $browser.needle)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Palette.ink)
                        .accessibilityLabel("Find on page")
                        .accessibilityHint("Type text to search this page. Press Return to find the next match.")
                        .focused($focused)
                        .onSubmit { browser.look(forward: true) }
                }
                .font(.system(size: 13))
                .frame(width: fieldWidth)

                // "3 of 17", as the page counted it.
                // Its room is kept, so the bar doesn't change width as one types.
                ZStack(alignment: .trailing) {
                    if let status = browser.findStatus {
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundStyle(browser.missed ? Color(nsColor: .systemRed) : Palette.muted)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                            .accessibilityLabel(status)
                            .accessibilityIdentifier("Find result status")
                    }
                }
                .frame(width: 52, alignment: .trailing)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Palette.wash, in: RoundedRectangle(
                cornerRadius: Metrics.concentric(outer: Self.corner, inset: Self.inset), style: .continuous))
            .padding(.trailing, 4)

            // A pane too narrow for them keeps Return and ⇧Return instead.
            if !narrow {
                Step(icon: "chevron.up", label: "Previous match", help: "Previous Match", shortcut: "edit.findPrevious") {
                    browser.look(forward: false)
                }
                Step(icon: "chevron.down", label: "Next match", help: "Next Match", shortcut: "edit.findNext") {
                    browser.look(forward: true)
                }
            }

            Step(icon: "xmark", label: "Close Find on Page", help: "Close the find field and clear its selection.") {
                browser.closeFind()
            }
        }
        .padding(Self.inset)
        .pill(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("find")) }) {
            onPillFrame?($0)
        }
        .padding(.top, 12)
        .padding(.trailing, 14)
        .frame(maxWidth: availableWidth == nil ? nil : .infinity,
               maxHeight: availableWidth == nil ? nil : .infinity, alignment: .topTrailing)
        .coordinateSpace(name: "find")
        .animation(Motion.quick, value: browser.missed)
        .onAppear(perform: focus)
        .onChange(of: browser.findFocus) { _, _ in focus() }
    }

    /// Into the field, and once more a moment later if it didn't take: as
    /// the bar comes in, the field may not be in the window yet, and with
    /// the Mac's keyboard navigation on, the keyboard went to the first
    /// button instead — the back button — until ⌘F was pressed again (#172).
    private func focus() {
        focused = true
        DispatchQueue.main.async {
            if !focused { focused = true }
        }
    }

    /// The magnifying glass, and the two switches under it.
    private var options: some View {
        Menu {
            Toggle("Match Case", isOn: $browser.matchCase)
                .help("Match uppercase and lowercase letters exactly.")
            Toggle("Whole Words", isOn: $browser.wholeWords)
                .disabled(browser.findResult?.nativeFallback == true && !browser.wholeWords)
                .help("Match complete words. This option is unavailable for PDF pages.")
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 6.5, weight: .bold))
            }
            .foregroundStyle(browser.matchCase || browser.wholeWords ? Palette.ink : Palette.muted)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Search options")
        .accessibilityHint("Choose whether to match case or whole words.")
        .help("Search options")
    }

    /// One of the bar's buttons: full ink, and a wash under the pointer.
    private struct Step: View {
        let icon: String
        let label: String
        let help: String
        var shortcut: String? = nil
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.concentric(outer: FindBar.corner, inset: FindBar.inset),
                                         style: .continuous)
                            .fill(hovering ? Palette.wash : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(label)
            .accessibilityHint(help)
            .shortcutHelp(help, shortcut)
        }
    }
}
