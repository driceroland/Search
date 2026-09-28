import SwiftUI
import WebKit

/// Looking for a word on the page. A pill in the top corner, the same white and
/// hairline as everything else that floats, and gone the moment it isn't wanted.
struct FindBar: View {
    @ObservedObject var find: FindSession
    var availableWidth: CGFloat? = nil

    @FocusState private var focused: Bool

    private var narrow: Bool { availableWidth.map { $0 < 290 } ?? false }
    private var fieldWidth: CGFloat {
        guard let availableWidth else { return 150 }
        return max(40, min(160, availableWidth - (narrow ? 80 : 130)))
    }

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                if find.needle.isEmpty {
                    Text("Find on page")
                        .foregroundStyle(Palette.ink.opacity(0.3))
                }
                TextField("", text: $find.needle)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .accessibilityLabel("Find on page")
                    .accessibilityHint("Type text to search this page. Press Return to find the next match.")
                    .focused($focused)
                    .onSubmit { find.look(forward: true) }
            }
            .font(.system(size: 12.5))
            .frame(width: fieldWidth)

            // "3 of 17", as the page counted it.
            if let status = find.findStatus {
                Text(status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(find.missed ? Color.red.opacity(0.8) : Palette.muted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityLabel(status)
                    .accessibilityIdentifier("Find result status")
            }

            // A pane too narrow for them keeps Return and ⇧Return instead.
            if !narrow {
                step("chevron.up", label: "Previous match", help: "Find the previous match.") {
                    find.look(forward: false)
                }
                step("chevron.down", label: "Next match", help: "Find the next match.") {
                    find.look(forward: true)
                }
            }

            Menu {
                Toggle("Match case", isOn: $find.matchCase)
                    .help("Match uppercase and lowercase letters exactly.")
                Toggle("Whole words", isOn: $find.wholeWords)
                    .disabled(find.findResult?.nativeFallback == true && !find.wholeWords)
                    .help("Match complete words. This option is unavailable for PDF pages.")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(find.matchCase || find.wholeWords ? Palette.ink : Palette.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Search options")
            .accessibilityHint("Choose whether to match case or whole words.")
            .help("Search options")

            step("xmark", label: "Close Find on Page", help: "Close the find field and clear its selection.") {
                find.close()
            }
        }
        .padding(.leading, narrow ? 10 : 16)
        .padding(.trailing, narrow ? 6 : 8)
        .padding(.vertical, 8)
        .background(Palette.ground, in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                find.missed ? Color.red.opacity(0.35) : Palette.hairline,
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.10), radius: 18, y: 5)
        .padding(.top, 12)
        .padding(.trailing, 14)
        .animation(Motion.quick, value: find.missed)
        .onAppear(perform: focus)
        .onChange(of: find.findFocus) { _, _ in focus() }
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

    private func step(
        _ icon: String,
        label: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(help)
        .help(help)
    }
}

/// ⌘F's state and its questions to one page: what is typed, the options,
/// and the page's last answer. The browser's window has one for whichever
/// tab is on screen; a link's small window (Little.swift) has one for its
/// page. `target` names the page to look on, asked each time, so a tab
/// changing under an open bar is noticed by the answers it drops.
@MainActor
final class FindSession: ObservableObject {
    private let target: () -> Tab?

    init(target: @escaping () -> Tab?) { self.target = target }

    @Published var finding = false
    // The same words written back (the field does, as it appears) aren't
    // a Next: Return and the buttons ask for that themselves.
    @Published var needle = "" {
        didSet { if !resettingFind, oldValue != needle { look(forward: true) } }
    }
    @Published var matchCase = false {
        didSet { if !resettingFind, oldValue != matchCase { look(forward: true) } }
    }
    @Published var wholeWords = false {
        didSet { if !resettingFind, oldValue != wholeWords { look(forward: true) } }
    }
    /// Set when the page doesn't hold what was asked for.
    @Published private(set) var missed = false
    @Published private(set) var findFocus = 0
    /// The count and which match is current, as the page last answered.
    @Published private(set) var findResult: PageFind.Result?

    private let pageFind = PageFind()
    private struct FindSpec: Equatable {
        let tab: Tab.ID
        let query: String
        let matchCase: Bool
        let wholeWords: Bool
    }
    private var findSpec: FindSpec?
    /// Goes up whenever what is looked for, or the page it is looked for on,
    /// changes: an answer for an older one is dropped.
    private var findGeneration: UInt64 = 0
    /// One question to the page at a time. Letters typed while it answers
    /// wait here, and only the last of them is asked next: on a long page
    /// every letter would otherwise queue a whole search of its own.
    private var findAsking: UInt64?
    private var findAsked: UInt64 = 0
    /// A new search not yet asked, and Next / Previous presses not yet sent.
    private var findFresh = false
    private var findSteps = 0
    private var resettingFind = false
    private weak var findWeb: WKWebView?

    /// A question to the page not answered yet, or one waiting to be asked.
    var findBusy: Bool { findAsking != nil || findFresh || findSteps != 0 }

    var findStatus: String? {
        guard !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let result = findResult else { return nil }
        guard result.available else { return "Search unavailable" }
        if result.nativeFallback {
            if wholeWords && !result.wholeWordsAvailable { return "Whole words unavailable" }
            return result.found ? "Match found" : "No matches"
        }
        guard let index = result.index, let count = result.count, count > 0 else { return "No matches" }
        return "\(index) of \(count)\(result.more ? "+" : "")"
    }

    func open() {
        guard target()?.isBlank == false else { return }
        finding = true
        findFocus += 1
    }

    func close() {
        guard finding || !needle.isEmpty || findResult != nil else { return }
        // The page's own selection back, and the match's highlight gone.
        resetFindState()
        // The keyboard back to the page, as in Safari. Left with the window,
        // the Mac's keyboard navigation handed it to the first button next.
        if let web = target()?.built, let window = web.window,
           window.firstResponder === window || window.firstResponder is NSText {
            window.makeFirstResponder(web)
        }
    }

    func look(forward: Bool) {
        guard let tab = target() else {
            missed = false
            findResult = nil
            return
        }

        guard !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            missed = false
            findResult = nil
            guard findSpec != nil || findWeb != nil else { return }
            let web = findWeb ?? tab.built
            forgetFind()
            if let web { clearFind(on: web) }
            return
        }

        let web = tab.web
        let spec = FindSpec(tab: tab.id, query: needle, matchCase: matchCase, wholeWords: wholeWords)
        if findSpec != spec || findWeb !== web {
            findGeneration &+= 1
            findSpec = spec
            findWeb = web
            findFresh = true
            findSteps = 0
        } else {
            findSteps += forward ? 1 : -1
        }
        askFind()
    }

    /// A page that has just come in under an open bar: look for the same
    /// words on it.
    func pageArrived() {
        guard finding, findSpec == nil,
              !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        look(forward: true)
    }

    /// A tab or document changed under an open find bar. Keep what was typed,
    /// but retire every result and callback tied to the page that just left.
    func pageLeft(retry: Bool) {
        let web = findWeb
        forgetFind()
        findResult = nil
        missed = false
        if let web { clearFind(on: web) }
        guard retry, finding,
              !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let tab = target(), !tab.loading, !tab.isBlank else { return }
        look(forward: true)
    }

    /// Sends what is waiting to the page, unless a question is still out:
    /// its answer sends the next one.
    private func askFind() {
        guard findAsking == nil, let spec = findSpec, let web = findWeb,
              findFresh || findSteps != 0 else { return }
        findAsked &+= 1
        let asking = findAsked
        let generation = findGeneration
        let steps = findSteps
        findAsking = asking
        findFresh = false
        findSteps = 0
        Task { [weak self, weak web] in
            guard let self else { return }
            guard let web, self.target()?.id == spec.tab, self.target()?.built === web else {
                if self.findAsking == asking { self.findAsking = nil }
                return
            }
            let result = await self.pageFind.update(
                on: web,
                query: spec.query,
                matchCase: spec.matchCase,
                wholeWords: spec.wholeWords,
                steps: steps,
                generation: generation
            )
            // Something newer took over while the page was answering.
            guard self.findAsking == asking else { return }
            self.findAsking = nil
            if !result.stale, self.findGeneration == generation, self.findSpec == spec,
               self.target()?.id == spec.tab, self.target()?.built === web {
                self.findResult = result
                self.missed = result.available && !result.found
                    && (!result.nativeFallback || !spec.wholeWords || result.wholeWordsAvailable)
            }
            self.askFind()
        }
    }

    /// Nothing asked or waiting any more; whatever answer is out is dropped.
    private func forgetFind() {
        findGeneration &+= 1
        findSpec = nil
        findWeb = nil
        findAsking = nil
        findFresh = false
        findSteps = 0
    }

    private func clearFind(on web: WKWebView) {
        let generation = findGeneration
        Task { [pageFind] in _ = await pageFind.clear(on: web, generation: generation) }
    }

    private func resetFindState() {
        let web = findWeb
        forgetFind()
        resettingFind = true
        finding = false
        needle = ""
        matchCase = false
        wholeWords = false
        resettingFind = false
        findResult = nil
        missed = false
        if let web { clearFind(on: web) }
    }
}
